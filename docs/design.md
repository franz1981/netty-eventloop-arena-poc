# Event-loop arena for Netty: the design, as implemented

Status: **implemented**. This file describes the allocator that exists today -
`io.netty.buffer.CycleArenaAllocator` on branch `expt/event-loop-arena`, pinned by this repository at
netty `256c1d86bd` - not a plan for one. It started as draft 3 of a pre-implementation design (three
Opus reviews: draft 1 revise; draft 2b revise-small; draft 3 two text fixes, applied); draft 1 is
kept as [`design-draft1.md`](design-draft1.md) so the review trail is visible. Sections 1, 2, 4 and
the precedents of section 3 are unchanged from that draft because the data they rest on has not
changed; sections 3, 5, 6, 7 and 8 were rewritten against the code and the measurements.

Every claim is measured (M, with source), taken from an existing system (R, with source), or a
decision/inference (D).

What arrived after draft 3 and is described here: the **variable-slot ring** (`-Darena.ring`, off by
default), **re-entry** into a stalled block, the **zero-slot rule** that made the ring's live-start
bitmap sound, and the **conclusion about io_uring's registered buffers**, which is where the design's
own "class D" showed up in a measurement for the first time.

## 1. Problem classes, measured

Source: `../results/ryzen9-7950x-node0/topology/` (`summary.txt`, `w1.txt`..`w6b.txt`): JFR AllocateBuffer /
FreeBuffer (stack) / ReallocateBuffer + an `IterationEnd` marker per event loop; NIO transport; this branch's adaptive
allocator at `cfb23bcf63`; ONE 1-1.5 s window per workload, no repeats; iteration counts are inflated on near-idle loops
by the marker task (W4: 31x CPU, `control.txt`), so W4/W5 use wall-clock or the read-iteration row.

| class | what | measured share | lifetime | release order |
|---|---|---|---|---|
| I - iteration-scoped | allocated and released on the same event loop within one iteration | 100% of buffers in W1 (h1 POST), W2 (h2 multiplexed), W6a (proxy on one loop); 98% W3, 91% W4, 37% W5 | 0 iterations; live buffers at every iteration end = 0 in W1/W2/W6a (13,954 / 4,180 / 388,922 markers) | FIFO (`oldest`, W1 67%, W5 55%) or interleaved (`middle`, W2 68%, W3 99%, W4 97%); the released buffer is the ONLY live one in 100% W6a, 59% W6b, 33% W1 (`only`); `youngest` (LIFO with older siblings still live) 0% everywhere |
| W - write-parked | `ChannelOutboundBuffer` holds the encoded write until the socket accepts it | W3 (h2, 4 KiB client window, 64 KiB echo): 2.2% of buffers = 41% of bytes; W4 (h1 slow readers, SO_SNDBUF 16 KiB): 8.7% = 20% | W3: longest-lived by iterations 1,636 it / 18.1 ms, by time 424 ms / 1,059 it; W4 up to 86 ms | n/a |
| A - aggregation / cumulation | `HttpObjectAggregator` (by construction any cumulating decoder) retains parts across reads | W5 (256 KiB bodies): 63% of buffers = 69% of bytes, sizes 16-64 KiB | read-iterations: 0 = 37%, 1 = 7%, 2-3 = 13%, 4-7 = 18%, 8+ = 25%; wall-clock p50 77 us, p99 228 us, max 1.2 ms | FIFO |
| X - cross-thread | read on one loop, released on another | W6b (proxy with separate groups): 84% of buffers, 100% of those freed on another thread; W6a (same loop): 0% | 1 productive iteration | n/a |
| D - kernel / long-lived | io_uring provided/registered buffers, user-retained data, composites kept across iterations | **now measured**: with the provided buffer ring filled by the arena, 12-32 block maxima pinned across 4-8 loops (`../results/ryzen9-7950x-node0/RESULTS.md` sections 3 and 4); with no ring at all, 24 (h1) / 9 (h2), and turning zero-copy writes off takes h1's 25 to 11 (section 5.3) | long-lived by construction | n/a |

