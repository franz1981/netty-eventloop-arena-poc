package poc.ring;

import io.netty.buffer.ByteBuf;
import io.netty.buffer.ByteBufAllocator;
import io.netty.buffer.UnpooledByteBufAllocator;
import io.netty.buffer.UnpooledUnsafeDirectByteBuf;
import io.netty.channel.uring.IoUringBufferRingAllocator;
import io.netty.util.internal.AdaptiveCalculator;
import io.netty.util.internal.PlatformDependent;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

/**
 * Slab v2/v3/v4 for one io_uring provided buffer ring: the "fixed population, adaptive slot size"
 * synthesis of {@code docs/uring-registered-buffers.md}.  One instance per event loop, one direct
 * region per instance (a <b>generation</b>), {@code entries * depth} equal slots in it, nothing
 * allocated per buffer in steady state.
 *
 * <p>Three knobs make the three measured candidates out of one code path, so that a difference
 * between two of them is the knob and not a second implementation:
 *
 * <table><tr><th>knob</th><th>what it changes</th></tr>
 * <tr><td>{@code adaptiveSlot}</td><td><b>v2 (R3)</b>: the slot size comes from netty's own
 *     {@link AdaptiveCalculator}, fed by {@link #lastBytesRead(int, int)} exactly as
 *     {@code IoUringAdaptiveBufferRingAllocator} feeds it.  The region is re-provisioned
 *     <b>only</b> when that estimate has moved by a factor of two or more, never per buffer.
 *     With the knob off the slot size is the configured chunk for the life of the process.</td></tr>
 * <tr><td>{@code loopLocal}</td><td><b>v3 (R4)</b>: the free list is a plain {@code int} stack that
 *     the owning loop pops and pushes with no atomic at all.  A release from a foreign thread goes
 *     instead through an intrusive MPSC hand-back stack (one CAS, only on the foreign path), which
 *     the owner detaches with a single {@code getAndSet} when its own stack is empty.  With the knob
 *     off the free list is a lock-free Treiber stack over the wrappers, like slab v1, so
 *     <i>every</i> release pays a CAS.</td></tr>
 * <tr><td>{@code align2M}</td><td><b>v4 (R5)</b>: the region is over-allocated by 2 MiB and sliced
 *     to a 2 MiB boundary, the way folly's {@code IoUringProvidedBufferRing} rounds its mmap, so a
 *     transparent huge page can back it.  Java cannot call {@code madvise(MADV_HUGEPAGE)}, so
 *     whether THP <i>actually</i> backs it is read out of {@code /proc/self/smaps} at shutdown
 *     ({@code AnonHugePages}) and never assumed.</td></tr></table>
 *
 * <p><b>Why generations.</b> A re-provision cannot free the old region: up to {@code entries} of its
 * slots are parked in the ring with their raw address already handed to the kernel, and any number of
 * others are in flight in the pipeline.  So a re-provision only replaces the <i>current</i>
 * generation; the old one keeps serving releases into its own (now unreachable) free list and becomes
 * garbage as a whole - wrappers, free list and the direct {@link ByteBuffer} - once the ring and the
 * pipeline have let go of its last slot.  Nothing is freed explicitly and no address is ever
 * invalidated under a parked bid.
 *
 * <p><b>Telemetry.</b> Every counter is a plain {@code long} field of this instance, written only by
 * the owning loop, except the two that a foreign thread can reach ({@code foreignReleases} and the
 * foreign in-flight buckets), which are {@link AtomicLong}s.  Instances register themselves in a
 * static list and the totals are summed on the shutdown thread.  That is deliberate: slab v1 keeps
 * its counters in process-wide {@link AtomicLong}s and pays five contended increments per buffer, and
 * a comparison between the two must not be reading that difference as a design difference.
 */
public final class SlabV2BufferRingAllocator implements IoUringBufferRingAllocator {

    /** Every instance ever built, for the shutdown summary. */
    private static final List<SlabV2BufferRingAllocator> INSTANCES = new ArrayList<>();

    private static synchronized void register(SlabV2BufferRingAllocator a) {
        INSTANCES.add(a);
    }

    private static synchronized List<SlabV2BufferRingAllocator> instances() {
        return new ArrayList<>(INSTANCES);
    }

