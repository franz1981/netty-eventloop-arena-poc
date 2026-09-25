# Does io_uring need a different arena, or is adaptive the right tool there?

**Recommendation: no arena on io_uring.** Use `AdaptiveByteBufAllocator` for the channels, and a
**fixed-slot, loop-local slab** for the provided buffer ring. Do not ship a second, io_uring-shaped
arena.

Section 8 iterated on that ring allocator and settled its shape: one region per loop, a fixed slot
size, the owning loop popping and pushing a plain `int` free stack with no atomic, foreign releases
through an MPSC hand-back, and one bounded growth step when the free list runs dry. It is **3.7x
cheaper per buffer** than adaptive (40.44 ns / 382 instructions against 148.19 / 1496) - and that is
worth **0.4 pp of event-loop CPU and 0% of throughput**, because the whole ring-allocation path is
0.4-0.6% of the loop against 40.8% for the socket-write syscall. The arena as the ring's allocator is
the worst of the candidates measured: **5-7% slower on W1** with a fifth of the ring's buffers
delegated away. Details in RESULTS.md section 8 and
[`uring-registered-buffers.md`](uring-registered-buffers.md) section 7.

Everything below is measured on one machine (the reference machine of
[`../results/ryzen9-7950x-node0/RESULTS.md`](../results/ryzen9-7950x-node0/RESULTS.md)), mostly one
run per cell. Section numbers refer to that file.

## The evidence, in the order it was gathered

**1. With the ring filled by the arena, the arena costs more CPU than adaptive.** (§3.5) On HTTP/1.1
the arena's share of event-loop CPU samples is **1.91% -> 4.31%** against adaptive - the opposite
direction from nio, where it is 7.72% -> 7.15%. Every loop grows to its 8-block bound and 24-41
block maxima are pinned across 8 loops, against nio's 0 (§3.2).

**2. Give the ring its own adaptive allocator and the counters go back to the nio shape.** (§4)
`maxPinned` W1 21 -> 6, W3 32 -> 5, W5 32 -> 4; allocator CPU h1 3.22% -> 1.71%, h2 7.74% -> 5.58%,
both at or below adaptive's 1.52% / 8.67%. The cross-loop proxy W6b goes from 398 violations and
10.5 req/s to **0 violations and 40,678 req/s** - the buffer that was crossing loops was the ring's
`retainedSlice`. Throughput across the three configurations spans 0.8%.

**3. Take the ring away entirely and the share returns but the pinning does not.** (§5) `BUFFER_RING=off`
gives h1 99.77-100% and h2 95.4% arena share, against nio's 100% and 95.54% - but 24 (h1) and 9 (h2)
block maxima stay pinned where nio pins 0, and W6b still fails (470/486 violations, ~24 req/s),
because with no ring it is the channel read buffers that cross the loops.

**4. What those remaining pinned blocks are, now measured.** (§7) On HTTP/1.1, **99.5% of them are
outbound write buffers**: `AbstractIoUringChannel.filterOutboundMessage` copies every outbound
buffer into a direct one from the channel allocator, and at or above
`IO_URING_WRITE_ZERO_COPY_THRESHOLD` that copy goes out as `SEND_ZC` and lives until the kernel's
notification. Turn zero-copy off and the pinned samples go from 8,682 to **3**. On HTTP/2 it is not
the zero-copy writes at all - 972 samples with them on, 974 with them off - it is the HTTP/2 frame
writer's own buffers during a flush: the oldest live buffer in a pinned block is a **9-byte DATA
frame header** in 74% of samples, with 51-63 other live buffers beside it in the same block.

**5. Fixing it buys nothing.** (§7.4) Keeping the 4,368-byte outbound copy out of the arena takes
`maxPinnedDirect` from 26 to 8 and moves throughput by **-0.4%**, while turning zero-copy off moves
it by **+36%**. The pinning and the throughput are separate effects.

## Why that adds up to "no arena here"

The arena's premise is that a buffer is allocated and released inside one iteration of one loop. The
three things io_uring is actually worth using are each a counter-example, and they are not corner
cases - they are the feature set:

| io_uring feature | what it does to a buffer's lifetime | measured consequence |
|---|---|---|
| **provided buffer rings** | the buffer belongs to the kernel from `add()` until the CQE, then to the pipeline for as long as it holds the `retainedSlice` - class D, unbounded iterations | 12-32 block maxima pinned; arena CPU share above adaptive's on h1 (§3, §4) |
| **zero-copy writes** (`SEND_ZC` / `SENDMSG_ZC`) | the written buffer lives until the notification, which is a later iteration | 99.5% of h1's pinned blocks (§7.2) |
| **multishot recv** | only reachable from the provided-buffer branch: `IoUring.isRecvMultishotEnabled()` is read inside `scheduleReadProviderBuffer()` | turning the ring off also turns multishot recv off (§5); the two cannot be separated |

