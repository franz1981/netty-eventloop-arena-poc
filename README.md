# Event-loop cycle arena - proof of concept

An experiment on Netty's allocator, not a proposal and not a patch anyone should merge.

## The hypothesis

On an event loop, most buffers are allocated and released **on the same thread, inside one
iteration**. If that is true, those buffers can be served by a bump arena with a plain `int`
refcount - no atomics, no size classes, no free lists, no cross-thread protocol - far more cheaply
than by a general-purpose allocator. The general allocator stays as the fallback for everything
else: buffers that escape the cycle, cross threads, or arrive when the arena is full.

The PoC is `io.netty.buffer.CycleArenaAllocator`, in the `netty` submodule (branch
`expt/event-loop-arena`). Sections 1-6 of the results were measured at `3dad84f578`; the submodule
now points at `11adeba602` ("Use a block as a ring with variable-sized slots", ring reuse behind
`-Darena.ring`, off by default). [RESULTS.md section 7](results/ryzen9-7950x-node0/RESULTS.md)
(transports) was measured on `2b961262d6`, the same commit before its final amend: the amend changed
only javadoc and the ring's default, and every section-7 run set `-Darena.ring` explicitly.
`3dad84f578` is **v3**, a rewrite against
[`docs/design.md`](docs/design.md); the two earlier builds are described, and measured, under
[the earlier builds (v2)](#the-earlier-builds-v2) - nothing in this section describes them.

**What the PoC deliberately is not:** it has no way to know whether a buffer is cycle-scoped. Every
allocation goes to the arena. In a real design that decision is a hint from the Netty code that
knows the lifecycle, not something the allocator guesses.

## Mechanics

One arena per event-loop thread (`FastThreadLocal`), two spaces (heap, direct), fixed 256 KiB blocks taken from
adaptive's own chunk allocators and never given back except by an explicit `trim()`. Allocation is a bump in the
current block; release is a plain `int` decrement; reuse happens in exactly one place, the event loop's own
end-of-iteration tail task, reached through the **public `endOfIteration()`**.

Every knob is a system property, read once in `CycleArenaAllocator`:

| knob | default | what it does |
|---|---|---|
| `-Darena.blockSize` | 262144 | fixed block size. Fixed, not geometric: a pinned block must cost little |
| `-Darena.maxBlocks` | 8 | blocks per space; when none is reusable and the bound is reached, allocation delegates (`maxBlocks <= 32`: the masks are `int`s) |
| `-Darena.cap` | 8192 | a request above it goes straight to adaptive, which keeps the bytes most likely to survive the iteration out of the arena |
| `-Darena.maxObjects` | 16384 | bound on the per-space buffer-object pool; past it, allocation delegates |
| `-Darena.debug` | false | checks that no block is reused before a hook; folded away when false |
| `-Darena.jfr.period` | 1000 | hooks per `ArenaIteration` / `ArenaAllocationSample` event |

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
 |     long[] base / byte[][] mem       (touched only on a block switch)                        |
 |     flat: curId, curBump, curMemory / curAddress                                             |
 |                                                                                              |
 |  ArenaBuf objects: preallocated array + int[] free stack; each holds                         |
 |     int blockId, int start, int length, int refCnt   (no reference to a block, no header)    |
 +---------------------------------------------------------------------------------------------+
        |  size > cap, bound reached, pool exhausted, off-loop thread
        v
   AdaptiveByteBufAllocator (unchanged) - also the source of the arena's blocks
```

### How the next block is chosen (there is no "best fit")

The question "which block fits this request?" never arises, for two reasons that hold by construction:

1. every block has the same size (256 KiB), and every request that reaches the arena is at most the cap (8 KiB), so
   any block with room for a bump fits any request;
2. a block is marked reusable only when it is *completely* empty (`allocs[id] == frees[id]` at the hook), and only
   the current block is ever bumped. So a reusable block always has `bump == 0`: there are no partially used blocks
   to compare, no holes to search, nothing to rank.

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
     curId = id; curBump = 0; curMemory/curAddress = mem[id]/base[id]
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

### By example

Three cases, on a block drawn with 16 slots: a letter = a live buffer, `.` = released, `|` = the bump.
Animated: [`docs/mechanics.html`](docs/mechanics.html)
(rendered: <https://franz1981.github.io/netty-eventloop-arena-poc/docs/mechanics.html>).

**1. The bump only advances.** Allocate `a`, release `a`, allocate `b`:

```
[a|             ]   ->   [.|             ]   ->   [. b|           ]
allocs=1 frees=0         allocs=1 frees=1         allocs=2 frees=1
```

`b` lands after `a`'s slot, not in it: a release increments `frees` and nothing else. `a`'s bytes come
back only at the hook, and only if the whole block is empty then (`allocs == frees`) - in which case
the bump goes back to 0, in place if this is the current block.

**2. Release order does not matter.** Allocate `a`, `b`, `c`, then release `c`, `b`, `a` - perfect LIFO:

```
[a b c|         ]   ->   [a b .|         ]   ->   [a . .|         ]   ->   [. . .|         ]
                                                                           allocs=3 frees=3
```

The bump stays at 3 through all of it; the block is empty at the end but still hands out nothing until
the hook. Reuse timing must not depend on the order releases arrive in - that is what makes it one
compare per release with no LIFO pop - and it is what keeps an NIO view or a raw address taken during
the iteration valid for the rest of the iteration.

**3. One survivor pins a block.** Allocate `a`..`p` (the block is full), release all but `p`, then hook:

```
[a b c d e f g h i j k l m n o p|]   ->   [. . . . . . . . . . . . . . . p|]
                                          allocs=16 frees=15  ->  HOOK: pinned
```

`allocs != frees`, so the hook leaves the block alone: the mask bit stays clear and the 15 released slots
are unavailable until some later hook finds `p` gone. The next allocation takes the lowest set bit of
`reusableMask`, else grows a block, else delegates to adaptive. If the pinned block is the current one, its
free tail ahead of the bump is still bumped - pinned stops reuse, not allocation.

Rules, in five lines:

1. the bump only advances; a release only increments `frees`;
2. a block is reset only at a hook, and only when `allocs == frees`;
3. the current block resets in place; the others are published through `reusableMask`;
4. a full block is left for the lowest mask bit, else growth, else the delegate;
5. released bytes behind the bump are never handed out before a hook, and a pinned block's free tail
   ahead of the bump is still used while it is current.

The steady state on a request/response loop is case 2 followed by a hook that finds the block empty:
everything allocated in an iteration is released in it, the current block resets in place, and
`switchBlock()` never runs at all.

Block memory holds user payload only: no per-allocation header, no per-block header, no free-list links, no fill.
Everything the allocator knows lives on the owner's own cache lines.

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
   nothing freed during iteration k is handed out before the HOOK: NIO views and addresses taken
   during an iteration stay valid until it ends.
```

Confinement (Invariant A): `retain()`/`release()` from another thread throw before touching any field; a counter records
it, because `ReferenceCountUtil.safeRelease` swallows the exception. Pipelines that cross event loops must not use
the arena (the cross-loop proxy is the negative test below).

### Counters

`CycleArenaAllocator.counters()` prints one process-wide `ARENATELE` line - the knobs, then arena and delegate
allocations per space, `arenaShare`, blocks in use / pinned / reusable, `maxPinnedHeap` / `maxPinnedDirect`, block
reuses and growths, `hooks`, `hookRejections`, confinement `violations`, `earlyReuses`, the three reallocation
counters, `trims` / `trimmedBlocks` / `leakedBlocks`, `objects`, bytes and live buffers per space - followed by one
`ARENALOOP` line per live arena (per event loop). It is called off the hot path: at shutdown, or from a benchmark's
teardown.

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
| the lifecycle-topology study (`topology/`) | buffer lifetime in event-loop iterations, nesting class at release, release cause, bytes crossing an iteration, across seven real pipelines | one short window per workload, NIO only, no derived-buffer events; it describes shapes, not converged numbers |
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
| `netty` | `https://github.com/franz1981/netty.git` | `expt/event-loop-arena` | `11adeba602` |
| `netty-allocator` | `https://github.com/franz1981/netty-allocator.git` | `cycle-arena-bench` | `e9fa807` |

Both branches are on GitHub at the pinned commits, so a fresh clone resolves them:

```
git clone --recurse-submodules https://github.com/franz1981/netty-eventloop-arena-poc.git
```

`netty-allocator` is lao's harness (`neoionet/netty-allocator`) with four commits on top of its
`1.2` head: the cycle benchmark, the harness additions, the `-Dexpt.hookEvery` hook driver, and
nothing else. `ARENA` there resolves to
`io.netty.buffer.CycleArenaAllocator` from the `netty` submodule - the class has exactly one source
of truth.

### Build

`java` and `mvn` are taken from `PATH`.

```
./build.sh                    # or:  MVN_FLAGS="-q -o" ./build.sh   (offline)
```

This installs the `netty` submodule's `buffer` and `common` modules into `~/.m2` - **overwriting any
snapshot of the same version already there** - builds the harness against exactly that version, and
copies the shaded jar to `target/benchmarks.jar`. It also installs the `example` module, which
`run-e2e.sh`, the lifetime study and the topology study all need (`--no-example` skips it).

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
prints `cRSS-pRSS:[cur, peak]`). **The `E_COMMERCE` size pattern needs the file `e-commerce.jfr` in
the working directory**; it is ~190 MB, is not in this repository - it comes from lao's
head-to-head material - and `run-harness.sh` refuses to start without it. `SOCKET_PROXY` and
`API_GATEWAY` need no input file; `run-cycle.sh` needs none either.

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
> the examples ship them. **The earlier e2e table measured the logging and has been replaced**; its
> raw logs are kept in `results/ryzen9-7950x-node0/e2e/` because that round found a real bug (see
> RESULTS.md section 5).
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
  probes as supported (the probe, not the API list, decides - see the table below):
  * one **provided buffer ring** per worker loop (`IoUringBufferRingConfig`), **filled by the
    allocator under test**, incremental when `IoUring.isRegisterBufferRingIncSupported()`;
  * `IO_URING_BUFFER_GROUP_ID` on every child channel, so reads consume that ring;
  * `IO_URING_WRITE_ZERO_COPY_THRESHOLD`, so writes at or above it go out as `SEND_ZC` /
    `SENDMSG_ZC`;
  * `setSingleIssuer(true)` (which is also what lets netty ask for `DEFER_TASKRUN`), an explicit
    ring size and CQ size.

