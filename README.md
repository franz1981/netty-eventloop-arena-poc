# Event-loop cycle arena - proof of concept

An experiment on Netty's allocator, not a proposal and not a patch anyone should merge.

## The hypothesis

On an event loop, most buffers are allocated and released **on the same thread, inside one
iteration**. If that is true, those buffers can be served by a bump arena with a plain `int`
refcount - no atomics, no size classes, no free lists, no cross-thread protocol - far more cheaply
than by a general-purpose allocator. The general allocator stays as the fallback for everything
else: buffers that escape the cycle, cross threads, or arrive when the arena is full.

The PoC is `io.netty.buffer.CycleArenaAllocator` (in the `netty` submodule, branch
`expt/event-loop-arena`, ~310 lines, **heap buffers only**):

- a `FastThreadLocal` arena per thread; `newDirectBuffer` goes straight to the fallback;
- blocks of 256 KiB, doubling to 8 MiB, at most N of them (`arena.initialBlock`, `arena.maxBlock`,
  `arena.maxBlocks`); allocation is a bump of the current block, minimum 32 B;
- when the current block is full: reuse an idle block (`live == 0`) if one is big enough, else grow,
  else give up and call `AdaptiveByteBufAllocator`;
- release must happen on the allocating thread - it throws `IllegalStateException` otherwise;
- plain `int` refcount, no `AtomicIntegerFieldUpdater`; per-block live counter;
- a block whose live count returns to zero resets its bump pointer; releasing the *topmost* buffer
  of a block pops the bump pointer back (LIFO);
- buffer objects come from a lazily filled per-arena array with an `int` free stack; past that array
  they are ordinary garbage (`arena.objects`).

Counters (`CycleArenaAllocator.counters()`): allocations served by the arena, sent to the fallback,
block reuses, block growths, LIFO pops, unpooled buffer objects. All knobs are system properties.

**What the PoC deliberately is not:** it has no way to know whether a buffer is cycle-scoped. Every
heap allocation goes to the arena. In a real design that decision is a hint from the Netty code that
knows the lifecycle, not something the allocator guesses.

## What each benchmark measures, and what it cannot show

| benchmark | measures | cannot show |
|---|---|---|
| `CycleScopedAllocBenchmark` | allocate k buffers, use, release all k: the best case, perfectly scope-aligned | anything about buffers that outlive the cycle; it is an upper bound on the win |
| `ByteBufAllocatorAllocPatternBenchmark` | a steady-state live set with a random release order over a ring of slots | real lifetime *distributions*: every buffer gets the same lifetime, so blocks drain deterministically |
| the same with `-Dexpt.randomRelease=true` | geometric lifetimes with the same mean | still a synthetic distribution, and still no application-level retention |
| the JFR lifetime study (`run-lifetimes.sh`) | same-thread ratio and "allocations in between" for real buffers in two netty example servers | applications that retain buffers - aggregation, queues, backpressure. It is a **lower bound** on real lifetimes |
| `-Dexpt.reuse=true` | reuse distance and 4 KiB page locality of the memory handed out | it is a probe for explaining a result, not a result |

## Measured results

Full tables, per-cell numbers and every caveat: **[`results/ryzen9-7950x-node0/RESULTS.md`](results/ryzen9-7950x-node0/RESULTS.md)**.
Headline, on the reference machine described below, 3 forks:

- **Scope-aligned (`CycleScopedAllocBenchmark`, heap, 1 thread, 12 cells):** ARENA 25-28 ns per
  buffer vs ADAPTIVE 44-51 and MIMALLOC 47-53 - 40-50% below adaptive on every cell.
- **Steady-state live set (E_COMMERCE heap), bound above the live set (`-Darena.maxBlocks=8`):**
  1 thread / 1024 live: 40.6 vs adaptive 83.1 and mimalloc 70.3 ns/op; 1 thread / 4096: 49.8 vs
  96.1 / 76.2. 32 threads / 1024: 298.6 vs 316.9 / 271.0; 32 threads / 4096: 350.3 vs 387.4 / 365.6.
  So about -50% where the core is the bottleneck and -6..-10% against adaptive in the memory-bound
  32-thread regime. *Caveat: this harness gives every buffer the same lifetime, so blocks drain
  deterministically.*
