# Reference results - ryzen9-7950x, one NUMA node

Every number below was produced on this machine and is reproduced here verbatim from
the maintainer's private backlog (block B2, event-loop cycle arena) and re-derived from the json
files in this directory with `../../summarize.py`.

Machine and settings:

| | |
|---|---|
| CPU | AMD Ryzen 9 7950X, 16 cores / 32 threads |
| pinned to | NUMA node 0 = CPUs 0-7,16-23 (8 cores / 16 threads), `numactl --cpunodebind=0 --preferred=0` |
| frequency | fixed at 2300 MHz for the run, restored to 4300 MHz afterwards |
| JDK | 21 (`21+35-LTS-2513`), `-XX:MaxRAM=60g` |
| glibc / kernel | 2.42 / 7.1 (`7.1.13-100.fc43.x86_64`) |
| date | sections 1, 2 and appendix A: 2026-09-22; sections 3-6: 2026-09-23; section 7: 2026-09-24; section 8: 2026-09-25/26 |
| code | section 1: netty `cfb23bcf63`, adaptive only (frozen classpath, see 1.1); **section 2 (v3): netty `3dad84f578`**; section 3: `2b961262d6`; sections 4-6: `52b19c8ebf`; appendix A: netty `dec589d0eb` (A.1, A.2, A.3, A.4) and the PoC build `26bd14b195` (A.2b, A.5). **section 8: netty `d04ac1f4ec`** (adds the two `IoUringBufferRing` instruments). All on `expt/event-loop-arena`, whose head is `d04ac1f4ec` today. Harness = lao 1.2 + this PoC's benchmark commits, now `e9fa807` |
| JMH | 3 forks, 10x1 s warmup, 10x1 s measurement |

Fork-to-fork sd on the harness heap cells is about 8% on this box: **3 forks resolve ~10%, not 3%.**
Differences smaller than that are not differences.