Sizes (M): class I buffers are small: W1/W6a/W6b read buffers exactly 8,192 B, W1 responses 208 B / 4.3 KiB, W2 frames
<= 256 B in 97%. Survivors: at the chosen 8 KiB cap, 99.98% of W3's crossers and 100% of W5's are above the cap
(`w3.txt:56`, `w5.txt:59`; at 16 KiB it would be 97.35% / 86.10%), BUT W4's crossers are 65,536 B 29.6% / 8 B 59.3% / 4 B 11.1% (`w4.txt:50`): 70% of W4's
parked writes are 4-8 byte buffers that no size cap filters.

## 2. Consequences (D, from section 1)

1. An iteration-end reset is exact for class I in plain request/response: nothing is live at the marker.
2. Blocks get pinned by class W/A/D survivors. A cap of 8 KiB keeps nearly all surviving BYTES out (W3 99.98%, W5 100%
   of crossing buffers are above it), not W4's surviving COUNT (4-8 byte parked writes). Pinning must therefore cost little per pinned block: fixed small blocks, not geometric growth
   (in the PoC one 8-byte parked write can pin an 8 MiB block).
3. LIFO pop: the data does not rule it out (`only` is 100% on W6a); the PoC's counters showed it never firing on the
   E_COMMERCE harness (no LIFO on/off A/B was run). Dropped as a cost/complexity decision. What was built instead,
   later, is the **ring** of section 3.1: reuse inside an iteration that does not depend on the release ORDER at all,
   only on where the oldest live buffer sits. It is off by default because it costs +29.3 instructions per
   allocate/release pair on the direct path (M, `../results/ryzen9-7950x-node0/RESULTS.md` section 4.6).
4. Foreign release is a real pattern (W6b, proxy with separate event-loop groups): it is OUT OF SCOPE for the arena by
   decision (the maintainer's rule from the start: an arena buffer is confined to its event loop; release or retain
   elsewhere throws). Such pipelines use the adaptive allocator (opt-in / hint decides), not a cross-thread path.
5. The class of a buffer is decided by its consumer, not at allocation (W1's read buffer is class I, W5's is class A):
   tolerate survivors (pinned blocks) + bound + cap + fallback. Promotion/relocation is impossible without lifetime-tied
   raw views (`nioBuffer()`, `memoryAddress()`, slices) - see section 7.

## 3. Design: bounded iteration arena, size cap, fixed blocks reset at the hook, owner-only counters

Precedents (R): nginx per-request pool - small allocations bump-allocated below `pool->max`, larger ones go to the
general allocator (`src/core/ngx_palloc.c`); httpz - per-request `ArenaAllocator` reset at `requestDone()` with
`retain_with_limit` (`src/worker.zig`); Zig `StackFallbackAllocator` - bounded fast region, transparent fallback
(`lib/std/heap.zig`); TigerBeetle `MessagePool` - plain int
refcount, owner-only (`src/message_pool.zig`; it panics on exhaustion, we fall back instead).

Per event-loop thread (`FastThreadLocal`): a heap space and a direct space, each with fixed-size blocks obtained from
the adaptive allocator's own `ChunkAllocator`s (NOTE: outside adaptive's byte budget, by design - reported in metrics).
Buffer objects (`ArenaBuf`) live in a per-arena array, grown up to `maxObjects`; each has a stable `index`.

**Invariant A (confinement).** Every `ArenaBuf` and `Block` field is read and written ONLY by the owning event-loop
thread. `release()` and `retain()` (and `release(int)`, `retain(int)`) called on any other thread throw
`IllegalStateException` before touching anything; `refCnt()` off-thread is unspecified. There is no cross-thread path:
no list, no atomics, no wake-up, no drain. Contrast with adaptive's Invariant N and Dekker pair, which exist because
chunks move between lists, are deallocated, and accept foreign releases; none of that applies here. The price is the
scope: pipelines that hand arena buffers to another thread (W6b) must not use the arena; the throw makes a violation
visible immediately instead of corrupting memory.

