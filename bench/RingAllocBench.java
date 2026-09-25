package poc.ring;

import io.netty.buffer.ByteBuf;
import io.netty.channel.uring.IoUringBufferRingAllocator;
import io.netty.util.internal.PlatformDependent;
import org.openjdk.jmh.annotations.*;

import java.util.concurrent.TimeUnit;

/**
 * The provided-buffer-ring allocator ALONE, on the OWNING thread, one op = one buffer's whole trip through the ring:
 *
 * <pre>
 *   allocate()                        step 7, IoUringBufferRing.fill(bid)
 *   memoryAddress() + writableBytes() step 2, IoUringBufferRing.add() - what is written into the slot
 *   lastBytesRead(writable, read)     step 5, the size feedback the ring gives the allocator
 *   retainedSlice(writerIndex, read)  step 5, what the pipeline is handed
 *   writerIndex += read; release()    step 6, the ring drops its own reference
 *   slice.release()                   the pipeline is done with the bytes
 * </pre>
 *
 * {@code inFlight} buffers are kept outstanding at all times, because that is the state the real ring
 * is in (netty fills {@code entries/2} buffers and re-adds a bid as soon as it is consumed): with
 * {@code inFlight=1} a free-list allocator always hits the same slot and the same cache line, which
 * flatters it.  {@code inFlight=32} is netty's default batch for a 64-entry ring.
 *
 * <p>The foreign-release half of the question is {@link RingAllocForeignBench}.
 */
@BenchmarkMode(Mode.AverageTime)
@OutputTimeUnit(TimeUnit.NANOSECONDS)
@State(Scope.Benchmark)
@Fork(value = 3, jvmArgs = {"-Dio.netty.allocator.type=adaptive"})
@Warmup(iterations = 5, time = 1)
@Measurement(iterations = 5, time = 1)
public class RingAllocBench {

    /** R0 adaptive, R1 netty's IoUringAdaptiveBufferRingAllocator, R2 slab v1, R3/R4 slab v2/v3. */
    @Param({"adaptive", "builtinadaptive", "slab", "slab2", "slab3"})
    public String alloc;

    /** Buffers outstanding at all times. */
    @Param({"1", "32"})
    public int inFlight;

    static final int CHUNK = RingAllocs.CHUNK;
    static final int READ = RingAllocs.READ;

    private IoUringBufferRingAllocator ring;
    private ByteBuf[] parents;
    private ByteBuf[] slices;
    private int cursor;

    @Setup(Level.Trial)
    public void setup() {
        if (!PlatformDependent.hasUnsafe()) {
            throw new IllegalStateException("needs Unsafe for memoryAddress()");
        }
        ring = RingAllocs.build(alloc);
        parents = new ByteBuf[inFlight];
        slices = new ByteBuf[inFlight];
        cursor = 0;
        // Prime the in-flight window, so the measured loop is always in steady state.
        for (int i = 0; i < inFlight; i++) {
            take(i);
        }
    }

    @TearDown(Level.Trial)
    public void tearDown() {
        for (int i = 0; i < inFlight; i++) {
            if (slices[i] != null) { slices[i].release(); slices[i] = null; }
            if (parents[i] != null) { parents[i].release(); parents[i] = null; }
        }
    }

    /** One buffer into the slot: allocate, what add() reads, useBuffer()'s slice, then the ring's release. */
    private long take(int i) {
        ByteBuf buf = ring.allocate();
        long addr = PlatformDependent.hasUnsafe() ? buf.memoryAddress() + buf.writerIndex() : 0;
        int writable = buf.writableBytes();
        ring.lastBytesRead(writable, READ);
        int start = buf.writerIndex();
        ByteBuf slice = buf.retainedSlice(start, Math.min(READ, writable));
        buf.writerIndex(start + Math.min(READ, writable));
        // The ring drops its own reference; the slice keeps the buffer alive.
        parents[i] = buf;
        slices[i] = slice;
        return addr + writable;
    }

    /** The owner-thread cycle: everything on one thread, which is the loop in the real server. */
    @Benchmark
    public long ownerCycle() {
        int i = cursor;
        // retire the oldest: the ring's reference, then the pipeline's
        parents[i].release();
        slices[i].release();
        parents[i] = null;
        slices[i] = null;
        long r = take(i);
        cursor = i + 1 == inFlight ? 0 : i + 1;
        return r;
    }


    /**
     * The same cycle with the netty-side {@code noSliceHandoff} shape: {@code useBuffer} hands the
     * buffer itself over instead of a {@code retainedSlice}, so there is no slice object and no
     * retain/release pair.  The difference from {@link #ownerCycle} is what the slice costs per
     * consumed buffer, and therefore how much of the per-op cost NO choice of allocator can remove.
     */
    @Benchmark
    public long ownerCycleNoSlice() {
        int i = cursor;
        parents[i].release();           // the pipeline releases the buffer it was handed
        if (slices[i] != null) {
            slices[i].release();        // only the primed window has one
            slices[i] = null;
        }
        parents[i] = null;
        ByteBuf buf = ring.allocate();
        long addr = buf.memoryAddress() + buf.writerIndex();
        int writable = buf.writableBytes();
        ring.lastBytesRead(writable, READ);
        int start = buf.writerIndex();
        buf.setIndex(start, start + Math.min(READ, writable));
        parents[i] = buf;               // the ring's reference is transferred, not copied
        cursor = i + 1 == inFlight ? 0 : i + 1;
        return addr + writable;
    }
}