**Appendix A describes the earlier arena builds (v2). The current code is v3: see
[section 2](#2-v3-the-pinned-build).** The appendix is kept because it holds the only measurements
of those builds; do not read it as a statement about the pinned commit.

## Summary

One row per section, every number copied verbatim from the section it names.

| section | build / configuration | what changed | headline numbers |
|---|---|---|---|
| [1](#1-the-lifecycle-topology-of-real-pipelines-adaptive-allocator-seven-pipelines-nio) | adaptive, NIO, 7 pipelines, one window each | nothing - this is the shape the arena was designed against | lifetime 0 iterations for 100.00% of paired buffers in W1/W2/W6a, 97.83% W3, 91.35% W4, 37.26% W5, 15.72% W6b; bytes crossing an iteration 0.00% (W1/W2/W6a), 41.01% (W3), 19.98% (W4), 68.51% (W5), 84.28% (W6b) |
| [2.1-2.3, 2.8](#2-v3-the-pinned-build) | v3 `3dad84f578`, microbenchmarks | fixed 256 KiB blocks, 8 KiB cap, flat metadata, `endOfIteration()` | cycle k=64 MIXED heap ARENA **2221.306 +- 45.082** vs ADAPTIVE 3344.521 +- 101.462 ns/64 pairs; `sizes=SMALL` 23.5 vs 49.3 (heap) and 23.8 vs 48.3 (direct) ns per pair, mimalloc port 44.8 / 42.9; harness with `-Dexpt.hookEvery=64` **65.184 +- 2.090** vs 83.584 +- 0.503 ns/op; 0%-share cells +32.1 instructions/op |
| [2.4](#24-lifecycle-topology-counters) | v3, topology counters | arena serving the same 7 pipelines | arena share 99.99% (W1) to 11.85% (W5); maxPinned 0 (W1/W2/W6a), 7 (W3), 4 (W4/W5), 64 (W6b); W6b **2,140** confinement violations |
| [2.5, 2.6](#25-end-to-end---2m-requests-3-runs-per-build) | v3, e2e, 2M requests, 3 runs | arena vs adaptive on the example servers | h1 177,191 / 176,115 / 177,787 vs 178,079 / 178,487 / 176,437 req/s; h2 388,480 / 389,652 / 390,394 vs 385,920 / 387,329 / 391,597; instructions/req 106.2k -> 105.2k; allocator CPU share h1 7.72% -> 7.15%, h2 11.03% -> 9.25% (filter B) |
| [2.9](#29-server-rss-and-glibc-adaptive-vs-mimalloc-vs-arena-measured-2026-09-22-2300-mhz-sut-node-0-h2load-node-1) | v3, fixed 1 GiB pre-touched heap | RSS, not throughput | h1 1298 / 1297 / 1281 MB and h2 1307 / 1300 / 1301 MB for adaptive / mimalloc / arena; the arena's own blocks are 3 MiB |
| [2.10](#210-the-harnesss-e_commerce-eventloop-ladder-with-a-driven-hook-measured-2026-09-22-2300-mhz-node-0-3-forks) | v3, 32 threads, live set 128..65536 | the live set crosses the 8-block bound | at 128 live 0.84 / 0.88 of adaptive; at 1024 0.72 / 0.76; from 4096 up share falls 49% -> 4% with all 8 blocks pinned and the arena is 1.01-1.37x adaptive; RSS +75..990 MB, unexplained |
| [3.2, 3.3](#3-transports-io_uring-and-epoll-measured-2026-09-23-2300-mhz-node-0) | `TRANSPORT=nio\|epoll\|io_uring`, ring filled by the allocator under test | the transport | within a transport the three allocators span <= 1.7%; io_uring h1 218,509 vs nio 300,868 (-27%), h2 within 2%; io_uring pins 41 (h1) / 24 (h2) block-maxima over 8 loops against nio's 0 |
| [3.4](#34-what-broke-w6b-the-cross-loop-proxy) | io_uring, W6b cross-loop proxy | the negative test, on io_uring | **10.25 req/s** against adaptive's 71,919, 406 violations, `ringReads=375` |
| [4.1, 4.2](#4-io_uring-is-the-arena-wrong-for-the-registered-buffers-or-wrong-measured-2026-09-23-2300-mhz-node-0) | `BUFFER_RING_ALLOC=adaptive`: the ring gets its own adaptive | who fills the provided buffer ring | maxPinned W1 21 -> 6, W3 32 -> 5, W5 32 -> 4; req/s within 0.8% (h1 126,782 / 126,697 / 126,902; h2 371,712 / 369,614 / 372,490); allocator CPU h1 3.22% -> 1.71%, h2 7.74% -> 5.58% against adaptive's 1.52% / 8.67% |
| [4.4](#44-w6b-the-cross-loop-proxy-with-the-ring-on-adaptive) | W6b with the ring on adaptive | which buffers crossed the loops | **0** violations and **40,678** req/s, against 398 and 10.50 with the arena everywhere |
| [4.6](#46-what-the-ring-and-the-re-entry-cost-on-the-microbenchmarks) | `-Darena.ring`, `ringReentries` | block-as-a-ring reuse and re-entry | the ring costs **+29.3** (direct) / **+8.5** (heap) instructions per pair; re-entry 284.9 -> 270.1 (direct) and 332.4 -> 292.1 (heap) ns/op at 1024 live, 392.1 -> 404.4 and 416.7 -> 468.2 at 4096 |
| [5.1, 5.2](#5-io_uring-with-no-registered-buffers-buffer_ringoff-measured-2026-09-23-2300-mhz-node-0) | `BUFFER_RING=off` - no provided buffer ring at all | the ring removed, so also one-shot recv | share returns to nio (h1 99.77% / 100.00%, h2 95.45% / 95.43%), pinning does not (24 h1, 9 h2 against nio's 0); twelve cells inside a 1.3% band per protocol; W6b still fails (470 / 486 violations, ~24 req/s) |
| [5.3](#53-what-is-still-pinned-the-zero-copy-writes-separate-4-cell-run) | `BUFFER_RING=off` + zero-copy writes off | `IO_URING_WRITE_ZERO_COPY_THRESHOLD` -1 vs 4096 | h1 maxPinnedDirect **25 -> 11** and req/s 127,533 -> **174,648 (+37%)**; h2 9 -> 8 and -1.2%. **11 blocks stay pinned and what holds them is not established here** |
| [6](#6-who-should-serve-the-registered-buffers-measured-2026-09-23-2300-mhz-node-0) | 5 ring allocators: control / adaptive / builtin / builtinadaptive / slab | who should fill the ring | throughput spread 0.7% (h1 126,840-127,572) and 1.4% (h2 370,529-375,775); slab lowest allocator CPU (0.93% h1, 5.54% h2 against the control's 2.05% / 9.35%) with `slabFallbacks=0`; builtinadaptive best on W3 (98.14% share, 19,009 req/s on a quarter of the `allocate()` calls); W5 ran the slab dry, 4,077 fallbacks |
| [7](#7-what-holds-the-blocks-that-stay-pinned-on-io_uring-measured-2026-09-24-2300-mhz-node-0) | `-Darena.debugPinned`, `BUFFER_RING=off`, zero-copy on and off | which allocation stacks hold the pinned blocks | h1: **99.5%** of 8,682 pinned-block samples are the 4,368-byte `filterOutboundMessage` copy, and zero-copy off takes the samples to **3**; h2: zero-copy is irrelevant (972 vs 974 samples), the oldest live buffer is a **9-byte** HTTP/2 DATA frame header in 74% of samples; `-Darena.cap=4096` takes maxPinnedDirect 26 -> 8 for -0.4% req/s, against +36% for turning zero-copy off |
| [8](#8-the-provided-buffer-ring-allocator-iterated-measured-2026-0925-26-2300-mhz-node-0) | 9 ring allocators incl. a loop-local slab, arena as ring allocator, 2 netty instruments | what the right provided-buffer-ring allocator is, and how close it is to its floor | microbench `slab3fixed` **40.44 ns / 382.0 insns/op** vs adaptive 148.19 / 1495.9 (3.7x) and 8x fewer L1d misses; the owner `int` stack is -7.7 ns vs a Treiber CAS, and with all releases foreign it is **171.4 ns vs slab v1 301.7** (slower than adaptive); e2e spread 0.8% (h1) / 1.1% (h2) and the whole ring path is **0.4-0.6% of loop CPU** against 40.8% socket write; refCnt at retire is **2 in 100%** of retirements, so the ring can never reuse the buffer; the no-slice handoff removes 3.8M allocations for +0.5%; W5 v1 **2,145 fallbacks -> 0** with one growth to 512 slots (maxInFlight 377-384); arena as ring allocator **5-7% slower** on W1 with `arenaShare=78%` |
| [A](#appendix-a-the-earlier-builds-v2---not-the-pinned-code) | v2, `dec589d0eb` / `26bd14b195` | history, not the pinned code | ARENA 25.2-27.5 vs ADAPTIVE 44.3-50.9 and MIMALLOC 46.6-52.6 ns/buf; 8-block harness 40.6 vs 83.1 (1024) and 49.8 vs 96.1 (4096); with the default 4-block bound the arena LOSES; geometric lifetimes 82.7 vs 83.1 and 122.1 vs 106.5 |

Sections 1-8 are the current line of work: section 1 is the shape of the problem measured with
adaptive, section 2 the pinned v3 build, sections 3-6 the io_uring questions on top of it,
section 7 the attribution that closes section 5.3's open question and section 8 the iterated
answer to section 6's - which allocator the provided buffer ring should have, and why the answer
changes nothing end to end. Appendix A is the history of two earlier builds and is not a
statement about the pinned commit.

## 1. The lifecycle topology of real pipelines (adaptive allocator, seven pipelines, NIO)

The question the microbenchmarks cannot answer: in a real pipeline, **how long does a buffer live
measured in event-loop iterations, in what order is it released, and who releases it?** The study in
[`../../topology/`](../../topology/) answers it by recording, in one window of a running server:

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

Results (`topology/`, copied exactly from `summary.txt`):

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

### 1.1 What limits this study

- **One 1-1.5 s window per workload**, one run each. These are shapes, not converged numbers.
- **NIO only.** No io_uring, so nothing here says anything about registered or provided buffers.
- **No derived-buffer events.** Slices and duplicates do not fire allocate/free, so a buffer pinned
  only by a derived reference is invisible.
- **The iteration counter is inflated on idle loops.** The `IterationEnd` tail task is always
  pending, so `hasTasks()` is always true and the selector never blocks. `topology/control.txt` measures the
  cost: on a saturated loop (W1) markers cost +3.3% CPU and no throughput, but on a near-idle loop
  (W4) they cost **31x** CPU and turn the iteration counter into a spin counter. **On W4 read the
  wall-clock column, not the iteration column.**
- `jfr print` truncates timestamps to milliseconds, which cannot order 450k events/s, so
  `../../topology/Dump.java` uses the JFR API directly to get nanoseconds.
- The recordings were made against a frozen classpath at netty `cfb23bcf63` - not the commit this
  repository pins (`256c1d86bd` today) - and the exact h2load flags of W1/W2/W3/W5 were not recorded.
  Both are spelled out in `topology/README.md`.
- The `.jfr` recordings (706 MB) are not in this repository; `../../topology/run.sh` regenerates them.

## 2. v3, the pinned build

Everything in this section was measured on **2026-09-22**, on the machine described at the top of
this file: **2300 MHz fixed, node 0**. Code: netty `3dad84f578` (`expt/event-loop-arena`, 6 commits
on the `26bd14b195` of sections A.2b and A.5); harness: netty-allocator `e9fa807`, which adds the
`-Dexpt.hookEvery` driver described below. Raw data: **`arena-v3/`**.

v3 is a rewrite, not a tuning of the build measured in sections A.2b and A.5: fixed 256 KiB blocks, flat
block metadata (ids and parallel columns, no block object), a size cap above which the request is
handed to adaptive, and a public `endOfIteration()` hook instead of `endOfCycle()`. The knobs and
the JFR events are listed in the README. Reuse in this build happens in exactly one place, the
end-of-iteration hook: the variable-slot ring (`-Darena.ring`) and the re-entry of a stalled ring into
another block came later, at `11adeba602` / `52b19c8ebf`, and are measured in sections 3 to 6 and
costed in section 4.6.

### 2.1 `CycleScopedAllocBenchmark`, k=64, FIFO, MIXED - 3 forks

JMH `avgt 30` = 3 forks x 10 iterations. The score is per invocation, i.e. **per 64 allocate/release
pairs**, not per buffer. Data: `arena-v3/cycle/cycle-v3b.{log,json}`.

| space | ARENA | ADAPTIVE |
|---|---|---|
| heap | **2221.306 +- 45.082** ns | 3344.521 +- 101.462 ns |
| direct | **2171.036 +- 3.447** ns | 3253.377 +- 32.830 ns |

The arena served **83.33%** of the allocations in these cells (`arenaShare=83.33%` on every
`ARENATELE` line of that log). That share is not a measurement of the arena's reach: the MIXED size
table has 12 entries, of which 16384 and 32768 are above the default `arena.cap=8192` and are
delegated to adaptive - 10/12 = 83.33% exactly. The remaining 16.67% is adaptive's own cost inside
the ARENA column.

### 2.2 `ByteBufAllocatorAllocPatternBenchmark` with the hook driven every 64 ops - 3 forks

E_COMMERCE, heap, 1 thread, 1024 live, `enableReadWrite=true`, `-Dexpt.hookEvery=64`. Data:
`arena-v3/micro/t1-heap-hook64-v3b.log` (ARENA) and `arena-v3/micro/t1-heap-v3b.log` (ADAPTIVE).

| allocator | ns/op |
|---|---|
| ARENA, hook every 64 ops | **65.184 +- 2.090** |
| ADAPTIVE | 83.584 +- 0.503 |

Counters on the ARENA run: `arenaShare=88.27%`, `blocksHeap=7`, `maxPinnedHeap=7`, and `pinned`
(the count at the last hook) 4 on four of the six `ARENATELE` lines and 5 on the other two.

**The hook is driven by the harness, not by an event loop.** The benchmark thread is not an event
loop, so nothing would ever close an iteration; `-Dexpt.hookEvery=N` calls `endOfIteration()` every
N allocations from the benchmark state. N=64 is a choice, and the score depends on it.

### 2.3 The 0%-share cells measure the delegate detour, not the arena

The ARENA cells run **without** the driver print `arenaShare=0.00%` and `hooks=0`: the blocks fill,
nothing is ever reset, and every allocation goes to adaptive. Those cells measure
**adaptive plus the arena's delegate detour** and nothing else.

`-prof perfnorm`, 1 fork, same cell (E_COMMERCE heap 1t 1024 live):

| build | instructions/op | ns/op | file |
|---|---|---|---|
| ADAPTIVE | 600.432 | 85.938 +- 0.094 | `arena-v3/prof/perfnorm-v3-adaptive.txt` |
| ARENA, 0% share, after the detour fix | 632.570 | 85.332 +- 0.082 | `arena-v3/prof/perfnorm-v3b-arena-0share.txt` |
| ARENA, 0% share, before the fix | 682.821 | 88.284 +- 0.051 | `arena-v3/prof/perfnorm-v3-arena.txt` |

Detour cost against the ADAPTIVE row: **+32.1 instructions/op after the fix, +82.4 before**. (The v3
agent report quotes +33 and +82; the arithmetic on these three files gives +32.1 and +82.4.) For
comparison, the same cell **with** the hook driven every 64 ops is 413.631 instructions/op at
62.880 ns/op (`arena-v3/prof/perfnorm-v3b-hook64.txt`, 1 fork).

### 2.4 Lifecycle-topology counters

One window per workload, arena build, 4 event loops, servers and labels as in
`topology/labels.txt`. The figures are the process-wide `ARENATELE` line of each
`arena-v3/topology/w*-arena-server.log`; per-loop `ARENALOOP` lines are in the same files.
`maxPinned` is the counter `maxPinnedDirect`, which is the **sum over the process's arenas of each
arena's own maximum** - not a per-loop figure. `maxPinnedHeap` is 0 in all seven workloads: these
pipelines allocate direct buffers. The per-loop maxima behind the column are 0 (W1, W2, W6a),
1/2/2/2 (W3), 1 per loop (W4, W5) and 8 per loop on all 8 loops of W6b - the last being every block
of every loop.

| workload | arena share | maxPinned | violations |
|---|---|---|---|
| W1 HTTP/1.1 snoop, 4 KiB POST | 99.99% | 0 | 0 |
| W2 HTTP/2 hello | 95.85% | 0 | 0 |
| W3 HTTP/2 echo, 64 KiB body, small windows | 95.86% | 7 (4 loops: 1,2,2,2) | 0 |
| W4 HTTP/1.1 chunked echo, slow readers | 86.92% | 4 (1 per loop) | 0 |
| W5 aggregator, 256 KiB POST | 11.85% | 4 (1 per loop) | 0 |
| W6a proxy, outbound on the SAME loop | 99.97% | 0 | 0 |
| W6b proxy, outbound on a SEPARATE loop | 0.25% | 64 (8 loops x all 8 blocks) | **2,140** |

**W6b is the negative test**, not a failure to fix: buffers allocated on one loop are released on
another, the arena refuses them, every block of every one of the 8 loops stays pinned and 2,140
confinement violations are counted.
It is there to show the counter fires when confinement is broken. W5 at 11.85% is the aggregator:
the aggregated body is above the cap and is delegated.

### 2.5 End to end - 2M requests, 3 runs per build

`run-e2e.sh`, logging off, server pinned on node 0, h2load on node 1, 2,000,000 requests per run,
all succeeded. Data: `arena-v3/e2e/`.

| run | h1 ADAPTIVE | h1 ARENA | h2 ADAPTIVE | h2 ARENA |
|---|---|---|---|---|
| 1 | 177,191 | 178,079 | 388,480 | 385,920 |
| 2 | 176,115 | 178,487 | 389,652 | 387,329 |
| 3 | 177,787 | 176,437 | 390,394 | 391,597 |

**Throughput did not change.** The three runs of each build overlap the three runs of the other on
both protocols, in both directions.

`perf stat` on the server process, divided by the 2,000,000 requests of the run:

| run | h1 ADAPTIVE instr/req | h1 ARENA instr/req | h1 ADAPTIVE cyc/req | h1 ARENA cyc/req |
|---|---|---|---|---|
| 1 | 105,929 | 105,324 | 76,800 | 76,439 |
| 2 | 105,289 | 105,084 | 76,613 | 76,328 |
| 3 | 107,308 | 105,252 | 77,768 | 76,648 |
| mean | **106.2k** | **105.2k** | **77.1k** | **76.5k** |

The v3 report quotes `cycles 76.8k -> 76.4k`, which are the run-1 values; the three-run means are
77.1k -> 76.5k. Either way the difference is about 1%, and **adaptive's own three runs span 1.9% on
instructions per request**, so three runs do not separate the two builds on this counter either.

On HTTP/2 the counters are unchanged: ADAPTIVE 40,970 / 40,382 / 41,090 instructions per request
against ARENA 40,658 / 41,424 / 40,688.

### 2.6 async-profiler: allocator share of event-loop CPU samples

**One profile per build**, 14 s, CPU samples, collapsed stacks in `arena-v3/e2e/*-prof.collapsed`.

The v3 report quotes **h1 8.24% -> 7.40%** and **h2 14.75% -> 12.18%**. A second, narrower filter -
samples whose stack contains `SingleThreadIoEventLoop.run` (the event-loop denominator), of which
those whose stack also contains `AdaptivePoolingAllocator`, `AdaptiveByteBufAllocator`,
`CycleArenaAllocator` or `ArenaBuf` - gives **h1 7.72% -> 7.15%** and **h2 11.03% -> 9.25%**. Same
direction, different magnitude, so both are recorded here instead of one.

Both filters are implemented in `../../tools/asprof-alloc-share.py`, which reproduces all eight
numbers from the `.collapsed` files in this directory (filter A = the wide one the report quoted,
filter B = the narrow cross-check). Neither is "right": A counts the recycler and the
reference-count helpers as allocator work and accepts any single-thread executor as a loop, B counts
only frames of the allocator classes on an IO event loop.

What both agree on: the allocator's share of event-loop CPU samples is **single-digit to low-double-digit
percent** and the arena build's share is lower than adaptive's on both protocols, in one profile each.
One profile is one sample; this is not a distribution.

### 2.7 What section 2 does not establish

- Throughput: unchanged (2.5). The only quantities that move are the allocator's share of loop CPU
  samples and, by about 1% and inside adaptive's own spread, instructions per request on HTTP/1.1.
- The 32-thread and `-Dexpt.randomRelease=true` cells were **not** re-measured on the v3 build.
- Topology and end-to-end are single windows per workload.
- 2.1 and 2.2 are the arena's best case with the hook driven artificially, exactly as sections A.1
  and A.2 were for the earlier build.

### 2.8 Like-for-like against the first PoC: sizes under the cap (measured 2026-09-22, 2300 MHz, node 0, 3 forks)

`CycleScopedAllocBenchmark`, k=64, FIFO, `sizes=SMALL` (64/128/256/512 B: every request under the 8 KiB cap, so both
arenas run at 100% share, `maxPinned=0` - stated for v3 from the twelve `arenaShare=100.00%` lines of `small-v3.log`;
`small-v2.log` carries no `ARENATELE` line at all, that build having no counter teardown). Files: `arena-v3/cycle/small-v3.*` (final jar + adaptive), `small-v2.*` (first PoC jar).

| cell | ADAPTIVE | MIMALLOC (lao port) | ARENA v2 (first PoC) | ARENA v3 (final) |
|---|---|---|---|---|
| heap, ns per 64 pairs | 3157.1 (3207/3121/3143) | 2870.2 (2884/2880/2847) | 1610.8 (1613/1606/1614) | 1502.1 (1568/1461/1478) |
| direct, ns per 64 pairs | 3091.2 (3102/3100/3072) | 2743.0 (2758/2738/2734) | 3060.1 (3070/3059/3052) | 1520.3 (1538/1401/1622) |
| heap, ns per pair | 49.3 | 44.8 | 25.2 | 23.5 |
| direct, ns per pair | 48.3 | 42.9 | 47.8 | 23.8 |

MIMALLOC files: `arena-v3/cycle/small-mi.*` (same jar, same flags, run right after). Where the arena applies, v3 is
−47.7% (heap) / −44.6% (direct) against the mimalloc port, which itself is −9.1% (heap) / −11.3% (direct) against
adaptive on this cell.

v3 is −52.4% (heap) / −50.8% (direct) against adaptive where the arena applies, level with or better than the first PoC on heap,
and twice as fast as it on direct. The gap to v2 seen on `sizes=MIXED` (section 2.2) is the cap: 16 and 32 KiB requests
delegate in v3 and were served by v2's arena. v3's fork spread is wider than adaptive's.

### 2.9 Server RSS and glibc: adaptive vs mimalloc vs arena (measured 2026-09-22, 2300 MHz, SUT node 0, h2load node 1)

`run-e2e.sh`, 4 event loops, 20 s per run, one run per cell, `JVM_OPTS="-Xms1g -Xmx1g -XX:+AlwaysPreTouch
-XX:MaxDirectMemorySize=2g"` so that RSS differences are native memory, not heap sizing. Files:
`arena-v3/e2e-rss-fixedheap/` (`h1/*.rss` and `h2/*.rss` = RSS sampled every 0.5 s, `*-smaps_rollup-*.txt` = one
`/proc/<pid>/smaps_rollup` at 12 s, `arena-maps-*.txt` = the arena server's `/proc/<pid>/maps`). The default-heap run in `arena-v3/e2e-rss/` is kept
but is not an RSS measurement: its heaps grew differently per run (67-97 young GCs).

| proto | allocator | req/s | RSS at 12 s (smaps Rss, MB) | RSS last sample (MiB) | arena counters |
|---|---|---|---|---|---|
| h1 | adaptive | 147,804 | 1298 | 1268 | |
| h1 | mimalloc | 148,479 | 1297 | 1267 | |
| h1 | arena | 149,553 | 1281 | 1251 | share 100%, 8 direct + 4 heap blocks, 0 pinned |
| h2 | adaptive | 420,400 | 1307 | 1276 | |
| h2 | mimalloc | 426,628 | 1300 | 1269 | |
| h2 | arena | 435,282 | 1301 | 1270 | share 97.5%, 0 pinned |

The two RSS columns are the same quantity in different units - smaps `Rss` in kB over 1000, and the last `.rss`
sample in kB over 1024; the underlying values differ by less than 0.01%, so the ~30 unit drop between the columns is
the divisor, not a decline. Allocator footprint differences are within 17 MB (about 1%) on a 1.3 GB process, arena
lowest; the arena's own native footprint is 3 MiB of blocks. Throughput: single runs, same direction as `e2e-rss/` (h2 arena +3.5% here,
+8% there) but the three-run 2M-request comparison in 2.5 showed no change - not established without repeats.

glibc: the arena's `/proc/<pid>/maps` holds only **two** 256 KiB anonymous `rw-p` mappings in each of the two
captures, against the 12 blocks the counters report, so most of the 256 KiB blocks obtained through
`Unsafe.allocateMemory` are carved from larger glibc segments rather than mmapped one by one. The anonymous rw size
histogram is dominated by 132K and 1008K mappings (`arena-maps-1790099196.txt`: 132K x25, 1008K x24, 256K x2, 4K x4;
`arena-maps-1790099264.txt`: 132K x27, 1008K x23, 256K x2, 4K x4). The blocks are never freed (trim is explicit
only), so they stay in the loop threads' glibc arenas for the life of the process. Which segments hold them was not
established.

### 2.10 The harness's E_COMMERCE "eventloop" ladder with a driven hook (measured 2026-09-22, 2300 MHz, node 0, 3 forks)

`ByteBufAllocatorAllocPatternBenchmark`, 32 threads on the FastThreadLocal harness executor (not event loops: the arena's
hook is driven every 64 operations with `-Dexpt.hookEvery=64`), `enableReadWrite=true`, seven live-buffer counts.
ADAPTIVE and MIMALLOC rows are the merged 84-cell matrix of the same day (same harness, same machine). **That matrix
is not in this repository**, so the ADAPTIVE and MIMALLOC columns, and every ratio built on them, cannot be re-derived
here; the ARENA ns, share/pinned and `RSS ar` columns can, from `arena-v3/ecommerce-eventloop/arena-hook64.{json,log}`
(the `pinned` column is the per-thread `ARENALOOP` maximum; the process-wide `ARENATELE` value is the sum over the 32
threads, i.e. 32x it). Peak RSS in MB (max over forks). Share = arena share of allocations;
pinned = max simultaneously pinned blocks per loop (8 = all).

| memory | live | ADAPTIVE ns | MIMALLOC ns | ARENA ns | arena/adaptive | arena/mimalloc | RSS ad / mi / ar | share, pinned |
|---|---|---|---|---|---|---|---|---|
| heap | 128 | 244 | 316 | 205 | 0.84 | 0.65 | 2024 / 1995 / 2075 | 88%, 2 |
| heap | 1024 | 426 | 269 | 309 | 0.72 | 1.15 | 2154 / 1907 / 2242 | 88%, 7 |
| heap | 4096 | 374 | 372 | 451 | 1.21 | 1.21 | 2157 / 2794 / 2886 | 49%, 8 |
| heap | 8192 | 565 | 519 | 588 | 1.04 | 1.13 | 3163 / 3596 / 3618 | 26%, 8 |
| heap | 16384 | 732 | 734 | 741 | 1.01 | 1.01 | 4234 / 4375 / 4910 | 14%, 8 |
| heap | 32768 | 694 | 1014 | 843 | 1.22 | 0.83 | 7316 / 6813 / 7411 | 7%, 8 |
| heap | 65536 | 1146 | 1819 | 1181 | 1.03 | 0.65 | 11544 / 12057 / 12534 | 4%, 8 |
| direct | 128 | 221 | 240 | 195 | 0.88 | 0.81 | 1804 / 1962 / 1820 | 88%, 2 |
| direct | 1024 | 345 | 263 | 263 | 0.76 | 1.00 | 2285 / 2088 / 2241 | 88%, 7 |
| direct | 4096 | 316 | 338 | 434 | 1.37 | 1.28 | 2642 / 2628 / 2835 | 49%, 8 |
| direct | 8192 | 448 | 490 | 610 | 1.36 | 1.24 | 3292 / 3269 / 3575 | 26%, 8 |
| direct | 16384 | 614 | 717 | 730 | 1.19 | 1.02 | 4566 / 4578 / 4848 | 14%, 8 |
| direct | 32768 | 692 | 849 | 776 | 1.12 | 0.91 | 7326 / 7066 / 7408 | 7%, 8 |
| direct | 65536 | 758 | 991 | 877 | 1.16 | 0.88 | 12351 / 12135 / 12426 | 4%, 8 |

Reading: at 128 live the arena beats both; at 1024 it beats adaptive by 24-28% and ties or loses to the mimalloc port;
from 4096 live up the live set exceeds the 8-block bound, share falls from 49% to 4% with all eight blocks pinned in
every fork, and the arena is 1-37% slower than adaptive while still ahead of the port at 32 K and 64 K live, where the
port is slow. RSS is above adaptive by 75-990 MB from 4096 live up, far more than the 128 MiB the blocks can account
for; that excess is not explained. A partial same-session re-run of adaptive and mimalloc (`adaptive-mimalloc.log`,
20 completed cells; it was stopped before JMH wrote a json, so there is no json for it) agrees with the matrix to within ~5% except adaptive heap 4096 (430 vs 374), adaptive direct 1024
(277 vs 345) and mimalloc heap 128 (270 vs 316), so the ratios at those cells carry a 15-20% run-to-run uncertainty. This is the geometric-lifetime regime the
design declares out of scope: the driven hook is a fixed cadence, not a lifetime boundary.

## 3. Transports: io_uring and epoll (measured 2026-09-23, 2300 MHz, node 0)

Code: netty `2b961262d6` (`expt/event-loop-arena`, the ring-reuse commit before its final amend; the pushed commit is `11adeba602`, differing only in javadoc and the ring's default, which every run here set explicitly), PoC `run-e2e.sh` /
`topology/run-matrix.sh` with `TRANSPORT=nio|epoll|io_uring`. Server pinned with
`numactl --cpunodebind=0 --membind=0`, h2load with `--cpunodebind=1 --membind=1`, logging off, one
run per cell. Raw output: `arena-v3/{io_uring,epoll,nio}/`.

### 3.1 What this kernel supports - probed, not assumed

`lib/java/IoUringProbe.java` run on this box (kernel `7.1.13-100.fc43.x86_64`, full output in
`arena-v3/io_uring/probe.txt`) reports **every** feature the branch probes as supported:

```
setup flags: SUBMIT_ALL=true CQE_MIXED=true CQSIZE=true SINGLE_ISSUER=true DEFER_TASKRUN=true NO_SQARRAY=true
ops:         SPLICE=true SEND_ZC=true SENDMSG_ZC=true ACCEPT_MULTISHOT=true RECV_MULTISHOT=true
             POLL_ADD_MULTISHOT=true RECVSEND_BUNDLE=true REGISTER_BUFFER_RING=true
             REGISTER_BUFFER_RING_INC=true REGISTER_IOWQ_MAX_WORKERS=true CQE_F_SOCK_NONEMPTY=true
             ENTER_NO_IOWAIT=true
enabled by netty's own defaults: ACCEPT_MULTISHOT=true RECV_MULTISHOT=true POLL_ADD_MULTISHOT=true
                                 RECVSEND_BUNDLE=false ENTER_NO_IOWAIT=false
```

Two features are supported by the kernel but **off in netty's defaults and left off here**:
`IORING_RECVSEND_BUNDLE` (netty disables it over a known kernel bug, see the comment in
`IoUring.java`) and `IORING_ENTER_NO_IOWAIT`. Everything else is on. The cells configure:
ring size 128, CQ size 4096, `setSingleIssuer(true)`, one provided buffer ring per worker loop
(bgId 1, 64 entries x 8 KiB, incremental, batch 32, buffers allocated **by the allocator under
test**), `IO_URING_BUFFER_GROUP_ID=1` and `IO_URING_WRITE_ZERO_COPY_THRESHOLD=4096` on every child.

Both io_uring options were read back off the first accepted channel
(`CHILDOPTS IO_URING_BUFFER_GROUP_ID=1 IO_URING_WRITE_ZERO_COPY_THRESHOLD=4096` in every
`*-server.log`); that says the channel config stored them. That the ring is **used** is the
`RINGTELE ringReads` counter (buffers taken back out of the ring: 6.6 M on the h1 arena cell, 0 by
construction on nio/epoll). That zero-copy writes are used is netty's own
`IoUringSocketChannel$IoUringSocketUnsafe.handleWriteCompleteZeroCopy` frame appearing as a release
site: it accounts for **32.3% of all buffer frees** in the W1 io_uring arena window
(`arena-v3/io_uring/topology/w1-io_uring-arena.txt`).

The kernel side agrees. A separate 6 s h1 arena run (NOT one of the measured cells) traced with
`bpftrace -e 'tracepoint:io_uring:io_uring_submit_req /pid == <server>/ { @op[args->opcode] = count(); }'`
counted, by opcode (`arena-v3/io_uring/verify/opcodes.txt`):

| opcode | name | submissions |
|---|---|---|
| 47 | `SEND_ZC` | 1,268,381 |
| 2 | `WRITEV` | 1,268,381 |
| 11 | `TIMEOUT` | 544,776 |
| 14 | `ASYNC_CANCEL` | 66 |
| 19 | `CLOSE` | 64 |
| 27 | `RECV` | 64 |
| 6 | `POLL_ADD` | 64 |
| 22 | `READ` | 16 |

`SEND_ZC` is submitted 1.27 M times, so the zero-copy threshold is honoured by the kernel path, not
only by the channel config. `RECV` is submitted **64 times** - once per connection - while the same
run's `RINGTELE` counted 1,917,439 buffers taken out of the provided buffer ring: multishot RECV
plus the buffer ring. `SENDMSG_ZC` (48) never appears in this workload. I do not know why `WRITEV`
and `SEND_ZC` have exactly equal counts; I did not investigate it.

### 3.2 End to end, 20 s per cell, one run per cell

req/s from h2load; RSS is the sampled max and is dominated by the JVM heap (no `-Xmx` is set on
these servers), so it separates nothing here.

| transport | protocol | ADAPTIVE | MIMALLOC | ARENA |
|---|---|---|---|---|
| nio | h1 | 300,868 | 300,844 | 300,937 |
| epoll | h1 | 298,726 | 298,556 | 298,616 |
| io_uring | h1 | 218,509 | 220,521 | 218,546 |
| nio | h2 | 672,701 | 673,136 | 675,066 |
| epoll | h2 | 674,454 | 679,203 | 677,757 |
| io_uring | h2 | 669,974 | 658,934 | 660,386 |

**Within a transport the three allocators are indistinguishable** (spread <= 1.7%, one run per cell).
**Across transports, io_uring is 27% below nio/epoll on HTTP/1.1** (218.5 k vs 300.9 k) and within
2% of them on HTTP/2. One run per cell: this is a single measurement, not a distribution, and no
cause is claimed.

Arena counters on the ARENA cell of each transport (`ARENATELE`, process-wide, 8 loops):

| transport | protocol | arena share | blocksDirect | maxPinnedDirect | violations | leaked |
|---|---|---|---|---|---|---|
| nio | h1 | 100.00% | 8 | 0 | 0 | 0 |
| epoll | h1 | 100.00% | 8 | 0 | 0 | 0 |
| io_uring | h1 | 99.70% | 64 | 41 | 0 | 0 |
| nio | h2 | 95.54% | 8 | 0 | 0 | 0 |
| epoll | h2 | 95.52% | 8 | 0 | 0 | 0 |
| io_uring | h2 | 93.72% | 64 | 24 | 0 | 0 |

`blocksDirect` is the number of blocks the process ever created and `maxPinnedDirect` the **sum over
the 8 arenas of each arena's own maximum**. On nio and epoll one block per loop is enough and
nothing is ever pinned at a hook; with the buffer ring every loop grows to its 8-block bound and 41
(h1) / 24 (h2) block-maxima are pinned across the 8 loops - about 5 and 3 blocks per loop. That is
the kernel-owned ring buffers plus the zero-copy writes in flight. No confinement violation and no
leaked block in any of these cells.

### 3.3 Lifecycle topology on io_uring, seven cells x three builds

One 1.5 s JFR window inside an 8 s load, 4 event loops, `topology/run-matrix.sh`. ARENA is run at
the branch default `-Darena.ring=true` and again with `-Darena.ring=false`. `maxPinned` is
`maxPinnedDirect`, the sum over the four arenas; `blocksDirect` is 32 = 4 loops x 8 blocks whenever
every block was created.

| workload | build | arena share | maxPinned | violations | ringReads | req/s |
|---|---|---|---|---|---|---|
| W1 h1 snoop | adaptive | - | - | - | 1,095,271 | 90,543 |
| W1 | arena ring=true | 64.43% | 28 | 0 | 1,864,138 | 154,108 |
| W1 | arena ring=false | 45.45% | 25 | 0 | 1,936,946 | 160,128 |
| W2 h2 hello | adaptive | - | - | - | 1,583,899 | 306,757 |
| W2 | arena ring=true | 61.64% | 17 | 0 | 2,438,158 | 469,277 |
| W2 | arena ring=false | 41.10% | 18 | 0 | 2,563,976 | 493,475 |
| W3 h2 echo 64 KiB | adaptive | - | - | - | 2,477,308 | 28,695 |
| W3 | arena ring=true | 55.29% | 32 | 0 | 2,581,502 | 30,014 |
| W3 | arena ring=false | 47.10% | 32 | 0 | 2,623,190 | 30,436 |
| W4 h1 chunked, slow readers | adaptive | - | - | - | 12,904 | 384 reqs |
| W4 | arena ring=true | 50.40% | 32 | 0 | 12,884 | 384 reqs |
| W4 | arena ring=false | 48.05% | 32 | 0 | 12,874 | 384 reqs |
| W5 aggregator 256 KiB | adaptive | - | - | - | 7,177,190 | 21,220 |
| W5 | arena ring=true | 83.66% | 24 | 0 | 7,155,108 | 21,308 |
| W5 | arena ring=false | 91.55% | 24 | 0 | 7,319,769 | 20,372 |
| W6a proxy, same loop | adaptive | - | - | - | 3,308,213 | 87,304 |
| W6a | arena ring=true | 100.00% | 12 | 0 | 3,202,391 | 84,360 |
| W6a | arena ring=false | 99.98% | 12 | 0 | 3,219,951 | 84,751 |
| W6b proxy, separate loop | adaptive | - | - | - | 2,756,305 | 71,919 |
| W6b | arena ring=true | 100.00% | 16 | **406** | **375** | **10.25** |
| W6b | arena ring=false | 100.00% | 16 | **414** | **387** | **10.62** |

Against the nio figures of section 2.4 (same workloads, same window shape, W1 99.99% share and
maxPinned 0), the io_uring cells show a **much lower arena share and a much higher pinned count** on
W1-W4: every block of every loop is created and 3-8 of them per loop are pinned at a hook. W5 is the
exception: its share goes up (11.85% on nio to 83.66% here), because on io_uring the 256 KiB body
arrives as 8 KiB ring slices instead of one large receive buffer.

The `req/s` column is reported because it is in the logs; these are **not** throughput measurements
(a JFR recording runs inside the window, 4 loops, 8 s). The adaptive cells of W1 and W2 came out far
below the arena cells (90.5 k vs 154.1 k, 306.8 k vs 469.3 k) while the e2e cells of the same
allocators on the same transport tie to within 1.7%. **I do not know what makes those two cells
differ** and did not investigate it.

### 3.4 What broke: W6b, the cross-loop proxy

W6b is the deliberate negative test: the buffer is allocated on the inbound loop and released on the
outbound loop. On nio it counted 2,140 violations and still served the load. On io_uring the same
cell **collapses to 10.25 req/s against adaptive's 71,919**, with 406 violations, and the server log
holds 406 copies of

```
java.lang.IllegalStateException: arena buffer of Thread[#26,multiThreadIoEventLoopGroup-3-1,...]
        touched from Thread[#31,multiThreadIoEventLoopGroup-4-2,...]
    at io.netty.buffer.CycleArenaAllocator$ArenaBuf.violation(CycleArenaAllocator.java:1279)
    at io.netty.buffer.CycleArenaAllocator$ArenaBuf.retain(CycleArenaAllocator.java:1182)
    at io.netty.buffer.AbstractDerivedByteBuf.retain(AbstractDerivedByteBuf.java:54)
    at io.netty.channel.uring.IoUringSocketChannel$IoUringSocketUnsafe.handleWriteCompleteZeroCopy(...)
    ...
    WARN i.n.channel.uring.IoUringIoHandler - Unexpected exception in the IO event loop.
```

with `RINGTELE ringReads=375` for the whole 8 s window (adaptive: 2,756,305). Counters: 406
violations, ringReads 375, 10.25 req/s. The throw lands on the zero-copy write-completion path and
is logged by the io_uring handler as an unexpected event-loop exception. No claim is made here about
the mechanism beyond what these three counters and that stack say.

### 3.5 async-profiler, io_uring, one 14 s CPU profile per cell

`tools/asprof-alloc-share.py` (filter B = stacks containing `SingleThreadIoEventLoop.run`, which is
transport independent, of which those containing an allocator frame):

| profile | loop samples | allocator samples | share B | share A (wide) |
|---|---|---|---|---|
| io_uring h1 ADAPTIVE | 87,461 | 1,673 | 1.91% | 2.72% |
| io_uring h1 ARENA | 88,509 | 3,819 | **4.31%** | 4.74% |
| io_uring h2 ADAPTIVE | 67,771 | 8,521 | 12.57% | 15.93% |
| io_uring h2 ARENA | 67,044 | 5,759 | **8.59%** | 13.88% |

On HTTP/2 the arena's share is below adaptive's, as it was on nio (11.03% -> 9.25% there). On
HTTP/1.1 it is **above** it, which is the opposite of the nio profile pair (7.72% -> 7.15%). One
profile per cell.

`tools/asprof-loop-breakdown.py`, same files (the rules now also name epoll and io_uring frames, and
the read/write rules are matched before the ring rule because `io_uring_enter(2)` runs the send and
recv inline, so what is left in "io_uring enter" is ring machinery):

| component | h1 ADAPTIVE | h1 ARENA | h2 ADAPTIVE | h2 ARENA |
|---|---|---|---|---|
| socket write (syscall incl.) | 56.2% | 52.4% | 28.6% | 28.3% |
| loop other | 20.7% | 20.6% | 10.9% | 8.8% |
| io_uring enter (submit/wait) | 10.0% | 9.7% | 5.3% | 5.2% |
| http codec | 6.8% | 8.4% | 33.9% | 40.9% |
| socket read (syscall incl.) | 4.3% | 4.6% | 8.8% | 8.2% |
| allocator | 1.9% | 4.3% | 12.6% | 8.6% |

### 3.6 What section 3 does not establish

- Every cell is **one run**. The e2e cells are 20 s, the topology cells a single 1.5 s window.
- Why io_uring is 27% below nio/epoll on HTTP/1.1 here: not investigated.
- Why the W1/W2 topology adaptive cells are far below the arena cells while the e2e cells tie: not
  investigated, and the topology cells are not throughput measurements.
- `RECVSEND_BUNDLE` and `ENTER_NO_IOWAIT` are supported by the kernel but were left at netty's
  defaults (off), so nothing here measures them.

## 4. io_uring: is the arena wrong for the registered buffers, or wrong? (measured 2026-09-23, 2300 MHz, node 0)

Section 3 measured the arena on io_uring with ONE allocator doing two jobs: serving the channels and
filling the provided buffer ring. A ring buffer is handed to the kernel and comes back only when the
kernel has filled it - lifetime class D, alive across an unbounded number of iterations - so that run
could not separate "the arena is wrong for io_uring" from "the arena is wrong for the buffers the
ring registers". `BUFFER_RING_ALLOC=adaptive` (PoC `lib/java/Transports.java`) gives the buffer ring
its own `AdaptiveByteBufAllocator` and leaves `ChannelOption.ALLOCATOR` on the allocator under test,
so the two can be measured apart. Code: netty `52b19c8ebf`, PoC `topology/run-matrix.sh` and `run-e2e.sh`
with `TRANSPORT=io_uring`; the arena cells set `-Darena.ring=true` explicitly, as section 3's did.
Server pinned with `numactl --cpunodebind=0 --membind=0`, h2load on node 1. Raw output:
`arena-v3/io_uring-split/`.

### 4.1 Lifecycle topology on io_uring, seven cells x three configurations

| workload | configuration | arena share | maxPinned | violations | ringReads | reentries | req/s |
|---|---|---|---|---|---|---|---|
| W1 h1 snoop | adaptive | - | - | - | 1,112,000 | - | 91,926 |
| W1 h1 snoop | arena everywhere | 100.00% | 21 | 0 | 1,191,403 | 43282 | 98,490 |
| W1 h1 snoop | arena + adaptive ring | 100.00% | 6 | 0 | 1,165,043 | 0 | 96,311 |
| W2 h2 hello | adaptive | - | - | - | 1,134,485 | - | 219,602 |
| W2 h2 hello | arena everywhere | 96.63% | 18 | 0 | 1,442,633 | 41554 | 280,825 |
| W2 h2 hello | arena + adaptive ring | 95.91% | 4 | 0 | 1,338,532 | 0 | 261,452 |
| W3 h2 echo 64 KiB | adaptive | - | - | - | 1,116,171 | - | 13,112 |
| W3 h2 echo 64 KiB | arena everywhere | 93.72% | 32 | 0 | 1,470,263 | 98317 | 17,265 |
| W3 h2 echo 64 KiB | arena + adaptive ring | 94.76% | 5 | 0 | 1,504,931 | 0 | 17,483 |
| W4 h1 chunked, slow readers | adaptive | - | - | - | 12,867 | - | 384 reqs |
| W4 h1 chunked, slow readers | arena everywhere | 74.63% | 32 | 0 | 12,963 | 649 | 385 reqs |
| W4 h1 chunked, slow readers | arena + adaptive ring | 99.97% | 4 | 0 | 12,858 | 0 | 384 reqs |
| W5 aggregator 256 KiB | adaptive | - | - | - | 4,128,214 | - | 12,121 |
| W5 aggregator 256 KiB | arena everywhere | 99.33% | 32 | 0 | 4,159,708 | 54192 | 12,105 |
| W5 aggregator 256 KiB | arena + adaptive ring | 99.47% | 4 | 0 | 4,148,462 | 0 | 11,990 |
| W6a proxy, same loop | adaptive | - | - | - | 1,744,296 | - | 46,048 |
| W6a proxy, same loop | arena everywhere | 100.00% | 12 | 0 | 499,321 | 1524 | 14,094 |
| W6a proxy, same loop | arena + adaptive ring | n/a | 0 | 0 | 1,758,231 | 0 | 46,461 |
| W6b proxy, separate loop | adaptive | - | - | - | 1,487,402 | - | 38,893 |
| W6b proxy, separate loop | arena everywhere | 100.00% | 16 | 398 | 371 | 0 | 10 |
| W6b proxy, separate loop | arena + adaptive ring | n/a | 0 | 0 | 1,555,149 | 0 | 40,678 |

### 4.2 End to end on io_uring, 20 s per cell, one run per cell

`summary-h1-ringadaptive.txt`:
```
arena          126902.00 req/s | 70us    164.75ms       510us      1.03ms    99.68% | RSS 105->821 MB (mean 774, 38 samples) | 82 young GCs | RINGTELE transport=io_uring ringAllocs=1299657 ringReads=3836872 ringReadBytes=10644720102 bgId=1 entries=64 chunk=8192 incremental=true batchSize=32 batchAllocation=false alloc=adaptive allocClass=AdaptiveByteBufAllocator | ARENATELE blockSize=262144 maxBlocks=8 cap=8192 maxObjects=16384 debug=false ring=false ringStats=false arenaHeap=0 arenaDirect=5104566 delegateHeap=0 delegateDirect=0 arenaShare=100.00% blocksHeap=8 blocksDirect=40 pinned=4 reusable=31 maxPinnedHeap=0 maxPinnedDirect=16 blockReuses=45499 blockGrowths=32 blockSwitches=45531 ringWraps=0 ringResets=0 ringScans=0 ringReentries=0 ringStalls=0 stallBytes=0 strandedBytes=0 strandedShare=n/a holes<=256=0 holes<=1k=0 holes<=4k=0 holes<=8k=0 holes>8k=0 hooks=793386 hookRejections=0 violations=0 earlyReuses=0 reallocInPlace=0 reallocMoved=0 reallocDelegated=0 trims=0 trimmedBlocks=0 leakedBlocks=0 objects=136 bytesHeap=0 bytesDirect=11866710040 liveHeap=0 liveDirect=0
```
`summary-h1-same.txt`:
```
adaptive       126781.95 req/s | 64us    162.00ms       511us       991us    99.66% | RSS 105->793 MB (mean 752, 38 samples) | 83 young GCs | RINGTELE transport=io_uring ringAllocs=1298422 ringReads=3833223 ringReadBytes=10634604174 bgId=1 entries=64 chunk=8192 incremental=true batchSize=32 batchAllocation=false alloc=same allocClass=AdaptiveByteBufAllocator
arena          126697.05 req/s | 69us    164.87ms       513us      1.10ms    99.69% | RSS 107->824 MB (mean 783, 38 samples) | 82 young GCs | RINGTELE transport=io_uring ringAllocs=1297553 ringReads=3830655 ringReadBytes=10627486956 bgId=1 entries=64 chunk=8192 incremental=true batchSize=32 batchAllocation=false alloc=same allocClass=CycleArenaAllocator | ARENATELE blockSize=262144 maxBlocks=8 cap=8192 maxObjects=16384 debug=false ring=false ringStats=false arenaHeap=0 arenaDirect=10088684 delegateHeap=0 delegateDirect=57413 arenaShare=99.43% blocksHeap=8 blocksDirect=64 pinned=38 reusable=26 maxPinnedHeap=0 maxPinnedDirect=40 blockReuses=152291 blockGrowths=56 blockSwitches=152648 ringWraps=0 ringResets=0 ringScans=0 ringReentries=0 ringStalls=0 stallBytes=0 strandedBytes=0 strandedShare=n/a holes<=256=0 holes<=1k=0 holes<=4k=0 holes<=8k=0 holes>8k=0 hooks=692555 hookRejections=0 violations=0 earlyReuses=0 reallocInPlace=26532 reallocMoved=1540 reallocDelegated=5 trims=0 trimmedBlocks=0 leakedBlocks=0 objects=395 bytesHeap=0 bytesDirect=39532247416 liveHeap=0 liveDirect=256
```
`summary-h2-ringadaptive.txt`:
```
arena          372490.00 req/s | 494us    226.87ms      1.32ms      2.88ms    99.55% | RSS 105->815 MB (mean 768, 38 samples) | 35 young GCs | RINGTELE transport=io_uring ringAllocs=3752589 ringReads=5484344 ringReadBytes=30739145571 bgId=1 entries=64 chunk=8192 incremental=true batchSize=32 batchAllocation=false alloc=adaptive allocClass=AdaptiveByteBufAllocator | ARENATELE blockSize=262144 maxBlocks=8 cap=8192 maxObjects=16384 debug=false ring=false ringStats=false arenaHeap=0 arenaDirect=37655978 delegateHeap=0 delegateDirect=2877037 arenaShare=92.90% blocksHeap=8 blocksDirect=16 pinned=0 reusable=8 maxPinnedHeap=0 maxPinnedDirect=12 blockReuses=143 blockGrowths=8 blockSwitches=151 ringWraps=0 ringResets=0 ringScans=0 ringReentries=0 ringStalls=0 stallBytes=0 strandedBytes=0 strandedShare=n/a holes<=256=0 holes<=1k=0 holes<=4k=0 holes<=8k=0 holes>8k=0 hooks=764853 hookRejections=0 violations=0 earlyReuses=0 reallocInPlace=3 reallocMoved=0 reallocDelegated=0 trims=0 trimmedBlocks=0 leakedBlocks=0 objects=1392 bytesHeap=0 bytesDirect=2393117488 liveHeap=0 liveDirect=0
```
`summary-h2-same.txt`:
```
adaptive       371712.40 req/s | 578us    229.93ms      1.32ms      2.85ms    99.54% | RSS 106->809 MB (mean 764, 38 samples) | 36 young GCs | RINGTELE transport=io_uring ringAllocs=3744764 ringReads=5471069 ringReadBytes=30675042093 bgId=1 entries=64 chunk=8192 incremental=true batchSize=32 batchAllocation=false alloc=same allocClass=AdaptiveByteBufAllocator
arena          369614.40 req/s | 516us    223.23ms      1.34ms      2.93ms    99.44% | RSS 107->827 MB (mean 773, 38 samples) | 34 young GCs | RINGTELE transport=io_uring ringAllocs=3723637 ringReads=5442376 ringReadBytes=30501975906 bgId=1 entries=64 chunk=8192 incremental=true batchSize=32 batchAllocation=false alloc=same allocClass=CycleArenaAllocator | ARENATELE blockSize=262144 maxBlocks=8 cap=8192 maxObjects=16384 debug=false ring=false ringStats=false arenaHeap=0 arenaDirect=43024727 delegateHeap=0 delegateDirect=3051403 arenaShare=93.38% blocksHeap=8 blocksDirect=64 pinned=17 reusable=47 maxPinnedHeap=0 maxPinnedDirect=24 blockReuses=162434 blockGrowths=56 blockSwitches=162778 ringWraps=0 ringResets=0 ringScans=0 ringReentries=0 ringStalls=0 stallBytes=0 strandedBytes=0 strandedShare=n/a holes<=256=0 holes<=1k=0 holes<=4k=0 holes<=8k=0 holes>8k=0 hooks=756872 hookRejections=0 violations=0 earlyReuses=0 reallocInPlace=0 reallocMoved=24 reallocDelegated=414031 trims=0 trimmedBlocks=0 leakedBlocks=0 objects=1664 bytesHeap=0 bytesDirect=42188570096 liveHeap=0 liveDirect=256
```

Allocator share of event-loop CPU samples (async-profiler `cpu`, 1 ms, filter B of
`tools/asprof-alloc-share.py`), one 14 s profile per cell:

| proto | adaptive | arena everywhere | arena + adaptive ring |
|---|---|---|---|
| h1 | 1.52% | 3.22% | 1.71% |
| h2 | 8.67% | 7.74% | 5.58% |

req/s is within 0.8% across all three configurations (h1 126,782 / 126,697 / 126,902; h2 371,712 /
369,614 / 372,490), so the split does not move throughput here - but it halves the arena's allocator
CPU on h1, back to adaptive's level, and takes h2 below adaptive. The ring's buffers were costing the
arena CPU as well as blocks.

### 4.3 What survives a hook, and an instrument that was blind

`CycleArenaAllocator` emits no `io.netty.AllocateBuffer` / `FreeBuffer` - those live on the adaptive
paths - so for an ARENA cell the lifetime study of sections 2.4 and 3.3 only ever saw the buffers the
arena could **not** serve. The event count tracks the delegated fraction exactly: W1 share 100% -> 0
events here against 3.3's 64.43% -> 243,411; W6a/W6b 100% -> 0; W5 99.33% -> 942 against 3.3's
83.66% -> 460,251. Those tables describe the delegated minority, not the arena's own traffic.

The split run gives the attribution anyway, because there the ring's buffers **are** adaptive and do
emit. Share of all pairs whose lifetime is at least one event-loop iteration, by release cause:

| cell | survive a hook | top causes |
|---|---|---|
| W1 | 17.9% | handler 17.4, decoder/cumulation 0.4 |
| W2 | 4.1% | decoder/cumulation 3.3, write-completion 0.9 |
| W5 | 63.5% | aggregator 63.4 |
| W6a | 85.0% | write-completion 49.4, `IoUringSocketUnsafe.handleWriteCompleteZeroCopy` 35.6 |
| W6b | 100.0% | write-completion 64.4, `handleWriteCompleteZeroCopy` 35.6 |

In the proxy workloads essentially every provided-ring buffer outlives the iteration that allocated
it, on the write-completion and zero-copy-completion paths - and those are the buffers that were
pinning 12-32 of the arena's blocks.

### 4.4 W6b, the cross-loop proxy, with the ring on adaptive

| configuration | violations | req/s |
|---|---|---|
| adaptive | 0 | 38,893 |
| arena everywhere | 398 | 10.50 |
| arena + adaptive buffer ring | **0** | **40,678** |

The failure is gone. The stack of the one that used to fire says it was the ring's buffer:

```
IllegalStateException: arena buffer of Thread[multiThreadIoEventLoopGroup-3-4]
    touched from Thread[multiThreadIoEventLoopGroup-4-2]
  at CycleArenaAllocator$ArenaBuf.release
  at AbstractDerivedByteBuf.release0        <- a retainedSlice, i.e. what useBuffer() hands out
  at ReferenceCountUtil.safeRelease
  at ChannelOutboundBuffer.remove           <- on the OUTBOUND loop
```

`IoUringBufferRing.useBuffer()` hands the pipeline a `retainedSlice` of a ring buffer; the proxy
writes that slice to the other loop's channel and the outbound loop releases it. Nothing else crossed
loops. Cross-loop is out of scope for the arena by design and is **not** fixed here.

### 4.5 What section 4 does not establish

* Absolute `req/s` is not comparable with section 3. The adaptive control is unchanged code and moved
  with everything else (W2 219,602 vs 306,757; W3 13,112 vs 28,695; W6a 46,049 vs 87,304), so the
  session differs, not the change. Everything above is compared **within** this run.
* One run per cell, 8 s with a JFR recording inside; no repetitions, no error bars.
* W6a with the arena everywhere came out at 14,094 req/s against adaptive's 46,049 in the same
  session, where 3.3 had them at parity. The arena counters do not point at the arena (100% share,
  12 blocks, 3,764 block switches, 1,524 re-entries, 0 violations). Unexplained.
* Nothing here says the arena is the right tool for the channel buffers either - only that the
  registered ring buffers are what it cannot hold.

### 4.6 What the ring and the re-entry cost, on the microbenchmarks

Raw data: `arena-v3/ring/` (copied from the `netty-bench` harness run of 2026-09-22; the two
`bench-*.jar` files are not in the repo). The `.sh` files next to the JSON are the exact commands.
`k=64`, so an `#/op` figure covers 64 alloc/release pairs.

**Cost of `-Darena.ring=true`**, instructions per *pair*, computed here from the `#/op` rows of the
`perfnorm` logs (`cycleDirect`/`cycleHeap`, `ARENA k=64 FIFO SMALL`):

| layout | direct | heap | files |
|---|---|---|---|
| `long[][]` metadata (the shipped one) | **+29.3** | **+8.5** | `prof/perfnorm-ring-{false,true}.log` |
| flat metadata | **+36.0** | **+17.7** | `flat/pn-flat-{false,true}.log` |
| flat + `Unsafe` | **+29.1** | **+17.5** | `flat/pn-unsafe-{false,true}.log` |

`CycleScopedAllocBenchmark` SMALL, 3 forks, ns per 64 pairs, straight out of the JSON:

| build | cycleDirect | cycleHeap | file |
|---|---|---|---|
| ring=false | 1439.2 | 1657.1 | `cycle-ring-false.json` |
| ring=true | 1622.9 | 1782.1 | `cycle-ring-true.json` |
| re-entry, ring=false | 1489.1 | 1516.9 | `reentry/cycle-reentry-false.json` |
| re-entry, ring=true | 1674.6 | 2137.1 | `reentry/cycle-reentry-true.json` |

A summary handed to me for this table quoted "1428/1674 vs 1622/1817"; three of those four numbers
are not in these files (1674 is the *re-entry* ring=true direct score). The table above is what the
JSON says and is the one to use.

**The re-entry ladder**, `ByteBufAllocatorAllocPatternBenchmark` E_COMMERCE, `enableReadWrite=true`,
3 forks, ns/op, `ecommerce-ring-hook0.json` vs `reentry/ecommerce-reentry-hook0.json`:

| live buffers | direct: ring -> +re-entry | heap: ring -> +re-entry |
|---|---|---|
| 1024 | 284.9 -> **270.1** | 332.4 -> **292.1** |
| 4096 | 392.1 -> **404.4** | 416.7 -> **468.2** |

Re-entry helps at 1024 and hurts at 4096, on both spaces. The last `ARENATELE` line of each log
shows `arenaShare=47.91% blockSwitches=8,451,058` (ring) against `arenaShare=70.00%
blockSwitches=4,352,011` (re-entry): the share goes up and the switches halve. The same summary
quoted "blockSwitches 260M -> 8.6M"; no such pair is in these two files, and I did not find the run
it came from, so it is not reported here.

**The zero-slot bug.** `14dbbe384b` ("Never hand out a buffer that occupies no slot") changed
`slotBytes` to `max(8, align8(size))`. Before it, a zero-length request took no slot, so the ring
bitmap could mark a slot free while a live buffer still pointed into it. Every number in this
subsection is from builds at or after that commit.

## 5. io_uring with no registered buffers (`BUFFER_RING=off`, measured 2026-09-23, 2300 MHz, node 0)

Sections 3 and 4 always had a provided buffer ring. This one removes it. `BUFFER_RING=off`
(PoC `lib/java/Transports.java`) installs **no** `IoUringBufferRingConfig` and sets **no**
`IO_URING_BUFFER_GROUP_ID`, so `AbstractIoUringStreamChannel.scheduleRead0()` falls through to its
plain branch: the receive buffer comes from the **channel allocator** via `allocHandle.allocate(alloc())`
and an `IORING_OP_RECV` carries that buffer's address and length. Unchanged: the zero-copy write
threshold (4096), `setSingleIssuer(true)`/`DEFER_TASKRUN`, ring size 128, CQ size 4096, multishot
accept and multishot poll. **One thing does change that is not a knob:** `IoUring.isRecvMultishotEnabled()`
is read only inside `scheduleReadProviderBuffer()`, so with no buffer ring the recv is also one-shot -
`IORING_RECV_MULTISHOT` has nowhere to put data it was not given an address for. `RINGTELE` reads
`bufferRing=off ringAllocs=0 ringReads=0` in every off cell, which is how the knob was checked.

Code: netty `52b19c8ebf`, PoC `run-e2e.sh` / `topology/run-matrix.sh`. Server
`numactl --cpunodebind=0 --membind=0`, h2load on node 1, logging off, one run per cell. Raw output:
`arena-v3/uring-noring/`.

### 5.1 End to end, 20 s per cell, one run per cell

`maxPin` is `maxPinnedDirect`, the **sum over the 8 arenas** of each arena's own maximum; `blk` is
`blocksDirect`. `share B` is `tools/asprof-alloc-share.py` filter B on a separate 14 s profiled run
of the same cell (`uring-noring/prof/`).

| proto | channel allocator | BUFFER_RING | req/s | RSS max | share B | arena share | blk | maxPin | viol | wraps | reent |
|---|---|---|---|---|---|---|---|---|---|---|---|
| h1 | adaptive | **off** | 128,011 | 783 MB | 1.39% | - | - | - | - | - | - |
| h1 | arena ring=false | **off** | 127,571 | 804 MB | 2.56% | 99.77% | 64 | 24 | 0 | 0 | 0 |
| h1 | arena ring=true | **off** | 128,045 | 805 MB | 1.18% | 100.00% | 16 | 16 | 0 | 207,321 | 1 |
| h1 | adaptive | on (ring=adaptive) | 127,525 | 786 MB | 2.04% | - | - | - | - | - | - |
| h1 | arena ring=false | on (ring=adaptive) | 126,333 | 824 MB | 1.86% | 100.00% | 40 | 16 | 0 | 0 | 0 |
| h1 | arena ring=true | on (ring=adaptive) | 127,046 | 833 MB | 1.95% | 100.00% | 16 | 14 | 0 | 45,538 | 0 |
| h2 | adaptive | **off** | 373,036 | 811 MB | 8.17% | - | - | - | - | - | - |
| h2 | arena ring=false | **off** | 373,484 | 804 MB | 3.37% | 95.45% | 16 | 9 | 0 | 0 | 0 |
| h2 | arena ring=true | **off** | 375,054 | 805 MB | 3.32% | 95.43% | 8 | 8 | 0 | 23 | 0 |
| h2 | adaptive | on (ring=adaptive) | 375,820 | 817 MB | 8.87% | - | - | - | - | - | - |
| h2 | arena ring=false | on (ring=adaptive) | 374,754 | 805 MB | 6.84% | 92.88% | 16 | 10 | 0 | 0 | 0 |
| h2 | arena ring=true | on (ring=adaptive) | 373,657 | 805 MB | 7.00% | 92.89% | 8 | 8 | 0 | 95 | 0 |

Readings, all within this one session:

* **Removing the buffer ring costs io_uring nothing measurable here.** The adaptive control moves
  128,011 -> 127,525 on h1 (-0.4%) and 373,036 -> 375,820 on h2 (+0.7%) between off and on. All
  twelve cells sit inside a 1.3% band per protocol. One run per cell; this is not a distribution.
* **The arena's share does go back to nio levels without the ring.** h1 99.77% / 100.00% against
  nio's 100.00% (§3.2); h2 95.45% / 95.43% against nio's 95.54%. On h2 the share is *higher* without
  the ring than with it (95.45% vs 92.88%).
* **Pinned blocks do not.** nio pins 0 in these cells; with `BUFFER_RING=off` the sum over 8 loops is
  24 (h1, ring=false) and 9 (h2). So the answer to "does the arena behave on io_uring as it does on
  nio" is **share yes, pinning no** - see §5.3 for what half of the h1 pinning is.
* **Zero confinement violations in every e2e cell**, with or without the ring.
* Allocator CPU: on h2 the arena's filter-B share halves when the ring goes away (6.84% -> 3.37%)
  and is less than half adaptive's 8.17%. On h1 the three-way spread (1.18-2.56%) is smaller than the
  difference between the two arena builds, and I would not read a ranking out of one profile each.

### 5.2 Lifecycle topology with `BUFFER_RING=off`, seven cells x three builds

One 1.5 s JFR window inside an 8 s load, 4 event loops. These are **not** throughput measurements.

| workload | build | arena share | blk | maxPin | viol | wraps | reent | req/s |
|---|---|---|---|---|---|---|---|---|
| W1 h1 snoop | adaptive | - | - | - | - | - | - | 95,532 |
| W1 | arena ring=false | 45.39% | 32 | 17 | 0 | 0 | 0 | 93,624 |
| W1 | arena ring=true | 99.99% | 14 | 14 | 0 | 48,211 | 44,532 | 99,341 |
| W2 h2 hello | adaptive | - | - | - | - | - | - | 257,262 |
| W2 | arena ring=false | 95.63% | 8 | 8 | 0 | 0 | 0 | 308,677 |
| W2 | arena ring=true | 95.46% | 5 | 4 | 0 | 2,114 | 0 | 297,614 |
| W3 h2 echo 64 KiB | adaptive | - | - | - | - | - | - | 16,785 |
| W3 | arena ring=false | 95.80% | 8 | 8 | 0 | 0 | 0 | 20,769 |
| W3 | arena ring=true | 95.70% | 6 | 5 | 0 | 146 | 0 | 20,710 |
| W4 h1 chunked, slow readers | adaptive | - | - | - | - | - | - | 384 reqs |
| W4 | arena ring=false | 86.92% | 4 | 4 | 0 | 0 | 0 | 384 reqs |
| W4 | arena ring=true | 86.92% | 4 | 4 | 0 | 0 | 0 | 384 reqs |
| W5 aggregator 256 KiB | adaptive | - | - | - | - | - | - | 12,519 |
| W5 | arena ring=false | 13.17% | 4 | 4 | 0 | 0 | 0 | 12,612 |
| W5 | arena ring=true | 12.14% | 4 | 4 | 0 | 0 | 0 | 12,425 |
| W6a proxy, same loop | adaptive | - | - | - | - | - | - | 55,592 |
| W6a | arena ring=false | 61.76% | 32 | 12 | 0 | 0 | 0 | 53,721 |
| W6a | arena ring=true | 61.81% | 8 | 8 | 0 | 26,200 | 84 | 55,992 |
| W6b proxy, separate loop | adaptive | - | - | - | - | - | - | 48,090 |
| W6b | arena ring=false | 51.52% | 13 | 9 | **470** | 0 | 0 | **24.25** |
| W6b | arena ring=true | 52.36% | 15 | 11 | **486** | 0 | 0 | **24.0** |

Readings:

* **W6b is not fixed by removing the ring.** 470 / 486 violations and ~24 req/s against adaptive's
  48,090. §4.4 made W6b pass by moving the ring's buffers to adaptive (0 violations, 40,678 req/s);
  with **no** ring at all the read buffers come from the arena instead and those cross the loops.
  Cross-loop is out of scope for the arena by design, and §4.4's result was about *which* buffers
  crossed, not about the ring being the only thing that can cross.
* **W1 at `ring=false` measures 45.39%**, against §3.3's 45.45% for the same build knob with the ring
  on - the two agree to 0.06 points across two sessions and two transports configurations, which is
  the best cross-check in this file that the harness is measuring what it claims. `ring=true` is
  99.99%.
* **W5's share collapses to 13.17%** where §3.3 had 83.66% / 91.55% with the ring on. With no ring
  the 256 KiB body arrives in large receive buffers rather than 8 KiB ring slices; `-Darena.cap=8192`
  sends anything bigger straight to adaptive. That is the documented behaviour of the knob - I read
  the code, I did not instrument this cell to confirm the size distribution.
* Every non-W6b cell has 0 violations, and `maxPin` is between 4 and 17 - never 0, and never the
  32 (= 4 loops x 8 blocks) that §3.3 hit with the ring on.

### 5.3 What is still pinned: the zero-copy writes (separate 4-cell run)

`maxPin` above is not 0, and the other class-D path the harness enables is
`IO_URING_WRITE_ZERO_COPY_THRESHOLD=4096`, which netty leaves **disabled** by default
(`IoUringSocketChannelConfig:39`). Four extra cells, `BUFFER_RING=off`, `arena ring=false`, 20 s,
one run each, all in one session (`arena-v3/uring-noring/zerocopy/`); the `CHILDOPTS` line was read
back to confirm `-1` vs `4096`:

| proto | zero-copy writes | req/s | arena share | maxPinnedDirect | viol |
|---|---|---|---|---|---|
| h1 | on (threshold 4096) | 127,533 | 99.77% | **25** | 0 |
| h1 | off (netty default) | **174,648** | 99.58% | **11** | 0 |
| h2 | on (threshold 4096) | 371,285 | 95.32% | **9** | 0 |
| h2 | off (netty default) | 366,928 | 95.32% | **8** | 0 |

* On h1, turning the zero-copy writes off takes `maxPinnedDirect` from 25 to 11 and req/s from
  127,533 to **174,648 (+37%)**. On h2 it moves neither (9 -> 8, -1.2% req/s).
* 11 blocks across 8 loops are still pinned at a hook with no buffer ring and no zero-copy writes.
  **I do not know what holds them** and did not instrument it.
* The +37% on h1 is one run per cell and is a property of *this harness's* choice of a 4096-byte
  threshold against a 4096-byte body, not a statement about `SEND_ZC`. It is also the first number
  in this file that dents §3.2's unexplained "io_uring is 27% below nio/epoll on HTTP/1.1"
  (218.5 k vs 300.9 k there); 174,648 is still below nio, and the sessions differ, so this is a lead,
  not an explanation.

### 5.4 What section 5 does not establish

* One run per e2e cell, one 1.5 s window per topology cell, no repetitions, no error bars.
* Nothing here separates "no buffer ring" from "no multishot recv": `BUFFER_RING=off` is both.
* W1/W2/W3 topology req/s again come out far above the adaptive control while the e2e cells tie, as
  in §3.3 and §4.5. Still not investigated.
* The zero-copy cells are a different session from §5.1 and are only compared among themselves.

## 6. Who should serve the registered buffers (measured 2026-09-23, 2300 MHz, node 0)

Four candidates fill the provided buffer ring while the channel allocator is held at
`arena -Darena.ring=false`, plus adaptive everywhere as the control. The lifecycle they have to
satisfy, the requirement ("as local as possible, not elastic, sort of perm gen") and what every other
io_uring project does are in [`docs/uring-registered-buffers.md`](../../docs/uring-registered-buffers.md).

| id | `BUFFER_RING_ALLOC` | what |
|---|---|---|
| control | `same` + adaptive channels | one `AdaptiveByteBufAllocator` for channels and ring |
| (i) | `adaptive` | the ring gets its own `AdaptiveByteBufAllocator` (this is §4's split) |
| (ii) | `builtin` | netty's `IoUringFixedBufferRingAllocator` over `ByteBufAllocator.DEFAULT` (= adaptive here) |
| (ii-a) | `builtinadaptive` | netty's `IoUringAdaptiveBufferRingAllocator`, the only one that varies the buffer **size** (1 KiB..64 KiB) |
| (iii) | `slab` | `RegisteredSlabBufferRingAllocator`: one preallocated direct region **per loop**, 64x4 chunks of 8 KiB, free list by slot, nothing allocated after start-up |

**Expectation stated before the run:** (i) and (ii) are the same code path
(`AbstractIoUringBufferRingAllocator.allocate()` is `allocator.directBuffer(size)`) over two
different adaptive instances, so they should be indistinguishable. Candidate (iv), the FFM mimalloc
allocator, was **not run**: it needs JDK 25 and these scripts run on `PATH`'s `java`, which is 21.

### 6.1 End to end, 20 s per cell, one run per cell

`ringAllocs` is `allocate()` calls, i.e. buffers handed to the kernel; `ringReads` is buffers the
kernel filled and gave back. Over the 20 s load that is ~65 k `allocate()`/s (h1) and ~188 k/s (h2).

| proto | ring served by | req/s | RSS max | share B | ring-alloc frames | arena share | blk | maxPin | ringAllocs | ringReads |
|---|---|---|---|---|---|---|---|---|---|---|
| h1 | control (adaptive everywhere) | 127,487 | 788 MB | 2.05% | 0.75% | - | - | - | 1,305,646 | 3,854,561 |
| h1 | (i) adaptive | 126,840 | 828 MB | 1.49% | 1.30% | 100.00% | 40 | 16 | 1,299,022 | 3,834,994 |
| h1 | (ii) builtin | 127,062 | 815 MB | 1.69% | 1.18% | 100.00% | 40 | 16 | 1,301,289 | 3,841,686 |
| h1 | (ii-a) builtinadaptive | 127,198 | 834 MB | 1.35% | 0.73% | 100.00% | 40 | 16 | **890,137** | 3,433,470 |
| h1 | **(iii) slab** | **127,572** | 807 MB | **0.93%** | 1.61% | 100.00% | 40 | 16 | 1,306,518 | 3,857,134 |
| h2 | control (adaptive everywhere) | 374,335 | 819 MB | 9.35% | 1.22% | - | - | - | 3,771,185 | 5,461,231 |
| h2 | (i) adaptive | 375,775 | 791 MB | 6.31% | 1.28% | 92.88% | 16 | 8 | 3,785,687 | 5,477,870 |
| h2 | (ii) builtin | 370,529 | 821 MB | 6.79% | 1.40% | 92.89% | 16 | 10 | 3,732,841 | 5,427,696 |
| h2 | (ii-a) builtinadaptive | 374,120 | 859 MB | 5.59% | 0.70% | **98.03%** | 16 | 10 | **1,026,844** | 2,773,440 |
| h2 | **(iii) slab** | 372,590 | 823 MB | **5.54%** | **0.46%** | 92.91% | 16 | 10 | 3,753,605 | 5,489,059 |

"ring-alloc frames" is **not** part of filter B - filter B's allocator regex names only
`AdaptivePoolingAllocator|AdaptiveByteBufAllocator|CycleArenaAllocator|ArenaBuf` and so cannot see a
slab or a `IoUringFixedBufferRingAllocator` frame at all. It is a second count I added over the same
collapsed files, same loop filter, matching the ring-allocator classes; it is reported beside filter
B, never folded into it.

`SLABTELE` for the slab cells (process-wide, 8 loops):

```
h1  instances=8 regionBytes=16777216 slabAcquires=1306518 slabReleases=1306262 slabFallbacks=0 slabForeignReleases=0
h2  instances=8 regionBytes=16777216 slabAcquires=3753605 slabReleases=3753349 slabFallbacks=0 slabForeignReleases=0
```

8 instances = one per worker loop; 16 MiB total (8 x 256 x 8 KiB); `slabAcquires == ringAllocs`, so
**every** buffer the ring received came from a preallocated slot; `acquires - releases = 256` = the
32 buffers per loop still parked in the ring at shutdown; **`slabFallbacks=0`**, so zero allocations
after start-up is measured, not assumed; `slabForeignReleases=0`, so in these two workloads nothing
released a ring buffer off its own loop and the Treiber stack's CAS was never contended.

### 6.2 Lifecycle topology, W1 / W3 / W5

| workload | ring served by | req/s | arena share | blk | maxPin | viol | ringAllocs | ringReads |
|---|---|---|---|---|---|---|---|---|
| W1 | control | 92,746 | - | - | - | - | 380,098 | 1,121,892 |
| W1 | (i) adaptive | 94,082 | 99.22% | 32 | 9 | 0 | 385,579 | 1,138,076 |
| W1 | (ii) builtin | 94,594 | 99.13% | 32 | 8 | 0 | 387,678 | 1,144,274 |
| W1 | (ii-a) builtinadaptive | 94,590 | 99.26% | 32 | 9 | 0 | 271,564 | 1,028,154 |
| W1 | **(iii) slab** | **96,021** | 99.25% | 32 | 8 | 0 | 393,522 | 1,161,529 |
| W3 | control | 12,439 | - | - | - | - | 802,626 | 1,072,042 |
| W3 | (i) adaptive | 17,621 | 94.72% | 8 | 8 | 0 | 1,136,514 | 1,528,921 |
| W3 | (ii) builtin | 17,773 | 94.82% | 8 | 8 | 0 | 1,146,232 | 1,511,527 |
| W3 | (ii-a) builtinadaptive | **19,009** | **98.14%** | 8 | 7 | 0 | 217,237 | 648,903 |
| W3 | (iii) slab | 17,715 | 94.74% | 8 | 8 | 0 | 1,142,550 | 1,535,981 |
| W5 | control | 11,925 | - | - | - | - | 3,055,255 | 4,131,185 |
| W5 | (i) adaptive | 11,888 | 99.47% | 4 | 4 | 0 | 3,046,169 | 4,118,260 |
| W5 | (ii) builtin | 11,954 | 99.47% | 4 | 4 | 0 | 3,062,863 | 4,166,676 |
| W5 | (ii-a) builtinadaptive | 12,237 | **99.93%** | 4 | **0** | 0 | 843,622 | 2,186,825 |
| W5 | (iii) slab | 11,975 | 99.45% | 4 | 4 | 0 | 3,068,667 | 4,341,107 |

`SLABTELE`: W1 `acq=393,522 fallbacks=0`, W3 `acq=1,142,550 fallbacks=0`, W5
`acq=3,064,590 **fallbacks=4,077**` out of 3,068,667 `allocate()` calls (0.13%). **W5 is the one cell
where the fixed slab ran dry** - 256 chunks per loop were not enough headroom for the 256 KiB
aggregator, and 4,077 buffers came from the fallback `UnpooledByteBufAllocator` instead. That is the
failure mode of "not elastic", and the counter is there precisely so it cannot pass unnoticed.

### 6.3 Five lines: what the data favours

1. **On throughput, nothing separates the candidates.** The five configurations span 0.7% on h1
   (126,840-127,572), 1.4% on h2 (370,529-375,775) and 3.5% on W1; one run per cell.
2. **The slab has the lowest allocator CPU in three of the four e2e columns** - filter B 0.93% (h1)
   and 5.54% (h2) against the control's 2.05% / 9.35% - and on h2 the lowest ring-allocator frame
   count too (0.46%). It is also the only candidate that allocates nothing after start-up
   (`slabFallbacks=0` on h1, h2, W1, W3).
3. **(i) and (ii) are indistinguishable, as predicted** (h1 1.49% vs 1.69%, h2 6.31% vs 6.79%, and
   the same arena counters), which is what reading the code said would happen and is not a finding.
4. **(ii-a) wins where the buffer size matters**: on W3 (64 KiB echo) it reaches 98.14% arena share
   and 19,009 req/s on a quarter of the `allocate()` calls, because `AdaptiveCalculator` grows the
   ring buffers towards 64 KiB. Fixed 8 KiB chunks - slab included - cannot do that.
5. **What the data does NOT show:** it does not show the slab is faster (the req/s spread is inside
   the noise of one run), it does not show *why* its filter-B share is lower, it says nothing about
   locality or NUMA (nothing here measured a remote access), and W5's 4,077 fallbacks show the fixed
   sizing is a real constraint that a 20 s h1/h2 run never exercised.

### 6.4 What section 6 does not establish

* One run per cell, one session, no repetitions. Absolute req/s is not comparable with §3, §4 or §5.
* `slabForeignReleases=0` everywhere means the cross-loop path was never taken in W1/W3/W5 or the
  e2e cells - it does **not** mean the slab handles the W6b topology, which was not run here.
* No candidate was run with `IORING_REGISTER_BUFFERS`; netty exposes no binding for it (§4 of the doc).
* `depth=4` was picked before the runs, not tuned; W5 says it is too small for that workload and
  nothing here says what the right value is.

## 7. What holds the blocks that stay pinned on io_uring (measured 2026-09-24, 2300 MHz, node 0)

Section 5.3 left a hole: with no provided buffer ring and zero-copy writes off, 11 blocks were still
pinned on HTTP/1.1 and **"I do not know what holds them"**. This section instruments it.

Code: netty `256c1d86bd`, which adds `-Darena.debugPinned=true`: every arena allocation captures its
own stack (`new Throwable().getStackTrace()`) and the hook generation it was made in, and every
`-Darena.debugPinned.period`-th hook that finds a pinned block walks the space's buffer objects and
charges the block to the allocation stack of the **oldest buffer still live in it**. The result is an
`ARENAPINNED` summary and one `ARENAPINNEDSITE` line per stack. These runs set `period=1` (every
pinned hook) and `-XX:MaxJavaStackTraceDepth=32`.

Twelve cells, all `TRANSPORT=io_uring BUFFER_RING=off`, arena at `-Darena.ring=false`, each cell run
under a shared mutex with the CPU ceiling set and read back inside the lock. Raw data:
`arena-v3/pinned-attr/`; the per-cell provenance (lock owner, `scaling_max_freq` read-back, load and
runnable-count samples) is `arena-v3/pinned-attr/run-provenance.log`, and the wrapper that produced
it is `arena-v3/pinned-attr/cell.sh`. All 13 frequency read-backs say `2300000`.

### 7.1 The instrument is not free, and one cell shows it

One stack capture per allocation. Same cells, instrument off and on:

| cell | req/s off | req/s on | hooks off | hooks on | maxPinnedDirect off | maxPinnedDirect on |
|---|---|---|---|---|---|---|
| e2e h1, zero-copy on | 128,436 | 93,035 | 746,114 | 20,153 | 26 | 25 |
| e2e h1, zero-copy off | 174,372 | 119,232 | 1,101,023 | 19,633 | 14 | **3** |
| W1 topology, zero-copy on | 93,851 | 65,549 | 4,088 | 1,869 | 15 | 6 |
| W1 topology, zero-copy off | 135,190 | 93,574 | 6,574 | 1,919 | 7 | 0 |
| W3 topology, zero-copy on | 20,239 | 3,674 | 10,152 | 1,111 | 8 | 8 |
| W3 topology, zero-copy off | 20,348 | 3,646 | 13,895 | 1,114 | 8 | 8 |

**Read this before reading 7.2.** The instrument costs 28-38% of throughput on h1 and 82% on W3, and
it cuts the hook count by one to two orders of magnitude. `maxPinnedDirect` survives it on the cells
that pin the most (e2e h1 zero-copy on: 26 -> 25; W3: 8 -> 8), so the attribution there is about the
same state the uninstrumented run was in. It does **not** survive on the cells that barely pin at all
(e2e h1 zero-copy off: 14 -> 3; W1 zero-copy off: 7 -> 0): those are rare transients, and slowing the
server down makes them rarer still. So the *rate* of pinned samples is not comparable between the two
columns anywhere - only which stacks the samples land on.

### 7.2 HTTP/1.1: it is the zero-copy write buffers, 99.5% of them

`e2e h1`, 8 loops, 20 s, `BUFFER_RING=off`, `-Darena.debugPinned=true`:

| zero-copy writes | pinnedBlockSamples | unattributed | distinct sites | top site | share |
|---|---|---|---|---|---|
| on (threshold 4096) | 8,682 | 0 | 3 | the outbound copy below | **99.5%** |
| off (`-1`, netty's default) | **3** | 0 | 2 | the same one | 66.7% |

The site that holds 8,640 of the 8,682 samples, `maxAgeHooks=10`, `avgOldestBytes=4368`:

```
AbstractIoUringChannel.newDirectBuffer0 <- AbstractIoUringChannel.newDirectBuffer
  <- AbstractIoUringChannel.filterOutboundMessage <- AbstractIoUringStreamChannel.filterOutboundMessage
  <- AbstractChannel$AbstractUnsafe.write <- DefaultChannelPipeline$HeadContext.write
  <- HttpObjectEncoder.writePromiseCombiner <- HttpObjectEncoder.writeOutList
  <- HttpSnoopServerHandler.writeResponse <- HttpSnoopServerHandler.channelRead0
```

4,368 bytes is the 4 KiB POST body echoed back plus its headers. `filterOutboundMessage` copies every
outbound buffer into a direct one from the **channel allocator**, which is the arena here; at or above
`IO_URING_WRITE_ZERO_COPY_THRESHOLD=4096` that copy goes out as `SEND_ZC` and stays alive until the
kernel's notification, which is a later iteration. The other two sites are the 208-byte response
header (`HttpObjectEncoder.encodeFullHttpMessage`, 21 samples) and the 8,192-byte receive buffer
(`IoUringRecvByteAllocatorHandle.allocate`, 21 samples) - 0.2% each.

**Turning zero-copy off takes the samples from 8,682 to 3.** The same site is still top, so what is
left with zero-copy off is the same outbound copy, merely rarely still live at a hook rather than
routinely. Section 5.3's "11 blocks, I do not know what holds them" is answered: **on HTTP/1.1 they
are outbound write buffers**, and they are a rare transient rather than a steady state once `SEND_ZC`
is out of the picture.

### 7.3 HTTP/2: it is not the zero-copy writes at all

W3 (HTTP/2 echo of a 64 KiB body, 4 KiB client windows), one 8 s window, 4 loops. Zero-copy makes no
difference whatsoever - 972 samples with it on, 974 with it off, the same six sites in the same order:

| share | maxAgeHooks | avgLive in block | avgOldestBytes | top frames |
|---|---|---|---|---|
| 66.9% | 0 | 55 | 9 | `DefaultHttp2FrameWriter.writeData <- FlowControlledData.write <- ... <- Http2ConnectionHandler.flush <- Http2MultiplexHandler.channelReadComplete` |
| 14.7% | 0 | 8 | 124 | `DefaultHttp2FrameWriter.writeHeadersInternal <- ... <- Http2FrameCodec.writeHeadersFrame <- AbstractHttp2StreamChannel.write0` |
| 8.8% | 1 | 13 | 6,560 | `ByteToMessageDecoder.expandCumulation <- ByteToMessageDecoder$1.cumulate <- ... <- AbstractIoUringStreamChannel$IoUringStreamUnsafe.readComplete0` |
| 6.9% | 0 | 54 | 9 | `DefaultHttp2FrameWriter.writeData <- ... <- Http2ConnectionHandler.channelReadComplete <- ...scheduleNextRead` |
| 2.3% | 0 | 63 | 13 | `DefaultHttp2FrameWriter.writeWindowUpdate <- ... <- AbstractHttp2StreamChannel$Http2ChannelUnsafe.beginRead` |
| 0.4% | 0 | 2 | 21 | `DefaultHttp2FrameWriter.writeSettings <- ... <- TopoServer$3.initChannel` |

Two things this says that the h1 answer does not:

1. **The bytes are tiny and the count is large.** The oldest live buffer in a pinned block is a
   **9-byte** HTTP/2 DATA frame header in 74% of the samples, with 51-63 other live buffers in the
   same block. This is the shape section 2's design notes called W4's case - "one 8-byte parked write
   can pin a block" - except here it is the frame writer's own headers during one flush.
2. **`maxAgeHooks=0` on every site but the cumulator.** The block is pinned *at the hook that observed
   it* and is free again shortly after; it is not held across iterations. `-Darena.cap=8192` cannot
   filter a 9-byte buffer, and neither can any size cap.

The one site that does cross an iteration is `ByteToMessageDecoder.expandCumulation` at 6,560 bytes
and `maxAgeHooks=1` - class A, the cumulator, exactly as section 1 measured on NIO.

### 7.4 Keeping those buffers out of the arena: it fixes the pinning and buys no throughput

If the h1 pinning is the outbound copy, then keeping that copy out of the arena should remove it.
The design's answer would be a consumer hint ("this buffer is destined for a zero-copy write, do not
arena it"), which does not exist. The only lever this build already has is the size cap: the copy is
4,368 bytes, so `-Darena.cap=4096` sends it to the delegate. Same cell as 7.2, zero-copy ON, no
instrument, one run:

| cell | req/s | arena share | blocksDirect | maxPinnedDirect |
|---|---|---|---|---|
| `cap=8192` (default) | 128,436 | 99.78% | 64 | **26** |
| `cap=4096` | 127,971 | 33.33% | 11 | **8** |
| `cap=8192`, zero-copy OFF | 174,372 | 99.61% | 64 | 14 |

**CONFOUND, and it is a large one:** 4,096 is below the 8,192-byte receive buffer as well, so the cap
pushes the reads to the delegate too - which is why the arena share falls to 33.33%. This is not a
clean test of "delegate the zero-copy write buffers"; it is the closest knob that exists.

What it does show, and what matters for the design: **taking those buffers out of the arena removes
two thirds of the pinning (26 -> 8) and moves throughput by -0.4%, while turning zero-copy off moves
it by +36%.** So the +37% of section 5.3 is not the arena's pinning being relieved - the pinning and
the throughput are separate effects, and a hint that delegated zero-copy write buffers would buy the
first and not the second. No claim is made here about what `SEND_ZC` itself costs on this workload;
that was not measured.

### 7.5 What section 7 does not establish

* One run per cell, one 20 s e2e run and one 8 s topology window each; no repetitions.
* The instrumented and uninstrumented columns of 7.1 are **not** comparable on throughput or on the
  number of pinned samples, only on which stacks those samples land on. On the two cells that barely
  pin, the instrument reduced the pinning it was meant to observe.
* The attribution charges a block to its OLDEST live buffer only. A block held by fifty buffers from
  fifty sites is charged to one of them; the `avgLiveInBlock` column is the only hint of that, and it
  is an average, not a distribution.
* Nothing here measured allocator CPU share, RSS or latency on these cells.
* `maxAgeHooks=0` means the oldest live buffer was allocated in the iteration the hook closed. It does
  not say how much longer it lived after that hook.
* 7.4 is one run per cell and its cap knob is confounded, as stated there. Nothing here measured what
  `SEND_ZC` costs or why turning it off is worth +36% on this 4 KiB-body workload.

## 8. The provided-buffer-ring allocator, iterated (measured 2026-09-25/26, 2300 MHz, node 0)

Section 6 compared five ring allocators for one run each and concluded "nothing separates the
candidates on throughput". This section asks the next question - **what is the right allocator for
the provided buffer ring, and how close to its floor is it?** - with a microbenchmark of the ring
allocator alone, seven candidates, the counters each one needs to be judged on, and two changes to
netty itself.

**Configuration, identical in every cell:** channel allocator **adaptive**, `TRANSPORT=io_uring`,
`BUFFER_RING=on`, **zero-copy writes OFF** (`-Diouring.zeroCopyThreshold=-1`, netty's own default;
the threshold-4096 configuration is a separate bug, netty/netty#17632), 8 loops for e2e and 4 for
topology, logging off. The only variable is `BUFFER_RING_ALLOC`. Code: netty `d04ac1f4ec`
(`expt/event-loop-arena`), PoC `lib/java/SlabV2BufferRingAllocator.java`. Every cell ran under a
shared mutex with the CPU ceiling set and **read back** inside the lock and the runnable count
sampled six times; raw data and the per-cell provenance are in
`arena-v3/ring-alloc/{e2e,topology,micro,variants,sizepolicy,w5rss}/run-provenance.log`. All
frequency read-backs say `2300000`; the ceiling was restored to `4300000` at the end.

### 8.0 The candidates

| id | `BUFFER_RING_ALLOC` | what it is |
|---|---|---|
| R0 | `adaptive` | one `AdaptiveByteBufAllocator.directBuffer(8192)` per re-add - today's practical default |
| R1 | `builtinadaptive` | netty's `IoUringAdaptiveBufferRingAllocator` (adaptive SIZE, general allocator behind it) |
| R2 | `slab` | slab v1 as section 6 measured it: one direct region per loop, Treiber stack over the wrappers |
| - | `slab2fixed` | v2 with a FIXED slot: isolates v2's structure and telemetry from its size policy |
| R3 | `slab2` | v2 = fixed population + slot size from netty's `AdaptiveCalculator`, re-provisioned rarely |
| - | `slab3fixed` | v3 with a FIXED slot - **the recommendation, see 8.6** |
| R4 | `slab3` | v3 = R3 + owner-thread plain `int` free stack, foreign releases through an MPSC hand-back |
| R5 | `slab3huge` | R4 with the region 2 MiB-aligned (folly's shape), so a THP *can* back it |
| R6 | `arena`, `arenaring` | `CycleArenaAllocator` as the RING's allocator, `-Darena.ring=false` and `=true` |

### 8.1 The microbenchmark: the ring allocator alone (3 forks, perfnorm, 2300 MHz)

One op is one buffer's whole trip through the ring, which is what step 7 of the lifecycle costs:
`allocate()` -> the address and length `add()` writes into the slot -> `lastBytesRead` ->
`retainedSlice` -> the ring's `release()` -> the pipeline's `release()`.
`inFlight=32` is netty's default batch for a 64-entry ring; `inFlight=1` is the flattering shape
where a free list always hits the same slot. `bench/RingAllocBench.java`, raw data
`arena-v3/ring-alloc/micro/owner.json`.

| ring allocator | ns/op | +-99.9% | insns/op | cycles/op | L1d misses/op | ns/op no slice | insns/op no slice |
|---|---|---|---|---|---|---|---|
| R0 `adaptive` | 148.19 | 1.43 | 1495.9 | 337.7 | 6.31 | 138.94 | 1318.9 |
| R1 `builtinadaptive` | 150.27 | 3.51 | 1482.2 | 342.3 | 6.48 | 138.25 | 1305.5 |
| R2 `slab` (v1) | 47.44 | 1.91 | 405.0 | 109.0 | 0.78 | 33.76 | 245.3 |
| `slab2fixed` | 48.17 | 0.24 | 457.8 | 110.6 | 0.74 | 31.13 | 300.4 |
| R3 `slab2` | 52.79 | 0.99 | 521.8 | 120.9 | 0.81 | 35.82 | 366.5 |
| **`slab3fixed`** | **40.44** | 2.85 | **382.0** | **92.7** | 0.88 | **23.00** | **232.3** |
| R4 `slab3` | 44.65 | 0.65 | 453.6 | 102.7 | 0.74 | 26.17 | 293.9 |

Four things this says, each of which is a number and not an opinion:

1. **A slab is 3-4x cheaper per buffer than any general-purpose allocator behind the ring.**
   `slab3fixed` 40.44 ns / 382.0 insns against `adaptive` 148.19 ns / 1495.9 insns, and **8x fewer
   L1d misses** (0.88 against 6.31).
2. **R1 is R0.** 150.27 vs 148.19 ns, 1482.2 vs 1495.9 insns - the same code path
   (`AbstractIoUringBufferRingAllocator.allocate()` is `allocator.directBuffer(nextBufferSize())`)
   over two adaptive instances. Confirmation, not a finding; section 6 predicted it too.
3. **The owner-thread `int` stack is worth 7.7 ns / 76 insns over the Treiber CAS**, at an identical
   feature set: `slab3fixed` 40.44/382.0 against `slab2fixed` 48.17/457.8. That is the R4 idea and it
   holds.
4. **The adaptive slot size costs 4.2 ns / 71 insns** and buys nothing (8.4):
   `slab3fixed` 40.44 -> `slab3` 44.65, `slab2fixed` 48.17 -> `slab2` 52.79.

**The floor.** `ownerCycleNoSlice` repeats the op with netty's `noSliceHandoff` shape (8.3): no
`retainedSlice`, no retain/release pair. The slice costs **150-177 instructions and 9-18 ns for every
candidate** - 17.4 ns of `slab3fixed`'s 40.44, i.e. **43% of the best candidate's per-op cost is a
cost no choice of allocator can remove.** The remaining 23.0 ns / 232.3 insns is the pop, the push,
the refCnt arm and the two field reads `add()` needs. A repeat run of the no-slice cells
(`micro/noslice.json`) reproduces them within 1.3% (adaptive 137.21 vs 138.94, slab 33.76 vs 33.76,
slab3 26.04 vs 26.17), so the microbenchmark is stable at the resolution these differences need.

### 8.2 The foreign-release path (3 forks, perfnorm)

Requirement 4 of [`uring-registered-buffers.md`](../../docs/uring-registered-buffers.md):
`allocate()` is always on the loop, `release()` is not. `cycleForeignRelease` allocates on the JMH
thread and hands buffer and slice to a second thread through a minimal SPSC queue; `handoffOnly` is
the same queue with the same `Object[2]` carrier and no allocator, so the queue is not charged to the
allocator. Raw data `micro/foreign.json`.

| ring allocator | pair ns/op | +-99.9% | insns/op (process) | stalled frontend cycles/op |
|---|---|---|---|---|
| R0 `adaptive` | 264.6 | 7.0 | 1279.1 | 82 |
| R1 `builtinadaptive` | 256.7 | 8.0 | 1230.3 | 81 |
| R2 `slab` (v1, Treiber) | **301.7** | 38.3 | 580.2 | **154** |
| R3 `slab2` (Treiber) | 271.3 | 14.8 | 661.0 | 110 |
| R4 `slab3` (loop-local + hand-back) | **171.4** | 21.7 | 585.5 | **66** |
| control `handoffOnly` | 26.4-33.4 | 16-32 | 135.9-140.4 | - |

**This is the cell where R4 stops being a micro-optimisation.** With every release coming from a
foreign thread, slab v1's CAS-per-release Treiber stack is **slower than adaptive** (301.7 against
264.6 ns) despite using 2.2x fewer instructions, and its stalled-frontend count doubles (154 against
82): the owner's `pop` CAS and the releaser's `push` CAS contend on the same head word. R4, whose
owner path never touches that word (it detaches the whole hand-back list in one `getAndSet`), is the
fastest of all at 171.4 ns with the *lowest* stall count. The five `handoffOnly` estimates agree with
each other (26.4-33.4 ns), so the queue is not what separates the rows.

**What this cell does NOT measure.** The producer blocks on a full queue, so the ns column is the
*pair's* throughput, not the loop's own cost, and the instruction counts are process-wide (they
include the releaser thread). The cost of one cross-thread release *in isolation* was not isolated by
this design, and the error bars (+-38, +-22) are large. The direction is supported by three
independent columns; the magnitude is not established.

### 8.3 Two questions asked of netty itself

netty `d04ac1f4ec` adds two opt-in instruments to `IoUringBufferRing` (both `static final`, so they
fold away when off).

**(a) Can the ring reuse the retiring buffer object instead of calling `allocate()`?** No, and this is
now measured rather than reasoned. `-Dio.netty.iouring.bufferRing.refCntTele=true` records `refCnt()`
at the moment the ring drops its own reference:

```
h1  retireRefCnt=1:0,2:343868,3:0,...   slices=1015382
h2  retireRefCnt=1:0,2:764111,3:0,...   slices=975548
```

**The count is 2 in 100.0% of 343,868 (h1) and 764,111 (h2) retirements and never 1.** It cannot be
1: the `retainedSlice` that `useBuffer` is about to return to the caller is itself the second
reference. So the ring is never the last holder at step 6/7, and the only place where "the kernel and
the pipeline are both finished" is observable is the buffer's own `deallocate()` - which is exactly
what a recycling allocator is. **The slab is not an alternative to reusing the retiring buffer; it is
the only way to do it.** (The same lines also say that 1,015,382 - 343,868 = 671,514 of h1's reads,
66%, are incremental continuations where the bid stays in the ring.)

**(b) What does the slice cost end to end?** `-Dio.netty.iouring.bufferRing.noSliceHandoff=true`
makes `useBuffer` hand the retiring buffer itself to the pipeline, transferring the ring's reference:
one `UnpooledSlicedByteBuf` and one retain/release pair fewer per retiring read. It is correct - 0
failed, 0 errored, all 2xx on h1 and h2 - and it is worth nothing measurable:

| cell | handoffs / total reads | req/s with handoff | req/s baseline | delta |
|---|---|---|---|---|
| h1 `adaptive` | 340,487 / 1,005,406 (34%) | 172,684 | 172,902 | -0.1% |
| h1 `slab3` | 341,242 / 1,007,630 (34%) | 173,405 | 173,538 | -0.1% |
| h2 `adaptive` | 3,766,336 / 5,455,254 (69%) | 373,879 | 372,240 | +0.4% |
| h2 `slab3` | 3,792,018 / 5,465,206 (69%) | 376,428 | 374,692 | +0.5% |

Removing 3.8 million object allocations and refcount pairs over 20 s moves h2 by +0.5%, inside the
band. The microbenchmark says the slice is 43% of the best allocator's per-op cost (8.1); the server
says that per-op cost is not where the server's time goes (8.5). Both are true and the second one
decides.

### 8.4 End to end, 20 s per cell, one run per cell, 8 loops

`B` is `tools/asprof-alloc-share.py`'s narrow filter (the general allocator on an IO loop);
`C ring-alloc` and `D ring-total` are the two filters added for this section - C matches the ring
allocator's own classes, D adds `IoUringBufferRing`, the slice classes and the general allocator.
**Read 8.5 before reading column C.**

| proto | ring served by | req/s | mean lat | RSS max | B | C | D | ringAllocs |
|---|---|---|---|---|---|---|---|---|
| h1 | R0 `adaptive` | 172,902 | 48us | 843 MB | 2.42% | 0.39% | 2.71% | 1,770,654 |
| h1 | R1 `builtinadaptive` | 173,469 | 48us | 852 MB | 2.40% | 0.39% | 2.71% | 1,209,166 |
| h1 | R2 `slab` | 172,973 | 53us | 848 MB | 1.77% | 0.00% | 2.15% | 1,771,390 |
| h1 | `slab2fixed` | 172,513 | 51us | 842 MB | 2.11% | 0.00% | 2.37% | 1,766,669 |
| h1 | R3 `slab2` | 173,262 | 57us | 845 MB | 1.71% | 0.07% | 2.34% | 1,774,352 |
| h1 | **`slab3fixed`** | 173,065 | 50us | 848 MB | 1.75% | 0.00% | **2.11%** | 1,772,331 |
| h1 | R4 `slab3` | **173,538** | 55us | 845 MB | 1.74% | 0.08% | 2.15% | 1,777,166 |
| h1 | R5 `slab3huge` | 173,088 | 59us | 863 MB | **1.59%** | 0.08% | 2.21% | 1,772,563 |
| h1 | R6 `arena` ring=false | 172,110 | 53us | 861 MB | 3.51% | 0.23% | **3.71%** | 1,762,552 |
| h1 | R6 `arena` ring=true | 173,026 | 58us | 856 MB | 3.72% | 0.34% | 3.77% | 1,771,927 |
| h2 | R0 `adaptive` | 372,240 | 516us | 865 MB | 9.72% | 0.86% | 11.47% | 3,750,070 |
| h2 | R1 `builtinadaptive` | 370,644 | 507us | 901 MB | 7.66% | 0.34% | 9.50% | 1,021,422 |
| h2 | R2 `slab` | **374,606** | 486us | 862 MB | 7.89% | 0.00% | 10.44% | 3,773,920 |
| h2 | `slab2fixed` | 373,716 | 495us | 865 MB | 8.21% | 0.08% | 11.70% | 3,764,948 |
| h2 | R3 `slab2` | 373,875 | 518us | 853 MB | 7.43% | 0.84% | 10.97% | 3,766,552 |
| h2 | **`slab3fixed`** | 373,950 | 493us | 860 MB | **6.25%** | 1.22% | **9.77%** | 3,767,301 |
| h2 | R4 `slab3` | **374,692** | 529us | 851 MB | 7.76% | 0.99% | 12.06% | 3,774,784 |
| h2 | R5 `slab3huge` | 372,791 | 569us | 857 MB | 7.56% | 0.18% | 11.12% | 3,755,631 |
| h2 | R6 `arena` ring=false | 372,150 | 510us | 917 MB | 10.39% | 0.16% | 12.01% | 3,749,180 |
| h2 | R6 `arena` ring=true | 373,115 | 553us | 897 MB | 9.96% | 0.30% | 11.63% | 3,758,888 |

**Throughput separates nothing**: 0.8% across ten configurations on h1 (172,110-173,538) and 1.1% on
h2 (370,644-374,692), one run per cell. What does move is allocator CPU: on h1 the slabs sit at
**2.11-2.37%** of loop samples (filter D) against adaptive's **2.71%** and the arena's **3.71-3.77%**.
On h2 the D column spans 9.50-12.06% and does *not* rank the slab variants consistently
(`slab3fixed` 9.77% but `slab3` 12.06%, `slab2fixed` 11.70% but `slab` 10.44%): with ~70,000 loop
samples per cell a 1 pp difference is ~700 samples and one run cannot resolve it. **The h1 D column
is the only e2e ranking this section claims.**

**R5 is dropped.** `aligned=true` is confirmed in the counters, and `THPTELE` says
`anonHugePagesKb=0 vmasWithThp=0 thpEnabled=always [madvise] never` in **every** cell. This box is in
`madvise` mode and Java cannot call `madvise(MADV_HUGEPAGE)` - `transport-native-io_uring` exposes no
binding for it and `java.lang.foreign` is preview on JDK 21. So the alignment is real and the huge
page is not, the instruction says keep R5 only if `AnonHugePages` shows it, and it does not. Its
numbers (h1 D 2.21%, h2 D 11.12%) are within the band of the unaligned R4 either way.

### 8.5 Where the ring allocator's cycles actually go

`tools/asprof-loop-breakdown.py` over the same h1 profiles, with the two ring rules added ahead of
the general-allocator rule, so a sample inside adaptive reached *from* the ring is charged to the ring:

| category | R0 `adaptive` | `slab3fixed` | R6 `arena` |
|---|---|---|---|
| socket write (syscall incl.) | **40.8%** | **40.9%** | **40.3%** |
| loop other (pipeline, channel, tasks) | 33.7% | 34.5% | 33.6% |
| http1 codec | 9.4% | 9.0% | 9.1% |
| io_uring enter (submit/wait) | 7.9% | 7.9% | 8.0% |
| socket read (syscall incl.) | 5.5% | 5.6% | 5.3% |
| general allocator | 2.1% | **1.7%** | **3.3%** |
| **ring allocator (own code)** | **0.4%** | **0.0%** | 0.2% |
| ring machinery + slice | 0.2% | 0.4% | 0.2% |

**The whole provided-buffer-ring allocation path is 0.4-0.6% of event-loop CPU.** Its top leaves are
`AbstractIoUringBufferRingAllocator.allocate` (121 samples) and `RefCnt$UnsafeRefCnt.isLiveNonVolatile`
(238 for the slab). For scale, in the same profiles `ByteBufUtil.unsafeWriteUtf8` is 10,806 samples
(12.8% of loop CPU on its own), `ByteBufUtil.utf8ByteCount` 6,318, and `nft_do_chain [nf_tables]` -
this box's firewall, in the send path - 2,434 (2.9%). **That is why the microbenchmark's 3.7x is
worth 0.6 pp of loop CPU and 0% of throughput**, and it is the answer to "is it at the floor":
`slab3fixed` contributes 0.0% of its own frames plus 0.4 pp of ring machinery, and the 1.7% general
allocator line is the *channels*, which this section does not change.

**Column C is an inlining detector, not a cost metric, and this corrects section 6.2's reading of it.**
Counting the actual frames in the h1 collapsed files:

```
adaptive     73 CountingRingAllocator.allocate   73 IoUringBufferRingAllocator.allocate   84 IoUringBufferRing.useBuffer
slab          0 (its own classes)                                                          6 IoUringBufferRing.useBuffer
slab3fixed    0 (its own classes)                                                          6 IoUringBufferRing.useBuffer
slab3         9 SlabV2BufferRingAllocator.allocate   18 CountingRingAllocator.allocate    81 IoUringBufferRing.useBuffer
```

`slab` and `slab3fixed` have **zero** samples in their own classes: their `allocate()` inlines
completely into `IoUringBufferRing`, so filter C cannot see them and reports 0.00%. `slab3`, whose
`allocate()` also carries the slot-size check, did **not** fully inline and so scores *higher* in C
(0.08% h1, 0.99% h2) while being *cheaper* than adaptive in the microbenchmark. Section 6.2 read the
slab's low "ring-alloc frame count" as a cost result; part of it was inlining. Filter D, whose regex
always matches `IoUringBufferRing` itself, does not have this failure mode and is the column to use.

**Predicted against measured.** 1,770,654 allocate() calls x 148.19 ns = 262 ms against 84.2 s of
loop CPU = **0.31% predicted** for adaptive, **0.39% measured** (filter C). For `slab3fixed`,
1,772,331 x 40.44 ns = 71.7 ms / 83.5 s = **0.086% predicted**, and 0.00% measured because the frames
are inlined away. The microbenchmark and the profile agree where the profile can see the frames, and
the slab is at the floor the microbenchmark implies.

### 8.6 The slot size: an iteration that failed, then one that fired, then a decision

**Iteration 1, and the bug it found.** R3's stated rule was "re-provision only on exhaustion, or when
the estimate moves by 2x". Measured on e2e h1 at 4 loops: **14,960 re-provisions in 37,357 buffers,
RSS 10.9 GB, 22,970 req/s against 132,211 for the baseline.** The rule is unusable against
`AdaptiveCalculator`, which steps its index by +4 on a full read and -1 on two small ones over a table
that doubles above 512 bytes - one step up is 16x and one step down is 2x, so "2x away" is true almost
always and each firing allocated and abandoned a multi-MiB region. Fix: a warm-up, a minimum gap, a
hard cap, and *persistence* (N consecutive allocations must want the same 2x-away size). RSS returned
to 791 MB and 135,396 req/s, with `reprovSize=0`.

**Iteration 2: persistence never fires, and the counters say why.** New telemetry on W3 (64 KiB
HTTP/2 echo), the workload where the size should matter:

```
wantAway=582442 wantNear=140375 wantMin=4096 wantMax=65536 longestRun=2
```

80.6% of samples want a size at least 2x away, over a 4 KiB..64 KiB range, and **the longest run of
the same away value is 2** against the 1024 the rule needs. The mechanism is that the feedback is
self-referential: the slab's slot stays 8192, so a "full read" is always 8192, which the calculator
reads as "shrink one step" and then "grow four steps", forever. It converges for
`IoUringAdaptiveBufferRingAllocator` only because *there* the estimate becomes the very next buffer's
size.

**Iteration 3: a windowed rate, which does fire.** Over a window of 1024 samples, re-provision if the
majority were 2x away, growth first. On W3 it does exactly what it should: `reprovSize=4` (one per
loop), slot 8 KiB -> 64 KiB, and `allocate()` calls drop from 905,766 to **344,653** - 2.6x fewer, the
effect section 6.2 credited to `builtinadaptive`.

**And it loses.** The e2e regression cells, same build, one knob apart:

| cell | fixed slot | windowed rate | delta | re-provisions | region |
|---|---|---|---|---|---|
| h1 `slab2` | 173,262 | 172,697 | -0.3% | 15 | 16 MB -> 63 MB |
| h1 `slab3` | 173,538 | 172,640 | -0.5% | 18 | 16 MB -> 54 MB |
| h2 `slab2` | 373,875 | 371,518 | -0.6% | 8 | 16 MB -> 134 MB |
| h2 `slab3` | 374,692 | 371,177 | -0.9% | 8 | 16 MB -> 134 MB |

0.3-0.9% slower for 3-8x the region, and on h1 it never settles (15-18 re-provisions in 20 s, slots
ending at a mixture of 16/32/64 KiB across the eight loops - a milder version of the original bug).
W3 cannot arbitrate: its spread across *nominally identical* designs is 13,036-15,442 req/s (18%),
and the two policies disagree in direction on the two variants (slab2 13,837 rate vs 14,040 run;
slab3 15,798 vs 13,119). **Decision: the slot size is fixed.** `slab3fixed` is the recommendation and
the adaptive-slot path stays behind `-Diouring.slabSizePolicy` as measured, not as a default.

### 8.7 Lifecycle topology W1 / W3 / W5, and the failure mode that is real

| workload | ring served by | req/s | ringAllocs | fallbacks | exhaustions | growths | final slots | maxInFlight |
|---|---|---|---|---|---|---|---|---|
| W1 | R0 `adaptive` | 134,761 | 552,230 | - | - | - | - | - |
| W1 | R2 `slab` | 131,524 | 538,971 | 0 | - | - | 256x8192 | - |
| W1 | R4 `slab3` | 132,036 | 541,067 | 0 | 0 | 0 | 256x8192 | 34 |
| W1 | R6 `arena` ring=false | **124,829** | 511,544 | - | - | - | - | - |
| W1 | R6 `arena` ring=true | 127,419 | 522,150 | - | - | - | - | - |
| W5 | R0 `adaptive` | 12,259 | 3,141,040 | - | - | - | - | - |
| W5 | R2 `slab` (v1) | 11,998 | 3,074,222 | **2,145** | - | - | 256x8192 | - |
| W5 | R4 `slab3` | 11,955 | 3,063,238 | **0** | 4 | 4 | **512x8192** | **377** |
| W5 | `slab3fixed` | 12,080 | 3,095,162 | **0** | 4 | 4 | 512x8192 | 384 |

**W5 is where "not elastic" actually costs something, and one bounded growth step fixes it.** Section
6.2 found slab v1 taking 4,077 fallback allocations on this workload and said `depth=4` "was picked
before the run rather than tuned". The counters now say what the right value is and why: **maxInFlight
is 377-384 against 256 slots** - the 256 KiB aggregator holds more ring buffers in flight than the
slab has - so v1 *must* run dry (2,145 fallbacks reproduced), and v2/v3's single doubling to 512 slots
takes it to **0 fallbacks with 4 exhaustions and 4 growths**, reproducibly (r1 377, r2 377, r3 384).
Throughput does not change (11,921-12,259 across every W5 cell).

The in-flight histograms say *why* W5 is different from h1, on the same instrument:

```
h1  occupancy[0-25%:1778923, ...]                    lifeSeq[<1ring:1778667, <8ring:0, <64ring:0]
W5  occupancy[0-25%:2959436, 25-50%:98965, 50-75%:4325, 75-100%:508, full:4]
                                                     lifeSeq[<1ring:0, <8ring:3062161, <64ring:821]
```

On h1 **every** slot returns within one ring's worth of acquires; on W5 **none** does - all 3.06
million take between one and eight - and the slab reaches full occupancy exactly 4 times, which is the
4 exhaustions. `drains=4` with `foreignReleases=0` in every cell: the owner's hand-back drain ran only
on those 4 exhaustions, so the loop-local path never took an atomic in any workload measured here.

**RSS on W5, 4 runs each** (`w5rss/`), because the first single-run pair suggested a 35% reduction and
that was not reproducible:

| ring served by | RSS at shutdown (kB), 4 runs | mean | spread |
|---|---|---|---|
| R0 `adaptive` | 782,064 / 837,692 / 984,416 / 1,143,636 | 936,952 | **46%** |
| `slab3fixed` | 737,504 / 740,320 / 746,036 / 752,500 | 744,090 | **2%** |

The slab is lower in 4 of 4 samples and the *lowest* adaptive run (782,064) still exceeds the
*highest* slab run (752,500) - but the honest statement is about variance, not a fixed saving: a fixed
region has a fixed footprint, and the difference in the means is 193 MB (-21%) with adaptive spanning
782-1144 MB run to run. **Where adaptive's extra 193-400 MB lives was not established** - it is far
more than the ring's own working set (512 x 8 KiB x 4 loops = 16 MiB) and nothing here attributed it.

**R6, the arena as the ring's allocator, is the worst candidate in every column that moves.** On W1 it
is 124,829-127,419 req/s against 131,524-135,194 for the slabs and 134,761 for adaptive - **5-7%
slower** - and on e2e h1 its filter-D share is 3.71-3.77% against the slabs' 2.11-2.37%. The
`ARENATELE` counters say why: on W1 `arenaShare=77.94%` with `delegateDirect=112,863` of 511,544 ring
buffers falling through to adaptive, `maxPinnedDirect=8` of 8 blocks, `blockSwitches=12,554`; on W3
`arenaShare=79.95%`, `maxPinnedDirect=8`. A provided-ring buffer is kernel-owned for an unbounded
number of iterations, so every block holding one is pinned at the hook, the space hits its 8-block
bound, and a fifth of the ring's buffers are served by the allocator the arena was supposed to
replace - while the loop-breakdown's general-allocator line rises from 2.1% to 3.3%.
**"Maybe it is still an arena" is answered: no.**

### 8.8 What section 8 does not establish

* **One run per cell** in 8.4 and 8.7 (the exceptions are the 4-run W5 RSS pairs and the 3-fork
  microbenchmarks). The h2 filter-D column does not rank the slab variants and is not read as doing so.
* **W3 is not usable for the size question** - 18% spread across nominally identical designs.
* **The cross-thread release cost is not isolated** (8.2): the benchmark measures a producer/consumer
  pair, and `foreignReleases=0` in every server cell, so the path that separates R2 from R4 in the
  microbenchmark was never *taken* in any e2e or topology workload here. W6b, the cross-loop proxy that
  would take it, was not run in this section.
* **No NUMA or locality measurement.** "One region per loop, first-touched by its loop" is the design;
  nothing here measured a remote access.
* **R5's huge pages were never obtained**, so whether a THP-backed region would move anything is
  unknown, not answered.
* **Where adaptive's extra W5 RSS lives** is unattributed (8.7).
* The `slab3huge` region is reported as 33.5 MB against `slab3`'s 16.8 MB because the 2 MiB
  over-allocation is counted; the usable body is the same 16.8 MB.

## Appendix A. The earlier builds (v2) - NOT the pinned code

These sections measure netty `dec589d0eb` (A.1-A.4) and the PoC build `26bd14b195` (A.2b, A.5), on
the same reference machine. **v3 is a rewrite, not a tuning of them**: `arena.release`, `arena.hook`,
`arena.retainBytes`, `arena.initialBlock`, `arena.maxBlock`, `arena.objects`, `endOfCycle()` and
`CycleArenaEndOfCycleHandler` do not exist at the pinned commit. Nothing here is a statement about
the pinned code. They are kept because they are the only measurements those builds will ever have.

### A.1 CycleScopedAllocBenchmark - the scope-aligned case

Allocate k buffers, write a byte into each, read a byte back, release all k. Heap buffers, one
event-loop thread. `ns/buf` is the JMH score divided by k; nothing else is computed.
Data: `cycle/cycle-heap.json`.

| allocator | ns per buffer (over k 8/64, FIFO/LIFO, MIXED/SMALL) |
|---|---|
| ARENA | 25.2 - 27.5 |
| ADAPTIVE | 44.3 - 50.9 |
| MIMALLOC | 46.6 - 52.6 |

ARENA is 40-50% below ADAPTIVE on every one of the 8 cells (k 8/64 x FIFO/LIFO x MIXED/SMALL;
`cycle/cycle-heap.json` holds 24 rows = 8 cells x 3 allocators). Adaptive is ahead of the mimalloc port
here. Full per-cell table: `../../summarize.py cycle/cycle-heap.json`.

### A.2 ByteBufAllocatorAllocPatternBenchmark - the steady-state case

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
  +8..34% (first-fork peaks: +30.8% / +8.3% / +19.5% / +34.4% down the table). Arena share at 4 blocks on these cells: 58% (1024) / 19% (4096) - from
  `diag/tele-arena2-1024.data` (`arena=83860117 fallback=61512762`) and `diag/tele-arena2-4096.data`
  (`arena=20499714 fallback=89222495`); the `harness-t1-*-ARENA` runs predate the counter teardown
  and carry no `ARENATELE` line.
- **With the bound above the live set** (8 blocks) the counters show effectively everything served
  by the arena (`harness/harness-t1-1024-ARENA8.data`: `arena=501300300 fallback=0
  blockReuse=1179648` -> one block recycled every ~425 allocations; at 4096, `fallback=1065` out of
  400M) and the LIFO pop essentially never firing (`lifoPop=5..27`). Then it is -50% against
  adaptive where the core is the bottleneck (1 thread) and -6..-10% in the memory-bound 32-thread
  regime.

**CAVEAT that limits all of section A.2:** this harness gives every buffer the same lifetime (N ops,
a ring of slots), so blocks drain deterministically. Variable lifetimes with long-lived pinning -
the real case - are not covered here. That is what sections A.3 and A.4 are for.

#### A.2b The heap + direct build (`26bd14b195`)

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

Evidence: **`micro-v2/`**. Read `micro-v2/INDEX.md` first - it states the gap itself. **There is no
JMH json or .data for these five cells:** the runs were made without `-rf json`, so
`micro-v2/quoted-scores.txt` is a *transcription of the console summary lines*, not a
machine-written artifact. Treat it as such. The perfasm captures behind the card-mark finding are
real files: `perfasm-new-v1-cardmarks.txt` (G1 barriers on `putfield reserved` in
`Space::reserve` and `putfield root` in `ArenaBuf::moveTo`, hottest region 24.69%),
`perfasm-new-v2-after-barrier-fix.txt` (barriers gone), `perfasm-old-control.txt`
(the heap-only PoC). Their own `Result` lines are **48.510 / 47.591 / 40.991 ns/op** - a perfasm run
is not a clean score, and the 47.2 / 45.6 / 40.5 quoted in the report come from the regression-walk
lines of `quoted-scores.txt`, not from these three files. All three with `-prof perfasm:event=cycles`, never `cycles:P` on
this AMD box. The refuted klass-guard hypothesis is the `monomorphic root` line of
`quoted-scores.txt`: 48.341 +- 2.861, no recovery.

### A.3 Geometric lifetimes (`-Dexpt.randomRelease=true`)

Release a uniformly random live slot instead of the next one in the ring: same mean lifetime,
geometric distribution. 1 thread, 3 forks, E_COMMERCE heap. Data: `rand/`.

**These runs use `-Darena.maxBlocks=8`** (the VM options line in each `.data` says so), i.e. the
same 8-block arena that wins section A.2. The comparison that matters is therefore the ARENA column
here against the ARENA8 column above: 40.6 -> 82.7 and 49.8 -> 122.1 for changing nothing but the
lifetime distribution.

| live | ADAPTIVE | MIMALLOC | ARENA (8 blocks) | arena share | peak RSS vs adaptive |
|---|---|---|---|---|---|
| 1024 | 83.1 ns | 68.6 ns | 82.7 ns | 77% | 1210-1223 vs 1071-1073 MB (+13..14%) |
| 4096 | 106.5 ns | 77.2 ns | 122.1 ns | 22% | 1225-1227 vs 1084-1091 MB (+13%) |

At 4096 the block reuses collapse from 538K (`harness/harness-t1-4096-ARENA8.data`) to 46K
(`rand/rand-t1-4096-ARENA.data`). A few long-lived buffers per block pin it and the bound fills
with mostly-dead blocks. The LIFO pop, silent in section A.2, now fires 103K-108K times: releases
stop arriving in stack order.

**CAVEAT on these two cells specifically:** Chrome was using about 66% of one CPU during this run.
The comparison is between allocators measured in the same conditions, but the absolute levels are
not clean.

### A.4 Real lifetimes from JFR - the gate

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

### A.5 End to end - the allocator is not visible

`run-e2e.sh`: the same netty example pipelines behind `E2EServer`, one allocator per run, 8 event
loops, `-Xms2g`, driven by h2load for 20 s.

Evidence: **`e2e-v2/`** - `INDEX.md` maps every table row to a `runs/<tag>/` directory holding
`h2load.txt`, `server.log` (the READY line and the `ARENATELE` counters from the shutdown hook),
`rss.txt` (VmRSS in KiB every 0.5 s) and `gc.log`. `e2e-v2/harness/` has the exact `E2EServer.java`
that was run, `logback-quiet.xml`, the driver `run.sh` and `cp.txt` (the exact classpath).

**What limits this section:**

1. **The frequency was NOT fixed** - these runs were at 4300 MHz, not the 2300 MHz of the other
   sections. Do not compare their absolute levels with anything above.
2. The server ran on node 0 (`numactl --cpunodebind=0 --membind=0`, `-Xms2g -Xmx2g`) and h2load on
   node 1.

#### HTTP/2 (h2c), `-c 16 -m 32`

| build | req/s | mean request time | RSS | GC pauses | run |
|---|---|---|---|---|---|
| ADAPTIVE | 671,887 | 720 us | 92 -> 1471 MiB | 34 | `runs/f-h2-adaptive` |
| ARENA heap (`-Dio.netty.noPreferDirect=true`) | 676,928 | 709 us | 93 -> 1457 MiB | 30 | `runs/f-h2-arena-heap` |
| ARENA direct | 672,233 | 711 us | 93 -> 1448 MiB | 32 | `runs/f-h2-arena-direct` |
| ARENA `-Darena.release=hook -Darena.hook=iteration` | 671,800 | 711 us | 93 -> 1458 MiB | 32 | `runs/f-h2-arena-hookiter` |
| ARENA `-Darena.release=hook -Darena.hook=off -Darena.e2e.readCompleteHook=true` | 666,754 | 716 us | 93 -> 1413 MiB | 32 | `runs/f-h2-arena-hookrc` |

#### HTTP/1.1, `--h1 -c 64`

| build | req/s | mean request time | RSS | GC pauses | run |
|---|---|---|---|---|---|
| ADAPTIVE | 298,586 | 218 us | 93 -> 1437 MiB | 92 | `runs/f-h1-adaptive` |
| ARENA direct | 300,662 | 216 us | 92 -> 1447 MiB | 92 | `runs/f-h1-arena-direct` |
| ARENA heap | 302,460 | 214 us | 92 -> 1436 MiB | 73 | `runs/f-h1-arena-heap` |

#### Counters

HTTP/2, ARENA heap run:

```
arenaHeap=71.7M  arenaDirect=111.4M  fallbackHeap=0  fallbackDirect=0
grow=0  resetOnZero=9.4M  lifoPop=68.7M
```

`release=hook`, `hook=iteration`: `hookRegistered=8 hookIteration=3.03M hookReset=3.03M`.
The `readCompleteHook` variant: `hookReadComplete=3.16M hookReset=604k`. On HTTP/1.1 the snoop
handler's `channelReadComplete` does not propagate, so that variant never fires there - a 3 s smoke
of `run-e2e.sh` on h1 with those flags gives `hookReadComplete=0`.

#### What these runs actually say

**End to end the allocators stay within run-to-run spread on these servers.** Every HTTP/2 build
lands between 666.8k and 676.9k req/s and every HTTP/1.1 build between 298.6k and 302.5k; the
request-time means differ by 11 us out of 709-720 (h2) and 4 us out of 214-218 (h1). Nothing here
separates the arena from adaptive, in either direction.

The earlier **"713 req/s" HTTP/2 arena result does not reproduce** at the pinned commit:
`runs/repro-h2-arena` gives 52,257 req/s against `runs/ref-h2-adaptive` 53,402 in the same
logging-bound harness, while `runs/repro-old-h2-arena` - the pre-fix `dec589d0eb` classes overlaid -
still gives 0.00 req/s. It is attributed to a stale build. **That attribution is not established.**

The RSS climb to ~1.5 GiB is the 2 GB Java heap filling between GCs under `-Xms2g`, the same for
every build. It is not native allocator retention.

#### The superseded run in `e2e/`

The files under `e2e/` are an earlier round that **measured the example servers' logging, not their
allocators**: the example pipelines log every HTTP/2 frame at INFO. Adaptive on HTTP/2 measured
23,507 req/s with that logging and 670,768 req/s without it - a factor of 28 (the quiet side of
that comparison is `e2e-v2/runs/q-h2-adaptive-heap`, the intermediate build; the final
`runs/f-h2-adaptive` of the table above is 671,887). `run-e2e.sh` now
passes `-Dlogback.configurationFile=e2e/logback-off.xml` by default; set `LOGBACK_CONFIG=` to
measure the servers as the examples ship them.

That round also hit a real bug, which is why its logs are kept. With the arena, HTTP/2 completed 0
of 512 started requests: h2load sent GO_AWAY with `errorCode=1` and the debug bytes
`DATA: stream not opened` on every connection, and the server threw no exception. **The kept logs do
not show that evidence**: `e2e/h2-arena.server.log.gz` is 93,494 lines of INBOUND/OUTBOUND frame
logging with no `GOAWAY` line in it, and `e2e/h2-arena.h2load` was truncated before h2load's summary
block. The GO_AWAY observation is from the console of that round and is not reproducible from this
directory; what the directory does show is the frame log of the failing run. **Cause, established:** `ArenaBuf.internalNioBuffer(index, len)` delegated to the
block's root buffer (an `UnpooledUnsafeHeapByteBuf`), whose `internalNioBuffer` returns **one cached
ByteBuffer per root**. A gathering write collects the NIO views of several outbound buffers of the
same block before using any of them, so all of those views pointed at the last position set -
corrupted DATA frames. **Fixed** on the PoC branch in commit `05604aa1c2` ("per-buffer NIO views"):
each `ArenaBuf` keeps its own cached duplicate for `internalNioBuffer` and slices a fresh view in
`nioBuffer` / `nioBuffers`.
