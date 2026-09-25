package poc.ring;

import io.netty.buffer.ByteBuf;
import io.netty.channel.uring.IoUringBufferRingAllocator;
import org.openjdk.jmh.annotations.*;
import org.openjdk.jmh.infra.Blackhole;

import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReferenceArray;

/**
 * The FOREIGN-release half of the ring allocator's cost: requirement 4 of
 * {@code docs/uring-registered-buffers.md} - {@code allocate()} is always on the loop, a
 * {@code release()} is not, because a proxy that writes an inbound slice to a channel on another loop
 * releases it there.
 *
 * <p>{@link #cycleForeignRelease} allocates on the JMH thread and hands the buffer and its slice to a
 * second thread through a minimal SPSC queue, which releases both. {@link #handoffOnly} is the SAME
 * queue with the same {@code Object[2]} carrier and no allocator in it, so the allocator's
 * foreign-release cost is the DIFFERENCE between the two: the queue is not attributed to the allocator.
 *
 * <p>What this does and does not say: it measures the producer's cost, which is what the event loop
 * pays. It does not measure the consumer's, and it does not reproduce contention between several
 * foreign releasers - there is exactly one here.
 */
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@Fork(value = 3, jvmArgs = {"-Dio.netty.allocator.type=adaptive"})
@Warmup(iterations = 5, time = 1)
@Measurement(iterations = 5, time = 1)
@State(Scope.Benchmark)
public class RingAllocForeignBench {

    @Param({"adaptive", "builtinadaptive", "slab", "slab2", "slab3"})
    public String alloc;

    IoUringBufferRingAllocator ring;
    Spsc queue;
    Thread releaser;
    volatile boolean stop;
    final AtomicLong drained = new AtomicLong();

    @Setup(Level.Trial)
    public void setup() {
        ring = RingAllocs.build(alloc);
        queue = new Spsc(8192);
        stop = false;
        releaser = new Thread(() -> {
            long n = 0;
            while (!stop) {
                Object[] pair = queue.poll();
                if (pair == null) {
                    Thread.onSpinWait();
                    continue;
                }
                if (pair.length == 2 && pair[0] != null) {
                    ((ByteBuf) pair[0]).release();
                    ((ByteBuf) pair[1]).release();
                }
                n++;
            }
            for (Object[] pair = queue.poll(); pair != null; pair = queue.poll()) {
                if (pair.length == 2 && pair[0] != null) {
                    ((ByteBuf) pair[0]).release();
                    ((ByteBuf) pair[1]).release();
                }
            }
            drained.set(n);
        }, "foreign-releaser");
        releaser.setDaemon(true);
        releaser.start();
    }

    @TearDown(Level.Trial)
    public void tearDown() throws InterruptedException {
        stop = true;
        releaser.join(5000);
    }

    /** Allocate here, release there.  Subtract {@link #handoffOnly} for the allocator's own share. */
    @Benchmark
    public void cycleForeignRelease() {
        ByteBuf buf = ring.allocate();
        int writable = buf.writableBytes();
        ring.lastBytesRead(writable, RingAllocs.READ);
        int n = Math.min(RingAllocs.READ, writable);
        ByteBuf slice = buf.retainedSlice(buf.writerIndex(), n);
        buf.writerIndex(buf.writerIndex() + n);
        while (!queue.offer(buf, slice)) {
            Thread.onSpinWait();
        }
    }

    /** The control: the same queue and carrier, no allocator.  The alloc parameter is ignored here, so
     *  its five values are five independent estimates of the queue's own cost. */
    @Benchmark
    public void handoffOnly(Blackhole bh) {
        while (!queue.offerRaw(new Object[2])) {
            Thread.onSpinWait();
        }
        bh.consume(queue);
    }

    /** A minimal SPSC array queue: one producer (the JMH thread), one consumer (the releaser). */
    static final class Spsc {
        private final AtomicReferenceArray<Object[]> buf;
        private final int mask;
        private final AtomicLong head = new AtomicLong();
        private final AtomicLong tail = new AtomicLong();

        Spsc(int capacity) {
            this.buf = new AtomicReferenceArray<>(capacity);
            this.mask = capacity - 1;
        }

        boolean offer(ByteBuf a, ByteBuf b) {
            return offerRaw(new Object[] { a, b });
        }

        boolean offerRaw(Object[] pair) {
            long t = tail.get();
            if (t - head.get() >= buf.length()) {
                return false;
            }
            buf.lazySet((int) t & mask, pair);
            tail.lazySet(t + 1);
            return true;
        }

        Object[] poll() {
            long h = head.get();
            int i = (int) h & mask;
            Object[] v = buf.get(i);
            if (v == null) {
                return null;
            }
            buf.lazySet(i, null);
            head.lazySet(h + 1);
            return v;
        }
    }
}
