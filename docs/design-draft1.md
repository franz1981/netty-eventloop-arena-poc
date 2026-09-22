> **Draft 1, superseded** by [`design.md`](design.md) (draft 3, final). Kept for the review trail. Imported unchanged from `netty-bench/docs/event-loop-arena-design-draft1.md`.

# Event-loop arena for Netty: design plan (draft 1, 2026-09-22)

Status: DRAFT for review. Every claim below is either measured (M, with the source), taken from an existing system (R,
with the source), or a decision/inference (D). Nothing here is implemented beyond the PoC named in section 6.

## 1. Problem classes, measured

Source: `results/h2h-merged-x86-2026-09-22/topology/summary.txt` (JFR AllocateBuffer/FreeBuffer/ReallocateBuffer +
an IterationEnd marker per event loop; NIO transport; this branch's adaptive allocator; one 1-1.5 s window per workload).

| class | what | measured share | lifetime | release order |
|---|---|---|---|---|
| I - iteration-scoped | allocated and released on the same event loop within one iteration | 100% of buffers in h1 request/response (W1), h2 multiplexed (W2), proxy on one loop (W6a); 98% (W3), 91% (W4), 37% (W5) | 0 iterations; live buffers at every iteration end = 0 in W1/W2/W6a (13,954 / 4,180 / 388,922 markers) | FIFO (`oldest`) or interleaved (`middle`); `youngest` (LIFO with younger siblings live) = 0.00% in all workloads |
| W - write-parked | `ChannelOutboundBuffer` holds the encoded write until the socket accepts it | W3: 2.2% of buffers = 41% of bytes; W4: 8.7% = 20% | W3 p50 623 iterations, max 1,636 (424 ms); W4 up to 86 ms | n/a |
| A - aggregation / cumulation | `HttpObjectAggregator` (and by construction any cumulating decoder) retains parts across reads | W5: 63% of buffers = 69% of bytes, sizes 16-64 KiB | p50 11 iterations, p99 59, max 318 | FIFO |
| X - cross-thread | buffer read on one loop, released on another (proxy with separate groups) | W6b: 84% of buffers, 100% of them freed on another thread; W6a (same loop): 0% | 1 productive iteration | n/a |
| D - kernel/long-lived | io_uring provided/registered buffers, user-retained data | not measured (io_uring transport not built here); long-lived by construction | | |

Sizes (M): class I buffers are small: h1 read buffers 8 KiB, response head/body 208 B / 4.3 KiB, h2 frame buffers
9-256 B; class W/A survivors are 16-128 KiB composites and parts. So a size cap separates most surviving BYTES from
the arena while keeping most COUNT in it (W3: 41% of bytes cross in 2.2% of buffers).

## 2. Consequences for any arena design (D, from section 1)

1. An iteration-end reset is exact for class I in plain request/response: nothing is live at the marker.
2. Blocks are pinned by class W/A/D buffers. In W5 63% of buffers cross, so an arena that serves the aggregator's
   input is useless there (blocks never empty) unless survivors are kept out of it.
3. LIFO reclamation is worthless on Netty pipelines (0% `youngest`): drop the LIFO pop.
4. Foreign release is a real pattern (W6b): the arena must support it, not throw. It stays a slow path.
5. The escape decision cannot be made at allocation time by the allocator: the same read buffer is class I in W1 and
   class A in W5 (the aggregator retains it). Either the CONSUMER hints, or survivors are tolerated (pinned blocks +
   bound + fallback), or survivors are promoted at the hook (copy) - the last needs no escaped raw views, which Netty
   cannot guarantee today (`nioBuffer()`, `memoryAddress()`, slices). => tolerate + bound + size cap.

## 3. Design: bounded iteration arena with a size cap, generational blocks and a foreign-release list

Precedents (R): nginx per-request pool (small allocations bump-allocated, allocations above `pool->max` ~ page size
go to the general allocator and are tracked individually; `ngx_palloc.c`); httpz per-request `ArenaAllocator` reset at
`requestDone()` with `retain_with_limit` (`src/worker.zig`); Zig `StackFallbackAllocator` (bounded fast region,
transparent fallback; `lib/std/heap.zig`); TigerBeetle `MessagePool` (plain int refcount checkout/return; exhaustion
is not a fallback there - we differ); Seastar's cross-shard free (lock-free push to the owner, drained by the owner;
`src/core/memory.cc`) - the same protocol the adaptive allocator already uses for foreign releases.

Per event-loop thread (FastThreadLocal), heap and direct spaces, blocks obtained from the adaptive allocator's own
`ChunkAllocator`s (same accounting as adaptive chunks). Knobs: block size, max blocks, size cap, retained blocks.

