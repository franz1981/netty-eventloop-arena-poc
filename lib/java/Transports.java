import io.netty.bootstrap.Bootstrap;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.buffer.ByteBufAllocator;
import io.netty.channel.Channel;
import io.netty.channel.IoHandlerFactory;
import io.netty.channel.ServerChannel;
import io.netty.channel.epoll.Epoll;
import io.netty.channel.epoll.EpollIoHandler;
import io.netty.channel.epoll.EpollServerSocketChannel;
import io.netty.channel.epoll.EpollSocketChannel;
import io.netty.channel.nio.NioIoHandler;
import io.netty.channel.socket.nio.NioServerSocketChannel;
import io.netty.channel.socket.nio.NioSocketChannel;
import io.netty.channel.uring.AbstractIoUringBufferRingAllocator;
import io.netty.channel.uring.IoUring;
import io.netty.channel.uring.IoUringBufferRingConfig;
import io.netty.channel.uring.IoUringChannelOption;
import io.netty.channel.uring.IoUringIoHandler;
import io.netty.channel.uring.IoUringIoHandlerConfig;
import io.netty.channel.uring.IoUringServerSocketChannel;
import io.netty.channel.uring.IoUringSocketChannel;

import java.util.Locale;
import java.util.concurrent.atomic.AtomicLong;

/**
 * The one place where the PoC's servers (e2e/E2EServer, topology/TopoServer) choose a transport, so
 * that the two launchers cannot drift apart.  {@code -Dtransport=nio|epoll|io_uring}.
 *
 * <p>io_uring is configured with every feature the branch exposes AND the running kernel probes as
 * supported - the probes are {@link IoUring}'s own ({@link IoUring#featureString()} is printed by
 * {@link #describe()}), never an assumption:
 * <ul>
 *   <li>a provided buffer ring per worker loop ({@code IORING_REGISTER_PBUF_RING}), incremental when
 *       {@link IoUring#isRegisterBufferRingIncSupported()}, whose buffers are allocated <b>by the
 *       allocator under test</b>;</li>
 *   <li>{@code IO_URING_BUFFER_GROUP_ID} on the child channels, so reads consume that ring;</li>
 *   <li>{@code IO_URING_WRITE_ZERO_COPY_THRESHOLD}, so writes at or above it are submitted as
 *       {@code SEND_ZC}/{@code SENDMSG_ZC} when the kernel supports those opcodes;</li>
 *   <li>{@code setSingleIssuer(true)} (which also lets netty use {@code DEFER_TASKRUN}), plus an
 *       explicit ring size and CQ size.</li>
 * </ul>
 *
 * <p><b>Buffer lifetimes.</b> A ring buffer is handed to the kernel and only comes back when the
 * kernel has filled it: it is alive across an unbounded number of event-loop iterations, and every
 * read hands the pipeline a {@code retainedSlice} of it.  Zero-copy writes keep the written buffer
 * alive until the completion notification.  Both are lifetime class D (kernel-owned) for an
 * iteration-scoped allocator.
 */
final class Transports {

    static final String NAME = System.getProperty("transport", "nio").toLowerCase(Locale.ROOT);

    // --- io_uring knobs (defaults are what the reported runs used) --------------------------------
    static final int RING_SIZE = Integer.getInteger("iouring.ringSize", 128);
    static final int CQ_SIZE = Integer.getInteger("iouring.cqSize", 4096);
    static final int BUFFER_RING_SIZE = Integer.getInteger("iouring.bufferRingSize", 64);
    static final int BUFFER_CHUNK = Integer.getInteger("iouring.bufferChunk", 8192);
    static final short BUFFER_GROUP_ID = (short) Integer.getInteger("iouring.bufferGroupId", 1).intValue();
    static final int ZERO_COPY_THRESHOLD = Integer.getInteger("iouring.zeroCopyThreshold", 4096);
    static final boolean SINGLE_ISSUER = Boolean.parseBoolean(System.getProperty("iouring.singleIssuer", "true"));

