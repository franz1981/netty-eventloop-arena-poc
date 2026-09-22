> **Draft 3, final** (three Opus reviews: draft 1 revise; draft 2b revise-small; draft 3 two text fixes, applied). Imported unchanged from `netty-bench/docs/event-loop-arena-design.md` on 2026-09-22. Draft 1 is kept as [`design-draft1.md`](design-draft1.md) so the review trail is visible.

# Event-loop arena for Netty: design plan (draft 3, 2026-09-22)

Status: DRAFT 3, final (three Opus reviews: draft 1 revise; draft 2b revise-small; draft 3 two text fixes, applied) (`event-loop-arena-design-draft1.md`). Every claim is measured
(M, with source), taken from an existing system (R, with source), or a decision/inference (D). Not implemented beyond
the PoC of section 8.

## 1. Problem classes, measured

Source: `results/h2h-merged-x86-2026-09-22/topology/` (`summary.txt`, `w1.txt`..`w6b.txt`): JFR AllocateBuffer /
FreeBuffer (stack) / ReallocateBuffer + an `IterationEnd` marker per event loop; NIO transport; this branch's adaptive
allocator at `cfb23bcf63`; ONE 1-1.5 s window per workload, no repeats; iteration counts are inflated on near-idle loops
by the marker task (W4: 31x CPU, `control.txt`), so W4/W5 use wall-clock or the read-iteration row.

| class | what | measured share | lifetime | release order |
|---|---|---|---|---|
| I - iteration-scoped | allocated and released on the same event loop within one iteration | 100% of buffers in W1 (h1 POST), W2 (h2 multiplexed), W6a (proxy on one loop); 98% W3, 91% W4, 37% W5 | 0 iterations; live buffers at every iteration end = 0 in W1/W2/W6a (13,954 / 4,180 / 388,922 markers) | FIFO (`oldest`, W1 67%, W5 55%) or interleaved (`middle`, W2 68%, W3 99%, W4 97%); the released buffer is the ONLY live one in 100% W6a, 59% W6b, 33% W1 (`only`); `youngest` (LIFO with older siblings still live) 0% everywhere |
| W - write-parked | `ChannelOutboundBuffer` holds the encoded write until the socket accepts it | W3 (h2, 4 KiB client window, 64 KiB echo): 2.2% of buffers = 41% of bytes; W4 (h1 slow readers, SO_SNDBUF 16 KiB): 8.7% = 20% | W3: longest-lived by iterations 1,636 it / 18.1 ms, by time 424 ms / 1,059 it; W4 up to 86 ms | n/a |
| A - aggregation / cumulation | `HttpObjectAggregator` (by construction any cumulating decoder) retains parts across reads | W5 (256 KiB bodies): 63% of buffers = 69% of bytes, sizes 16-64 KiB | read-iterations: 0 = 37%, 1 = 7%, 2-3 = 13%, 4-7 = 18%, 8+ = 25%; wall-clock p50 77 us, p99 228 us, max 1.2 ms | FIFO |
| X - cross-thread | read on one loop, released on another | W6b (proxy with separate groups): 84% of buffers, 100% of those freed on another thread; W6a (same loop): 0% | 1 productive iteration | n/a |
| D - kernel / long-lived | io_uring provided/registered buffers, user-retained data, composites kept across iterations | not measured (io_uring not built here) | long-lived by construction | n/a |

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
   E_COMMERCE harness (no LIFO on/off A/B was run). Dropped as a cost/complexity decision; revisit with W6a-shaped data.
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

Defaults derived from the data (D): cap 8 KiB (section 1 sizes); block 256 KiB; `maxBlocks` 8 per space = 2 MiB per
loop per space. The governing quantity is the PEAK BYTES BUMP-ALLOCATED PER ITERATION (bump space is not reclaimed
before the hook): W1 max 48 allocations per iteration (`w1.txt:48`) at 8,192 / 4,370 / 208 B is ~200 KiB (inferred:
the size mix is workload-wide) - one block; survivors then add pinned blocks on top - W3's survivors are above the cap and
delegate, so they pin nothing; the pinning case is W4's 4-8 byte parked writes, which can pin up to `maxBlocks`. 32 loops x 2 spaces x 2 MiB = 128 MiB worst case, plateau,
never freed without `trim()`. NOT the PoC's 32 MiB: that came from the synthetic E_COMMERCE harness (1024 live x
4.7 KiB), not from these servers. `maxObjects` 16,384.

Not in the design: consumer hints (a later "never arena" mark for cumulation / io_uring producers), relocation, timers,
decaying purge, any change to adaptive.

## 4. GC-free and JIT-friendly constraints (D)

- Zero allocations per allocate/release pair (preallocated objects, int free stack). NIO views allocate as adaptive's do (`nioBuffer()` a slice per call; one cached
  duplicate per buffer for `internalNioBuffer`, re-created after a move).
- No reference stores on the owner hot path except `block`/`root` when the buffer lands in another block (the PoC's
  first direct build regressed 15% until two such stores were removed; evidence `micro-v2/perfasm-new-v1-cardmarks.txt`).