    // --- configuration, fixed at construction -------------------------------------------------
    private final String name;
    private final int entries;
    private final boolean adaptiveSlot;
    private final boolean loopLocal;
    private final boolean align2M;
    private final boolean growOnExhaustion;
    private final int maxRegionBytes;
    private final int maxSlots;
    private final ByteBufAllocator fallback;
    private final AdaptiveCalculator calculator;
    private final boolean timeHist;
    /** Buffers to serve before the slot size may be reconsidered at all. */
    private final long warmupAcquires;
    /** Minimum buffers between two re-provisions. */
    private final long reprovGap;
    /** Consecutive allocations that must all want the SAME 2x-away size before the region is rebuilt. */
    private final long reprovRuns;
    /** Hard cap on re-provisions per instance; after it the slot size is frozen for good. */
    private final int maxReprov;
    /** {@code true} = the windowed-rate rule, {@code false} = the consecutive-run rule that failed. */
    private final boolean ratePolicy;

    private int pendingSize;
    private long pendingRuns;
    private long lastReprovAcquire;
    /** Telemetry for the slot-size policy: what the calculator actually asked for, and how often. */
    private long nextSizeAway;
    private long nextSizeNear;
    private int nextSizeMin = Integer.MAX_VALUE;
    private int nextSizeMax;
    private long pendingRunsMax;
    /** Windowed-rate state: samples in the window, how many were 2x away, and the extremes asked for. */
    private long windowSamples;
    private long windowAway;
    private int windowMax;
    private int windowMin = Integer.MAX_VALUE;

    /** The current generation.  Read and written by the owning loop only. */
    private Gen gen;
    /** The loop that owns this slab; set on the first {@link #allocate()}, which runs on it. */
    private volatile Thread owner;

    // --- owner-only counters (plain longs) ----------------------------------------------------
    private long acquires;
    private long fallbacks;
    private long exhaustions;
    private long reprovisionsSize;
    private long reprovisionsGrow;
    private long lastBytesReadCalls;
    /** Slots handed out and not yet back, and the maximum that was ever true. */
    private int inFlight;
    private int maxInFlight;
    /** Releases seen on the owning loop.  Plain long: only the owner writes and reads it. */
    private long ownerReleases;
    /** Owner-side drains of the foreign hand-back list, and the ones that found it empty. */
    private long drains;
    /** Occupancy histogram sampled at every allocate: how many slots were in flight. */
    private final long[] occupancy = new long[5];      // 0-25%, -50%, -75%, -100%, saturated
    /** In-flight lifetime in "slots this loop acquired meanwhile": <1x ring, <8x, <64x, >=64x. */
    private final long[] lifeSeq = new long[4];
    /**
     * The same in wall-clock time, only when {@code timeHist} is on: {@code <100us, <1ms, <10ms, >=10ms}.
     * The first cut of these buckets was {@code <10us/<100us/<1ms/>=1ms} and put 100% of 1,778,667
     * buffers in the last one, which says nothing: a provided-ring buffer spends most of its life
     * PARKED IN THE RING waiting for the kernel to choose it, not in the pipeline.  Little's law on the
     * same cell agrees - 222k acquires per loop over 20 s with 34 in flight is a 3.1 ms mean - so the
     * buckets have to start where that is.
     */
    private final long[] lifeNanos = new long[4];

    // --- counters a foreign thread can reach --------------------------------------------------
    private final AtomicLong foreignReleases = new AtomicLong();
    /** Releases seen by a generation that is no longer current (a racy read of {@code gen}: telemetry only). */
    private final AtomicLong staleReleases = new AtomicLong();

    public SlabV2BufferRingAllocator(String name, int entries, int chunkSize, int depth,
                              boolean adaptiveSlot, boolean loopLocal, boolean align2M,
                              boolean growOnExhaustion, int maxRegionBytes,
                              int minSlot, int maxSlot, boolean timeHist,
                              long warmupAcquires, long reprovGap, long reprovRuns, int maxReprov,
                              boolean ratePolicy, ByteBufAllocator fallback) {
        if (!PlatformDependent.hasUnsafe()) {
            throw new IllegalStateException(name + " needs sun.misc.Unsafe for ByteBuf.memoryAddress()");
        }
        if (entries <= 0 || chunkSize <= 0 || depth <= 0) {
            throw new IllegalArgumentException("entries=" + entries + " chunkSize=" + chunkSize
                    + " depth=" + depth);
        }
        this.name = name;
        this.entries = entries;
        this.adaptiveSlot = adaptiveSlot;
        this.loopLocal = loopLocal;
        this.align2M = align2M;
        this.growOnExhaustion = growOnExhaustion;
        this.maxRegionBytes = maxRegionBytes;
        this.fallback = fallback;
        this.timeHist = timeHist;
        this.warmupAcquires = warmupAcquires;
        this.reprovGap = reprovGap;
        this.reprovRuns = reprovRuns;
        this.maxReprov = maxReprov;
        this.ratePolicy = ratePolicy;
        // The slot count is the population; it never shrinks and only grows when the ring ran dry.
        int slots = entries * depth;
        this.maxSlots = Math.max(slots, entries * depth * 4);
        this.calculator = adaptiveSlot
                ? new AdaptiveCalculator(Math.min(minSlot, chunkSize), chunkSize, Math.max(maxSlot, chunkSize))
                : null;
        this.gen = new Gen(chunkSize, slots);
        register(this);
    }