So "use the arena but turn the awkward features off" is not a configuration, it is a decision to run
io_uring as a slower epoll. And on this box io_uring is already **27% below nio/epoll on HTTP/1.1**
(218.5 k vs 300.9 k, §3.2) - a gap nobody investigated, and one the allocator cannot close: on the
same servers the allocator is 1.9-12.6% of event-loop CPU (§3.5) and end-to-end throughput does not
move between allocators at all (§2.5).

**A second io_uring-shaped arena would have to become the thing it replaces.** To hold class-D
buffers it would need either per-buffer lifetimes (a free list, i.e. adaptive) or relocation
(impossible: the ring hands the kernel a raw address that nothing re-validates - see
[`uring-registered-buffers.md`](uring-registered-buffers.md) §2.1). To survive a proxy it would need
a cross-thread release path, which Invariant A exists to avoid. What is left after granting those is
`AdaptiveByteBufAllocator`.

## What to do instead

1. **Channels: adaptive.** It is within run-to-run spread of everything else on throughput, it has no
   confinement rule to violate, and it already handles the kernel-owned lifetimes.
2. **The provided buffer ring: a fixed-slot, loop-local slab.** One preallocated direct region per
   ring, one ring per loop, carved into equal chunks, refilled as the consumer finishes, never trimmed.
   That is what liburing (x2), folly and Zig all do - 4 of 4 PBUF_RING implementations surveyed - and
   the measurement agrees: 3.7x fewer instructions per buffer than adaptive and the lowest
   ring-allocator CPU share on h1 (2.11% against 2.71%), with zero allocation after start-up measured
   rather than assumed (§6, §8).
   * **Make the loop's own path atomic-free.** A plain `int` free stack with an MPSC hand-back for
     foreign releases saves 7.7 ns per buffer over a Treiber stack, and when every release comes from
     a foreign thread the Treiber version is *slower than adaptive* (301.7 ns against 264.6) while the
     hand-back is the fastest of all (171.4 ns) - §8.2.
   * **Size it by `maxInFlight`, and count the fallbacks.** W5 (256 KiB aggregator) holds **377-384**
     ring buffers in flight against 256 slots, so a fixed population must run dry: v1 took 2,145
     fallbacks there. One bounded doubling to 512 slots takes it to **0**, reproducibly, at no cost in
     throughput (§8.7). `depth` is not a constant to guess; `maxInFlight` is the counter that tells you.
   * **Do not make the slot size adaptive.** It costs 4.2 ns per buffer, and the policy that makes it
     fire costs 0.3-0.9% throughput for 3-8x the region. `AdaptiveCalculator` cannot converge when it
     does not also control the next buffer's size (§8.6).
   * **On a workload where the buffer SIZE matters, netty's own `IoUringAdaptiveBufferRingAllocator`
     wins instead**: on W3 it reached 98.14% arena share and 19,009 req/s on a quarter of the
     `allocate()` calls, because it grows the ring buffers towards 64 KiB. A fixed-chunk slab cannot
     do that (§6.3).
3. **Keep the arena for nio/epoll only, and keep it opt-in.** Even there it changes no end-to-end
   throughput; what it moves is the allocator's own slice of loop CPU (§2.5, §2.6).

## The option that was considered and rejected

**"Give the arena a hint so buffers destined for zero-copy writes are delegated."** It is the natural
fix for §7.2, and the design already lists consumer hints as out of scope. Cost: an allocator-level
hint API or a second allocator on the io_uring channel, in `transport-classes-io_uring`, plus a way
for `filterOutboundMessage` to know the write will be `SEND_ZC` before it allocates. That is not a
small change, and §7.4 measured what it would buy: two thirds of the pinning gone, throughput
unchanged to within 0.4%. It also does nothing on HTTP/2, where zero-copy is not what pins the blocks
(§7.3). **Not implemented**, on that evidence.

## What this recommendation does not rest on

* One machine, one kernel (7.1.13), one run per cell in §3-§7; no repetitions and no error bars.
* `IORING_RECVSEND_BUNDLE` and `IORING_ENTER_NO_IOWAIT` are supported by this kernel but left at
  netty's defaults (off), so nothing here measures them.
* `IORING_REGISTER_BUFFERS` (fixed buffers, as opposed to provided ones) has **no netty binding**, so
  no candidate was run with it (`uring-registered-buffers.md` §4). A fixed-buffer design might change
  the picture; it was not testable here.
* Nothing here measured NUMA or locality effects, and nothing explains why io_uring is 27% below
  nio/epoll on HTTP/1.1 on this box, or why turning `SEND_ZC` off is worth +36% on a 4 KiB body.
