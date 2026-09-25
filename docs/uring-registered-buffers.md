# What should serve io_uring's registered buffers

Everything about netty in this file was read at `netty` submodule commit `52b19c8ebf`
(section 7, the verdict, at `d04ac1f4ec`, which adds the two `IoUringBufferRing` instruments it uses)
(`expt/event-loop-arena`), in `transport-classes-io_uring/src/main/java/io/netty/channel/uring/`.
Everything about other projects was read from the clones/links in [the survey](#5-what-everyone-else-does)
on 2026-09-23. Anything I could not verify is labelled as such.

## 1. The lifecycle of one registered buffer

Netty uses **provided buffer rings** (`IORING_REGISTER_PBUF_RING`), where the kernel picks the
buffer. It does **not** use registered/fixed buffers (`IORING_REGISTER_BUFFERS`), where the
application picks an index - see [§4](#4-ioring_register_buffers-is-not-exposed).

| # | step | code |
|---|---|---|
| 1 | **ring array registered**, one per `IoUringIoHandler` (= per event loop): `Native.ioUringRegisterBufRing(ringFd, entries, bgId, flags)`, `flags = IOU_PBUF_RING_INC` when incremental. This mmaps the *array of `struct io_uring_buf`*, not the data buffers. | `IoUringIoHandler:249-263` |
| 2 | **filled**: `initialize()` -> `fill(0, batchSize)` -> `batchSize` x `allocator.allocate()`. Each buffer is `add()`ed: the ring slot at `(tail + offset) & mask` gets `addr = IoUring.memoryAddress(buf) + writerIndex`, `len = writableBytes`, `bid`; the `ByteBuf` is parked in `buffers[bid]`; then one release-store bumps `tail`. | `IoUringBufferRing:75-79,87-157` |
| 3 | **recv submitted** with `IOSQE_BUFFER_SELECT` and the bgId and **no address**, `IORING_RECV_MULTISHOT` when enabled. The kernel chooses a bid. | `AbstractIoUringStreamChannel:450-490` |
| 4 | **kernel writes**, CQE returns `res = bytes`, `IORING_CQE_F_BUFFER` set and the bid in `flags >> IORING_CQE_BUFFER_SHIFT`; `IORING_CQE_F_BUF_MORE` means the bid is not finished. | `AbstractIoUringStreamChannel:508-511` |
| 5 | **handed to the pipeline**: `useBuffer(bid, read, more)` calls `allocator.lastBytesRead(writableBytes, read)` and returns `byteBuf.retainedSlice(writerIndex, read)`, then advances `writerIndex`. | `IoUringBufferRing:220-227` |
| 5a | **incremental consumption**: if `incremental && more && byteBuf.isWritable()`, the bid **stays in the ring** and the same buffer is written into again, further along. Several slices come out of one buffer. | `IoUringBufferRing:229-232` |
| 6 | **retired**: otherwise `buffers[bid] = null; byteBuf.release()` - the ring drops *its own* reference. The pipeline's slices are derived buffers and share that reference count, so the buffer is only really free when the ring **and** every slice are done. | `IoUringBufferRing:234-236` |
| 7 | **re-added**: `fill(bid)` calls `allocator.allocate()` for a **fresh** buffer and puts it at the tail under the same bid - or, when the ring ran empty, `fill(0, allocatedBuffers)` refills all of them. | `IoUringBufferRing:237-263` |
| 8 | **exhaustion**: `-ENOBUFS` -> `expand()` grows towards `entries`; if it is already full, `IoUringBufferRingExhaustedEvent` is fired at the pipeline. | `AbstractIoUringStreamChannel:525-537` |
| 9 | **close**: `ioUringUnRegisterBufRing`, then release every buffer still parked in `buffers[]`. | `IoUringBufferRing:283-295` |

Step 7 is the one that matters for an allocator: **one allocation per consumed buffer, forever.**

## 2. What that imposes on an allocator

1. **The address is handed over once and never revisited.** `add()` writes a raw address into the
   ring slot; the kernel reads it back at selection time (`io_uring/kbuf.c:214-216`: `sel.addr =
   u64_to_user_ptr(READ_ONCE(buf->addr))`, guarded only by `access_ok`). Nothing in netty or in the
   kernel re-validates it. *I did not find any man page or kernel comment that states provided-buffer
   memory must stay resident or unmoved while its bid sits in the ring* - see the quotes in
   [§5](#5-what-everyone-else-does). What is documented is only that a buffer must stay valid from
   selection to completion (`man io_uring.7:462-469`). So: an allocator that can move or free memory
   under a parked bid is writing an address the kernel will later read; I am not claiming what the
   kernel does then, I have not tested it.
2. **Lifetime is kernel-bound - class D.** From `add()` to the CQE is an unbounded number of
   event-loop iterations, and step 5/6 extends it by however long the pipeline keeps the slice. An
   iteration-scoped allocator has no answer for this; that is what RESULTS.md §8 measured.
3. **Size is fixed per buffer at `allocate()` time** and written into the slot as `len`. Netty's
   `RECVSEND_BUNDLE` path additionally needs bids to be re-added in sequential order
   (`IoUringBufferRing:253-256`), so varying sizes per bid buys nothing and costs ordering freedom.
4. **The owner is the loop.** `allocate()` is only ever reached from `initialize()` and `useBuffer()`,
   both on the `IoHandler`'s own thread. **Release is not**: a proxy that writes an inbound slice to a
   channel on another loop releases it there - that is exactly the W6b failure of RESULTS.md §7.4/§8.4.
5. **Release can be delayed arbitrarily** by the pipeline (aggregation, an outbound queue, a
   zero-copy write completion), so the allocator cannot assume the buffer it just re-added is the one
   that came back.

### The requirement this PoC is built to

The user's framing, which is the target these candidates are judged against:

> **as local as possible, not elastic, sort of perm gen**

Concretely:

| property | what it means here |
|---|---|
| **locality** | one region per ring, and one ring per loop. Memory is first-touched and afterwards only touched by the loop that reads into it - no sharing, no cross-node traffic, no cross-loop cache line ping-pong. |
| **elasticity: none** | count x size fixed at construction from the ring config. No growth, no adaptive sizing, no per-buffer size decision. |
| **lifetime: process** | allocated once at start-up, never freed, never trimmed. Steady state allocates nothing. |

## 3. The candidates

| # | what | local? | elastic? | perm gen? | allocations in steady state |
|---|---|---|---|---|---|
| (i) | **adaptive as now** - `AdaptiveByteBufAllocator` behind `Transports.FixedSizeRingAllocator`, one `directBuffer(8192)` per re-add (`BUFFER_RING_ALLOC=adaptive`, RESULTS.md §8) | per-thread magazines, but one allocator shared by every loop | **yes** - magazines grow and are trimmed | **no** | 1 per consumed buffer |
| (ii) | **netty's built-in** - `IoUringFixedBufferRingAllocator(ByteBufAllocator.DEFAULT, false, size)`: `allocate()` is literally `allocator.directBuffer(nextBufferSize())` (`AbstractIoUringBufferRingAllocator:66-69`). `IoUringAdaptiveBufferRingAllocator` is the same with an `AdaptiveCalculator` choosing the size. `ByteBufAllocator.DEFAULT` is whatever `io.netty.allocator.type` says - **adaptive** on this box, so (ii) differs from (i) mainly by *which* adaptive instance and by the size policy, not by strategy. | no - one instance for all loops, and `DEFAULT` is process-wide | **yes** (and `...Adaptive...` also varies the buffer size) | **no** | 1 per consumed buffer |
| (ii-b) | the same class with `largeAllocation=true`: **one** `directBuffer(size * number)` per batch, sliced. Only reachable with `batchAllocation=true`, and it allocates a **new** big block on every full-ring refill, because the slices share its reference count and it dies with the last one (`AbstractIoUringBufferRingAllocator:45-62`). | no | **yes** | **no** | 1 per full ring cycle |
| (iii) | **registered slab** - `RegisteredSlabBufferRingAllocator` (this PoC, `lib/java/`) | **yes** - one `ByteBuffer.allocateDirect` region per ring, one instance per loop | **no** - `entries x depth` chunks of `chunk` bytes, fixed at construction | **yes** - never freed, never trimmed | **0** (counted: `slabFallbacks`) |

### (iii) in detail

* One direct region per ring: `entries * depth` chunks x `chunk` bytes (`64 * 4 x 8192` = 2 MiB per
  loop by default; `-Diouring.slabDepth`). `Transports` builds a **fresh instance per worker loop** by
  constructing the `IoUringIoHandlerConfig` inside the `IoHandlerFactory` lambda instead of once
  outside it - no netty change was needed for that.
* One wrapper per chunk, built at start-up, reused: `SlabBuf extends UnpooledUnsafeDirectByteBuf`
  using the *protected* `(ByteBufAllocator, ByteBuffer, maxCapacity)` constructor, which sets
  `doNotFree`. `deallocate()` does **not** call `super` - it resets the indices and pushes the slot
  back on the free list. `maxCapacity == chunk`, so nothing can grow a slot in place.
* Incremental consumption falls out for free: the ring's `retainedSlice`s are derived buffers sharing
  the `SlabBuf`'s reference count, so the slot returns to the free list exactly when the ring and
  every outstanding slice are done.
* **Why `depth > 1`.** Step 7 re-adds a bid while the slice from step 5 may still be alive. With
  exactly `entries` chunks the free list would run dry the moment anything outlives its iteration.
  `depth` is that headroom.
* **Fallback, not a throw.** If the free list is empty, `allocate()` takes a plain direct buffer from
  `UnpooledByteBufAllocator.DEFAULT` and counts it. Throwing out of `allocate()` would set
  `corrupted = true` and tear the whole ring down (`IoUringBufferRing:104-113`). `slabFallbacks == 0`
  in the `SLABTELE` line is therefore a *measurement* that "zero allocation after start-up" held, not
  an assumption.
* **Free list is a lock-free Treiber stack** over the `SlabBuf`s themselves (no node allocation),
  because release can happen on a foreign thread (requirement 4). `slabForeignReleases` counts how
  often it actually did.

## 4. `IORING_REGISTER_BUFFERS` is not exposed

`Native.java` at `52b19c8ebf` declares `ioUringRegisterBufRing`, `ioUringUnRegisterBufRing`,
`ioUringBufRingSize`, `ioUringRegisterIoWqMaxWorkers`, `ioUringRegisterEnableRings` and
`ioUringRegisterRingFds` - and **no** `io_uring_register_buffers` binding, nor any
`IORING_REGISTER_BUFFERS` constant. So the slab's region **cannot** additionally be registered as a
fixed buffer without adding a JNI entry point to `netty-transport-native-io_uring`. That is a native
build change, not a Java one, and it was not made here. The slab is a *provided-buffer* slab only.

## 5. What everyone else does

Read from clones on 2026-09-23. URLs are branch-tip links, not commit permalinks.

| project | mechanism | one block or per buffer | sizing | refill | ever freed while the ring lives |
|---|---|---|---|---|---|
| [liburing `examples/io_uring-udp.c`](https://github.com/axboe/liburing/blob/master/examples/io_uring-udp.c#L46-L89) | PBUF_RING | **one `mmap`**, ring array **and** buffers; `base + (idx << buf_shift)` | constants `BUFFERS=1024`, `BUF_SHIFT=12` | immediate per CQE: `buf_ring_add` + `advance(1)` | no free path at all |
| [liburing `examples/proxy.c`](https://github.com/axboe/liburing/blob/master/examples/proxy.c#L360-L396) | PBUF_RING + FIXED | **one** `posix_memalign(page, buf_size*nr_bufs)` (or huge pages) | CLI `-b`/`-n`, default 32 x 256, pow2 | **batched** `replenish_buffers()` then one `advance(n)` | only at connection teardown |
| [folly `IoUringProvidedBufferRing`](https://github.com/facebook/folly/blob/main/folly/io/async/IoUringProvidedBufferRing.cpp#L59-L98) | PBUF_RING | **one `mmap`**, ring + `sizePerBuffer_*count`, rounded to 2 MiB, `MADV_HUGEPAGE` | `Options{bufferCount, bufferSize}`, count rounded to pow2, cap 32768 | immediate on IOBuf free -> `returnBuffer(bid)` | no - one `munmap` at destroy |
| [Zig `std.os.linux.IoUring.BufferGroup`](https://github.com/ziglang/zig/blob/master/lib/std/os/linux/IoUring.zig#L1619-L1732) | PBUF_RING | **one** `allocator.alloc(u8, buffer_size*count)` | all caller-supplied | immediate, one at a time | only at `deinit` |
| [glommio](https://github.com/DataDog/glommio/blob/master/glommio/src/sys/uring.rs#L94-L166) | FIXED only | **one** 4 KiB-aligned region + a buddy sub-allocator, registered as a single iovec | `io_memory`, default 10 MiB; no per-buffer knob | `Drop` -> buddy `free`, no syscall | region held for the reactor's life; **falls back** to an unregistered `DmaBuffer` when the buddy is full |
| [tokio-uring `FixedBufRegistry`](https://github.com/tokio-rs/tokio-uring/blob/master/src/buf/fixed/plumbing/registry.rs#L39-L51) | FIXED only | **per buffer**, caller-supplied `IoBufMut`s | entirely caller's | `Drop for FixedBuf` -> `check_in(index)` | not while registered |
| monoio | **neither** | - | - | - | its `driver/pool.rs` (old `IORING_OP_PROVIDE_BUFFERS`) has no `mod pool;` and is not compiled |

**The majority pattern among the PBUF_RING implementations (liburing x2, folly, Zig - 4 of 4) is
exactly candidate (iii):** one contiguous block per ring carved into N equal-size buffers indexed
`base + bid*size`, refilled as soon as the consumer is done, and never trimmed while the ring lives.
Netty's own `IoUringFixedBufferRingAllocator` is the odd one out - one heap-managed allocation per
buffer, forever. Among FIXED-buffer users there is no majority (glommio one region, tokio-uring one
allocation per buffer). The slab copies the majority pattern; the only thing it adds is `depth`,
which the C/Zig implementations do not need because their consumer hands the buffer back before the
next recv rather than passing a refcounted slice up a pipeline.

Two kernel/man findings worth keeping:

* **Fixed buffers are documented as pinned**, provided buffers are not.
  `man io_uring_register.2:52-67`: *"The buffers associated with the iovecs will be locked in memory
  and charged against the user's `RLIMIT_MEMLOCK` resource limit."* (`io_sqe_buffer_register` ->
  `io_pin_pages` with `FOLL_LONGTERM`). The *ring array* is pinned too, when the app allocates it
  (`io_uring/kbuf.c:670-681`). The **data buffers of a provided ring are not pinned and not
  referenced** - `kbuf.c:214-216` just `access_ok`s the stored address.
* **Incremental consumption mutates the slot in place**: `WRITE_ONCE(buf->addr, READ_ONCE(buf->addr)
  + this_len); WRITE_ONCE(buf->len, buf_len)` (`io_uring/kbuf.c:36-59`). The bid stays at the same
  head slot and is not returned until it is fully consumed, so with `IOU_PBUF_RING_INC` the
  application must keep that buffer untouched across several CQEs. Netty's `useBuffer` step 5a does
  exactly that.

## 6. Measured, round 1

**Read [section 7](#7-the-verdict-after-iterating-resultsmd-section-8-measured-2026-0925-26) with
this.** Two readings below were revised by it: the "lowest ring-allocator frame count" is partly an
inlining artifact (a slab whose `allocate()` inlines into `IoUringBufferRing` disappears from that
filter entirely - measured), and `builtinadaptive`'s W3 win did not reproduce with adaptive channels
and zero-copy writes off.

RESULTS.md **section 6** runs (i), (ii), (ii-a) and (iii) as the ring's allocator with the channel
allocator held at `arena -Darena.ring=false`, plus adaptive everywhere as the control: two e2e cells
(h1, h2; 20 s, one run each) and three topology cells (W1, W3, W5). Section 5 measures the other end
of the question - io_uring with no buffer ring at all (`BUFFER_RING=off`) - and section 4 the split
that separated "the arena is wrong for io_uring" from "the arena is wrong for the buffers the ring
registers". What those runs found, with the numbers that carry it:

**1. Nothing separates the candidates on throughput.** The five configurations span 0.7% on h1
(126,840-127,572 req/s), 1.4% on h2 (370,529-375,775) and 3.5% on W1. One run per cell: this is a
band, not a ranking.

**2. The slab has the lowest allocator CPU in three of the four e2e columns.** Filter B of
`tools/asprof-alloc-share.py` gives it 0.93% (h1) and 5.54% (h2) against the control's 2.05% /
9.35%, and on h2 the lowest ring-allocator frame count too (0.46% against 1.22%). It is also the
only candidate that allocates nothing after start-up, and that is measured rather than assumed:

```
h1  instances=8 regionBytes=16777216 slabAcquires=1306518 slabReleases=1306262 slabFallbacks=0 slabForeignReleases=0
h2  instances=8 regionBytes=16777216 slabAcquires=3753605 slabReleases=3753349 slabFallbacks=0 slabForeignReleases=0
```

8 instances = one per worker loop; 16 MiB total (8 x 256 x 8 KiB); `slabAcquires == ringAllocs`, so
every buffer the ring received came from a preallocated slot; `acquires - releases = 256` = the 32
buffers per loop still parked in the ring at shutdown; `slabForeignReleases=0`, so in these
workloads nothing released a ring buffer off its own loop and the Treiber stack's CAS was never
contended. **It does not show the slab is faster** - the req/s spread is inside the noise of one run
- and nothing here explains *why* its filter-B share is lower.

**3. (i) and (ii) are indistinguishable, as predicted before the run** (h1 1.49% vs 1.69%, h2 6.31%
vs 6.79%, and the same arena counters). Reading the code said they would be: both are
`allocator.directBuffer(size)` over an `AdaptiveByteBufAllocator`. This is a confirmation, not a
finding.

**4. (ii-a) wins wherever the buffer SIZE matters.** On W3 (64 KiB HTTP/2 echo) it reaches 98.14%
arena share and 19,009 req/s on a quarter of the `allocate()` calls (217,237 against 1,142,550),
because `AdaptiveCalculator` grows the ring buffers towards 64 KiB and each CQE then carries more
bytes. On W5 it is the only candidate that leaves **zero** blocks pinned. Fixed 8 KiB chunks - the
slab included - cannot do that. **This is the one axis on which "not elastic" costs something
measurable**, and it is a size policy, not an allocation strategy: a slab of larger or mixed-size
chunks would close it, and was not tried.

**5. "Not elastic" has a failure mode, and it fired.** W5 (the 256 KiB aggregator) is the one cell
where the fixed slab ran dry: `slabAcquires=3,064,590` with **`slabFallbacks=4,077`** out of
3,068,667 `allocate()` calls (0.13%), served by the fallback `UnpooledByteBufAllocator`. 256 chunks
per loop were not enough headroom, and `depth=4` was picked before the run rather than tuned -
nothing here says what the right value is. The counter exists precisely so that this cannot pass
unnoticed.

**What this section does not establish.** One run per cell, one session; absolute req/s is not
comparable across sections. `slabForeignReleases=0` means the cross-loop path was never *taken* in
these workloads - not that the slab handles the W6b cross-loop topology, which was not run. Nothing
here measured locality or NUMA. No candidate was run with `IORING_REGISTER_BUFFERS`, because netty
exposes no binding for it (section 4 above).

Candidate **(iv)**, the FFM mimalloc allocator from `franz1981/netty-ffm-allocator`, was **not run**:
it needs JDK 25 and the PoC's scripts run on whatever `java` is on `PATH`, which is JDK 21 here
(`java version "21" 2023-09-19 LTS`). JDK 25 is installed on this box, but moving one cell to a
different JDK would have made it incomparable with every other cell in the session, and the whole
matrix is only ever compared within a run.

## 7. The verdict, after iterating (RESULTS.md section 8, measured 2026-09-25/26)

**Use a fixed-slot, loop-local slab: one direct region per event loop, `entries x depth` equal slots,
the owning loop popping and pushing a plain `int` free stack with no atomic, foreign releases going
through an MPSC hand-back the owner detaches in one `getAndSet`, and one bounded growth step when the
free list runs dry. That is `slab3fixed` in `lib/java/SlabV2BufferRingAllocator.java`.** It is the
majority pattern of [section 5](#5-what-everyone-else-does) (liburing x2, folly, Zig) plus the two
things a netty pipeline needs that a C consumer does not: headroom, because the pipeline holds a
refcounted slice past the read, and a cross-thread release path, because a proxy releases on another
loop.

What decided it, with the numbers:

| question | answer | evidence |
|---|---|---|
| Slab or general allocator behind the ring? | **slab**, 3.7x cheaper per buffer | 40.44 ns / 382.0 insns/op against adaptive's 148.19 / 1495.9, and 0.88 against 6.31 L1d misses/op (RESULTS 8.1) |
| Is it still an arena? | **no**, the worst candidate | as the ring's allocator the arena is 5-7% slower on W1 (124,829-127,439 vs 131,524-135,194) and 3.71-3.77% of loop CPU against the slabs' 2.11-2.37%; `arenaShare=77.94%`, so a fifth of the ring's buffers fall through to adaptive anyway, with all 8 blocks pinned (RESULTS 8.7) |
| Treiber stack or loop-local `int` stack? | **loop-local** | -7.7 ns / -76 insns per buffer at an identical feature set; and when every release is foreign, slab v1's CAS-per-release is **301.7 ns, slower than adaptive's 264.6**, against 171.4 ns for the hand-back, with half the stalled frontend cycles (RESULTS 8.2) |
| Adaptive slot size (the "fixed population, adaptive slot" synthesis)? | **no** | it costs 4.2 ns / 71 insns, and the policy that makes it fire costs 0.3-0.9% throughput for 3-8x the region (16 MB -> 54-134 MB). `AdaptiveCalculator` cannot converge when it does not control the next buffer's size: 80.6% of samples want a size >=2x away and the longest run of the same value is **2** (RESULTS 8.6) |
| Does the size ever matter, as section 6.2 suggested? | **not established** | W3's spread across nominally identical designs is 18% (13,036-15,442 req/s); section 6.2's `builtinadaptive` win did not reproduce with adaptive channels and zero-copy off (14,053, mid-pack) |
| folly's 2 MiB alignment / huge pages? | **dropped** | `aligned=true` but `AnonHugePages=0` in every cell: the box is `transparent_hugepage=[madvise]` and Java cannot call `madvise` - no JNI binding, and `java.lang.foreign` is preview on JDK 21 (RESULTS 8.4) |
| How much does any of it buy end to end? | **nothing measurable** | 0.8% across ten configurations on h1, 1.1% on h2, one run per cell |

### 7.1 Why it buys nothing, stated as a profile line

The whole provided-buffer-ring allocation path is **0.4-0.6% of event-loop CPU** on HTTP/1.1
(`tools/asprof-loop-breakdown.py`, RESULTS 8.5), against **40.8%** for the socket-write syscall and
33.7% for the pipeline - where `ByteBufUtil.unsafeWriteUtf8` alone is 12.8% and this box's
`nft_do_chain [nf_tables]` firewall hook is 2.9%. A 3.7x saving on 0.5% of the loop is 0.4 pp, which
is exactly the filter-D difference the e2e cells show (2.11% for `slab3fixed` against 2.71% for
adaptive), and it is below the resolution of a 20 s throughput run. The microbenchmark's floor and the
server's profile agree: `1,772,331 allocate()` calls x 40.44 ns = 71.7 ms against 83.5 s of loop CPU
= 0.086%, and for adaptive 0.31% predicted against 0.39% measured.

**So the allocator is at its floor and the floor does not matter here.** What is left of the per-buffer
cost is not the allocator's: **43% of `slab3fixed`'s 40.44 ns is the `retainedSlice`** that
`useBuffer` hands the pipeline (150-177 instructions and 9-18 ns for every candidate), and removing it
is a netty change, not an allocator change - see 7.2.

### 7.2 The two netty questions, answered with counters

**Step 7 cannot reuse the retiring buffer.** `-Dio.netty.iouring.bufferRing.refCntTele=true` (netty
`d04ac1f4ec`) records `refCnt()` where the ring drops its own reference: it is **2 in 100.0% of
343,868 (h1) and 764,111 (h2) retirements, never 1**. It cannot be 1 - the `retainedSlice` that
`useBuffer` is about to return *is* the second reference. So the ring is never the last holder, the
only place "the kernel and the pipeline are both done" is observable is the buffer's own
`deallocate()`, and **a recycling allocator is not an alternative to reusing the retiring buffer, it is
the only implementation of it.** (Those counters also show 66% of h1's reads are incremental
continuations where the bid stays in the ring.)

**Handing the buffer over instead of slicing it works and is worth nothing.**
`-Dio.netty.iouring.bufferRing.noSliceHandoff=true` makes `useBuffer` transfer the ring's reference to
the caller when the read retires the bid - one `UnpooledSlicedByteBuf` and one retain/release pair
fewer per retiring read, 34% of reads on h1 and 69% on h2. Correct (0 failed, all 2xx) and worth
-0.1% to +0.5% req/s over 3.8 million removed allocations. The caller then sees a buffer whose
capacity is the whole ring chunk, which is what the upstream comment "we always slice so the user will
not mess up things later" is protecting against; on this evidence the protection is free.

### 7.3 Sizing it: the counter that tells you the answer

`maxInFlight` is the number to watch, and it is the one that explains section 6.2's W5 failure.

| workload | slots per loop | maxInFlight | fallbacks v1 | fallbacks v2/v3 |
|---|---|---|---|---|
| e2e h1/h2 | 256 | 34-36 | 0 | 0 |
| W1 | 256 | 34 | 0 | 0 |
| W3 | 256 | 64-66 | 0 | 0 |
| W5 (256 KiB aggregator) | 256 -> 512 | **377-384** | **2,145** | **0** |

W5 holds 377-384 ring buffers in flight against 256 slots, so a fixed population **must** run dry;
one bounded doubling to 512 takes it to zero fallbacks with 4 exhaustions and 4 growths, reproducibly
across three runs, and throughput does not change. The in-flight histogram says why W5 is different:
on h1 **every** slot returns within one ring's worth of acquires (`lifeSeq[<1ring:1778667]`), on W5
**none** does (`lifeSeq[<1ring:0, <8ring:3062161, <64ring:821]`). A provided-ring buffer's life is
dominated by waiting in the ring for the kernel, not by the pipeline - 3.1 ms mean on h1 by Little's
law, which the `lifeNanos` histogram confirms - so the thing to size is the slot **count**, not the
slot lifetime.

`drains=4` with `foreignReleases=0` in every workload measured: the hand-back path exists for
correctness (requirement 4) and was never taken here, so the measurement that separates it from a
Treiber stack is the microbenchmark of 7.0, not any of these servers.

## 8. What follows for the arena

The arena is not a candidate here and should not be one. A provided-buffer-ring buffer is
class D by construction (section 1, step 7 and requirement 2): its lifetime is decided by the
kernel and by the pipeline that holds the slice, never by an event-loop iteration boundary. The
measurement of that is RESULTS.md section 4: with the ring filled by the arena, 12-32 of the
process's block maxima stay pinned and the arena's HTTP/1.1 allocator CPU share goes *above*
adaptive's; give the ring its own allocator and the counters return to the nio shape. The
recommendation that follows for io_uring as a whole, including the option of no arena there at all,
is [`uring.md`](uring.md).