- `root` is bimorphic at best (heap or direct chunk buffer), as adaptive's `rootParent` is; not a regression.
- Hot methods must inline into their callers: C2 refuses to inline an ALREADY-COMPILED callee whose code exceeds
  `InlineSmallCode` (2500 B on this JVM, `-XX:+PrintFlagsFinal`, measured to cost 12% on adaptive's event-loop path when
  it happens). Allocation and owner release each in one small method; hook, growth, delegate path, reallocation and
  the confinement violation in separate methods reached only on rare branches. Verified with `-XX:+PrintInlining` and
  `jcmd Compiler.codelist` on the harness, not by reading the Java.
- Per-arena plain `long` counters, read only by the owner or at shutdown; no `LongAdder` on the hot path.
- Per operation: one `FastThreadLocal.get()` on allocation; `Thread.currentThread() == owner` on release and retain.

## 5. Validation gates (before any benchmark)

0. Tests: the arena passes `AbstractByteBufTest`-derived suites for heap and direct; targeted tests for: release and
   retain on another thread throw (also through a slice/duplicate), block pinned across resets, double release
   (throws), `capacity()` move with a live view in the same iteration, no reuse of freed memory before the hook,
   thread termination with live buffers, hook after `isShutdown()`.
1. Microbenchmarks (existing harness, 3 forks, 2300 MHz, pinned): E_COMMERCE 1024 / 4096, 1 and 32 threads, heap and
   direct, `randomRelease` variant: no cell worse than adaptive. KNOWN FAILING TODAY with the PoC: `randomRelease`
   4096 live at 1 thread, ARENA 122.1 vs ADAPTIVE 106.5 (arena share 22%): the fixed blocks + cap + delegate must fix
   this or the design is rejected. Target at 1 thread ~-50% as the PoC's 43-44 ns vs 80-84 (those cells were run with
   `-Darena.release=lifo`, not the hook policy, and survive only as transcribed console lines - to be re-measured).
2. Topology re-run (same six workloads, same launcher) with the arena: arena share, pinned blocks per loop at the hook,
   fallback rate, max simultaneously pinned blocks per loop (W3/W4/W5 are the cases); NO reusable-block reuse before a
   hook (assertion in a debug build); W6b with the arena must show the confinement-violation counter > 0 and log the
   exceptions (it will NOT fail fast: `ReferenceCountUtil.safeRelease` swallows), and pass with adaptive - the negative
   test for the scope rule.
3. End to end with logging off: no regression (h2 ~672k req/s, h1 ~300k on this box). The allocator is ~1% of a
   request here (W1: 3 buffers x 84 ns = 0.25 us of ~26 us at 300k req/s over 8 loops), so e2e is a regression check.
4. RSS over time: the bound must show as a plateau; pinned-block count in metrics.

## 6. Metrics (per arena, plain longs)

arena/delegate allocations by space, blocks in use / pinned / reusable, max simultaneously pinned, confinement
violations (counted before throwing), hooks,
reallocations (in place / moved / delegated), trims. Exposed through the allocator's metric provider, never on the
hot path across threads.

## 7. Known unsoundness and lifecycle edges (D)

- Raw views and addresses (`nioBuffer()`, `memoryAddress()`, `array()`) of a LIVE buffer stay valid: its region is not
  reused while `live > 0`. A view kept after the buffer's release addresses memory that the next hook may hand out
  again: the same bug class as with any pooled allocator, with a shorter window (one iteration). Stated, not solved;
  the arena is opt-in per allocator instance until it has soak time.
- Composites: a `CompositeByteBuf` holding arena components across iterations pins their blocks (class D behaviour).
- Thread termination: `FastThreadLocal.onRemoval` releases the block roots of blocks with `live == 0`. Blocks with
  live buffers LEAK until GC, unconditionally: under Invariant A no thread may release them once the owner is gone.
  Counted in metrics; acceptable for an opt-in allocator whose loops live as long as the process.
- Shutdown: `executeAfterEventLoopIteration` rejects after `isShutdown()`; the arming path swallows the rejection; the
  allocator's `close()`/`trim()` is called by whoever owns the allocator (the bootstrap / the application), as with
  adaptive.

## 8. State of the PoC (branch `expt/event-loop-arena` @ 26bd14b195)

Has: heap + direct via adaptive's chunk allocators, bump, int refcount, reset-on-zero / LIFO / hook policies, tail-task
hook armed from allocation, `trim()`, global counters, growth in place or by move. Micro: 43-44 ns/op vs adaptive 80-84
(E_COMMERCE 1024, 1 thread, from a jar at 26bd14b195; the topology study ran at cfb23bcf63). Missing vs section 3:
Invariant A enforced before any field access on both release and retain (today `release()` decrements `refCnt`
before the owner check, and `retain()` never checks), cap, fixed blocks with reuse only across the hook, the DELEGATED
reallocation state, underflow detection, per-arena metrics, termination handling, tests; the LIFO and reset-on-zero policies to
be removed.

## 9. Open decisions for the maintainer

- Confinement is the rule (decided): pipelines that move buffers across loops are out of scope.
- Cap 8 KiB, block 256 KiB, 8 blocks per space: defaults to confirm with the topology re-run.
- Opt-in per allocator instance vs default for event loops.
