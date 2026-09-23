import io.netty.buffer.ByteBuf;
import io.netty.buffer.ByteBufAllocator;
import io.netty.buffer.UnpooledByteBufAllocator;
import io.netty.buffer.UnpooledUnsafeDirectByteBuf;
import io.netty.channel.uring.IoUringBufferRingAllocator;
import io.netty.util.internal.PlatformDependent;

import java.nio.ByteBuffer;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Candidate (iii) of {@code docs/uring-registered-buffers.md}: an AD HOC registered slab for one
 * io_uring provided buffer ring.
 *
 * <p>The requirement this is built to, in the user's words, is "as local as possible, not elastic,
 * sort of perm gen":
 * <ul>
 *   <li><b>local</b> - ONE direct region per instance, and one instance per ring, i.e. per event
 *       loop ({@code Transports} builds a fresh one per worker loop).  Nothing is shared between
 *       loops, so the memory is first-touched by the loop that will read into it;</li>
 *   <li><b>not elastic</b> - the chunk count and the chunk size are fixed at construction from the
 *       ring config ({@code entries * depth} chunks of {@code chunkSize} bytes).  There is no
 *       growth path and no shrink path;</li>
 *   <li><b>perm gen</b> - the region is allocated once, in the constructor, and is never freed and
 *       never trimmed for the life of the process.  After start-up the steady state allocates
 *       nothing: {@link #allocate()} pops a slot off a free list and hands back a wrapper that was
 *       also built at start-up.</li>
 * </ul>
 *
 * <p><b>How a slot comes back.</b> {@code IoUringBufferRing.useBuffer()} hands the pipeline a
 * {@code retainedSlice} of the buffer this allocator returned and then releases its own reference.
 * A derived buffer shares its parent's reference count, so the slot's {@link SlabBuf} reaches
 * refCnt 0 only when the ring AND every outstanding slice are done with it - which is exactly the
 * moment the kernel and the pipeline are both finished with those bytes.  {@link SlabBuf#deallocate()}
 * then pushes the slot back on the free list instead of freeing memory.
 *
 * <p><b>Why more chunks than ring entries.</b> The ring refills a bid as soon as it is consumed,
 * while the slice handed to the pipeline may still be alive (aggregation, a proxy write, a
 * zero-copy write completion).  With exactly {@code entries} chunks the free list would run dry
 * whenever anything outlives one iteration.  {@code depth} (default 4) is the headroom.  If the
 * free list runs dry anyway the call falls back to a plain direct allocation from
 * {@code fallbackAllocator} and is counted: that keeps "zero allocation after start-up" a
 * measurement ({@code slabFallbacks=0}) instead of an assumption, and it can never corrupt the ring
 * the way a throw out of {@code allocate()} would.
 *
 * <p><b>Thread safety.</b> {@link #allocate()} only ever runs on the ring's own event loop.  A
 * release can happen on another thread (a proxy that writes an inbound slice to a channel on a
 * different loop releases it there), so the free list is a lock-free Treiber stack whose nodes are
 * the {@link SlabBuf}s themselves - no node allocation.  {@code slabForeignReleases} counts the
 * releases that did not come from the owning loop, so the run says whether the CAS was needed.
 */
final class RegisteredSlabBufferRingAllocator implements IoUringBufferRingAllocator {

    /** Process-wide totals, printed as the {@code SLABTELE} line. */
    static final AtomicLong ACQUIRES = new AtomicLong();
    static final AtomicLong RELEASES = new AtomicLong();
    static final AtomicLong FALLBACKS = new AtomicLong();
    static final AtomicLong FOREIGN_RELEASES = new AtomicLong();
    static final AtomicLong LAST_BYTES_READ_CALLS = new AtomicLong();
    static final AtomicLong REGION_BYTES = new AtomicLong();
    static final AtomicInteger INSTANCES = new AtomicInteger();

    private final int chunkSize;
    private final int chunks;
    /** The one region.  Held so nothing can clean it; never freed. */
    private final ByteBuffer region;
    private final AtomicReference<SlabBuf> free = new AtomicReference<>();
    private final ByteBufAllocator fallbackAllocator;
    private final AtomicInteger inFlight = new AtomicInteger();
    private volatile int maxInFlight;
    /** The loop that built the slab; set on the first {@link #allocate()} (which runs on it). */
    private volatile Thread owner;

    RegisteredSlabBufferRingAllocator(int entries, int chunkSize, int depth) {
        this(entries, chunkSize, depth, UnpooledByteBufAllocator.DEFAULT);
    }

    RegisteredSlabBufferRingAllocator(int entries, int chunkSize, int depth, ByteBufAllocator fallback) {
        if (!PlatformDependent.hasUnsafe()) {
            throw new IllegalStateException("RegisteredSlabBufferRingAllocator needs sun.misc.Unsafe "
                    + "for ByteBuf.memoryAddress(); io.netty.noUnsafe is set");
        }
        if (entries <= 0 || chunkSize <= 0 || depth <= 0) {
            throw new IllegalArgumentException("entries=" + entries + " chunkSize=" + chunkSize
                    + " depth=" + depth);
        }
        this.chunkSize = chunkSize;
        this.chunks = entries * depth;
        this.fallbackAllocator = fallback;
        long bytes = (long) chunks * chunkSize;
        if (bytes > Integer.MAX_VALUE) {
            throw new IllegalArgumentException("slab region " + bytes + " bytes > 2 GiB");
        }
        // ONE region for this ring.  Nothing here is ever freed or trimmed.
        this.region = ByteBuffer.allocateDirect((int) bytes);
        REGION_BYTES.addAndGet(bytes);
        INSTANCES.incrementAndGet();
        // Build every wrapper now, and push them all on the free list: after this constructor the
        // allocator never allocates again unless the free list runs dry.
        for (int i = chunks - 1; i >= 0; i--) {
            ByteBuffer window = region.duplicate();
            window.limit((i + 1) * chunkSize).position(i * chunkSize);
            SlabBuf buf = new SlabBuf(this, window, chunkSize);
            buf.next = free.get();
            // Single-threaded construction: a plain set is enough, but keep it uniform.
            free.set(buf);
        }
    }

    @Override
    public ByteBuf allocate() {
        if (owner == null) {
            owner = Thread.currentThread();
        }
        SlabBuf buf = pop();
        if (buf == null) {
            FALLBACKS.incrementAndGet();
            // Never throw out of allocate(): IoUringBufferRing marks the ring corrupted and
            // releases every buffer in it.
            return fallbackAllocator.directBuffer(chunkSize, chunkSize);
        }
        ACQUIRES.incrementAndGet();
        int n = inFlight.incrementAndGet();
        if (n > maxInFlight) {
            maxInFlight = n;
        }
        buf.acquire();
        return buf;
    }

    @Override
    public void lastBytesRead(int attempted, int actual) {
        LAST_BYTES_READ_CALLS.incrementAndGet();
    }

    private SlabBuf pop() {
        for (;;) {
            SlabBuf head = free.get();
            if (head == null) {
                return null;
            }
            if (free.compareAndSet(head, head.next)) {
                head.next = null;
                return head;
            }
        }
    }

    void push(SlabBuf buf) {
        RELEASES.incrementAndGet();
        if (Thread.currentThread() != owner) {
            FOREIGN_RELEASES.incrementAndGet();
        }
        inFlight.decrementAndGet();
        for (;;) {
            SlabBuf head = free.get();
            buf.next = head;
            if (free.compareAndSet(head, buf)) {
                return;
            }
        }
    }

    int chunks() {
        return chunks;
    }

    int maxInFlight() {
        return maxInFlight;
    }

    /**
     * One line, process-wide.  {@code slabAcquires} is buffers handed to the ring,
     * {@code slabReleases} slots pushed back (kernel AND pipeline done), {@code slabFallbacks} the
     * allocations that were NOT served from a slab, which must be 0 for the design to hold.
     */
    static String counters() {
        return "SLABTELE instances=" + INSTANCES.get()
                + " regionBytes=" + REGION_BYTES.get()
                + " slabAcquires=" + ACQUIRES.get()
                + " slabReleases=" + RELEASES.get()
                + " slabFallbacks=" + FALLBACKS.get()
                + " slabForeignReleases=" + FOREIGN_RELEASES.get()
                + " lastBytesReadCalls=" + LAST_BYTES_READ_CALLS.get();
    }

    /**
     * A wrapper over one chunk of the slab region.  {@code doFree=false} is what the protected
     * {@code UnpooledUnsafeDirectByteBuf(alloc, ByteBuffer, maxCapacity)} constructor gives us, so
     * the underlying memory is never touched by netty's cleaner; {@link #deallocate()} only returns
     * the slot.  maxCapacity is the chunk size, so nothing can grow this buffer in place.
     */
    static final class SlabBuf extends UnpooledUnsafeDirectByteBuf {
        private final RegisteredSlabBufferRingAllocator slab;
        SlabBuf next;

        SlabBuf(RegisteredSlabBufferRingAllocator slab, ByteBuffer window, int chunkSize) {
            super(UnpooledByteBufAllocator.DEFAULT, window, chunkSize);
            this.slab = slab;
            setIndex(0, 0);
        }

        /** Re-arm the slot: refCnt back to 1, indices back to 0. */
        void acquire() {
            resetRefCnt();
            setIndex(0, 0);
        }

        @Override
        protected void deallocate() {
            // Do NOT call super.deallocate(): the region outlives every slot.
            setIndex(0, 0);
            slab.push(this);
        }
    }
}