- Allocation (hot): `size > cap` -> delegate (adaptive). Else bump in the current block; if full, take a block marked
  reusable by the last hook (see below), else grow (up to `maxBlocks`), else delegate. Object from the free-index stack.
  `refCnt = 1`, `block.live++`. Once per iteration (first allocation after a hook), arm the hook.
- Release on the owner thread (hot): `if (refCnt <= 0) throw IllegalReferenceCountException; if (--refCnt == 0)
  { block.live--; push index on the free stack }`. Nothing else: no reset, no pop.
- Release or retain on another thread: throws (Invariant A) - one `Thread.currentThread() == owner` compare on both
  `release()` and `retain()`, before any field is touched. NOTE (measured in code): `ReferenceCountUtil.safeRelease`
  catches Throwable and logs, and `ChannelOutboundBuffer` releases through it, so a violation on the write path is NOT
  fail-fast: it is logged, counted (section 6), and the buffer's block stays pinned. The counter is the observable.
- Hook (end of iteration, `executeAfterEventLoopIteration`, armed from allocation - a self-renewing tail task livelocks
  `runAllTasksFrom(tailTasks)` and keeps idle loops awake, measured): every block with `live == 0` becomes reusable (`bump = 0`, marked reusable); the current
  block stays current. Memory freed during an iteration is therefore NEVER reused before the next hook - which also
  makes any NIO view or raw address taken during the iteration safe until the iteration ends (section 7 for beyond).
- Pinned blocks: a block with `live > 0` at the hook is skipped by the allocator until a later hook finds it empty.
  Generational, no copy, no relocation. Cost of a pinned block = one fixed block = 32 x 8 KiB slots pinned by as little
  as one 8-byte parked write (W4's shape: 72 survivors at a marker, 70% of them 4-8 B, up to 86 ms). Nothing bounds how
  many blocks are pinned at once except `maxBlocks`: with all 8 pinned the space is 100% delegate until they drain.
  "Max simultaneously pinned blocks" is a metric (section 6) and a validation gate (section 5.2).
- Bound and fallback: the arena holds at most `maxBlocks` fixed blocks per space; when none is reusable and the bound is
  reached, allocation delegates. Nothing is ever freed except by `trim()` (explicit; shutdown / operator signal).
- Reallocation (`capacity(int)`): grow in place if the buffer is topmost in its block; else allocate a new region,
  copy, and treat the old region as released (`live--`; reused only after the next hook, so views of the old region
  taken in this iteration stay valid until the hook). If the new region comes from the delegate, the buffer enters an
  explicit DELEGATED state (`block = null`, it wraps the delegate buffer): its release then releases the delegate
  buffer and touches no block; it returns to the object pool like any other. `maxObjects` exhausted -> delegate too.

**Layout (D, decided during the PoC).** There is no block object on any path that runs per allocation, per
release, per block switch or per hook. A block is an `int` id in `[0, maxBlocks)` and a column of flat
per-space arrays: `int[] live`, `long[] base` (direct), `byte[][] mem` (heap), `ByteBuffer[] nio` (the source
the per-buffer views are duplicated from), `AbstractByteBuf[] roots` (the chunk, for the bulk paths and to
give the memory back). Two `int` bit masks hold the rest: `allocatedMask` (slot holds a chunk) and
`reusableMask` (bit i = block i was empty at the LAST hook and its bump is 0). The current block is flat
fields of the space - `curId`, `curBump`, `curMemory`, `curAddress` - so allocation touches the space's own
fields and the `int[]` object stack, nothing else. There is no `bump[]` column: only the current block is
ever bumped, and a block switched away from is never bumped again. Block switch is
`id = numberOfTrailingZeros(reusableMask)`; a zero mask means grow if under `maxBlocks`, else delegate, and
is also the latch that stops rescanning. The hook scans the `maxBlocks` live ints, resets the CURRENT
block's bump in place when it is empty (steady state on request/response: no switch ever happens) and
rebuilds the mask; it touches no buffer object. A buffer holds an `int blockId`, not a block reference, so
allocation writes ints and one `long` address; a HEAP buffer also keeps a `byte[] memory` field with a
guarded store (`if (memory != cur) memory = cur`), because every get/set needs the array and an indirection
through `roots[blockId]` on the data path is worse - that is the only reference store on a hot path and it
is paid once per block switch, not once per allocation. A DIRECT buffer keeps a plain `long address` and no
NIO root: views fetch `nio[blockId]` on demand. Release is `refCnt--`, `live[blockId]--`, push the object
index. The DELEGATED state is the column slot `maxBlocks`, so release needs no test on block identity
before the decrement.

**No in-band metadata (D).** Block memory holds user payload only: no per-allocation header, no per-block
header, no free-list link written into the block, no fill on retire, nothing written to a block at reset.
All bookkeeping is out of band, on the owner's own cache lines (the buffer objects, `int[] live`, the masks,
the `int[]` object free stack, the flat cursor). Consequence: metadata is never derived from an address -
the buffer carries its `int blockId`. Shape test: paint a block and check that allocate / grow / release /
hook / trim leave every byte of it untouched.