- Allocation (hot): `size > cap` -> delegate (adaptive). Else bump in the current block; if full, take the next EMPTY
  block (`live == 0`), else grow (up to the bound), else delegate. Buffer object from a lazily filled array with an
  int free stack (no reference stores per op). Plain `int` refcount. Cost target: <= the PoC's 43-44 ns/op on the
  E_COMMERCE 1024 cell (adaptive 80-84).
- Release on the owner thread (hot): `--refCnt == 0` -> `--block.live`; that is all. No LIFO pop, no reset here.
- Release on another thread (slow, class X): CAS-push the (block, index) onto the arena's MPSC list (an int queue,
  no object), as adaptive's `externalFreeList`; the owner drains it at the hook. Never throw.
- Hook (end of iteration): armed from the allocation path once per iteration via
  `SingleThreadEventLoop.executeAfterEventLoopIteration` (never self-renewing from `run()`: livelock, and keeps an idle
  loop awake - measured 31x iteration inflation on W4). The hook drains the foreign list, then resets every block with
  `live == 0` (`bump = 0`), then applies the retention limit (blocks above `retainedBlocks` that are empty are returned
  to the chunk allocator; default = keep all, i.e. no trimming; `trim()` explicit only, for shutdown).
- Pinned blocks: a block with survivors is simply skipped by the allocator until it empties (generational, no copy,
  no relocation). With the size cap, survivors are few (W3: 2.2%, W4: 8.7% of buffers) so pinning is bounded by the
  count of parked writes / aggregated parts per loop, not by bytes.
- Bound and fallback: `maxBlocks` reached and no empty block -> delegate. Steady-state footprint is at most the bound
  per event loop; nothing is freed without `trim()`.
- Reallocation (`capacity(int)`): grow in place if topmost in its block, else allocate anew (arena or delegate) and
  copy, as the PoC does; the old segment's `live` decrements like a release.

What is NOT in the design: hints from Netty code (not needed for correctness; can be added later as "never arena" for
known class A/D producers, e.g. cumulation and io_uring provided buffers), relocation, timers, decaying purge.

## 4. GC-free and JIT-friendly constraints (D; the InlineSmallCode finding of 2026-09-22 applies)

- Zero allocations per operation on every path incl. foreign release (int MPSC queue, preallocated buffer objects).
- No reference stores on the hot path except when the buffer moves to another block (G1 card marks measured at
  +28 instructions/op in the PoC before removal).
- Monomorphic types on the hot path: one `Block` class, one `ArenaBuf` class, `AbstractByteBuf root` accessed through
  a final field of the concrete chunk-buffer type where possible; no interface calls, no lambdas, no `switch` on the
  policy in the hot path (the policy is a static final).
- Hot methods small enough to inline into their callers under the default `InlineSmallCode` (2500 B of machine code):
  allocation and owner-release each in one small method; the hook, growth, foreign release and delegate paths in
  separate methods that are only reached on rare branches. Verify with `-XX:+PrintInlining` / `jcmd Compiler.codelist`
  as done for the adaptive allocator, not by reading the Java.
- No `ThreadLocal` lookup per operation beyond the one `FastThreadLocal.get()` (index access), no `Thread.currentThread()`
  compare on allocation (only on release, where it decides local vs foreign).

## 5. Validation plan (what must be true before this goes anywhere)

1. Microbenchmarks (existing harness, 3 forks, 2300 MHz, pinned): E_COMMERCE 1024 / 4096, 1 and 32 threads, heap and
   direct, `randomRelease` variant: must not be worse than adaptive in any cell, and ~-50% at 1 thread as the PoC.
2. Topology re-run (same six workloads) with the arena: arena share per workload, pinned blocks per loop, fallback
   rate, and NO cross-iteration surviving arena block on W1/W2/W6a; W6b must be correct (foreign releases) with the
   expected fallback rate.
3. End to end with logging off: no regression on any workload (the allocator is ~0.03-0.05 us of ~46 us per request on
   these servers: e2e is a regression check, not a benefit measurement).
4. RSS over time and peak vs adaptive on the same runs; the bound must be visible as a plateau.

## 6. State of the PoC (branch `expt/event-loop-arena` @ 26bd14b195)

Has: heap + direct via adaptive's chunk allocators, bump, int refcount, reset-on-zero / LIFO pop / hook policies,
tail-task hook armed from allocation, `trim()`, counters, growth in place or by move. Measured 43-44 ns/op vs adaptive
80-84 (E_COMMERCE 1024, 1 thread). Missing vs section 3: size cap, foreign-release list (it throws), removal of the
LIFO pop, hook-driven reset as the single policy, the JIT verification of section 4.

## 7. Open decisions for the maintainer

- Size cap default (data suggests 8-16 KiB; adaptive's size classes go to 128 KiB).
- Bound default per event loop (PoC: 4 blocks x2 from 256 KiB = 3.75 MiB was too small for 1024 live x 4.7 KiB; 8 blocks
  = 31.75 MiB served 100%).
- Whether the arena is on by default for event loops or opt-in per allocator instance.