**What this does to buffer lifetimes.** A provided-buffer-ring buffer is handed to the *kernel*: it
stays alive for an unbounded number of event-loop iterations - until the kernel fills it - and each
read hands the pipeline a `retainedSlice` of it. A zero-copy write keeps the written buffer alive
until the completion notification arrives, which is a later iteration. For an iteration-scoped
allocator both are **lifetime class D (kernel-owned)**: blocks holding them cannot be recycled at
the end-of-iteration hook, and the `maxPinned` counter is where that shows up.

**Splitting the ring off the channels: `BUFFER_RING_ALLOC=same|adaptive`.** The provided buffer ring
does not have to be filled by the channel allocator: `IoUringBufferRingConfig` takes its own
`IoUringBufferRingAllocator`, and `IoUringBufferRing` calls it (`allocator.allocate()`,
`allocateBatch`) independently of `ChannelOption.ALLOCATOR`. `BUFFER_RING_ALLOC=adaptive` (the
scripts pass it as `-DbufferRingAlloc`; `same` is the default and is what every earlier run used)
gives the ring its own `AdaptiveByteBufAllocator` shared by every loop, while the channels keep the
allocator under test. That separates two questions that were measured together before: *is this
allocator wrong for kernel-owned registered buffers* and *is this allocator wrong*. The
`RINGTELE`/`TRANSPORT` lines carry `alloc=` and `allocClass=` so a run says which one it used.