    /** Buffers allocated into a provided buffer ring, and buffers taken back out of one. */
    static final AtomicLong RING_ALLOCS = new AtomicLong();
    static final AtomicLong RING_READS = new AtomicLong();
    static final AtomicLong RING_READ_BYTES = new AtomicLong();

    private static volatile String ringDescription = "(no buffer ring)";

    private Transports() { }

    static boolean isIoUring() { return "io_uring".equals(NAME) || "iouring".equals(NAME); }
    static boolean isEpoll() { return "epoll".equals(NAME); }
    static boolean isNio() { return !isIoUring() && !isEpoll(); }

    /** Acceptor loop: no buffer ring (nothing is read on it). */
    static IoHandlerFactory bossFactory() {
        if (isIoUring()) {
            IoUring.ensureAvailability();
            return IoUringIoHandler.newFactory(baseConfig());
        }
        if (isEpoll()) {
            Epoll.ensureAvailability();
            return EpollIoHandler.newFactory();
        }
        return NioIoHandler.newFactory();
    }

    /**
     * Worker loops.  For io_uring every loop registers its own provided buffer ring, filled from
     * {@code allocator} - the allocator under test - on the loop's own thread.
     */
    static IoHandlerFactory workerFactory(ByteBufAllocator allocator) {
        if (isIoUring()) {
            IoUring.ensureAvailability();
            IoUringIoHandlerConfig config = baseConfig();
            if (IoUring.isRegisterBufferRingSupported() && BUFFER_RING_SIZE > 0) {
                boolean incremental = Boolean.parseBoolean(System.getProperty("iouring.incremental",
                        Boolean.toString(IoUring.isRegisterBufferRingIncSupported())));
                IoUringBufferRingConfig ring = IoUringBufferRingConfig.builder()
                        .bufferGroupId(BUFFER_GROUP_ID)
                        .bufferRingSize((short) BUFFER_RING_SIZE)
                        .batchSize(Math.max(1, BUFFER_RING_SIZE / 2))
                        .incremental(incremental)
                        .batchAllocation(false)
                        .allocator(new CountingRingAllocator(allocator, BUFFER_CHUNK))
                        .build();
                config.setBufferRingConfig(ring);
                ringDescription = "bgId=" + BUFFER_GROUP_ID + " entries=" + BUFFER_RING_SIZE
                        + " chunk=" + BUFFER_CHUNK + " incremental=" + incremental
                        + " batchSize=" + Math.max(1, BUFFER_RING_SIZE / 2) + " batchAllocation=false";
            } else {
                ringDescription = "(buffer ring unsupported or disabled)";
            }
            return IoUringIoHandler.newFactory(config);
        }
        if (isEpoll()) {
            Epoll.ensureAvailability();
            return EpollIoHandler.newFactory();
        }
        return NioIoHandler.newFactory();
    }

    private static IoUringIoHandlerConfig baseConfig() {
        IoUringIoHandlerConfig config = new IoUringIoHandlerConfig();
        config.setRingSize(RING_SIZE);
        config.setSingleIssuer(SINGLE_ISSUER);
        try {
            config.setCqSize(CQ_SIZE);
        } catch (RuntimeException ignored) {
            // IORING_SETUP_CQSIZE unsupported on this kernel: keep the default.
        }
        return config;
    }

    static Class<? extends ServerChannel> serverChannel() {
        if (isIoUring()) { return IoUringServerSocketChannel.class; }
        if (isEpoll()) { return EpollServerSocketChannel.class; }
        return NioServerSocketChannel.class;
    }

    static Class<? extends Channel> clientChannel() {
        if (isIoUring()) { return IoUringSocketChannel.class; }
        if (isEpoll()) { return EpollSocketChannel.class; }
        return NioSocketChannel.class;
    }

