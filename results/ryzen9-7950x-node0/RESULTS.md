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
| code | sections 1-4: netty `dec589d0eb`; sections 2b and 5: the later PoC build, now pinned at `26bd14b195` (`expt/event-loop-arena`). Harness = lao 1.2 + this PoC's benchmark commits |
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

### 2b. The current PoC build (heap + direct arenas)

The table above is the first PoC, which was heap-only. The arena now has a heap arena and a direct
arena, both backed by adaptive's own chunk allocators. Same cell as the first row of the table
above - E_COMMERCE, 1 thread, 1024 live, 3 forks, 2300 MHz:

| build | ns/op |
|---|---|
| ARENA heap, `release=lifo` | 44.28 +- 0.73 |
| ARENA direct | 43.30 +- 0.46 |
| ADAPTIVE heap | 83.99 +- 0.29 |
| ADAPTIVE direct | 79.74 +- 0.38 |
| heap-only PoC (control) | 40.87 +- 0.17 |

The +3.4 ns of the current build over the heap-only control is **not attributed**. What is known:
G1 card marks on two hot reference stores were found with perfasm and removed, and a klass-guard
hypothesis was tested and refuted. Neither accounts for the remaining 3.4 ns.

The raw json for this table is not in this repository.

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
loops, `-Xms2g`, driven by h2load for 20 s.

**Two things make this section different from sections 1-4, and both limit it:**

1. **The frequency was NOT fixed** - these runs were at 4300 MHz, not the 2300 MHz of the other
   sections. Do not compare their absolute levels with anything above.
2. The server ran on node 0 and h2load on node 1 (`SUT_PIN_CMD` / `LOADGEN_PIN_CMD`).
3. The raw h2load/RSS/GC files for *these* runs are not in this repository - only the superseded
   ones described at the end of this section are. The numbers below are reported as measured
   elsewhere; `e2e/` holds the older, logging-bound run.

### HTTP/2 (h2c), `-c 16 -m 32`

| build | req/s | mean request time | RSS | GC pauses |
|---|---|---|---|---|
| ADAPTIVE | 671,887 | 720 us | 92 -> 1471 MiB | 34 |
| ARENA heap+direct (`noPreferDirect`) | 676,928 | 709 us | 93 -> 1457 MiB | 30 |
| ARENA direct | 672,233 | 711 us | 93 -> 1448 MiB | 32 |
| ARENA `release=hook`, `hook=iteration` | 671,800 | 711 us | 93 -> 1458 MiB | 32 |
| ARENA `release=hook`, `hook=readComplete` | 666,754 | 716 us | 93 -> 1413 MiB | 32 |

### HTTP/1.1, `--h1 -c 64`

| build | req/s | mean request time | RSS | GC pauses |
|---|---|---|---|---|
| ADAPTIVE | 298,586 | 218 us | 93 -> 1437 MiB | 92 |
| ARENA direct | 300,662 | 216 us | 92 -> 1447 MiB | 92 |
| ARENA heap | 302,460 | 214 us | 92 -> 1436 MiB | 73 |

### Counters

HTTP/2, ARENA heap run:

```
arenaHeap=71.7M  arenaDirect=111.4M  fallbackHeap=0  fallbackDirect=0
grow=0  resetOnZero=9.4M  lifoPop=68.7M
```

`release=hook`, `hook=iteration`: `hookRegistered=8 hookIteration=3.03M hookReset=3.03M`.
`hook=readComplete`: `hookReadComplete=3.16M hookReset=604k`. On HTTP/1.1 the snoop handler's
`channelReadComplete` does not propagate, so the `readComplete` variant never fires there.

### What these runs actually say

**End to end the allocators stay within run-to-run spread on these servers.** Every HTTP/2 build
lands between 666.8k and 676.9k req/s and every HTTP/1.1 build between 298.6k and 302.5k; the
request-time means differ by 11 us out of 709-720 (h2) and 4 us out of 214-218 (h1). Nothing here
separates the arena from adaptive, in either direction.

The earlier **"713 req/s" HTTP/2 arena result does not reproduce** at the pinned commit (52k vs 53k
in the logging-bound harness). It is attributed to a stale build. That attribution is not
established.

The RSS climb to ~1.5 GiB is the 2 GB Java heap filling between GCs under `-Xms2g`, the same for
every build. It is not native allocator retention.

### The superseded run in `e2e/`

The files under `e2e/` are an earlier round that **measured the example servers' logging, not their
allocators**: the example pipelines log every HTTP/2 frame at INFO. Adaptive on HTTP/2 measured
23,507 req/s with that logging and 671,887 req/s without it - a factor of 28. `run-e2e.sh` now
passes `-Dlogback.configurationFile=e2e/logback-off.xml` by default; set `LOGBACK_CONFIG=` to
measure the servers as the examples ship them.

That round also hit a real bug, which is why its logs are kept. With the arena, HTTP/2 completed 0
of 512 started requests: h2load sent GO_AWAY with `errorCode=1` and the debug bytes
`DATA: stream not opened` on every connection (`e2e/h2-arena.server.log.gz`), and the server threw
no exception. **Cause, established:** `ArenaBuf.internalNioBuffer(index, len)` delegated to the
block's root buffer (an `UnpooledUnsafeHeapByteBuf`), whose `internalNioBuffer` returns **one cached
ByteBuffer per root**. A gathering write collects the NIO views of several outbound buffers of the
same block before using any of them, so all of those views pointed at the last position set -
corrupted DATA frames. **Fixed** on the PoC branch in commit `05604aa1c2` ("per-buffer NIO views"):
each `ArenaBuf` keeps its own cached duplicate for `internalNioBuffer` and slices a fresh view in
`nioBuffer` / `nioBuffers`.