    // ---------------------------------------------------------------------------------------------
    // IoUringBufferRingAllocator
    // ---------------------------------------------------------------------------------------------

    @Override
    public ByteBuf allocate() {
        if (owner == null) {
            owner = Thread.currentThread();
        }
        Gen g = gen;
        if (adaptiveSlot && acquires >= warmupAcquires
                && reprovisionsSize < maxReprov
                && acquires - lastReprovAcquire >= reprovGap) {
            g = maybeResize(g);
        }
        int idx = g.pop();
        if (idx < 0) {
            exhaustions++;
            if (growOnExhaustion && g.slots < maxSlots
                    && (long) (g.slots << 1) * g.slotSize <= maxRegionBytes) {
                lastReprovAcquire = acquires;
                g = reprovision(g.slotSize, g.slots << 1, true);
                idx = g.pop();
            }
            if (idx < 0) {
                fallbacks++;
                // Never throw out of allocate(): IoUringBufferRing marks the ring corrupted.
                return fallback.directBuffer(g.slotSize, g.slotSize);
            }
        }
        acquires++;
        // In flight = handed out and not yet back.  Derived, so nothing on this path walks a list:
        // one plain read, one plain read and one read of the foreign counter's line.
        int n = (int) (acquires - ownerReleases - foreignReleases.get());
        inFlight = n;
        if (n > maxInFlight) {
            maxInFlight = n;
        }
        int q = (int) ((long) n * 4 / Math.max(1, g.slots));
        occupancy[q > 4 ? 4 : q]++;
        SlabBuf buf = g.bufs[idx];
        buf.acquireSeq = acquires;
        if (timeHist) {
            buf.acquireNanos = System.nanoTime();
        }
        buf.arm();
        return buf;
    }