Defaults derived from the data (D): cap 8 KiB (section 1 sizes); block 256 KiB; `maxBlocks` 8 per space = 2 MiB per
loop per space. The governing quantity is the PEAK BYTES BUMP-ALLOCATED PER ITERATION (bump space is not reclaimed
before the hook): W1 max 48 allocations per iteration (`w1.txt:48`) at 8,192 / 4,370 / 208 B is ~200 KiB (inferred:
the size mix is workload-wide) - one block; survivors then add pinned blocks on top - W3's survivors are above the cap and
delegate, so they pin nothing; the pinning case is W4's 4-8 byte parked writes, which can pin up to `maxBlocks`. 32 loops x 2 spaces x 2 MiB = 128 MiB worst case, plateau,
never freed without `trim()`. NOT the PoC's 32 MiB: that came from the synthetic E_COMMERCE harness (1024 live x
4.7 KiB), not from these servers. `maxObjects` 16,384.

Not in the design: consumer hints (a later "never arena" mark for cumulation / io_uring producers), relocation, timers,
decaying purge, any change to adaptive.

### 3.1 The ring: reuse inside an iteration (`-Darena.ring`, default OFF)

The hook is the only reuse point of the design above, and it is exact but coarse: an iteration that
allocates more than one block's worth of bytes grows or delegates even when almost everything it
allocated is already dead. The ring is the answer to that, and it is **off by default** because it is
not free.

A block is used as a ring of variable-sized slots. The space keeps, per block, one bit per 8-byte
slot set at the START of every live buffer (`long[] startBits`, the current block's row cached in
`curBits` so the allocation path reads no column). When the tail `curBump` cannot serve a request
before the wall `curLimit`, a cold path runs:

* **not wrapped** (`curLimit == BLOCK_SIZE`): find the lowest live start in the block. None -> the
  block is empty, restart the tail at 0 in place (`ringResets`). Otherwise wrap the tail to 0 and put
  the wall at that start (`ringWraps`).
* **wrapped**: move the wall up to the next live start above it.
* if the request still does not fit, **re-enter** another non-empty block at the best free window its
  last scan found (`ringReentries`), else grow a block, else delegate.

