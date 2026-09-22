# Reference results - ryzen9-7950x, one NUMA node

Every number below was produced on this machine and is reproduced here verbatim from
`netty-bench/docs/BACKLOG.md`, block **B2. Event-loop cycle arena**, and re-derived from the json
files in this directory with `../../summarize.py`.

Machine and settings:

| | |
|---|---|
| CPU | AMD Ryzen 9 7950X, 16 cores / 32 threads |
| pinned to | NUMA node 0 = CPUs 0-7,16-23 (8 cores / 16 threads), `numactl --cpunodebind=0 --preferred=0` |
| frequency | fixed at 2300 MHz for the run, restored to 4300 MHz afterwards |
| JDK | 21 (`21+35-LTS-2513`), `-XX:MaxRAM=60g` |
| glibc / kernel | 2.42 / 7.1 (`7.1.13-100.fc43.x86_64`) |
| date | 2026-09-22 |
| code | netty `dec589d0eb` (`expt/event-loop-arena`), harness = lao 1.2 + this PoC's benchmark commits |
| JMH | 3 forks, 10x1 s warmup, 10x1 s measurement |

Fork-to-fork sd on the harness heap cells is about 8% on this box: **3 forks resolve ~10%, not 3%.**
Differences smaller than that are not differences.

## 1. CycleScopedAllocBenchmark - the scope-aligned case

Allocate k buffers, write a byte into each, read a byte back, release all k. Heap buffers, one
event-loop thread. `ns/buf` is the JMH score divided by k; nothing else is computed.
Data: `cycle/cycle-heap.json`.

| allocator | ns per buffer (over k 8/64, FIFO/LIFO, MIXED/SMALL) |
|---|---|
| ARENA | 25.2 - 27.5 |
| ADAPTIVE | 44.3 - 50.9 |
| MIMALLOC | 46.6 - 52.6 |

ARENA is 40-50% below ADAPTIVE on every one of the 12 cells. Adaptive is ahead of the mimalloc port
here. Full per-cell table: `../../summarize.py cycle/cycle-heap.json`.

## 2. ByteBufAllocatorAllocPatternBenchmark - the steady-state case

A live set of MAX_LIVE_BUFFERS buffers, E_COMMERCE size pattern, heap, `enableReadWrite=true`,
release order random over the ring. **This is not the workload the arena is for**; it is here
because the arena must not be quoted only on the case that suits it.

Peak RSS is the harness's own `cRSS-pRSS:[cur, peak]`, first fork (the per-fork values are in the
summarizer output; forks agree within ~1% on these cells).

`ARENA` = the default bound (`arena.maxBlocks=4`, <= 4 blocks); `ARENA8` = `-Darena.maxBlocks=8`
(<= 32 MiB), which is **above** the live set of these cells.

| threads | live | ADAPTIVE | MIMALLOC | ARENA (4 blocks) | ARENA8 (8 blocks) |
|---|---|---|---|---|---|
| 1 | 1024 | 83.1 ns (1091 MB) | 70.3 ns (1069 MB) | 76.8 ns (1427 MB) | **40.6 ns** (1050 MB) |
| 1 | 4096 | 96.1 ns (1097 MB) | 76.2 ns (1075 MB) | 100.0 ns (1188 MB) | **49.8 ns** (1084 MB) |
| 32 | 1024 | 316.9 ns (2134 MB) | 271.0 ns (1930 MB) | 427.4 ns (2551 MB) | 298.6 ns (2352 MB) |
| 32 | 4096 | 387.4 ns (2128 MB) | 365.6 ns (2798 MB) | 481.3 ns (2860 MB) | 350.3 ns (2821 MB) |

Two separate readings:

- **With the bound below the live set** (the default 4 blocks) the arena LOSES: blocks are pinned by
  their longest-lived buffer, the bound is reached, the fallback pays both paths, and RSS is
  +8..30%. Arena share at 4 blocks on these cells: 58% (1024) / 19% (4096) - from
  `diag/tele-arena2-1024.data` (`arena=83860117 fallback=61512762`) and `diag/tele-arena2-4096.data`
  (`arena=20499714 fallback=89222495`); the `harness-t1-*-ARENA` runs predate the counter teardown
  and carry no `ARENATELE` line.
- **With the bound above the live set** (8 blocks) the counters show effectively everything served
  by the arena (`harness/harness-t1-1024-ARENA8.data`: `arena=501300300 fallback=0
  blockReuse=1179648` -> one block recycled every ~425 allocations; at 4096, `fallback=1065` out of
  400M) and the LIFO pop essentially never firing (`lifoPop=5..27`). Then it is -50% against
  adaptive where the core is the bottleneck (1 thread) and -6..-10% in the memory-bound 32-thread
  regime.

**CAVEAT that limits all of section 2:** this harness gives every buffer the same lifetime (N ops,
a ring of slots), so blocks drain deterministically. Variable lifetimes with long-lived pinning -
the real case - are not covered here. That is what sections 3 and 4 are for.

## 3. Geometric lifetimes (`-Dexpt.randomRelease=true`)

Release a uniformly random live slot instead of the next one in the ring: same mean lifetime,
geometric distribution. 1 thread, 3 forks, E_COMMERCE heap. Data: `rand/`.

**These runs use `-Darena.maxBlocks=8`** (the VM options line in each `.data` says so), i.e. the
same 8-block arena that wins section 2. The comparison that matters is therefore the ARENA column
here against the ARENA8 column above: 40.6 -> 82.7 and 49.8 -> 122.1 for changing nothing but the
lifetime distribution.

| live | ADAPTIVE | MIMALLOC | ARENA (8 blocks) | arena share | peak RSS vs adaptive |
|---|---|---|---|---|---|
| 1024 | 83.1 ns | 68.6 ns | 82.7 ns | 77% | 1210-1223 vs 1071-1073 MB (+13..14%) |
| 4096 | 106.5 ns | 77.2 ns | 122.1 ns | 22% | 1225-1227 vs 1084-1091 MB (+13%) |

At 4096 the block reuses collapse from 538K (`harness/harness-t1-4096-ARENA8.data`) to 46K
(`rand/rand-t1-4096-ARENA.data`). A few long-lived buffers per block pin it and the bound fills
with mostly-dead blocks. The LIFO pop, silent in section 2, now fires 103K-108K times: releases
stop arriving in stack order.

**CAVEAT on these two cells specifically:** Chrome was using about 66% of one CPU during this run.
The comparison is between allocators measured in the same conditions, but the absolute levels are
not clean.

## 4. Real lifetimes from JFR - the gate

`io.netty.AllocateBuffer` / `io.netty.FreeBuffer` (see `../../lifetimes/buf.jfc`), paired by
address by `../../lifetimes/lifetimes.py`. Allocator: adaptive. Outputs: `lifetimes/*.txt`.

| server | load | req/s | buffers | same thread | allocations in between |
|---|---|---|---|---|---|
| HttpSnoopServer, HTTP/1.1 POST 4 KiB | h2load, 64 conn, 4 threads, 12 s | 274,927 | 4.14M | 100.0000% | p50 1, **max 2** |
| Http2Server (h2c) | h2load, 16 conn x 32 streams, 12 s | 45,478 | 3.00M | 100.0000% | p50 14, p90 37, p99 45, **max 90** |

In the HTTP/1.1 case the 8 kB inbound read buffer lives exactly 2 allocations: the response header
and body buffers are allocated inside its lifetime and released first - nested stack discipline. In
the HTTP/2 case the lifetime is bounded by the multiplexing window; 76% of the buffers are 9-15 B
frame buffers, 4.5% are the 32/64 kB read buffers.

**What this does NOT show.** These are two example servers that retain nothing. Application code
that holds buffers across iterations - aggregation, queues, backpressure, `ChannelOutboundBuffer`
under a slow peer - is absent. This is a lower bound on real lifetimes, not the general case.