    /**
     * The slot-size policy, and the one thing this allocator got wrong the first time it was measured.
     *
     * <p>The rule "re-provision when the estimate has moved by 2x" is <b>not</b> a usable rule against
     * {@link AdaptiveCalculator}: the calculator steps its index by +4 on a full read and by -1 on two
     * small ones, and its size table doubles per index above 512 bytes, so a single step up is 16x and
     * a single step down is 2x.  Measured on e2e h1 with that rule: <b>14,960 re-provisions in 37,357
     * buffers</b>, RSS 10.9 GB and 22,970 req/s against 132,211 for the adaptive baseline - the slab
     * spent the run allocating and abandoning multi-MiB direct regions.  So the trigger needs all four
     * of these, and they are what makes "perm gen" true rather than aspirational:
     * <ul>
     *   <li>a warm-up: the first {@code warmupAcquires} buffers only FEED the calculator;</li>
     *   <li>persistence: {@code reprovRuns} consecutive allocations must all want the same 2x-away
     *       size.  An oscillating estimate resets the run and therefore changes nothing;</li>
     *   <li>a gap: at least {@code reprovGap} buffers between two re-provisions;</li>
     *   <li>a cap: at most {@code maxReprov} of them, ever.  After that the region is frozen.</li>
     * </ul>
     */
    private Gen maybeResize(Gen g) {
        int want = calculator.nextSize();
        int have = g.slotSize;
        if (want < nextSizeMin) {
            nextSizeMin = want;
        }
        if (want > nextSizeMax) {
            nextSizeMax = want;
        }
        if (want >= (have << 1) || (want << 1) <= have) {
            nextSizeAway++;
        } else {
            nextSizeNear++;
        }
        if (ratePolicy) {
            // WINDOWED RATE.  Over reprovRuns samples, count how many asked for a size at least 2x
            // away and remember the extremes.  Resize at the end of the window if the majority did.
            // This is the rule the consecutive-run one had to be replaced by: measured on W3, 80.6%
            // of samples were 2x away (wantAway=582,442 against wantNear=140,375) and the longest run
            // of the SAME away value was 2, because AdaptiveCalculator cannot converge when it does
            // not control the size of the next buffer - it steps down 1 index and up 4 forever.
            windowSamples++;
            if (want >= (have << 1) || (want << 1) <= have) {
                windowAway++;
            }
            if (want > windowMax) {
                windowMax = want;
            }
            if (want < windowMin) {
                windowMin = want;
            }
            if (windowSamples >= reprovRuns) {
                boolean majority = windowAway * 2 > windowSamples;
                int grow = windowMax;
                int shrink = windowMin;
                long samples = windowSamples;
                windowSamples = 0;
                windowAway = 0;
                windowMax = 0;
                windowMin = Integer.MAX_VALUE;
                if (majority) {
                    // Growth first: an undersized slot is the failure mode that costs CQEs, an
                    // oversized one only costs bytes.
                    if (grow >= (have << 1)) {
                        lastReprovAcquire = acquires;
                        return reprovision(grow, g.slots, false);
                    }
                    if ((shrink << 1) <= have) {
                        lastReprovAcquire = acquires;
                        return reprovision(shrink, g.slots, false);
                    }
                }
                assert samples > 0;
            }
            return g;
        }
        if (want >= (have << 1) || (want << 1) <= have) {
            if (want == pendingSize) {
                if (++pendingRuns > pendingRunsMax) {
                    pendingRunsMax = pendingRuns;
                }
                if (pendingRuns >= reprovRuns) {
                    pendingRuns = 0;
                    pendingSize = 0;
                    lastReprovAcquire = acquires;
                    return reprovision(want, g.slots, false);
                }
            } else {
                pendingSize = want;
                pendingRuns = 1;
            }
        } else {
            pendingSize = 0;
            pendingRuns = 0;
        }
        return g;
    }

