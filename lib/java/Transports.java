import io.netty.bootstrap.Bootstrap;
import io.netty.bootstrap.ServerBootstrap;
import io.netty.buffer.ByteBuf;
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
import io.netty.channel.uring.IoUringBufferRingAllocator;
import io.netty.channel.uring.IoUringBufferRingConfig;
import io.netty.channel.uring.IoUringChannelOption;
import io.netty.channel.uring.IoUringAdaptiveBufferRingAllocator;
import io.netty.channel.uring.IoUringFixedBufferRingAllocator;
import io.netty.channel.uring.IoUringIoHandler;
import io.netty.channel.uring.IoUringIoHandlerConfig;
import io.netty.channel.uring.IoUringServerSocketChannel;
import io.netty.channel.uring.IoUringSocketChannel;

import java.util.Locale;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;

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
 *       allocator under test</b> - unless {@link #BUFFER_RING} is off, see below;</li>
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
    /** Chunks per slab = {@link #BUFFER_RING_SIZE} x this.  See RegisteredSlabBufferRingAllocator. */
    static final int SLAB_DEPTH = Integer.getInteger("iouring.slabDepth", 4);

    /**
     * {@code BUFFER_RING=on|off} (or {@code -DbufferRing=}), default {@code on}.
     *
     * <p><b>on</b> - unchanged, and what every run before section 9 used: each worker loop registers
     * a provided buffer ring ({@code IORING_REGISTER_PBUF_RING}) through
     * {@link IoUringIoHandlerConfig#setBufferRingConfig}, and every child/client channel carries
     * {@code IO_URING_BUFFER_GROUP_ID}, so {@code AbstractIoUringStreamChannel.scheduleRead0()} takes
     * its {@code scheduleReadProviderBuffer()} branch: a recv with {@code IOSQE_BUFFER_SELECT} and no
     * address, the kernel picking a registered buffer and returning its bid in the CQE flags.
     *
     * <p><b>off</b> - NO {@code IoUringBufferRingConfig} is installed and NO
     * {@code IO_URING_BUFFER_GROUP_ID} is set on any channel.  {@code scheduleRead0()} then falls
     * through to the plain branch: {@code allocHandle.allocate(alloc())} takes a receive buffer from
     * the <b>channel allocator</b> and an {@code IORING_OP_RECV} is submitted with that buffer's
     * address and length.  Everything else is untouched - the zero-copy write threshold, single
     * issuer / {@code DEFER_TASKRUN}, ring size, CQ size, multishot accept and multishot poll are all
     * as before.
     *
     * <p><b>One consequence is not a choice made here:</b> multishot recv is only reachable through
     * the provided-buffer branch ({@code IoUring.isRecvMultishotEnabled()} is read inside
     * {@code scheduleReadProviderBuffer()} and nowhere else), so {@code BUFFER_RING=off} also means
     * one-shot recv.  That is how io_uring works - {@code IORING_RECV_MULTISHOT} needs somewhere to
     * put the data it was not given an address for - not an extra knob turned off here.
     */
    static final boolean BUFFER_RING = bufferRingEnabled();

    /**
     * {@code BUFFER_RING_ALLOC=same|adaptive|builtin|slab} (or {@code -DbufferRingAlloc=}).  Ignored
     * when {@link #BUFFER_RING} is off.
     * <ul>
     *   <li>{@code same} - the default and what every run before section 8 used: the ring is filled
     *       from the allocator under test, the same instance the channels use;</li>
     *   <li>{@code adaptive} - candidate (i) of {@code docs/uring-registered-buffers.md}: the ring
     *       gets its OWN {@link io.netty.buffer.AdaptiveByteBufAllocator} (one for the JVM) and the
     *       channel allocator is left alone, so a run can separate "the allocator is wrong for
     *       registered buffers" from "the allocator is wrong";</li>
     *   <li>{@code builtin} - candidate (ii): netty's own
     *       {@link IoUringFixedBufferRingAllocator} over {@link ByteBufAllocator#DEFAULT}, i.e. what
     *       a netty user gets without writing any allocator code;</li>
     *   <li>{@code builtinadaptive} - candidate (ii-adaptive): netty's
     *       {@link IoUringAdaptiveBufferRingAllocator}, the only candidate that varies the buffer
     *       SIZE (1 KiB..64 KiB from an {@code AdaptiveCalculator}) instead of the chunk default;</li>
     *   <li>{@code slab} - candidate (iii): {@link RegisteredSlabBufferRingAllocator}, ONE preallocated
     *       direct region per ring, free list by slot, nothing allocated after start-up.  This is the
     *       only value that builds a SEPARATE allocator instance per worker loop, because per-loop
     *       locality is the point of it.</li>
     * </ul>
     * A ring buffer is kernel-owned for an unbounded number of iterations (lifetime class D), which is
     * exactly what an iteration-scoped allocator has no answer for.
     */
    static final String BUFFER_RING_ALLOC = bufferRingAlloc();

    /** Buffers allocated into a provided buffer ring, and buffers taken back out of one. */
    static final AtomicLong RING_ALLOCS = new AtomicLong();
    static final AtomicLong RING_READS = new AtomicLong();
    static final AtomicLong RING_READ_BYTES = new AtomicLong();

    private static volatile String ringDescription = "(no buffer ring)";

    /** The ring's own allocator when {@link #BUFFER_RING_ALLOC} is not {@code slab}; one for the JVM. */
    private static IoUringBufferRingAllocator sharedRingAllocator;
    private static volatile boolean slabInUse;

    private Transports() { }

    private static String property(String sysProp, String envVar) {
        String value = System.getProperty(sysProp);
        if (value == null) {
            value = System.getenv(envVar);
        }
        return value == null || value.isEmpty() ? null : value.toLowerCase(Locale.ROOT);
    }

    private static boolean bufferRingEnabled() {
        String value = property("bufferRing", "BUFFER_RING");
        if (value == null) {
            return true;
        }
        switch (value) {
            case "on": case "true": case "1": return true;
            case "off": case "false": case "0": return false;
            default: throw new IllegalArgumentException("BUFFER_RING=" + value + " (want on|off)");
        }
    }

    private static String bufferRingAlloc() {
        String value = property("bufferRingAlloc", "BUFFER_RING_ALLOC");
        if (value == null) {
            return "same";
        }
        switch (value) {
            case "same": case "adaptive": case "builtin": case "builtinadaptive": case "slab":
                return value;
            default: throw new IllegalArgumentException(
                    "BUFFER_RING_ALLOC=" + value + " (want same|adaptive|builtin|builtinadaptive|slab)");
        }
    }

    /**
     * The allocator that fills one provided buffer ring, wrapped in the counting delegate.  Every
     * value but {@code slab} returns the SAME inner instance for every loop - which is what the
     * earlier runs measured and what a netty user configuring one {@code IoUringBufferRingConfig}
     * gets.  {@code slab} builds a fresh instance per loop.
     */
    private static synchronized IoUringBufferRingAllocator ringAllocator(ByteBufAllocator underTest) {
        if ("slab".equals(BUFFER_RING_ALLOC)) {
            slabInUse = true;
            return new CountingRingAllocator(
                    new RegisteredSlabBufferRingAllocator(BUFFER_RING_SIZE, BUFFER_CHUNK, SLAB_DEPTH));
        }
        if (sharedRingAllocator == null) {
            final IoUringBufferRingAllocator inner;
            switch (BUFFER_RING_ALLOC) {
                case "adaptive":
                    inner = new FixedSizeRingAllocator(new io.netty.buffer.AdaptiveByteBufAllocator(), BUFFER_CHUNK);
                    break;
                case "builtin":
                    inner = new IoUringFixedBufferRingAllocator(ByteBufAllocator.DEFAULT, false, BUFFER_CHUNK);
                    break;
                case "builtinadaptive":
                    // The only candidate that varies the buffer SIZE: AdaptiveCalculator, 1 KiB..64 KiB.
                    inner = new IoUringAdaptiveBufferRingAllocator(ByteBufAllocator.DEFAULT);
                    break;
                default:
                    inner = new FixedSizeRingAllocator(underTest, BUFFER_CHUNK);
                    break;
            }
            sharedRingAllocator = new CountingRingAllocator(inner);
        }
        return sharedRingAllocator;
    }

    /** The class that actually allocates the ring's buffers, for the description line. */
    private static String ringAllocClass(ByteBufAllocator underTest) {
        switch (BUFFER_RING_ALLOC) {
            case "adaptive": return "AdaptiveByteBufAllocator";
            case "builtin": return "IoUringFixedBufferRingAllocator/" + ByteBufAllocator.DEFAULT.getClass()
                    .getSimpleName();
            case "builtinadaptive": return "IoUringAdaptiveBufferRingAllocator/"
                    + ByteBufAllocator.DEFAULT.getClass().getSimpleName();
            case "slab": return "RegisteredSlabBufferRingAllocator[" + BUFFER_RING_SIZE * SLAB_DEPTH
                    + "x" + BUFFER_CHUNK + " per loop]";
            default: return underTest.getClass().getSimpleName();
        }
    }

    static boolean isIoUring() { return "io_uring".equals(NAME) || "iouring".equals(NAME); }
    static boolean isEpoll() { return "epoll".equals(NAME); }
    static boolean isNio() { return !isIoUring() && !isEpoll(); }

    /** True when io_uring is selected AND a provided buffer ring is actually installed. */
    private static boolean ringEnabled() {
        return isIoUring() && BUFFER_RING && IoUring.isRegisterBufferRingSupported() && BUFFER_RING_SIZE > 0;
    }

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
     * Worker loops.  For io_uring with {@code BUFFER_RING=on} every loop registers its own provided
     * buffer ring, filled on the loop's own thread.  With {@code BUFFER_RING=off} no ring is
     * registered at all and reads take their buffers from the channel allocator.
     */
    static IoHandlerFactory workerFactory(ByteBufAllocator allocator) {
        if (isIoUring()) {
            IoUring.ensureAvailability();
            if (!BUFFER_RING) {
                ringDescription = "(BUFFER_RING=off: no IoUringBufferRingConfig, no IO_URING_BUFFER_GROUP_ID,"
                        + " recv into channel-allocator buffers, one-shot)";
                return IoUringIoHandler.newFactory(baseConfig());
            }
            if (!IoUring.isRegisterBufferRingSupported() || BUFFER_RING_SIZE <= 0) {
                ringDescription = "(buffer ring unsupported or disabled)";
                return IoUringIoHandler.newFactory(baseConfig());
            }
            boolean incremental = Boolean.parseBoolean(System.getProperty("iouring.incremental",
                    Boolean.toString(IoUring.isRegisterBufferRingIncSupported())));
            int batchSize = Math.max(1, BUFFER_RING_SIZE / 2);
            ringDescription = "bgId=" + BUFFER_GROUP_ID + " entries=" + BUFFER_RING_SIZE
                    + " chunk=" + BUFFER_CHUNK + " incremental=" + incremental
                    + " batchSize=" + batchSize + " batchAllocation=false"
                    + " alloc=" + BUFFER_RING_ALLOC
                    + " allocClass=" + ringAllocClass(allocator);
            // One IoUringIoHandlerConfig per worker loop.  For every value but "slab" the allocator
            // INSTANCE inside it is the same shared object the earlier runs used, so this is a no-op
            // for them; "slab" needs a fresh instance per ring, which is why the config is built here
            // and not once outside the factory.
            return ioExecutor -> {
                IoUringIoHandlerConfig config = baseConfig();
                config.setBufferRingConfig(IoUringBufferRingConfig.builder()
                        .bufferGroupId(BUFFER_GROUP_ID)
                        .bufferRingSize((short) BUFFER_RING_SIZE)
                        .batchSize(batchSize)
                        .incremental(incremental)
                        .batchAllocation(false)
                        .allocator(ringAllocator(allocator))
                        .build());
                return IoUringIoHandler.newFactory(config).newHandler(ioExecutor);
            };
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
            if (ringEnabled()) {
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
            if (ringEnabled()) {
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
                    + " singleIssuer=" + SINGLE_ISSUER + " bufferRing=" + (BUFFER_RING ? "on" : "off")
                    + " [" + ringDescription + "]"
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
        String line = "RINGTELE transport=" + NAME + " bufferRing=" + (BUFFER_RING ? "on" : "off")
                + " ringAllocs=" + RING_ALLOCS.get()
                + " ringReads=" + RING_READS.get() + " ringReadBytes=" + RING_READ_BYTES.get()
                + " " + ringDescription;
        if (slabInUse) {
            line = line + " | " + RegisteredSlabBufferRingAllocator.counters();
        }
        return line;
    }

    /**
     * A fixed-size ring allocator over a {@link ByteBufAllocator}: exactly what
     * {@code CountingRingAllocator} used to be before the counting moved into a delegate, so the
     * {@code same} and {@code adaptive} cells allocate as they did in sections 7 and 8.
     */
    static final class FixedSizeRingAllocator extends AbstractIoUringBufferRingAllocator {
        private final int bufferSize;

        FixedSizeRingAllocator(ByteBufAllocator allocator, int bufferSize) {
            super(allocator, false);
            this.bufferSize = bufferSize;
        }

        @Override
        protected int nextBufferSize() {
            return bufferSize;
        }
    }

    /**
     * Counts, then delegates.  {@code allocate()} is called once per buffer put into the ring and
     * {@code lastBytesRead} once per buffer taken out of it ({@code IoUringBufferRing#useBuffer} is
     * its only caller), so the two counters are "buffers provided to the kernel" and "buffers the
     * kernel filled and handed back".
     *
     * <p>Before section 9 the counting lived in {@code nextBufferSize()} of a subclass of
     * {@link AbstractIoUringBufferRingAllocator}; it is one increment per {@code allocate()} either
     * way, but the counter now also works for candidates that are not built on that base class.
     */
    static final class CountingRingAllocator implements IoUringBufferRingAllocator {
        private final IoUringBufferRingAllocator delegate;

        CountingRingAllocator(IoUringBufferRingAllocator delegate) {
            this.delegate = delegate;
        }

        @Override
        public ByteBuf allocate() {
            RING_ALLOCS.incrementAndGet();
            return delegate.allocate();
        }

        @Override
        public void allocateBatch(Consumer<ByteBuf> consumer, int num) {
            RING_ALLOCS.addAndGet(num);
            delegate.allocateBatch(consumer, num);
        }

        @Override
        public void lastBytesRead(int attempted, int actual) {
            RING_READS.incrementAndGet();
            if (actual > 0) {
                RING_READ_BYTES.addAndGet(actual);
            }
            delegate.lastBytesRead(attempted, actual);
        }
    }
}