    /** Transport-specific options for accepted (child) channels. */
    static void childOptions(ServerBootstrap b) {
        if (isIoUring()) {
            if (IoUring.isRegisterBufferRingSupported() && BUFFER_RING_SIZE > 0) {
                b.childOption(IoUringChannelOption.IO_URING_BUFFER_GROUP_ID, BUFFER_GROUP_ID);
            }
            if (ZERO_COPY_THRESHOLD >= 0) {
                b.childOption(IoUringChannelOption.IO_URING_WRITE_ZERO_COPY_THRESHOLD, ZERO_COPY_THRESHOLD);
            }
        }
    }

    /** The same options for a channel this process opens itself (the proxy workload's outbound leg). */
    static void clientOptions(Bootstrap b) {
        if (isIoUring()) {
            if (IoUring.isRegisterBufferRingSupported() && BUFFER_RING_SIZE > 0) {
                b.option(IoUringChannelOption.IO_URING_BUFFER_GROUP_ID, BUFFER_GROUP_ID);
            }
            if (ZERO_COPY_THRESHOLD >= 0) {
                b.option(IoUringChannelOption.IO_URING_WRITE_ZERO_COPY_THRESHOLD, ZERO_COPY_THRESHOLD);
            }
        }
    }

    /**
     * Reads the two io_uring channel options back off a live child channel.  This says the option was
     * accepted and stored by the channel config; it does NOT say a SEND_ZC was ever submitted.
     */
    static String childOptionsReadBack(Channel ch) {
        if (!isIoUring()) {
            return "transport=" + NAME + " (no io_uring child options)";
        }
        Object bg = ch.config().getOption(IoUringChannelOption.IO_URING_BUFFER_GROUP_ID);
        Object zc = ch.config().getOption(IoUringChannelOption.IO_URING_WRITE_ZERO_COPY_THRESHOLD);
        return "IO_URING_BUFFER_GROUP_ID=" + bg + " IO_URING_WRITE_ZERO_COPY_THRESHOLD=" + zc;
    }

    /** One line naming the transport and, for io_uring, the kernel's own feature probe. */
    static String describe() {
        if (isIoUring()) {
            return "transport=io_uring ringSize=" + RING_SIZE + " cqSize=" + CQ_SIZE
                    + " singleIssuer=" + SINGLE_ISSUER + " bufferRing[" + ringDescription + "]"
                    + " zeroCopyThreshold=" + ZERO_COPY_THRESHOLD
                    + " | " + IoUring.featureString();
        }
        if (isEpoll()) {
            return "transport=epoll available=" + Epoll.isAvailable();
        }
        return "transport=nio";
    }

    /** Buffer-ring telemetry: zero reads means the ring was never consumed. */
    static String ringCounters() {
        return "RINGTELE transport=" + NAME + " ringAllocs=" + RING_ALLOCS.get()
                + " ringReads=" + RING_READS.get() + " ringReadBytes=" + RING_READ_BYTES.get()
                + " " + ringDescription;
    }

    /**
     * A fixed-size ring allocator that counts.  {@code nextBufferSize()} is called once per buffer
     * put into the ring, {@code lastBytesRead} once per buffer taken out of it
     * (IoUringBufferRing#useBuffer is its only caller), so the two counters are "buffers provided to
     * the kernel" and "buffers the kernel filled and handed back".
     */
    static final class CountingRingAllocator extends AbstractIoUringBufferRingAllocator {
        private final int bufferSize;

        CountingRingAllocator(ByteBufAllocator allocator, int bufferSize) {
            super(allocator, false);
            this.bufferSize = bufferSize;
        }

        @Override
        protected int nextBufferSize() {
            RING_ALLOCS.incrementAndGet();
            return bufferSize;
        }

        @Override
        public void lastBytesRead(int attempted, int actual) {
            RING_READS.incrementAndGet();
            if (actual > 0) {
                RING_READ_BYTES.addAndGet(actual);
            }
        }
    }
}