**Invariant B (the ring never hands out live bytes).** `[curBump, curLimit)` holds no live buffer.
Proof (D, and written out in the class javadoc): a live buffer starting in that region would have its
start bit set there, and both branches above put the wall at the lowest live start at or above the
tail, so there is none; a live buffer starting below the tail ends at or before it, because every
buffer of the current pass was handed out by bumping and the in-place growth path refuses to grow
past `curLimit`; a buffer starting at or above the wall is outside the region by construction; and a
wrap resets the tail to 0 with the wall at the lowest live start of the whole block, so nothing lies
in `[0, head)`.

**The zero-slot rule.** `slotBytes(size) = max(8, align8(size))` - never zero. The bitmap has one bit
per 8-byte slot, so two buffers must never share a start: a zero-length buffer handed out at the tail
would set, and on release clear, the bit belonging to its neighbour, and the ring would then hand out
live bytes. It also keeps `start < BLOCK_SIZE`, so a zero-length request at
`curBump == curLimit == BLOCK_SIZE` cannot index one word past the bitmap. This was a real bug, fixed
in netty `14dbbe384b`; every ring number in the results is from a build at or after it.

**What it costs and what it buys** (M, `../results/ryzen9-7950x-node0/RESULTS.md` section 4.6):
+29.3 instructions per allocate/release pair on the direct path and +8.5 on the cycle cell's heap
column, for the shipped `long[][]` layout. Re-entry helps at 1024 live (direct 284.9 -> 270.1 ns/op,
heap 332.4 -> 292.1) and hurts at 4096 (392.1 -> 404.4, 416.7 -> 468.2). Two alternative metadata
layouts were measured and were worse, which is why the shipped one is a row per block rather than one
flat array: flat +36.0 / +17.7, flat + `Unsafe` +29.1 / +17.5.

**What it takes away.** With the ring on, the "nothing freed in an iteration is handed out before the
next hook" guarantee of section 3 is gone: the tail may wrap into the bytes of a buffer released
earlier in the same iteration. A raw view or address taken from a buffer that is still LIVE stays
valid - Invariant B says exactly that - but the window in which a view kept past its buffer's release
is harmless shrinks from one iteration to nothing. See section 7.

### 3.2 What the implementation does that the plan did not say (D)

Recorded here because they are real parts of the design now, not oversights:

1. **In-place capacity growth**, including above the cap: `capacity(int)` grows the topmost buffer of
   the current block in place when the block has room, and the ring path refuses to grow past
   `curLimit`. A buffer can therefore end up larger than `arena.cap` without ever leaving the arena.
2. **An object pool per space**, not per arena: `ArenaBuf[] objects` + an `int[]` free stack, grown to
   `maxObjects`, so a buffer object never migrates between the heap and the direct space and its
   `space` and `owner` fields are final.
3. **`DELEGATED` is a real column slot** (`DELEGATE_SLOT == maxBlocks`), so release decrements a
   column without first testing whether the buffer has a block.
4. **A manual JFR period** (`-Darena.jfr.period`): the JFR API this module compiles against has no
   throttle annotation.
5. **`endOfIteration()` is public**, because drivers that are not event loops need it (tests, and
   `-Dexpt.hookEvery=N` in the harness).
6. **The `int[] live` column of the plan is the `allocs`/`frees` pair**: a block is empty iff
   `allocs[id] == frees[id]`, which is what lets the statistics accumulate at reset rather than per
   operation (section 6).
7. **`-Darena.debugPinned`** (added after the io_uring runs): a diagnostic mode that captures every
   allocation's stack and charges each pinned block to the oldest buffer still live in it. Off by
   default; every field and branch of it folds away when it is off.

## 4. GC-free and JIT-friendly constraints (D)

- Zero allocations per allocate/release pair (preallocated objects, int free stack). NIO views allocate as adaptive's do (`nioBuffer()` a slice per call; one cached
  duplicate per buffer for `internalNioBuffer`, re-created after a move).
- No reference stores on the owner hot path except `block`/`root` when the buffer lands in another block (the PoC's
  first direct build regressed 15% until two such stores were removed; evidence `../results/ryzen9-7950x-node0/micro-v2/perfasm-new-v1-cardmarks.txt`).