    @Override
    public void lastBytesRead(int attempted, int actual) {
        lastBytesReadCalls++;
        if (adaptiveSlot && attempted == actual) {
            calculator.record(actual);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // generations
    // ---------------------------------------------------------------------------------------------

    /**
     * Replace the current generation.  The old one is simply abandoned: it keeps taking releases into
     * its own free list, nothing pops from it again, and it is collected - region included - once the
     * ring and the pipeline have let go of its last slot.  No address is invalidated under a parked bid.
     */
    private Gen reprovision(int slotSize, int slots, boolean growth) {
        int size = Math.max(64, slotSize);
        int count = Math.max(entries, slots);
        while ((long) count * size > maxRegionBytes && count > entries) {
            count >>= 1;
        }
        Gen g = new Gen(size, count);
        gen = g;
        if (growth) {
            reprovisionsGrow++;
        } else {
            reprovisionsSize++;
        }
        return g;
    }

    /** One region, its wrappers and its free list. */
    private final class Gen {
        final int slotSize;
        final int slots;
        final int regionBytes;
        /** Held so nothing can clean it while a slot of this generation is alive. */
        final ByteBuffer region;
        final SlabBuf[] bufs;
        final long baseAddress;
        final boolean aligned;

        // loopLocal free list: owner-only stack of slot indices, plus the foreign hand-back.
        private final int[] stack;
        private int top;
        private final AtomicInteger handback = new AtomicInteger(-1);
        private final int[] handbackNext;
        // treiber free list (loopLocal == false)
        private final java.util.concurrent.atomic.AtomicReference<SlabBuf> free =
                new java.util.concurrent.atomic.AtomicReference<>();

        Gen(int slotSize, int slots) {
            this.slotSize = slotSize;
            this.slots = slots;
            long bytes = (long) slotSize * slots;
            if (bytes > Integer.MAX_VALUE - (2 << 20)) {
                throw new IllegalArgumentException("slab region " + bytes + " bytes too large");
            }
            ByteBuffer raw;
            ByteBuffer body;
            if (align2M) {
                // alignedSlice() rounds the position UP and the limit DOWN to the unit, so the raw
                // region must be the body rounded up to a 2 MiB multiple PLUS one unit of slack.
                final int unit = 2 << 20;
                int rounded = (int) ((bytes + unit - 1) / unit * unit);
                raw = ByteBuffer.allocateDirect(rounded + unit);
                body = raw.alignedSlice(unit);
                if (body.capacity() < bytes) {
                    throw new IllegalStateException("alignedSlice gave " + body.capacity()
                            + " bytes for a " + bytes + " byte slab");
                }
            } else {
                raw = ByteBuffer.allocateDirect((int) bytes);
                body = raw;
            }
            this.region = raw;               // the OWNER of the memory: never dropped before body
            ByteBuffer window0 = body;
            this.baseAddress = PlatformDependent.directBufferAddress(window0);
            this.aligned = (baseAddress & ((2L << 20) - 1)) == 0;
            this.regionBytes = raw.capacity();
            this.bufs = new SlabBuf[slots];
            this.stack = loopLocal ? new int[slots] : null;
            this.handbackNext = loopLocal ? new int[slots] : null;
            for (int i = 0; i < slots; i++) {
                ByteBuffer w = window0.duplicate();
                w.limit((i + 1) * slotSize).position(i * slotSize);
                SlabBuf b = new SlabBuf(this, i, w, slotSize);
                bufs[i] = b;
            }
            if (loopLocal) {
                for (int i = 0; i < slots; i++) {
                    stack[i] = slots - 1 - i;
                }
                top = slots;
            } else {
                for (int i = slots - 1; i >= 0; i--) {
                    bufs[i].next = free.get();
                    free.set(bufs[i]);
                }
            }
        }

        /** Owner only. */
        int pop() {
            if (loopLocal) {
                if (top == 0 && !drain()) {
                    return -1;
                }
                return stack[--top];
            }
            for (;;) {
                SlabBuf head = free.get();
                if (head == null) {
                    return -1;
                }
                if (free.compareAndSet(head, head.next)) {
                    head.next = null;
                    return head.index;
                }
            }
        }

        /** Owner only: detach the whole hand-back list in one getAndSet and move it onto the stack. */
        private boolean drain() {
            drains++;
            int h = handback.get();
            if (h < 0) {
                return false;
            }
            h = handback.getAndSet(-1);
            int n = 0;
            while (h >= 0) {
                int next = handbackNext[h];
                stack[n++] = h;
                h = next;
            }
            top = n;
            return n > 0;
        }

        void push(int idx, boolean byOwner) {
            if (loopLocal) {
                if (byOwner) {
                    stack[top++] = idx;             // no atomic at all on the owner's path
                    return;
                }
                for (;;) {
                    int h = handback.get();
                    handbackNext[idx] = h;
                    if (handback.compareAndSet(h, idx)) {
                        return;
                    }
                }
            }
            SlabBuf buf = bufs[idx];
            for (;;) {
                SlabBuf head = free.get();
                buf.next = head;
                if (free.compareAndSet(head, buf)) {
                    return;
                }
            }
        }

    }

    /**
     * One slot's wrapper, built once with its generation.  {@code doFree=false} comes from the
     * protected {@code UnpooledUnsafeDirectByteBuf(alloc, ByteBuffer, maxCapacity)} constructor, so
     * netty's cleaner never touches the region; {@link #deallocate()} only returns the slot.
     */
    private final class SlabBuf extends UnpooledUnsafeDirectByteBuf {
        private final Gen home;
        private final int index;
        SlabBuf next;                 // treiber link, owner/CAS
        long acquireSeq;
        long acquireNanos;

        SlabBuf(Gen home, int index, ByteBuffer window, int slotSize) {
            super(UnpooledByteBufAllocator.DEFAULT, window, slotSize);
            this.home = home;
            this.index = index;
            setIndex(0, 0);
        }

        void arm() {
            resetRefCnt();
            setIndex(0, 0);
        }

        @Override
        protected void deallocate() {
            // Do NOT call super.deallocate(): the region outlives every slot.
            setIndex(0, 0);
            boolean byOwner = Thread.currentThread() == owner;
            if (byOwner) {
                ownerReleases++;
                long d = acquires - acquireSeq;
                int b = d < entries ? 0 : d < entries * 8L ? 1 : d < entries * 64L ? 2 : 3;
                lifeSeq[b]++;
                if (timeHist) {
                    long ns = System.nanoTime() - acquireNanos;
                    lifeNanos[ns < 100_000 ? 0 : ns < 1_000_000 ? 1 : ns < 10_000_000 ? 2 : 3]++;
                }
            } else {
                foreignReleases.incrementAndGet();
            }
            if (home != gen) {
                staleReleases.incrementAndGet();
            }
            home.push(index, byOwner);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // reporting
    // ---------------------------------------------------------------------------------------------

    private static String hist(long[] a, String[] labels) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < a.length; i++) {
            if (i > 0) {
                sb.append(',');
            }
            sb.append(labels[i]).append(':').append(a[i]);
        }
        return sb.toString();
    }

    private static final String[] OCC = {"0-25%", "25-50%", "50-75%", "75-100%", "full"};
    private static final String[] LIFE = {"<1ring", "<8ring", "<64ring", ">=64ring"};
    private static final String[] NANOS = {"<100us", "<1ms", "<10ms", ">=10ms"};

    /** One line per configuration, summed over the instances (= over the loops). */
    public static String counters() {
        List<SlabV2BufferRingAllocator> all = instances();
        if (all.isEmpty()) {
            return null;
        }
        long acq = 0, rel = 0, fb = 0, exh = 0, rpSize = 0, rpGrow = 0, foreign = 0, stale = 0, lbr = 0;
        long regionBytes = 0, drains = 0, away = 0, near = 0, runsMax = 0;
        int wantMin = Integer.MAX_VALUE, wantMax = 0;
        int maxIn = 0, minSlots = Integer.MAX_VALUE;
        long[] occ = new long[5];
        long[] life = new long[4];
        long[] nanos = new long[4];
        StringBuilder slots = new StringBuilder();
        boolean aligned = true;
        for (SlabV2BufferRingAllocator a : all) {
            Gen g = a.gen;
            acq += a.acquires;
            rel += a.ownerReleases + a.foreignReleases.get();
            fb += a.fallbacks;
            exh += a.exhaustions;
            rpSize += a.reprovisionsSize;
            rpGrow += a.reprovisionsGrow;
            foreign += a.foreignReleases.get();
            stale += a.staleReleases.get();
            lbr += a.lastBytesReadCalls;
            regionBytes += g.regionBytes;
            maxIn = Math.max(maxIn, a.maxInFlight);
            minSlots = Math.min(minSlots, g.slots);
            drains += a.drains;
            away += a.nextSizeAway;
            near += a.nextSizeNear;
            runsMax = Math.max(runsMax, a.pendingRunsMax);
            wantMin = Math.min(wantMin, a.nextSizeMin);
            wantMax = Math.max(wantMax, a.nextSizeMax);
            aligned &= g.aligned;
            for (int i = 0; i < 5; i++) {
                occ[i] += a.occupancy[i];
            }
            for (int i = 0; i < 4; i++) {
                life[i] += a.lifeSeq[i];
                nanos[i] += a.lifeNanos[i];
            }
            if (slots.length() > 0) {
                slots.append('/');
            }
            slots.append(g.slots).append('x').append(g.slotSize);
        }
        SlabV2BufferRingAllocator f = all.get(0);
        return "SLAB2TELE name=" + f.name + " instances=" + all.size()
                + " adaptiveSlot=" + f.adaptiveSlot + " loopLocal=" + f.loopLocal
                + " align2M=" + f.align2M + " aligned=" + aligned
                + " finalSlots=" + slots + " regionBytes=" + regionBytes
                + " acquires=" + acq + " releases=" + rel + " fallbacks=" + fb
                + " exhaustions=" + exh + " reprovSize=" + rpSize + " reprovGrow=" + rpGrow
                + " foreignReleases=" + foreign + " staleReleases=" + stale
                + " lastBytesReadCalls=" + lbr
                + " maxInFlight=" + maxIn
                + " minFreeSlots=" + (minSlots == Integer.MAX_VALUE ? -1 : minSlots - maxIn)
                + " drains=" + drains
                + " wantAway=" + away + " wantNear=" + near
                + " wantMin=" + (wantMin == Integer.MAX_VALUE ? -1 : wantMin) + " wantMax=" + wantMax
                + " longestRun=" + runsMax + " ratePolicy=" + f.ratePolicy
                + " occupancy[" + hist(occ, OCC) + "]"
                + " lifeSeq[" + hist(life, LIFE) + "]"
                + (f.timeHist ? " lifeNanos[" + hist(nanos, NANOS) + "]" : "");
    }
}