The servers print what they got: a `TRANSPORT` line with `IoUring.featureString()` (the kernel's own
probe), a `CHILDOPTS` line reading the two io_uring channel options back off the first accepted
channel, and a `RINGTELE` line at shutdown counting buffers put into the ring
(`ringAllocs`) and taken back out of it (`ringReads`, `ringReadBytes`) - `ringReads=0` would mean the
ring was never consumed.

On the reference machine (kernel 7.1.13) every feature the branch probes came back supported;
`lib/java/IoUringProbe.java` prints that list, and
`results/ryzen9-7950x-node0/arena-v3/io_uring/probe.txt` is its output. Two features that the kernel
supports are left at netty's own defaults, which are OFF: `IORING_RECVSEND_BUNDLE` (netty disables it
over a known kernel bug) and `IORING_ENTER_NO_IOWAIT`. The measured transport matrix is
[RESULTS.md section 7](results/ryzen9-7950x-node0/RESULTS.md#7-transports-io_uring-and-epoll-measured-2026-09-23-2300-mhz-node-0);
its one hard failure is W6b, the deliberately cross-loop proxy, where the arena's confinement check
now fires inside the io_uring zero-copy write completion (406 violations, 10.25 req/s against
adaptive's 71,919).

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

`topology/run.sh` (W1-W5), `topology/run6.sh` (W6a, W6b) and `topology/control.sh` (the
instrumentation-cost control) start `topology/TopoServer.java` with one of seven pipelines, record a
JFR window in the middle of a load run, and analyse it with `topology/Dump.java` +
`topology/topology.py`. The exact invocations of the reference run are in the header of
`topology/run.sh`. They need `javac`, `jcmd`, `h2load` and `python3`.

## Results

Full tables, per-cell numbers and every caveat: **[`results/ryzen9-7950x-node0/RESULTS.md`](results/ryzen9-7950x-node0/RESULTS.md)**.
Reference machine at the bottom of this file. **v3 is the pinned build**; the sections after it are
the history of two earlier builds and are not statements about the pinned code.

### v3, the pinned build - measured 2026-09-22, 2300 MHz, node 0

Raw data: `results/ryzen9-7950x-node0/arena-v3/`. Details and caveats:
[RESULTS.md section 6](results/ryzen9-7950x-node0/RESULTS.md#6-v3---the-designed-event-loop-arena).

**Lifecycle topology, one window per workload, arena build, 4 event loops (W6b: two groups of 4),
process-wide `ARENATELE` counters at shutdown**. `max pinned blocks` is the counter `maxPinnedDirect`: the sum over the
process's arenas of each arena's own maximum, not a per-loop figure (`maxPinnedHeap` is 0
everywhere - these pipelines allocate direct buffers):

| workload | arena share | max pinned blocks | hooks | confinement violations |
|---|---|---|---|---|
| W1 HTTP/1.1 request/response (snoop), 4 KiB POST | 99.99% | 0 | 92,764 | 0 |
| W2 HTTP/2 hello | 95.85% | 0 | 139,356 | 0 |
| W3 HTTP/2 echo, 64 KiB body, small windows | 95.86% | 7 (1,2,2,2 over 4 loops) | 173,892 | 0 |
| W4 HTTP/1.1 chunked echo, slow readers | 86.92% | 4 (1 per loop) | 325 | 0 |
| W5 aggregator, 256 KiB POST | 11.85% | 4 (1 per loop) | 91,675 | 0 |
| W6a proxy, outbound on the SAME loop | 99.97% | 0 | 812,486 | 0 |
| W6b proxy, outbound on a SEPARATE loop | 0.25% | 64 (8 loops x 8 blocks) | 754,155 | **2,140** |

W6b is a **negative test**: the outbound channel runs on another loop, the arena refuses those
buffers, every block of all 8 loops stays pinned and the violation counter fires 2,140 times. That is the counter
working, not a regression. W5 at 11.85% is the aggregator: the aggregated body is above the cap and
is delegated.

**End to end** (`E2EServer`, logging off, SUT node 0 / h2load node 1, 2,000,000 requests per run,
all succeeded):

| | adaptive | arena | note |
|---|---|---|---|
| h1 req/s, 3 runs | 177.2k / 176.1k / 177.8k | 178.1k / 178.5k / 176.4k | unchanged |
| h2 req/s, 3 runs | 388.5k / 389.7k / 390.4k | 385.9k / 387.3k / 391.6k | unchanged |
| h1 instructions per request (3-run mean) | 106.2k | 105.2k | adaptive's own three runs span 1.9% |
| h1 cycles per request (3-run mean) | 77.1k | 76.5k | 76.8k -> 76.4k on run 1 alone |
| h2 instructions per request | 41.0k / 40.4k / 41.1k | 40.7k / 41.4k / 40.7k | unchanged |
| h1 allocator share of event-loop CPU samples (async-profiler, cpu, 1 ms) | 7.72% | 7.15% | narrow filter; wide filter 8.24% -> 7.40% |
| h2 allocator share of event-loop CPU samples | 11.03% | 9.25% | narrow filter; wide filter 14.75% -> 12.18% |
| h1 / h2 RSS with a fixed 1 GiB pre-touched heap, smaps at 12 s | 1298 / 1307 MB | 1281 / 1301 MB | mimalloc port 1297 / 1300 |

**End-to-end throughput did not change.** Both filters behind the CPU-share rows are in
[`tools/asprof-alloc-share.py`](tools/asprof-alloc-share.py), which reproduces all eight numbers
from the collapsed stacks in the repository.

Where the event-loop CPU goes on these servers (same four profiles,
[`tools/asprof-loop-breakdown.py`](tools/asprof-loop-breakdown.py)): socket write path 39-46%, HTTP
codec and response building 42-47% (on HTTP/1.1 that is the 6.5-8.0% codec bucket plus the 34-35%
"loop other" bucket, whose top leaves are `ByteBufUtil.unsafeWriteUtf8` / `utf8ByteCount`), socket
read 5-7%, select 3.5-5%, allocator 7.2-11.0% (narrow filter) or 7.4-14.8% (wide). The arena removes
7% (h1) to 16% (h2) of the allocator's own slice on the narrow filter, 10% and 17% on the wide one;
it cannot touch the other ~90% of the loop. That is the whole end-to-end story: the allocator claim
holds in the microbenchmark (23.5 ns per allocate+release pair against 49.3 for adaptive and 44.8
for the mimalloc port, sizes under the cap), and on request/response servers it is second order.

**Microbenchmarks:**

- **Scope-aligned (`CycleScopedAllocBenchmark`, k=64, FIFO, MIXED, 3 forks).** Score is per 64
  allocate/release pairs: heap ARENA **2221.3** vs ADAPTIVE **3344.5** ns, direct ARENA **2171.0**
  vs ADAPTIVE **3253.4** ns. The arena served 83.33% of the allocations - exactly the 10 of 12 MIXED
  sizes at or below `arena.cap=8192`; the 16 KiB and 32 KiB sizes are delegated to adaptive inside
  the ARENA column.
- **Sizes under the cap (`sizes=SMALL`, k=64, FIFO, 100% arena share):** 23.5 ns per pair on heap
  and 23.8 on direct, against adaptive 49.3 / 48.3 and the mimalloc port 44.8 / 42.9; the first PoC
  was 25.2 on heap and 47.8 on direct.
- **Steady-state harness with the hook driven (E_COMMERCE heap, 1 thread, 1024 live, 3 forks,
  `-Dexpt.hookEvery=64`):** ARENA **65.18 +- 2.09** vs ADAPTIVE **83.58 +- 0.50** ns/op, arena share
  88.27%, `maxPinnedHeap` 7. The hook is driven by the harness; N=64 is a choice and the
  score depends on it. The same ladder at 4096 live and above, where the live set exceeds the
  8-block bound, is where the arena *loses*: see RESULTS.md section 6.10.
- **The harness cells that print `arenaShare=0.00%` measure the delegate detour and nothing else** -
  the benchmark thread never closes an iteration, the blocks fill and every allocation goes to
  adaptive. Against ADAPTIVE's 600.4 instructions/op on that cell (perfnorm, 1 fork): **+32
  instructions/op after the detour fix** (632.6) and **+82 before** it (682.8). The v3 report quotes
  +33; the three perfnorm files give +32.1 and +82.4.

**What v3 measured, stated plainly: end-to-end throughput did not change.** The measured effect is
the allocator's share of event-loop CPU samples and, on HTTP/1.1, instructions per request. The
microbenchmark wins are the scope-aligned best case with the hook driven artificially.

### The lifecycle-topology study (adaptive allocator, seven pipelines)

The question the microbenchmarks cannot answer: in a real pipeline, **how long does a buffer live
measured in event-loop iterations, in what order is it released, and who releases it?** The study in
[`topology/`](topology/) answers it by recording, in one window of a running server:

- `io.netty.AllocateBuffer` / `io.netty.FreeBuffer` / `io.netty.ReallocateBuffer` (the
  `Reallocate` events are what balances the ledger when a buffer grows in place);
- a `netty.IterationEnd` marker committed by a self-renewing tail task on every event loop, so a
  buffer's lifetime can be counted in **iterations of its own loop**, not only in wall-clock time;
- the **nesting class** at release - was this buffer the only live one, the youngest (LIFO), the
  oldest, or in the middle of the live set;
- the **release cause**, taken from the first non-plumbing frame of the `FreeBuffer` stack;
- how many **bytes cross an iteration boundary**, which is the number a per-iteration arena would
  have to keep.

Seven pipelines, all NIO:

```
  w1  W1 HTTP/1.1 snoop, 4 KiB POST, 64 conn, h2load --h1
  w2  W2 HTTP/2 hello, 16 conn x 32 streams, 4 KiB POST
  w3  W3 HTTP/2 echo of a 64 KiB body, 4 KiB client flow-control windows, 8 conn x 16 streams
  w4  W4 HTTP/1.1 chunked echo of a 256 KiB POST, 64 slow readers (4 KiB/20 ms), server SO_SNDBUF=16 KiB
  w5  W5 HttpServerCodec + HttpObjectAggregator(1 MiB) + small OK, 256 KiB POST, 64 conn
  w6a  W6a TCP proxy (HexDumpProxy topology) -> snoop backend, outbound on the SAME event loop, 4 KiB POST, 64 conn
  w6b  W6b same proxy but the outbound channel on a SEPARATE event loop group, 4 KiB POST, 64 conn
```

Results (`results/ryzen9-7950x-node0/topology/`, copied exactly from `summary.txt`):

```
LIFETIME IN EVENT-LOOP ITERATIONS (share of paired buffers)
wl        pairs        0        1      2-3      4-7       8+ x-thread
w1       549633  100.00%    0.00%    0.00%    0.00%    0.00%    0.00%
w2       568072  100.00%    0.00%    0.00%    0.00%    0.00%    0.00%
w3      1385797   97.83%    0.00%    0.00%    0.00%    2.17%    0.00%
w4         2496   91.35%    1.20%    0.00%    0.00%    7.45%    0.00%
w5       332006   37.26%    5.32%    8.78%   10.03%   38.61%    0.00%
w6a      310270  100.00%    0.00%    0.00%    0.00%    0.00%    0.00%
w6b      254132   15.72%   17.66%   27.80%   31.86%    6.96%  100.00%

HEADLINE CLASSES (share of paired buffers)
wl             i         ii        iii         iv          v  vi-other
w1        33.33%     66.67%      0.00%      0.00%      0.00%     0.00%
w2         2.94%     97.06%      0.00%      0.00%      0.00%     0.00%
w3         0.05%     97.77%      2.17%      0.00%      0.00%     0.00%
w4         0.20%     91.15%      8.65%      0.00%      0.00%     0.00%
w5         5.21%     32.05%      0.00%     62.74%      0.00%     0.00%
w6a      100.00%      0.00%      0.00%      0.00%      0.00%     0.00%
w6b        8.17%      7.56%     84.28%      0.00%      0.00%     0.00%

BYTES AND OCCUPANCY
wl       MiB alloc MiB crossing     %bytes   avgLive   maxLive  alloc/it  it/s/thr
w1          2231.2          0.0      0.00%      0.00         0     39.39      3253
w2          1081.6          0.0      0.00%      0.00         0    135.85       972
w3          4653.0       1908.3     41.01%     64.76        85      4.71     25302
w4            20.0          4.0     19.98%      1.04        72      0.00    525237
w5         13386.2       9170.8     68.51%      3.23        34      0.32    239218
w6a         2424.0          0.0      0.00%      0.00         0      0.80     90164
w6b         1985.4       1673.2     84.28%      0.51        16      0.13    232206
```

Headline classes: **i** = same iteration, LIFO or only-live; **ii** = same iteration, out of order;
**iii** = crosses an iteration, released by write completion; **iv** = crosses an iteration, held by
a decoder/cumulator or an aggregator; **v** = crosses an iteration, HTTP/2 flow control;
**vi** = anything else.

#### What limits this study

- **One 1-1.5 s window per workload**, one run each. These are shapes, not converged numbers.
- **NIO only.** No io_uring, so nothing here says anything about registered or provided buffers.
- **No derived-buffer events.** Slices and duplicates do not fire allocate/free, so a buffer pinned
  only by a derived reference is invisible.
- **The iteration counter is inflated on idle loops.** The `IterationEnd` tail task is always
  pending, so `hasTasks()` is always true and the selector never blocks. `control.txt` measures the
  cost: on a saturated loop (W1) markers cost +3.3% CPU and no throughput, but on a near-idle loop
  (W4) they cost **31x** CPU and turn the iteration counter into a spin counter. **On W4 read the
  wall-clock column, not the iteration column.**
- `jfr print` truncates timestamps to milliseconds, which cannot order 450k events/s, so
  `Dump.java` uses the JFR API directly to get nanoseconds.
- The recordings were made against a frozen classpath at netty `cfb23bcf63`, not the `3dad84f578`
  this repository pins, and the exact h2load flags of W1/W2/W3/W5 were not recorded. Both are
  spelled out in `results/ryzen9-7950x-node0/topology/README.md`.
- The `.jfr` recordings (706 MB) are not in this repository; `topology/run.sh` regenerates them.

### The earlier builds (v2)

**Not the pinned code.** Sections 1-5 of RESULTS.md measure netty `dec589d0eb` and `26bd14b195`, on
the same reference machine, 3 forks. Those builds worked differently from v3:

- blocks of 256 KiB **doubling to 8 MiB**, at most N per space (`arena.initialBlock`,
  `arena.maxBlock`, `arena.maxBlocks`); no size cap - every request entered the arena;
- `-Darena.release` chose what happened when a block went idle: `zero` (reset the bump when the live
  count returned to zero), `lifo` (the default: `zero` plus a LIFO pop of the topmost buffer), or
  `hook` (nothing automatic; `endOfCycle()` reset every wholly-free block and kept at most
  `arena.retainBytes`);
- with `hook`, `-Darena.hook=iteration` armed netty's `executeAfterEventLoopIteration`;
  `-Darena.hook=off` left closing a cycle to whoever called `endOfCycle()` - for instance
  `io.netty.example.arena.CycleArenaEndOfCycleHandler`, appended to the pipeline at
  `channelReadComplete`;
- buffer objects came from a lazily filled per-arena array with an `int` free stack (`arena.objects`).

**v3 removed all of that**: `arena.release`, `arena.hook`, `arena.retainBytes`, `arena.initialBlock`,
`arena.maxBlock`, `arena.objects`, `endOfCycle()` and `CycleArenaEndOfCycleHandler` do not exist at
the pinned commit (the handler was dropped in netty `58a79ebd42`), and the knobs of the table at the
top of this file replaced them.

What those builds measured:

- **Scope-aligned (`CycleScopedAllocBenchmark`, heap, 1 thread, 8 cells: k 8/64 x FIFO/LIFO x
  MIXED/SMALL):** ARENA 25.2-27.5 ns per buffer vs ADAPTIVE 44.3-50.9 and MIMALLOC 46.6-52.6 -
  40-50% below adaptive on every cell.
- **Steady-state live set (E_COMMERCE heap), bound above the live set (`-Darena.maxBlocks=8`):**
  1 thread / 1024 live: 40.6 vs adaptive 83.1 and mimalloc 70.3 ns/op; 1 thread / 4096: 49.8 vs
  96.1 / 76.2. 32 threads / 1024: 298.6 vs 316.9 / 271.0; 32 threads / 4096: 350.3 vs 387.4 / 365.6.
  So about -50% where the core is the bottleneck and -6..-10% against adaptive in the memory-bound
  32-thread regime. *Caveat: this harness gives every buffer the same lifetime, so blocks drain
  deterministically.*
- **Same, with the default bound of 4 blocks (below the live set):** the arena LOSES - 76.8 vs 83.1
  at 1024 but 100.0 vs 96.1 at 4096, 427/481 vs 317/387 at 32 threads, and +8..34% peak RSS. Blocks
  are pinned by their longest-lived buffer, the bound is reached and the fallback pays both paths.
  Arena share at 4 blocks: 58% (1024) / 19% (4096).
- **Geometric lifetimes (`-Dexpt.randomRelease=true`, same 8-block arena, 1 thread):** 1024:
  82.7 vs 83.1 / 68.6; 4096: 122.1 vs 106.5 / 77.2, with +13% peak RSS and the arena share falling
  to 77% / 22%. The win of the previous point disappears. *Caveat: Chrome was using ~66% of one CPU
  during this pair of runs; allocators are comparable with each other, absolute levels are not
  clean.*
- **Real lifetimes (JFR, adaptive allocator, h2load):** `HttpSnoopServer` with 4 KiB POSTs,
  275k req/s, 4.14M buffers: **100.0000% released on the allocating thread**, allocations-in-between
  max 2 - the 8 kB read buffer's lifetime contains exactly the response header and body buffers.
  `Http2Server` (h2c, 16 conn x 32 streams), 45k req/s, 3.00M buffers: 100.0000% same thread,
  allocations-in-between p50 14 / p90 37 / p99 45 / max 90 - bounded by the multiplexing window.
  *Caveat: both example servers retain nothing. Application-level retention - aggregation, queues,
  backpressure - is absent, so this is a lower bound, not the general case.*
- **End to end (`run-e2e.sh`, 20 s, 8 event loops, `-Xms2g`, logging off, server on node 0 and
  h2load on node 1, **4300 MHz - not a fixed-frequency run**):** HTTP/2 `-c 16 -m 32`: ADAPTIVE
  671,887 req/s / 720 us mean; ARENA heap+direct 676,928 / 709 us; ARENA direct 672,233 / 711 us;
  ARENA `-Darena.release=hook -Darena.hook=iteration` 671,800 / 711 us; the same with
  `-Darena.hook=off -Darena.e2e.readCompleteHook=true` 666,754 / 716 us (those two flags are v2's,
  and the `readCompleteHook` one was an `E2EServer` flag of that round).
  HTTP/1.1 `--h1 -c 64`: ADAPTIVE 298,586 / 218 us; ARENA direct 300,662 / 216 us; ARENA heap
  302,460 / 214 us. **End to end the allocators stay within run-to-run spread on these servers.**
  RSS rises to ~1.5 GiB everywhere: the 2 GB Java heap filling between GCs, not native retention.
- **The heap+direct build, single harness cell** (E_COMMERCE heap, 1 thread, 1024 live, 3 forks,
  2300 MHz): ARENA heap `release=lifo` 44.28 +- 0.73 ns/op, ARENA direct 43.30 +- 0.46, ADAPTIVE
  heap 83.99 +- 0.29, ADAPTIVE direct 79.74 +- 0.38, heap-only PoC control 40.87 +- 0.17. The
  +3.4 ns of that build over the heap-only control is **not attributed** (G1 card marks on
  two hot reference stores were found with perfasm and removed; a klass-guard hypothesis was tested
  and refuted). These five cells were run without `-rf json`, so the only record of them is a
  transcription of the console lines - see `results/ryzen9-7950x-node0/micro-v2/INDEX.md`, which
  says so itself. The perfasm captures are real files.

The conclusion these numbers support, and nothing more: **a bump path pays when lifetimes are
scope-aligned and the bound is above the live set, and loses otherwise.** Whether Netty can supply
the scope signal is the open question; the allocator cannot infer it.

Fork-to-fork sd on the harness heap cells is ~8% on this box. Three forks resolve ~10%, not 3%.

## Documents

- [`docs/design.md`](docs/design.md) - the design plan built on these numbers (draft 3, final).
  **v3, the pinned netty commit `3dad84f578`, implements it**; the deviations the implementing agent
  recorded are in-place capacity growth above the cap, an object pool per space, `DELEGATED` as a
  column slot, a manual JFR period, a public `endOfIteration()`, and the `int[] live` column of
  section 3 being the `allocs`/`frees` pair of section 6. Its section 8 describes the state of the
  PoC at `26bd14b195`, i.e. before v3.
- [`docs/layout-survey.md`](docs/layout-survey.md) - block/arena metadata layouts read from the
  source of ten allocators (mimalloc, TigerBeetle, G1, Zig, protobuf, folly, pmr and others). It is
  where v3's flat block metadata comes from: only mimalloc, TigerBeetle and G1 keep per-block
  liveness at all, and no precedent stores an int block id in the buffer object.
- [`docs/design-draft1.md`](docs/design-draft1.md) - draft 1, kept so the review trail is visible.

## Reference machine

AMD Ryzen 9 7950X (16C/32T); pinned to NUMA node 0 = CPUs 0-7,16-23 (8 cores / 16 threads) with
`numactl --cpunodebind=0 --preferred=0`; CPU frequency fixed at 2300 MHz for the runs and restored
to 4300 MHz afterwards; JDK 21 (`21+35-LTS-2513`), `-XX:MaxRAM=60g`; glibc 2.42; kernel 7.1
(`7.1.13-100.fc43.x86_64`). None of that is hardcoded anywhere in the scripts.