- **Same, with the default bound of 4 blocks (below the live set):** the arena LOSES - 76.8 vs 83.1
  at 1024 but 100.0 vs 96.1 at 4096, 427/481 vs 317/387 at 32 threads, and +8..30% peak RSS. Blocks
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

The conclusion these numbers support, and nothing more: **a bump path pays when lifetimes are
scope-aligned and the bound is above the live set, and loses otherwise.** Whether Netty can supply
the scope signal is the open question; the allocator cannot infer it.

Fork-to-fork sd on the harness heap cells is ~8% on this box. Three forks resolve ~10%, not 3%.

## Reproducing

### Submodules

```
git clone <this repo> && cd netty-eventloop-arena-poc
git submodule update --init
```

| submodule | repository | branch | pinned commit |
|---|---|---|---|
| `netty` | `https://github.com/franz1981/netty.git` | `expt/event-loop-arena` | `dec589d0eb` |
| `netty-allocator` | `https://github.com/franz1981/netty-allocator.git` | `cycle-arena-bench` | `1041207` |

> **Neither branch is pushed yet.** `git submodule update --init` cannot work from a fresh clone
> until `expt/event-loop-arena` is pushed to `franz1981/netty` and `cycle-arena-bench` to
> `franz1981/netty-allocator`. In the working copy this repository was assembled in, the submodules
> were added from local paths and `.git/config` still points at them; `.gitmodules` carries the
> GitHub URLs, so `git submodule sync` will switch a clone over once the branches exist.

`netty-allocator` is lao's harness (`neoionet/netty-allocator`) with three commits on top of its
`1.2` head: the cycle benchmark, the harness additions, and nothing else. `ARENA` there resolves to
`io.netty.buffer.CycleArenaAllocator` from the `netty` submodule - the class has exactly one source
of truth.

### Build

`java` and `mvn` are taken from `PATH`.

```
./build.sh                    # or:  MVN_FLAGS="-q -o" ./build.sh   (offline)
```

This installs the `netty` submodule's `buffer` and `common` modules into `~/.m2` - **overwriting any
snapshot of the same version already there** - builds the harness against exactly that version, and
copies the shaded jar to `target/benchmarks.jar`. It also installs the `example` module for the
lifetime study (`--no-example` skips that).

### Run

All knobs are in [`lib/env.sh`](lib/env.sh), each with a machine-neutral default: `PIN_CMD`
(empty; e.g. `numactl --cpunodebind=0 --preferred=0` or `taskset -c 0-15`), `CPU_FREQ_HOOK` (empty;
a script taking `pin` / `restore`), `JVM_OPTS` (empty; the reference runs used `-XX:MaxRAM=60g`),
`FORKS` / `WI` / `I` / `W` / `R` / `THREADS`, `MVN_FLAGS`, `RESULTS_DIR`.

```
# the scope-aligned benchmark, all three allocators
PIN_CMD="numactl --cpunodebind=0 --preferred=0" JVM_OPTS=-XX:MaxRAM=60g ./run-cycle.sh

# one cell only - any extra argument is passed straight to JMH
FORKS=1 WI=1 I=1 ./run-cycle.sh -p k=8 -p sizes=SMALL -p releaseOrder=FIFO -p allocatorType=ARENA

# the steady-state harness: pattern, live set, threads, allocators
THREADS=1 ./run-harness.sh E_COMMERCE 1024 1 "ADAPTIVE MIMALLOC ARENA" -- -jvmArgsAppend -Darena.maxBlocks=8

# tables from whatever has been produced
./summarize.py out/
```

`run-harness.sh` adds `-Xlog:gc` and reports peak RSS per fork out of the `.data` (the harness
prints `cRSS-pRSS:[cur, peak]`). **The `E_COMMERCE` size pattern needs the file `e-commerce.jfr` in
the working directory**; it is ~190 MB and is not in this repository - it comes from lao's
head-to-head material.

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

## Reference machine

AMD Ryzen 9 7950X (16C/32T); pinned to NUMA node 0 = CPUs 0-7,16-23 (8 cores / 16 threads) with
`numactl --cpunodebind=0 --preferred=0`; CPU frequency fixed at 2300 MHz for the runs and restored
to 4300 MHz afterwards; JDK 21 (`21+35-LTS-2513`), `-XX:MaxRAM=60g`; glibc 2.42; kernel 7.1
(`7.1.13-100.fc43.x86_64`). None of that is hardcoded anywhere in the scripts.