- `root` is bimorphic at best (heap or direct chunk buffer), as adaptive's `rootParent` is; not a regression.
- Hot methods must inline into their callers: C2 refuses to inline an ALREADY-COMPILED callee whose code exceeds
  `InlineSmallCode` (2500 B on this JVM, `-XX:+PrintFlagsFinal`, measured to cost 12% on adaptive's event-loop path when
  it happens). Allocation and owner release each in one small method; hook, growth, delegate path, reallocation and
  the confinement violation in separate methods reached only on rare branches. Verified with `-XX:+PrintInlining` and
  `jcmd Compiler.codelist` on the harness, not by reading the Java.
- Per-arena plain `long` counters, read only by the owner or at shutdown; no `LongAdder` on the hot path.
- Per operation: one `FastThreadLocal.get()` on allocation; `Thread.currentThread() == owner` on release and retain.

## 5. The validation gates, and what they said

The gates were written before the implementation. This is what each one returned; the sources are
sections of `../results/ryzen9-7950x-node0/RESULTS.md`.

0. **Tests: PASSED.** The arena passes `AbstractByteBufTest`-derived suites for heap and direct
   (`CycleArenaHeapByteBufTest` / `CycleArenaDirectByteBufTest`, 412 cases each) plus
   `CycleArenaAllocatorTest` (30 cases) and `CycleArenaJfrTest`. The targeted cases the gate named
   are in there: release and retain on another thread throw, also through a slice or duplicate; a
   block pinned across resets; double release; `capacity()` move with a live view in the same
   iteration; no reuse of freed memory before the hook; thread termination with live buffers; hook
   after `isShutdown()`.
1. **Microbenchmarks: FAILED as a gate, and the failure is the design's declared scope.** "No cell
   worse than adaptive" does not hold. Where lifetimes are scope-aligned and under the cap the arena
   is -52% (heap) / -51% (direct) per allocate/release pair (2.8); with the hook driven at 1024 live
   it is 0.72x / 0.76x adaptive (2.10). From **4096 live buffers up the live set exceeds the 8-block
   bound**, the share falls 49% -> 4%, every block is pinned and the arena is 1.01-1.37x adaptive
   with 75-990 MB more RSS that is **not explained** (2.10). The `randomRelease` cell the gate
   singled out (122.1 vs 106.5 at 4096 live) was **never re-measured on v3** - it is A.3, a v2
   number - so the gate's own test case is still open.
2. **Topology re-run: PASSED, with the negative test firing as designed.** Arena share 99.99% (W1)
   to 11.85% (W5); maxPinned 0 on W1/W2/W6a, 7 on W3, 4 on W4/W5; zero confinement violations
   everywhere except W6b, which counts 2,140 and logs them (2.4). No early reuse was ever detected
   (`earlyReuses=0` in every run; `-Darena.debug` asserts it).
3. **End to end: PASSED as a regression check, and that is all it can be.** Three 2-million-request
   runs per build per protocol: h1 177.2k / 176.1k / 177.8k against 178.1k / 178.5k / 176.4k, h2
   388.5k / 389.7k / 390.4k against 385.9k / 387.3k / 391.6k (2.5). **Throughput did not change.**
   What moved is the allocator's share of event-loop CPU samples - h1 7.72% -> 7.15%, h2
   11.03% -> 9.25% on the narrow filter (2.6) - and instructions per request on h1 by about 1%,
   inside adaptive's own 1.9% three-run spread.
4. **RSS: PASSED.** With a fixed 1 GiB pre-touched heap the three allocators are within 17 MB on a
   1.3 GB process, the arena lowest (2.9). The bound shows as a plateau: the arena's own blocks are
   3 MiB and are never freed without `trim()`.

A fifth question the gates did not ask, and the io_uring runs forced: **which transport the arena is
for.** Sections 3-6 of the results answer it and [`uring.md`](uring.md) states the conclusion.

