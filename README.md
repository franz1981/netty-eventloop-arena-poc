# Event-loop cycle arena - proof of concept

An experiment on Netty's allocator. **Not a proposal, not a patch anyone should merge, and not a
recommendation to change Netty's default.** It exists to answer one question with measurements: if
most buffers on an event loop are allocated and released on the same thread inside one iteration,
how much does a bump arena that assumes exactly that buy, and where does the assumption break?

The short answer, measured on this machine and stated up front: **on the example servers the
allocator is second order and adaptive is the better default.** The details, with the numbers, are
in [What it buys and what it does not](#what-it-buys-and-what-it-does-not).

## The design, as it exists today

One arena per event-loop thread (`FastThreadLocal`), with a heap space and a direct space. Each
space bump-allocates out of fixed **256 KiB blocks taken from adaptive's own chunk allocators**;
a request above the **8 KiB cap** never enters the arena and goes straight to the delegate, which is
an ordinary `AdaptiveByteBufAllocator` and is also the fallback when the space's 8-block bound is
reached, when the buffer-object pool is exhausted, or when the calling thread is not an event loop.
Allocation is a bump in the current block and release is a plain `int` decrement - no atomics, no
size classes, no free lists, no cross-thread path - and a buffer is confined to its loop: `retain()`
or `release()` from another thread throws and is counted. Bytes come back at **the event loop's own
end-of-iteration tail task** (`endOfIteration()`), which resets every block that is completely
empty; a block still holding a live buffer is "pinned" and is skipped until a later hook finds it
empty. With the optional `-Darena.ring=true` a block is *also* reused inside an iteration, as a
variable-slot ring whose tail wraps below the oldest live buffer start, and a stalled ring
**re-enters** another non-empty block that has room before growing or delegating; both are off by
default because they cost instructions on the hot path (see
[RESULTS.md 4.6](results/ryzen9-7950x-node0/RESULTS.md#46-what-the-ring-and-the-re-entry-cost-on-the-microbenchmarks)).

The PoC is `io.netty.buffer.CycleArenaAllocator`, in the `netty` submodule (branch
`expt/event-loop-arena`).

**What the PoC deliberately is not:** it has no way to know whether a buffer is cycle-scoped. Every
allocation under the cap goes to the arena. In a real design that decision would be a hint from the
Netty code that knows the lifecycle, not something the allocator guesses.

### Knobs

Every knob is a system property, read once in `CycleArenaAllocator`.

| knob | default | what it does |
|---|---|---|
| `-Darena.blockSize` | 262144 | fixed block size. Fixed, not geometric: a pinned block must cost little |
| `-Darena.maxBlocks` | 8 | blocks per space; when none is reusable and the bound is reached, allocation delegates (`maxBlocks <= 32`: the masks are `int`s) |
| `-Darena.cap` | 8192 | a request above it goes straight to adaptive, which keeps the bytes most likely to survive the iteration out of the arena |
| `-Darena.maxObjects` | 16384 | bound on the per-space buffer-object pool; past it, allocation delegates |
| `-Darena.ring` | false | reuse a block as a variable-slot ring, wrapping below the oldest live start, instead of waiting for it to drain. On: +29 instructions per allocate/release pair on the direct path |
| `-Darena.ringStats` | false | at every ring stall, measure what the ring leaves behind (`ringStalls`, `stallBytes`, `strandedBytes`, the hole histogram). One walk of the space's buffer objects plus a sort per stall: a run that reports these is not comparable with one that does not |
| `-Darena.debug` | false | checks that no block is reused before a hook; folded away when false |
| `-Darena.debugPinned` | false | diagnostic: capture every allocation's stack and charge each pinned block to the oldest buffer still live in it (`ARENAPINNED` / `ARENAPINNEDSITE` lines). **One stack capture per allocation** - cap the depth with `-XX:MaxJavaStackTraceDepth` and never compare its throughput with a run that does not set it |
| `-Darena.debugPinned.period` | 64 | hooks between two attribution walks; only hooks that find a pinned block count |
| `-Darena.debugPinned.frames` | 16 | frames kept per attributed stack, after the allocator's own `io.netty.buffer` frames |
| `-Darena.jfr.period` | 1000 | hooks per `ArenaIteration` / `ArenaAllocationSample` event |

## Mechanics

```
 event loop thread N
 +---------------------------------------------------------------------------------------------+
 |  Arena (plain fields, owner thread only, no atomics, no cross-thread path)                    |
 |                                                                                              |
 |  Space: heap                              Space: direct                                      |
 |  +-----------+ +-----------+ +---------+  +-----------+ +-----------+ +---------+            |
 |  | current   | | reusable  | | pinned  |  | current   | | reusable  | |  ...    |            |
 |  | bump ->   | | live == 0 | | live > 0|  | bump ->   | | live == 0 | |         |            |
 |  +-----------+ +-----------+ +---------+  +-----------+ +-----------+ +---------+            |
 |   256 KiB blocks, at most 8 per space (2 MiB), requests > 8 KiB never enter                  |
 |                                                                                              |
 |  block metadata = columns, no Block object on any hot path:                                  |
 |     int[] allocs, int[] frees        (block empty <=> allocs[id] == frees[id])               |
 |     int   reusableMask               (next block = numberOfTrailingZeros(mask))              |
 |     AbstractByteBuf[] roots          (the block's backing buffer; read on a block switch)    |
 |     flat: curId, curBump, curLimit                                                           |
 |     ring only (-Darena.ring=true): tailBump/tailLimit/freeBase/freeLimit/freeHint/hintFrees  |
 |                                     and long[][] startBits, one bit per live buffer start    |
 |                                                                                              |
 |  ArenaBuf objects: preallocated array + int[] free stack; each holds                         |
 |     int blockId, start, length, refCnt + the block's root parent (guarded store, no header)  |
 |     element access forwards to that root parent at start + i, as AdaptiveByteBuf does        |
 +---------------------------------------------------------------------------------------------+
        |  size > cap, bound reached, pool exhausted, off-loop thread
        v
   AdaptiveByteBufAllocator (unchanged) - also the source of the arena's blocks
```

Block memory holds user payload only: no per-allocation header, no per-block header, no free-list
links, no fill. Everything the allocator knows lives on the owner's own cache lines.

```
 iteration k                                                             iteration k+1
 |-- runIo(): reads ---- pipeline: decode/handle/encode/flush ---- runAllTasks() --|HOOK|-----------
     [read buf 8 KiB   bump ........................ release: frees[id]++ ]
                  [headers 208 B ....... release]
                    [body 4 KiB .............. write completes, release]
                      [parked write (socket full) .......................... still live at HOOK ]
                                                                            |
   at the HOOK (tail task, armed by the first allocation of the iteration): |
     every block with allocs == frees  -> bump = 0, reusable               |
     the block holding the parked write -> skipped ("pinned") until a later hook finds it empty
   nothing freed during iteration k is handed out before the HOOK - unless -Darena.ring=true, which
   lets the tail wrap inside the current block below the oldest live start. With the ring off, NIO
   views and addresses taken during an iteration stay valid until it ends.
```

Confinement (Invariant A): `retain()`/`release()` from another thread throw before touching any
field; a counter records it, because `ReferenceCountUtil.safeRelease` swallows the exception.
Pipelines that cross event loops must not use the arena (the cross-loop proxy W6b is the negative
test).

### How the next block is chosen (there is no "best fit")

The question "which block fits this request?" never arises, for two reasons that hold by
construction:

1. every block has the same size (256 KiB), and every request that reaches the arena is at most the
   cap (8 KiB), so any block with room for a bump fits any request;
2. a block is marked reusable only when it is *completely* empty (`allocs[id] == frees[id]` at the
   hook), and only the current block is ever bumped. So a reusable block always has `bump == 0`:
   there are no partially used blocks to compare, no holes to search, nothing to rank.

What remains is "is there an empty block, and which one": one `int` answers it.

```
 reusableMask   bit i set  <=>  block i was found empty by the LAST hook

 allocate(size):
     end = curBump + align8(size)
     if end <= 256 KiB:                 -> bump the current block (the hot path: no block decision at all)
     else:                               -> switchBlock()

 switchBlock():
     if reusableMask == 0:
         if blockCount < 8:  grow one block, make it current        (blockGrowths++)
         else:               exhausted = true; return null          (-> delegate until the next hook)
     id = numberOfTrailingZeros(reusableMask)     # lowest set bit: one instruction, no walk
     reusableMask &= reusableMask - 1             # clear it
     curId = id; curBump = 0; curLimit = BLOCK_SIZE; curRoot = roots[id]
     (blockReuses++)

 hook():                                          # end of the event-loop iteration
     mask = 0
     for each allocated block id:
         if allocs[id] == frees[id]:              # 8 ints, one cache line
             allocs[id] = frees[id] = 0
             if id == curId: curBump = 0          # the current block resets IN PLACE
             else:            mask |= 1 << id
     reusableMask = mask; exhausted = false
```

With `-Darena.ring=true` two cold paths are inserted before `switchBlock()`: the tail wraps inside
the current block to the lowest live start, and if that still does not fit, the allocator re-enters
another non-empty block at its best free window. Neither changes the picture above; both add
instructions to the hot path, which is why they are off by default.

### By example

Three cases, on a block drawn with 16 slots: a letter = a live buffer, `.` = released, `|` = the
bump. Animated: [`docs/mechanics.html`](docs/mechanics.html)
(rendered: <https://franz1981.github.io/netty-eventloop-arena-poc/docs/mechanics.html>).

**1. The bump only advances.** Allocate `a`, release `a`, allocate `b`:

```
[a|             ]   ->   [.|             ]   ->   [. b|           ]
allocs=1 frees=0         allocs=1 frees=1         allocs=2 frees=1
```

`b` lands after `a`'s slot, not in it: a release increments `frees` and nothing else. `a`'s bytes
come back only at the hook, and only if the whole block is empty then (`allocs == frees`) - in which
case the bump goes back to 0, in place if this is the current block.

**2. Release order does not matter.** Allocate `a`, `b`, `c`, then release `c`, `b`, `a` - perfect
LIFO:

```
[a b c|         ]   ->   [a b .|         ]   ->   [a . .|         ]   ->   [. . .|         ]
                                                                           allocs=3 frees=3
```

The bump stays at 3 through all of it; the block is empty at the end but still hands out nothing
until the hook. Reuse timing must not depend on the order releases arrive in - that is what makes it
one compare per release with no LIFO pop - and it is what keeps an NIO view or a raw address taken
during the iteration valid for the rest of the iteration.

**3. One survivor pins a block.** Allocate `a`..`p` (the block is full), release all but `p`, then
hook:

```
[a b c d e f g h i j k l m n o p|]   ->   [. . . . . . . . . . . . . . . p|]
                                          allocs=16 frees=15  ->  HOOK: pinned
```

`allocs != frees`, so the hook leaves the block alone: the mask bit stays clear and the 15 released
slots are unavailable until some later hook finds `p` gone. The next allocation takes the lowest set
bit of `reusableMask`, else grows a block, else delegates to adaptive. If the pinned block is the
current one, its free tail ahead of the bump is still bumped - pinned stops reuse, not allocation.

Rules, in five lines:

1. the bump only advances; a release only increments `frees`;
2. a block is reset only at a hook, and only when `allocs == frees`;
3. the current block resets in place; the others are published through `reusableMask`;
4. a full block is left for the lowest mask bit, else growth, else the delegate;
5. released bytes behind the bump are never handed out before a hook (unless `-Darena.ring=true`),
   and a pinned block's free tail ahead of the bump is still used while it is current.

The steady state on a request/response loop is case 2 followed by a hook that finds the block empty:
everything allocated in an iteration is released in it, the current block resets in place, and
`switchBlock()` never runs at all.

### Counters

`CycleArenaAllocator.counters()` prints one process-wide `ARENATELE` line - the knobs, then arena
and delegate allocations per space, `arenaShare`, blocks in use / pinned / reusable,
`maxPinnedHeap` / `maxPinnedDirect`, block reuses and growths, the four ring counters (`ringWraps`,
`ringResets`, `ringScans`, `ringReentries`, all 0 unless `-Darena.ring=true`), `hooks`,
`hookRejections`, confinement `violations`, `earlyReuses`, the three reallocation counters,
`trims` / `trimmedBlocks` / `leakedBlocks`, `objects`, bytes and live buffers per space - followed
by one `ARENALOOP` line per live arena (per event loop), and, under `-Darena.debugPinned=true`, an
`ARENAPINNED` summary plus one `ARENAPINNEDSITE` line per allocation stack that was found holding a
pinned block. It is called off the hot path: at shutdown, or from a benchmark's teardown.

### JFR events

Modelled on the JDK's TLAB events and emitted **only on cold boundaries** - a block switch, the
hook, a delegate allocation, a confinement violation - so the bump and release paths carry no event
instruction, exactly as `jdk.ObjectAllocationInNewTLAB` carries none in the TLAB fast path. All are
disabled by default. Source: `netty/buffer/src/main/java/io/netty/buffer/ArenaEvents.java`.

| event | analogue in the JDK | fields |
|---|---|---|
| `io.netty.ArenaBlockSwitch` | `jdk.ObjectAllocationInNewTLAB` | `bytesBumped`, `allocations`, `liveAtRetire`, `blockId`, `next` (REUSE / GROWTH / DELEGATE), `space` (HEAP / DIRECT) |
| `io.netty.ArenaAllocationOutside` | `jdk.ObjectAllocationOutsideTLAB` | `size`, `reason` (CAP / BOUND / OBJECTS / OFF_LOOP), `space` |
| `io.netty.ArenaAllocationSample` | `jdk.ObjectAllocationSample` | `weight` (bytes bumped since the previous sample), `allocations`, `space` |
| `io.netty.ArenaIteration` | - | `blocksReset`, `pinned`, `bytesBumped`, `allocations`, `delegated`, `hooks` (how many hooks this event stands for), `space` |
| `io.netty.ArenaConfinementViolation` | - | `owner`, `offender`, `operation` (RETAIN / RELEASE); keeps stack traces |

`ArenaIteration` and `ArenaAllocationSample` are emitted once every `-Darena.jfr.period` hooks
(default 1000). The period is manual because the JFR API this module compiles against has no
throttle annotation.

### What each benchmark measures, and what it cannot show

| benchmark | measures | cannot show |
|---|---|---|
| `CycleScopedAllocBenchmark` | allocate k buffers, use, release all k: the best case, perfectly scope-aligned | anything about buffers that outlive the cycle; it is an upper bound on the win |
| `ByteBufAllocatorAllocPatternBenchmark` | a steady-state live set with a random release order over a ring of slots | real lifetime *distributions*: every buffer gets the same lifetime, so blocks drain deterministically |
| the same with `-Dexpt.randomRelease=true` | geometric lifetimes with the same mean | still a synthetic distribution, and still no application-level retention |
| the JFR lifetime study (`run-lifetimes.sh`) | same-thread ratio and "allocations in between" for real buffers in two netty example servers | applications that retain buffers - aggregation, queues, backpressure. It is a **lower bound** on real lifetimes |
| `-Dexpt.reuse=true` | reuse distance and 4 KiB page locality of the memory handed out | it is a probe for explaining a result, not a result |
| the lifecycle-topology study (`topology/`) | buffer lifetime in event-loop iterations, nesting class at release, release cause, bytes crossing an iteration, across seven real pipelines | one short window per workload, no derived-buffer events; it describes shapes, not converged numbers |
| `run-e2e.sh` | a real example server under h2load: req/s, request latency, RSS over time, young GC count, arena counters | **it cannot distinguish allocators at all** on these servers - see the results below |

### Driving the hook off an event loop

The harness thread is not an event loop, so it never closes an iteration and the arena never reuses
a block. `netty-allocator` (`e9fa807`) adds **`-Dexpt.hookEvery=N`** to
`ByteBufAllocatorAllocPatternBenchmark`: every N allocations the benchmark state calls
`endOfIteration()`. The default 0 leaves the arena hookless - and those runs measure adaptive plus
the delegate detour, not the arena. `CycleScopedAllocBenchmark` calls `endOfIteration()` at the end
of every invocation, because one invocation there *is* one event-loop iteration.

## Reproducing

### Submodules

```
git clone --recurse-submodules https://github.com/franz1981/netty-eventloop-arena-poc.git
```

(`git submodule update --init` after a plain clone does the same.)

| submodule | repository | branch | pinned commit |
|---|---|---|---|
| `netty` | `https://github.com/franz1981/netty.git` | `expt/event-loop-arena` | `256c1d86bd` |
| `netty-allocator` | `https://github.com/franz1981/netty-allocator.git` | `cycle-arena-bench` | `e9fa807` |

Both branches are on GitHub at the pinned commits, so a fresh clone resolves them.

`netty-allocator` is lao's harness (`neoionet/netty-allocator`) with four commits on top of its
`1.2` head: the cycle benchmark, the harness additions, the `-Dexpt.hookEvery` hook driver, and
nothing else. `ARENA` there resolves to `io.netty.buffer.CycleArenaAllocator` from the `netty`
submodule - the class has exactly one source of truth.

Which commit measured which section of the results is recorded in
[RESULTS.md](results/ryzen9-7950x-node0/RESULTS.md); `256c1d86bd` is `52b19c8ebf` plus the
`-Darena.debugPinned` diagnostic mode, which is off by default. When it is off its branches read a
`static final false` and fold away; what it does add unconditionally is 10 bytes of bytecode to
`ArenaBuf.init()`, taking it from 63 to 73, which is on the same side of both `MaxInlineSize` (35)
and `FreqInlineSize` (325) as before. **That is a bytecode-size argument, not a measurement**: no
A/B of `52b19c8ebf` against `256c1d86bd` was run.

### Build

`java` and `mvn` are taken from `PATH`.

```
./build.sh                    # or:  MVN_FLAGS="-q -o" ./build.sh   (offline)
```

This installs the `netty` submodule's `buffer` and `common` modules into `~/.m2` - **overwriting any
snapshot of the same version already there** - builds the harness against exactly that version, and
copies the shaded jar to `target/benchmarks.jar`. It also installs the `example` module, which
`run-e2e.sh`, the lifetime study and the topology study all need (`--no-example` skips it), and the
epoll / io_uring native transports (`WITH_NATIVE=0` skips them, and then only `TRANSPORT=nio` runs).

### CPU sets

All machine knobs are in [`lib/env.sh`](lib/env.sh), each with a machine-neutral default:
`SUT_PIN_CMD` and `LOADGEN_PIN_CMD` (both empty), `CPU_FREQ_HOOK` (empty; a script taking `pin` /
`restore`), `JVM_OPTS` (empty; the reference runs used `-XX:MaxRAM=60g`), `FORKS` / `WI` / `I` /
`W` / `R` / `THREADS`, `MVN_FLAGS`, `RESULTS_DIR` (default `out/`).

The server under test and the load generator must not share cores. `./topology.sh` reads this
machine's own `lscpu -e=CPU,NODE,CORE` and prints, per NUMA node, the physical cores, their SMT
siblings, and a suggestion for two disjoint sets (it is only a printer of suggestions - the
lifecycle-topology *study* is the separate `topology/` directory):

```
$ ./topology.sh
NUMA node 0: 8 physical cores
  first CPU of each core: 0 1 2 3 4 5 6 7
  SMT siblings (leave idle): 16 17 18 19 20 21 22 23
  suggestion:
    export SUT_PIN_CMD="taskset -c 0,1,2,3"
    export LOADGEN_PIN_CMD="taskset -c 4,5,6,7"
    # or, binding memory to the node as well:
    export SUT_PIN_CMD="numactl --physcpubind=0,1,2,3 --membind=0"
    export LOADGEN_PIN_CMD="numactl --physcpubind=4,5,6,7 --membind=0"
```

The rules behind the suggestion matter more than the numbers: **do not share cores, or the SMT
siblings of cores, between the load generator and the server; keep both sets inside one NUMA node;
keep the CPU frequency fixed if you can.** JMH runs use `SUT_PIN_CMD`; `run-lifetimes.sh`,
`run-e2e.sh` and `topology/*.sh` use `SUT_PIN_CMD` for the server and `LOADGEN_PIN_CMD` for h2load.

### Microbenchmarks

```
# the scope-aligned benchmark, all three allocators
SUT_PIN_CMD="numactl --cpunodebind=0 --preferred=0" JVM_OPTS=-XX:MaxRAM=60g ./run-cycle.sh

# one cell only - any extra argument is passed straight to JMH
FORKS=1 WI=1 I=1 ./run-cycle.sh -p k=8 -p sizes=SMALL -p releaseOrder=FIFO -p allocatorType=ARENA

# the steady-state harness: pattern, live set, threads, allocators
THREADS=1 ./run-harness.sh E_COMMERCE 1024 1 "ADAPTIVE MIMALLOC ARENA" -- -jvmArgsAppend -Darena.maxBlocks=8

# the same with the hook driven, which is the only way the arena reuses a block off an event loop
THREADS=1 ./run-harness.sh E_COMMERCE 1024 1 ARENA -- -jvmArgsAppend -Dexpt.hookEvery=64

# tables from whatever has been produced
./summarize.py out/
```

`run-harness.sh` adds `-Xlog:gc` and reports peak RSS per fork out of the `.data` (the harness
prints `cRSS-pRSS:[cur, peak]`). It defaults to `METHOD=heapAllocation`; `METHOD=directAllocation`
exercises the direct space, which the arena serves too. **The `E_COMMERCE` size pattern needs the
file `e-commerce.jfr` in the working directory**; it is ~190 MB, is not in this repository - it
comes from lao's head-to-head material - and `run-harness.sh` refuses to start without it.
`SOCKET_PROXY` and `API_GATEWAY` need no input file; `run-cycle.sh` needs none either.

### End to end

```
./run-e2e.sh                                          # HTTP/1.1, all three allocators, 20 s
PROTO=h2 ALLOCATORS="adaptive arena" ./run-e2e.sh     # HTTP/2, h2c, 16 conn x 32 streams
```

It runs `e2e/E2EServer.java` - the same pipelines as the `HttpSnoopServer` / `Http2Server` examples,
with `ChannelOption.ALLOCATOR` set to the chosen allocator - waits for its `READY` line, samples
`ps -o rss=` every 0.5 s, drives it with h2load, stops it by matching `E2EServer` inside
`/proc/<pid>/cmdline` of every `pgrep -x java`, and prints a table of req/s, h2load's
`time for request` line, RSS min/max/mean, the `Pause Young` count from `-Xlog:gc`, and the arena
counters from the launcher's shutdown hook. `PROTO`, `ALLOCATORS`, `DURATION`, `PORT`, `LOOPS`,
`CONNS`, `STREAMS`, `LOAD_THREADS`, `BODY_SIZE`, `ARENA_MAX_BLOCKS`, `ARENA_PROPS` (extra `-Darena.*`
flags) and `JVM_OPTS` are all configurable; raw logs stay in `RESULTS_DIR`. It needs `h2load` on
`PATH` and refuses to start without it.

> **Logging is off by default.** The example pipelines log every HTTP/2 frame at INFO, and that
> logging - not the allocator - is what these servers are bound by: adaptive on HTTP/2 measured
> 23,507 req/s with it and 670,768 req/s without. `run-e2e.sh` therefore passes
> `-Dlogback.configurationFile=e2e/logback-off.xml`; set `LOGBACK_CONFIG=` to measure the servers as
> the examples ship them.
>
> The arena serves heap *and* direct buffers, so nothing forces a path. Pass
> `JVM_OPTS=-Dio.netty.noPreferDirect=true` for the heap variant, and note that
> `AbstractByteBufAllocator.ioBuffer()` - which the receive-buffer allocator calls - returns a direct
> buffer whenever direct buffers can be reliably freed and never consults that property.

### Transports

Both servers - `e2e/E2EServer.java` and `topology/TopoServer.java` - take
`TRANSPORT=nio|epoll|io_uring` (the scripts pass it as `-Dtransport`), and both build their event
loops through the single helper [`lib/java/Transports.java`](lib/java/Transports.java), so the two
launchers cannot drift apart. Everything else - pipelines, allocators, h2load flags, pinning - is
identical across the three.

* **nio** `NioIoHandler` + `NioServerSocketChannel`. The receive buffer is allocated per read from
  the channel's allocator and released by the pipeline: the lifetime the arena was designed for.
* **epoll** `EpollIoHandler` + `EpollServerSocketChannel`, nothing else changed. Same buffer
  lifetimes as nio; only the readiness mechanism differs.
* **io_uring** `IoUringIoHandler` with every feature this branch exposes that the running kernel
  probes as supported (the probe, not the API list, decides):
  * one **provided buffer ring** per worker loop (`IoUringBufferRingConfig`), filled by the
    allocator `BUFFER_RING_ALLOC` names, incremental when
    `IoUring.isRegisterBufferRingIncSupported()`;
  * `IO_URING_BUFFER_GROUP_ID` on every child channel, so reads consume that ring;
  * `IO_URING_WRITE_ZERO_COPY_THRESHOLD` (`-Diouring.zeroCopyThreshold`, default 4096, `-1` turns it
    off, which is netty's own default), so writes at or above it go out as `SEND_ZC` / `SENDMSG_ZC`;
  * `setSingleIssuer(true)` (which is also what lets netty ask for `DEFER_TASKRUN`), an explicit
    ring size and CQ size.

**What this does to buffer lifetimes.** A provided-buffer-ring buffer is handed to the *kernel*: it
stays alive for an unbounded number of event-loop iterations - until the kernel fills it - and each
read hands the pipeline a `retainedSlice` of it. A zero-copy write keeps the written buffer alive
until the completion notification arrives, which is a later iteration. For an iteration-scoped
allocator both are **lifetime class D (kernel-owned)**: blocks holding them cannot be recycled at
the end-of-iteration hook, and the `maxPinned` counter is where that shows up.

Two knobs separate the questions that were first measured together:

* **`BUFFER_RING=on|off`** (`-DbufferRing`). `off` installs no `IoUringBufferRingConfig` and sets no
  `IO_URING_BUFFER_GROUP_ID`, so `AbstractIoUringStreamChannel.scheduleRead0()` takes its plain
  branch: the receive buffer comes from the **channel allocator** and `IORING_OP_RECV` carries its
  address and length. Multishot RECV is only reachable from the provided-buffer branch, so `off`
  also means one-shot recv - that is io_uring, not a second knob. `RINGTELE` prints
  `bufferRing=off ringAllocs=0 ringReads=0`.
* **`BUFFER_RING_ALLOC=same|adaptive|builtin|builtinadaptive|slab`** (`-DbufferRingAlloc`). The ring
  does not have to be filled by the channel allocator: `IoUringBufferRingConfig` takes its own
  `IoUringBufferRingAllocator`. `same` (the default) uses the allocator under test; `adaptive` gives
  the ring its own shared `AdaptiveByteBufAllocator`; `builtin` and `builtinadaptive` are netty's
  own `IoUringFixedBufferRingAllocator` / `IoUringAdaptiveBufferRingAllocator`; `slab` is
  [`lib/java/RegisteredSlabBufferRingAllocator.java`](lib/java/RegisteredSlabBufferRingAllocator.java),
  one preallocated direct region **per loop** with a free list by slot and nothing allocated after
  start-up (`SLABTELE ... slabFallbacks=0` is how that is checked).

The servers print what they got: a `TRANSPORT` line with `IoUring.featureString()` (the kernel's own
probe), a `CHILDOPTS` line reading the two io_uring channel options back off the first accepted
channel, and a `RINGTELE` line at shutdown counting buffers put into the ring (`ringAllocs`) and
taken back out of it (`ringReads`, `ringReadBytes`) - `ringReads=0` would mean the ring was never
consumed.

On the reference machine (kernel 7.1.13) every feature the branch probes came back supported;
`lib/java/IoUringProbe.java` prints that list, and
`results/ryzen9-7950x-node0/arena-v3/io_uring/probe.txt` is its output. Two features that the kernel
supports are left at netty's own defaults, which are OFF: `IORING_RECVSEND_BUNDLE` (netty disables
it over a known kernel bug) and `IORING_ENTER_NO_IOWAIT`.

What the ring's lifecycle demands of an allocator, what every other io_uring project does about it,
and what this repository measured, is in
[`docs/uring-registered-buffers.md`](docs/uring-registered-buffers.md). What should actually run on
io_uring is [`docs/uring.md`](docs/uring.md).

### The lifetime study

```
./run-lifetimes.sh snoop -- --h1 -c 64 -t 4 -D 12 -d lifetimes/body4k.bin http://127.0.0.1:8080/
./run-lifetimes.sh http2 -- -c 16 -m 32 -t 4 -D 12 http://127.0.0.1:8080/
```

It starts `HttpSnoopServer` or `Http2Server` from the netty `example` module with a JFR recording
that enables only `io.netty.AllocateBuffer` / `io.netty.FreeBuffer` (`lifetimes/buf.jfc`), drives it
with `h2load`, stops the server by matching the main class inside `/proc/<pid>/cmdline` of every
`pgrep -x java` (**never `pkill -f`** - that matches the calling shell), then pairs allocate/free by
address with `lifetimes/lifetimes.py`.

> Use `h2load`, not `wrk`. The jbang `wrk` on the reference box silently ignored the Lua POST body
> (`lifetimes/post.lua`), so no request bodies were sent and the inbound read buffers never appeared
> in the recording. That produced one wrong sample before it was caught.

The text event dump is multi-GB and is deleted unless `KEEP_EVENTS=1`.

### The lifecycle-topology study

`topology/run.sh` (W1-W5), `topology/run6.sh` (W6a, W6b), `topology/run-matrix.sh` (a
transport x allocator matrix) and `topology/control.sh` (the instrumentation-cost control) start
`topology/TopoServer.java` with one of seven pipelines, record a JFR window in the middle of a load
run, and analyse it with `topology/Dump.java` + `topology/topology.py`. The exact invocations of the
reference run are in the header of `topology/run.sh`. They need `javac`, `jcmd`, `h2load` and
`python3`.

## What it buys and what it does not

**The honest summary: on the example servers in this repository the allocator is second order, and
adaptive is the better default.** End-to-end throughput did not change on either protocol; what
moved is the allocator's own share of event-loop CPU samples, and only by a point or two of a loop
whose other ~90% the arena cannot touch. Everything below is one machine, and the per-cell caveats
are in [RESULTS.md](results/ryzen9-7950x-node0/RESULTS.md).

**Where it wins - scope-aligned lifetimes, sizes under the cap.**

| cell | ADAPTIVE | MIMALLOC (lao's port) | ARENA |
|---|---|---|---|
| `CycleScopedAllocBenchmark` k=64 FIFO SMALL, heap, ns per allocate/release pair | 49.3 | 44.8 | **23.5** |
| the same, direct | 48.3 | 42.9 | **23.8** |

That is **-52% against adaptive and -48% against the mimalloc port on heap** (-51% / -44% on
direct), at 100% arena share with nothing pinned. On the steady-state harness with the hook driven
every 64 operations and 1024 live buffers the arena is **0.72x adaptive on heap and 0.76x on
direct** (-28% / -24%), and the single 3-fork heap cell is 65.18 +- 2.09 ns/op against adaptive's
83.58 +- 0.50. In the real pipelines the shape the win depends on is there: 100% of the
paired buffers of W1 (HTTP/1.1 POST), W2 (HTTP/2 multiplexed) and W6a (proxy on one loop) live
0 iterations - allocated and released inside one iteration of one loop
([RESULTS.md 1](results/ryzen9-7950x-node0/RESULTS.md#1-the-lifecycle-topology-of-real-pipelines-adaptive-allocator-seven-pipelines-nio)).

**Where it does not.**

* **Random / geometric lifetimes** ([A.3](results/ryzen9-7950x-node0/RESULTS.md#a3-geometric-lifetimes--dexptrandomreleasetrue)). Same arena, same bound, only the release order changed: 40.6 ->
  82.7 ns/op at 1024 live and 49.8 -> 122.1 at 4096, against adaptive's 83.1 and 106.5. The win is
  gone and at 4096 it loses.
* **Live sets above the 8-block bound** ([2.10](results/ryzen9-7950x-node0/RESULTS.md#210-the-harnesss-e_commerce-eventloop-ladder-with-a-driven-hook-measured-2026-09-22-2300-mhz-node-0-3-forks)). From 4096 live buffers up, the arena share falls from 49%
  to 4%, all eight blocks are pinned in every fork, and the arena is 1-37% slower than adaptive
  while carrying 75-990 MB more RSS - an excess far larger than the 128 MiB the blocks can account
  for and which is **not explained**.
* **io_uring, and not only its provided buffers** ([3](results/ryzen9-7950x-node0/RESULTS.md#3-transports-io_uring-and-epoll-measured-2026-09-23-2300-mhz-node-0), [4](results/ryzen9-7950x-node0/RESULTS.md#4-io_uring-is-the-arena-wrong-for-the-registered-buffers-or-wrong-measured-2026-09-23-2300-mhz-node-0), [7](results/ryzen9-7950x-node0/RESULTS.md#7-what-holds-the-blocks-that-stay-pinned-on-io_uring-measured-2026-09-24-2300-mhz-node-0)). A registered buffer belongs to the kernel
  for an unbounded number of iterations. With the ring filled by the arena, 12-32 of the
  process's block-maxima stay pinned and the arena's allocator CPU share on HTTP/1.1 goes *above*
  adaptive's (1.91% -> 4.31%). Give the ring its own adaptive allocator and the counters return to
  the nio shape - but the blocks still pinned after that are **zero-copy write buffers** on
  HTTP/1.1 (99.5% of 8,682 attributed samples; turning zero-copy off takes them to 3) and
  **9-byte HTTP/2 frame headers** on HTTP/2, where zero-copy makes no difference at all. The
  recommendation, with its evidence, is [`docs/uring.md`](docs/uring.md): **no arena on io_uring.**
* **Cross-loop pipelines** ([3.4](results/ryzen9-7950x-node0/RESULTS.md#34-what-broke-w6b-the-cross-loop-proxy), [4.4](results/ryzen9-7950x-node0/RESULTS.md#44-w6b-the-cross-loop-proxy-with-the-ring-on-adaptive)). W6b - a proxy whose outbound channel is on another event loop - is the
  deliberate negative test: the confinement check fires (398-486 violations) and throughput
  collapses to ~10-24 req/s against adaptive's 38.9-48.1 k. Confinement is a design decision, not a
  bug to fix, and such pipelines must not use the arena.

**End to end, the whole story.**

| | adaptive | arena | note |
|---|---|---|---|
| h1 req/s, 3 runs of 2 M requests | 177.2k / 176.1k / 177.8k | 178.1k / 178.5k / 176.4k | unchanged |
| h2 req/s, 3 runs of 2 M requests | 388.5k / 389.7k / 390.4k | 385.9k / 387.3k / 391.6k | unchanged |
| h1 instructions per request (3-run mean) | 106.2k | 105.2k | adaptive's own three runs span 1.9% |
| h1 allocator share of event-loop CPU samples | 7.72% (wide filter 8.24%) | 7.15% (7.40%) | one 14 s profile per build |
| h2 allocator share of event-loop CPU samples | 11.03% (14.75%) | 9.25% (12.18%) | one 14 s profile per build |
| h1 / h2 RSS, fixed 1 GiB pre-touched heap, smaps at 12 s | 1298 / 1307 MB | 1281 / 1301 MB | mimalloc port 1297 / 1300 |

So: **throughput unchanged, allocator CPU share 7.7-11.0% -> 7.2-9.3% of event-loop samples, RSS
neutral.** Where the rest of the loop's CPU goes, on the same four profiles: socket write path
39-46%, HTTP codec and response building 42-47%, socket read 5-7%, select 3.5-5%. The arena removes
7% (h1) to 16% (h2) of the allocator's own slice and cannot touch the other ~90% of the loop.

The allocator claim itself holds - 23.5 ns per allocate/release pair against adaptive's 49.3 where
the arena applies - and on request/response servers it is second order. Whether Netty could supply
the scope signal that would make the win reachable outside a microbenchmark is the open question;
the allocator cannot infer it.

## Results

Full tables, per-cell numbers and every caveat:
**[`results/ryzen9-7950x-node0/RESULTS.md`](results/ryzen9-7950x-node0/RESULTS.md)**. It opens with
a one-screen summary table, then the current build, the transports, the three io_uring studies and
the pinned-block attribution, and ends with an appendix holding the two earlier builds (v2), which
are **not** statements about the pinned code.

## Documents

- [`docs/design.md`](docs/design.md) - the design, as implemented. Problem classes measured from the
  topology study, the bounded iteration arena, the flat block layout, the ring and re-entry, the
  metrics and JFR events, the known unsoundness.
- [`docs/uring.md`](docs/uring.md) - what should run on io_uring, with the evidence.
- [`docs/uring-registered-buffers.md`](docs/uring-registered-buffers.md) - the lifecycle of one
  provided buffer, what it imposes on an allocator, what liburing / folly / Zig / glommio /
  tokio-uring do, and which candidate the measurements favour.
- [`docs/layout-survey.md`](docs/layout-survey.md) - block/arena metadata layouts read from the
  source of ten allocators (mimalloc, TigerBeetle, G1, Zig, protobuf, folly, pmr and others). It is
  where the flat block metadata comes from: only mimalloc, TigerBeetle and G1 keep per-block
  liveness at all, and no precedent stores an int block id in the buffer object.
- [`docs/design-draft1.md`](docs/design-draft1.md) - draft 1, kept so the review trail is visible.

## Reference machine

AMD Ryzen 9 7950X (16C/32T); pinned to NUMA node 0 = CPUs 0-7,16-23 (8 cores / 16 threads) with
`numactl --cpunodebind=0 --preferred=0`; CPU frequency fixed at 2300 MHz for the runs and restored
to 4300 MHz afterwards; JDK 21 (`21+35-LTS-2513`), `-XX:MaxRAM=60g`; glibc 2.42; kernel 7.1
(`7.1.13-100.fc43.x86_64`). None of that is hardcoded anywhere in the scripts.
