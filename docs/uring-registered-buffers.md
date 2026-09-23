# What should serve io_uring's registered buffers

Everything about netty in this file was read at `netty` submodule commit `52b19c8ebf`
(`expt/event-loop-arena`), in `transport-classes-io_uring/src/main/java/io/netty/channel/uring/`.
Everything about other projects was read from the clones/links in [the survey](#5-what-everyone-else-does)
on 2026-09-23. Anything I could not verify is labelled as such.

## 1. The lifecycle of one registered buffer

Netty uses **provided buffer rings** (`IORING_REGISTER_PBUF_RING`), where the kernel picks the
buffer. It does **not** use registered/fixed buffers (`IORING_REGISTER_BUFFERS`), where the
application picks an index - see [§4](#4-io_uring_register_buffers-is-not-exposed).

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

## 6. Measured

RESULTS.md **§10** runs (i), (ii) and (iii) as the ring's allocator with the channel allocator held at
`arena -Darena.ring=false`, plus adaptive everywhere as the control. §9 measures the other end of the
question: io_uring with no buffer ring at all (`BUFFER_RING=off`).

Candidate **(iv)**, the FFM mimalloc allocator from `franz1981/netty-ffm-allocator`, was **not run**:
it needs JDK 25 and the PoC's scripts run on whatever `java` is on `PATH`, which is JDK 21 here
(`java version "21" 2023-09-19 LTS`). JDK 25 is installed on this box, but moving one cell to a
different JDK would have made it incomparable with every other cell in the session, and the whole
matrix is only ever compared within a run.