## 6. Metrics (per arena, plain longs)

arena/delegate allocations by space, blocks in use / pinned / reusable, max simultaneously pinned, confinement
violations (counted before throwing), hooks,
reallocations (in place / moved / delegated), trims. Exposed through the allocator's metric provider, never on the
hot path across threads.

Counting follows the JDK's TLAB rule - a TLAB's statistics are accumulated when it is RETIRED, never per object
(D, added during the PoC): allocations live in two per-block `int` columns (`allocs`, `frees`; a block is empty iff
they are equal) and are added to the space's plain `long` totals when the block is reset; bytes are added from the
cursor when a block is retired at a switch or reset by the hook. The bump and the release path therefore carry no
statistics instruction. Delegate allocations and confinement violations are counted per event, both being slow
paths already.

JFR (D, added during the PoC), modelled on the JDK's TLAB events, disabled by default and emitted only on cold
boundaries, so the bump and release paths carry no event instruction either: `io.netty.ArenaBlockSwitch`
(`jdk.ObjectAllocationInNewTLAB`), `io.netty.ArenaAllocationOutside` (`jdk.ObjectAllocationOutsideTLAB`),
`io.netty.ArenaAllocationSample` (`jdk.ObjectAllocationSample`, manual period), `io.netty.ArenaIteration` (one per
N hooks) and `io.netty.ArenaConfinementViolation` (with a stack trace). The per-buffer
`AllocateBuffer`/`FreeBuffer`/`ReallocateBuffer` events stay as the expensive mode.

The ring adds four counters, all 0 unless `-Darena.ring=true` and all written on cold paths:
`ringWraps` (the tail hit the wall with live buffers below it and wrapped), `ringResets` (it hit the wall with
nothing live and restarted in place), `ringScans` (live-start bitmap scans: one per wrap decision, one per
re-entry hint refresh) and `ringReentries`. `-Darena.ringStats=true` adds what a stalled ring leaves behind -
`ringStalls`, `stallBytes`, `strandedBytes` and a hole histogram - at the price of one walk of the space's buffer
objects plus a sort per stall; a run reporting those is not comparable with one that does not.

**Pinned-block attribution** (D, added after the io_uring runs). `maxPinned` says HOW MANY blocks a hook left
pinned; it never said WHY. `-Darena.debugPinned=true` makes every arena allocation capture its own stack and the
hook generation it was made in, and every `-Darena.debugPinned.period`-th hook that finds a pinned block walks the
space's buffer objects and charges the block to the allocation stack of the **oldest buffer still live in it**.
The result is one `ARENAPINNED` summary line and one `ARENAPINNEDSITE` line per stack, with the number of pinned
blocks charged to it, the greatest age in hooks, the average number of live buffers in the block and the average
size of the oldest one. It is a diagnostic: one stack capture per allocation, so its throughput is not comparable
with a run that does not set it, and the capture depth should be capped with `-XX:MaxJavaStackTraceDepth`. Every
field and branch of it folds away when the flag is off. A JFR event was considered and not taken: the counter
survives a run with no recording, which is how every other number in this repository is collected.

## 7. Known unsoundness and lifecycle edges (D)

- Raw views and addresses (`nioBuffer()`, `memoryAddress()`, `array()`) of a LIVE buffer stay valid: its region is not
  reused while `live > 0` (with the ring on, that is Invariant B; with it off, nothing in the block is reused before
  the next hook at all). A view kept after the buffer's release addresses memory that may be handed out again: the
  same bug class as with any pooled allocator. **The window depends on the ring.** With `-Darena.ring=false` it is
  one iteration; with the ring on it is zero - the tail can wrap into those bytes inside the same iteration. Stated,
  not solved; the arena is opt-in per allocator instance until it has soak time, and the ring is off by default.