**An earlier sample in the same block is invalid and is not reported here:** an `HttpSnoopServer`
run driven by the jbang `wrk` on this box showed no inbound read buffers at all, because that `wrk`
ignores the Lua body and no POST bodies were sent (`lifetimes/snoop-wrk.log`, `lifetimes/wrk.log`).
h2load was used for every number above.

## 5. End to end - the allocator is not visible

`run-e2e.sh`: the same netty example pipelines behind `E2EServer`, one allocator per run, 8 event
loops, `-Xms2g`, `-Dio.netty.noPreferDirect=true`, driven by h2load for 20 s. Raw logs: `e2e/`.

### HTTP/1.1, 4 KiB POST, 64 connections, 4 h2load threads

| allocator | req/s | mean request time | RSS | young GCs | arena counters |
|---|---|---|---|---|---|
| ADAPTIVE | 174,490 | 373 us | 241 -> 1500 MB | 57 | - |
| MIMALLOC | 174,791 | 372 us | 271 -> 1528 MB | 56 | - |
| ARENA | 174,489 | 373 us | 231 -> 1502 MB | 56 | `arena=3489820 fallback=0 blockReuse=0 grow=0` |

### HTTP/2 (h2c), 16 connections x 32 streams

| allocator | req/s | mean request time | RSS | young GCs |
|---|---|---|---|---|
| ADAPTIVE | 23,508 | 21.8 ms | 251 -> 1495 MB | 12 |
| MIMALLOC | 23,968 | 21.3 ms | 290 -> 1572 MB | 12 |
| ARENA | **failed** | - | 236 -> 303 MB | 0 |

**The ARENA HTTP/2 run failed and the cause is not established - under investigation.** What the
logs show, and nothing beyond it: 0 of 512 started requests completed in 20 s; h2load sent GO_AWAY
with `errorCode=1` and the debug bytes `DATA: stream not opened` on every connection
(`e2e/h2-arena.server.log.gz`); the server threw no exception and logged no error; the arena
counters at shutdown read `arena=1472 fallback=0 blockReuse=0 grow=0 lifoPop=40`. The same h2load
command against the same server with ADAPTIVE and MIMALLOC succeeded. I do not know why.

### What these runs actually say

The three allocators are indistinguishable on HTTP/1.1: 174,489 / 174,490 / 174,791 req/s and
372-373 us mean. That is the expected outcome, not a null result to explain away.

The arithmetic: 174,490 req/s spread over 8 event loops is **~46 us of event-loop time per
request**. The arena counted 3,489,820 allocations in 20 s - 174,491 per second, i.e. almost exactly
one counted heap buffer per request - which at the 25-50 ns per buffer measured in section 1 is
**0.03-0.05 us**. The direct buffers are not in that count (see below), so the real allocator share
is higher than 0.05 us, but it is nowhere near the resolution of a 20-second throughput number.
**The end-to-end runs cannot distinguish these allocators; the microbenchmarks isolate exactly what
this test cannot.**

The RSS climb to ~1.5 GB is the 2 GB Java heap filling between young GCs under `-Xms2g` (the GC log
lines read `...(2048M)`), identical for all three. It is not native allocator retention.

`blockReuse=0 grow=0 fallback=0` in the HTTP/1.1 arena run: both counters live in `nextBlock()`,
which is only reached when the current block runs out of room, so it was never reached in 3.49M
allocations - the block's live count kept returning to zero and resetting the bump pointer first
(that reset has no counter of its own).
And the counters cover the heap path only. `AbstractByteBufAllocator.ioBuffer()` - which is what
the receive-buffer allocator calls - returns `directBuffer(...)` whenever direct buffers can be
reliably freed; it never consults `io.netty.noPreferDirect`. `CycleArenaAllocator.newDirectBuffer`
forwards straight to its fallback and increments no counter. So the inbound read buffers of these
runs did not go through the arena at all.