- **Class D is not a corner case on io_uring, it is the normal path.** A provided-buffer-ring buffer is owned by the
  kernel from `add()` until the CQE and by the pipeline for as long as it holds the `retainedSlice`; a zero-copy
  write keeps its buffer alive until the notification. Both outlive the iteration that allocated them by
  construction, and the measurements are sections 3-5 of the results. The arena has no answer to this and should not
  be given one: see [`uring.md`](uring.md) and [`uring-registered-buffers.md`](uring-registered-buffers.md).
- Composites: a `CompositeByteBuf` holding arena components across iterations pins their blocks (class D behaviour).
- Thread termination: `FastThreadLocal.onRemoval` releases the block roots of blocks with `live == 0`. Blocks with
  live buffers LEAK until GC, unconditionally: under Invariant A no thread may release them once the owner is gone.
  Counted in metrics; acceptable for an opt-in allocator whose loops live as long as the process.
- Drivers that are not event loops: a public `endOfIteration()` runs the same hook body on the calling thread, for
  tests and for benchmarks that model a cycle. On an event loop nothing calls it - the hook is armed from the
  allocation path. A thread with no event loop and no such call never closes an iteration, so its arena fills its
  `maxBlocks` blocks once and then delegates for ever (measured on the JMH harness: arena share 0.00%).
- Shutdown: `executeAfterEventLoopIteration` rejects after `isShutdown()`; the arming path swallows the rejection; the
  allocator's `close()`/`trim()` is called by whoever owns the allocator (the bootstrap / the application), as with
  adaptive.

## 8. History

The PoC that this design was written against was branch `expt/event-loop-arena` @ `26bd14b195`: heap + direct via
adaptive's chunk allocators, bump, int refcount, three release policies (`zero` / `lifo` / `hook`), a tail-task hook
armed from allocation, `trim()`, global counters, growth in place or by move. Its numbers are Appendix A of
`../results/ryzen9-7950x-node0/RESULTS.md`, and they are **not** statements about the code described here.

v3 (`3dad84f578`) is a rewrite against sections 3-6 above, not a tuning of that build:
`arena.release`, `arena.hook`, `arena.retainBytes`, `arena.initialBlock`, `arena.maxBlock`, `arena.objects`,
`endOfCycle()` and `CycleArenaEndOfCycleHandler` do not exist any more (the handler was dropped in netty
`58a79ebd42`). The ring (`11adeba602`), the zero-slot fix (`14dbbe384b`), re-entry (`52b19c8ebf`) and the
pinned-block attribution (`256c1d86bd`) came after it.

## 9. What is decided and what is open

**Decided.**

- Confinement is the rule: pipelines that move buffers across loops are out of scope, and the counter plus the throw
  is the observable. W6b is the standing negative test.
- The defaults the topology re-run confirmed: cap 8 KiB, block 256 KiB, 8 blocks per space. They hold nothing pinned
  on W1/W2/W6a and at most 7 block-maxima on W3.
- The ring and re-entry stay OFF by default: they cost instructions on the hot path and they cost the
  "no reuse before the hook" guarantee (sections 3.1 and 7).
- The arena is not the allocator for io_uring's provided buffer ring, and a fixed per-loop slab is the shape the
  rest of the ecosystem uses ([`uring-registered-buffers.md`](uring-registered-buffers.md)).

**Open.**

- **Opt-in per allocator instance, or a default for event loops?** Nothing measured here argues for a default: on the
  example servers end-to-end throughput does not move, and above the 8-block bound the arena loses.
- **The scope signal.** The allocator cannot tell a cycle-scoped buffer from a surviving one; it tolerates survivors
  instead. Whether Netty can supply that hint from the code that knows the lifecycle is the question the whole
  experiment ends on, and nothing in this repository answers it.
- **The `randomRelease` gate (5.1) was never re-run on v3.** Until it is, "no cell worse than adaptive" has an
  untested counter-example.
- **The unexplained RSS excess above the bound** (75-990 MB at 4096 live and up, far more than the blocks account
  for) is not attributed.
