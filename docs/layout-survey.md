# Block/arena metadata layouts in 10 allocators (verified from source, 2026-09-22)

Research agent report, sources read from the repos' default branches; line numbers as fetched that day.

All 10 sources verified against real source. Report below.

---

# Block/arena metadata layout: 10 verified allocators

All line numbers are from the files as fetched today from the repos' default branches (`master`/`main`). Everything below I read directly; anything I did not read is labelled.

## 1. Zig `std.heap.ArenaAllocator` — `lib/std/heap/arena_allocator.zig`

- **(a) HOT fields**: `State.end_index: usize` (line 19) is flat in the allocator struct; the *current block* is NOT flat — it is `state.buffer_list.first`, reached by a pointer load each `alloc` (line 190). There is no cached `limit`; the limit is recomputed from `cur_node.data` every allocation (lines 195-196).
- **(b) PER-BLOCK metadata**: in-band header at the **start** of the block. `const BufNode = struct { data: usize, node: std.SinglyLinkedList.Node }` (lines 41-44); `data` is the total allocation size. The payload is `cur_alloc_buf[@sizeOf(BufNode)..]` (line 196).
- **(c) NEXT block**: never walked. A full block triggers `rawResize` in place, else `createNode` which **prepends** a new, larger node and sets `end_index = 0` (lines 208-213, 180-181). Older blocks are never revisited.
- **(d) LIVE count**: none. `reset(.retain_capacity)` (line 102) frees every node but the last and zeroes `end_index` unconditionally — liveness is not tracked or checked. Use-after-reset is the caller's problem.
- **(e) ptr → block on free**: not needed. `free` (line 253) only checks whether the freed slice ends exactly at the current bump (line 263) and, if so, rewinds `end_index`. Otherwise it is a no-op.

## 2. Zig `FixedBufferAllocator` — `lib/std/heap/FixedBufferAllocator.zig`

- **(a)** Fully flat: `end_index: usize` and `buffer: []u8` (lines 8-9) are the whole struct. `limit` is `buffer.len`.
- **(b)** No per-block metadata at all — one block, supplied by the caller.
- **(c)** No next block. `alloc` returns `null` when `new_end_index > self.buffer.len` (line 69).
- **(d)** No live count. `reset()` (line 145) is `self.end_index = 0`, unconditional.
- **(e)** `isLastAllocation` (lines 58-60): `buf.ptr + buf.len == self.buffer.ptr + self.end_index`. `free` (line 114) rewinds only in that case — LIFO-only, otherwise a no-op. Note the doc comment at lines 54-57: this has **false negatives** when the last allocation was realigned.

## 3. TigerBeetle `src/message_pool.zig`

This is the one that matches your "metadata in a side array" shape most literally.

- **(a)** No cursor — it is a fixed-size pool, not a bump arena. `free_list: StackType(Message)` (line 188) is flat in `MessagePool`.
- **(b)** **Two parallel arrays, out-of-band**: `messages: []Message` and `buffers: []align(sector_size) [message_size_max]u8` (lines 191-192), allocated once in `init_capacity` (lines 205-214) and zipped `for (messages, buffers) |*message, *buffer|` (line 219). The metadata (`header`, `buffer`, `references`, `link`) lives in `Message` in the `messages` array — **not** inside the payload buffer.
- **(c)** `free_list.pop()` (line 263) — an intrusive stack whose `link` lives in the metadata struct, not the payload.
- **(d)** **Yes, a live count**: `references: u32 = 0` (line 135). `ref()` asserts `references > 0` and increments (lines 140-143). `unref_base` (line 288) decrements and **only on reaching zero** pushes back to the free list (lines 291-297). A message with `references > 0` is simply not returned — the analogue of your "pinned" block. `deinit` asserts `free_list.count() == messages_max` (line 236), i.e. leaking a live message is a hard failure, not a tolerated state.
- **(e)** Not by arithmetic: `Message` stores `buffer: *[message_size_max]u8` (line 134), a **stored pointer** from metadata to payload. There is no payload → metadata direction; callers always hold the `*Message`. Note the in-repo TODO at lines 131-132: *"TODO Avoid the extra level of indirection."*

## 4. mimalloc

- **(a)** Per-size-class, flat-ish: `heap->pages_free_direct[MI_PAGES_DIRECT]` (`types.h:582`) is an array of `mi_page_t*` indexed by word-size, read by `_mi_heap_get_free_small_page` (`internal.h:534-538`) as `heap->pages_free_direct[_mi_wsize_from_size(size)]`. The cursor itself is not a bump pointer but `page->free` (a free list head) — one pointer dereference from the heap. `_mi_page_malloc_zero` (`alloc.c:31`) is: load `page->free` (37), `page->free = mi_block_next(...)` (44), `page->used++` (45).
- **(b)** **Array indexed by block id, placed in-band at the head of the segment**: `mi_slice_t slices[MI_SLICES_PER_SEGMENT+1]` (`types.h:504`) at the end of `mi_segment_t`. `mi_slice_t` and `mi_page_t` are the same storage (`mi_slice_to_page`, `internal.h:555`). So per-page metadata is *not* inside the page's own data; it is in a table at the segment head, indexed by slice index.
- **(c)** Linked-list walk with a candidate cap: `mi_page_queue_find_free_ex` (`page.c:784`) walks `pq->first` → `page->next` in "next fit" order, moving full pages to the `mi_pages_full` queue (`page.c:874-876` region) so they are not revisited.
- **(d)** **Yes — `uint16_t used` (`types.h:341`)**, "number of blocks in use (including blocks in `thread_free`)". `mi_page_all_free(page)` is `page->used == 0` (`internal.h:674-677`). A page with `used > 0` at heap teardown is **abandoned, not freed**: `page.c:454-459` — `if (mi_page_all_free(page)) { _mi_page_free(...) } else { _mi_page_abandon(page, pq); }`. And an all-free page is not necessarily released either: `_mi_page_retire` (`page.c:493`) keeps it if it is the only page in its queue, setting `page->retire_expire` (line 512) — a deliberate "don't reset the last one" hysteresis.
- **(e)** **Pointer arithmetic, id derived not stored.** `_mi_ptr_segment` masks: `((uintptr_t)p - 1) & ~MI_SEGMENT_MASK` (`internal.h:547`). `_mi_segment_page_of` (`internal.h:582`) then computes `idx = (p - segment) >> MI_SEGMENT_SLICE_SHIFT` and indexes `segment->slices[idx]`, then `mi_slice_first` follows `slice_offset` back to the head slice. Two shifts and a mask; no id is stored in the object.

## 5. protobuf `SerialArena` — `serial_arena.h`, `arena.cc`

- **(a)** **Flat, and explicitly for that reason.** `std::atomic<char*> ptr_` and `char* limit_` sit in `SerialArena` (serial_arena.h:417 and the line after), with the comment at 415-417: *"Points inside head_ ... We keep these here to reduce indirection."* `head_` is a separate `std::atomic<ArenaBlock*>` (line 412). Fast path `MaybeAllocateAligned` (line 201): `limit_ - ptr()` compare, `set_ptr(ret + n)`.
- **(b)** **In-band header at the start**: `struct ArenaBlock { ArenaBlock* const next; const size_t size; }` (lines 39-57), payload at `Pointer(kBlockHeaderSize)`.
- **(c)** Prepend, never walk for allocation: `AllocateNewBlock` (arena.cc:314) placement-news `ArenaBlock{old_head, mem.n}` and `set_range(new_head->Pointer(kBlockHeaderSize), new_head->Limit())`. The `next` chain is walked only in `Free` (arena.cc:259-271).
- **(d)** **No per-block live count.** Per-*arena* byte counters only (`space_used_`, `space_allocated_`, arena.cc:314-325). `ThreadSafeArena::Reset` (arena.cc:796) runs `CleanupList()` (registered destructors), then `Free()` discards **all** blocks except the first, unconditionally — liveness is never consulted.
- **(e)** Not needed; there is no per-object free. Destructors are run from a separate `cleanup_list_` (`serial_arena.h:85`).

## 6. folly `Arena` — `folly/memory/Arena.h`

- **(a)** Flat: `char* ptr_; char* end_;` (lines 268-269), plus `typename BlockList::iterator currentBlock_` (line 266) and `size_t bytesUsed_` (271). `allocate` (line 88) is `end_ - ptr_ >= size` then `ptr_ += size`.
- **(b)** **In-band intrusive header at the start**: `struct alignas(max_align_v) Block { BlockLink link; char* start() { return reinterpret_cast<char*>(this + 1); } }` (lines 156-162), where `BlockLink = boost::intrusive::slist_member_hook<>` (line 154). Blocks live in `BlockList blocks_` (line 265).
- **(c)** **Iterator advance over the intrusive list**: `canReuseExistingBlock` (line 185) checks `currentBlock_ != blocks_.last()`, then `currentBlock_++` and recompute `ptr_`/`end_` from `currentBlock_->start()` (lines 102-105). So after `clear()`, previously-allocated blocks are walked forward and reused — the closest thing here to your "advance to the next block".
- **(d)** **No live count.** `clear()` (line 124) resets `currentBlock_ = blocks_.begin()` and the cursor, unconditionally; only large blocks are freed.
- **(e)** `void deallocate(void*, size_t = 0) { /* Deallocate? Never! */ }` (line 117). Literal no-op.

## 7. libstdc++ `std::pmr::monotonic_buffer_resource`

- **(a)** Flat: `void* _M_current_buf`, `size_t _M_avail`, `size_t _M_next_bufsiz` (include/std/memory_resource:461-463). `do_allocate` (line 416) is `std::align(...)` then `_M_current_buf += __bytes; _M_avail -= __bytes;`.
- **(b)** **In-band header at the END of each chunk** — confirmed. `src/c++17/memory_resource.cc:230` `class _Chunk`, and `_Chunk::allocate` at line 260: `void* const __back = (char*)__p + __size - sizeof(_Chunk); __head = ::new(__back) _Chunk(...)`. Fields are `aligned_size<64> _M_size; _Chunk* _M_next;` (lines 288-289). The comment at 226-229 says so explicitly: *"placed at end of the block."* Payload returned is `{__p, __size - sizeof(_Chunk)}`.
- **(c)** Prepend only. `_M_new_buffer` (memory_resource.cc:292) allocates `max(bytes, _M_next_bufsiz)`, pushes onto `_M_head`, and grows `_M_next_bufsiz *= 1.5`. The `_M_next` chain is walked only in `_Chunk::release` (line 267).
- **(d)** No live count. `release()` (memory_resource:391) frees all chunks and restores the original buffer, unconditionally.
- **(e)** `do_deallocate(void*, size_t, size_t) override { }` (memory_resource:433). No-op.

## 8. mtrebi/memory-allocators

**Correction to the premise in the brief**: on current `master`, `StackAllocator` does **not** use in-band allocation headers. `StackAllocator.h:9-12` is `void* m_start_ptr; size_t m_offset; std::vector<size_t> m_markers; std::vector<size_t> m_checkpoints;` — the per-allocation metadata is an **out-of-band side vector of offsets**. `Free` (StackAllocator.cpp:54-59) asserts LIFO and pops `m_markers.back()` into `m_offset`. I did not check the repo history, so whether an `AllocationHeader` version existed earlier is **not verified**.

`LinearAllocator` (LinearAllocator.h:8-9): `void* m_start_ptr; size_t m_offset;` — flat cursor, single block, no per-block metadata, no live count. `Free(void*)` is `assert(false && "Use Reset() method")` (LinearAllocator.cpp:55-57); `Reset()` zeroes `m_offset` (line 59).

## 9. HotSpot TLAB — `gc/shared/threadLocalAllocBuffer.{hpp,cpp,inline.hpp}`

- **(a) Flat, and flat *on the thread object***. `ThreadLocalAllocBuffer _tlab;` is a by-value member of `Thread` (`runtime/thread.hpp:258`), and the TLAB's own fields are flat: `HeapWord* _start; HeapWord* _top; HeapWord* _pf_top; HeapWord* _end; HeapWord* _allocation_end;` (threadLocalAllocBuffer.hpp:48-52), plus `size_t _desired_size` (54) and `size_t _refill_waste_limit` (59). Fast path (`.inline.hpp:38-52`): `obj = top(); if (pointer_delta(end(), obj) >= size) { set_top(obj + size); return obj; }`.
- **JIT-inlined fast path**: the C2 expansion is `BarrierSetC2::obj_allocate` (`gc/shared/c2/barrierSetC2.cpp:757`), which builds the address nodes from **constant byte offsets off the thread pointer** — `JavaThread::tlab_top_offset()` and `JavaThread::tlab_end_offset()` (lines 764-765), with the bump written back via `StorePNode` to `tlab_top_adr` (line 810). Those offsets are `byte_offset_of(Thread, _tlab) + ThreadLocalAllocBuffer::top_offset()` (thread.hpp:584-587, feeding hpp:185-188). This is exactly the "flat so the JIT can address it as a constant offset" property. I did not read the C1 path — **not verified**.
- **(b)** No per-block metadata structure. A TLAB *is* the metadata; there is one per thread.
- **(c)** **Refill from a shared source, not a scan.** `memAllocator.cpp:276-299`: if `tlab.free() > tlab.refill_waste_limit()` the TLAB is *retained* and the object goes to shared space (`record_slow_allocation`, line 277); otherwise `record_refill_waste()` (284), `_thread->retire_tlab()` (287), `compute_size` (290), `Universe::heap()->allocate_new_tlab(min_tlab_size, new_tlab_size, ...)` (299).
- **(d)** **No live count — the opposite design.** `retire()` (threadLocalAllocBuffer.cpp:145-155) calls `insert_filler()` → `Universe::heap()->fill_with_dummy_object(top(), hard_end(), true)` (line 134) and then `initialize(nullptr,nullptr,nullptr)`. The buffer is abandoned to the heap while objects in it are still live; the GC, not the allocator, decides their fate. The filler exists purely to keep the region *parsable*.
- **Adaptive sizing**: `resize()` (threadLocalAllocBuffer.cpp:161-186) computes `new_size = (alloc_fraction * tlab_capacity) / _target_num_refills`, clamps to `[min_size(), max_size()]`, and `set_desired_size(...)`. Also `compute_size` (.inline.hpp:54+) boosts up to 16x when `_num_refills > _target_num_refills`.
- **(e)** Not needed — there is no free. Reclamation is by GC.

## 10. G1 region metadata — `gc/g1/g1HeapRegion*.hpp`, `g1BiasedArray.hpp`

- **(a)** Per-region cursor is in the region object: `Atomic<HeapWord*> _top`, with `HeapWord* const _bottom; HeapWord* const _end;` (g1HeapRegion.hpp:74-78). Not flat in a global allocator — G1's *thread* fast path is the TLAB above.
- **(b)** **Array indexed by region id — but an array of pointers.** `class G1HeapRegionTable : public G1BiasedMappedArray<G1HeapRegion*>` (g1HeapRegionManager.hpp:42), member `G1HeapRegionTable _regions` (line 124). `G1HeapRegion : public CHeapObj<mtGC>` (g1HeapRegion.hpp:71) — each region's metadata is a **separately heap-allocated C++ object**, and the id-indexed table holds `G1HeapRegion*`, not inline structs. `at(uint index)` is `_regions.get_by_index(index)` (g1HeapRegionManager.inline.hpp:46-48). The id is stored in the metadata too: `const uint _hrm_index` (g1HeapRegion.hpp:203). The comment at g1HeapRegionManager.hpp:53-57 states regions are kept in address order, index *i* ↔ the *i*-th region.
- **(c)** Free list / contiguous scan, not a walk: `find_contiguous_in_free_list`, `find_contiguous_in_range`, `find_contiguous_allow_expand` (g1HeapRegionManager.hpp:100-106).
- **(d)** **Two separate per-region counters, and a real pinned state.** `used()` is `byte_size(bottom(), top())` (g1HeapRegion.hpp:119) — a bump-derived byte count, not a live count. Liveness is `live_bytes() = used() - garbage_bytes()` (line 330) with `Atomic<size_t> _garbage_bytes` (238) filled in by marking. Separately, `Atomic<size_t> _pinned_object_count` (line 253) with `has_pinned_objects()` (398) and `add_pinned_object_count()` (300) — that is an actual live/pin counter, incremented for JNI-critical objects.
- **What happens to a region with live objects**: it is **relocated, not skipped**. `G1ParScanThreadState::do_copy_to_survivor_space` (g1ParScanThreadState.cpp:470) copies each live object out; the region is then reclaimed wholesale. A region that *is* pinned is treated as an evacuation failure and kept in place: g1ParScanThreadState.cpp:490-491 `if (region_attr.is_pinned() && klass->is_typeArray_klass()) return handle_evacuation_failure_par(..., true /* cause_pinned */)`, and g1YoungCollector.cpp:640-641 records every pinned region in the collection set as evac-failed. Humongous regions with pinned objects are excluded from collection outright (g1YoungCollector.cpp:300-301).
- **(e)** **Shift arithmetic on the address, id not stored in the object.** `G1CollectedHeap::addr_to_region` (g1CollectedHeap.inline.hpp:127-131): `(uint)(pointer_delta(addr, reserved().start(), 1) >> G1HeapRegion::LogOfHRGrainBytes)`, then `region_at(idx)` → `_hrm.at(idx)`. The biased variant avoids even the subtraction: `G1BiasedMappedArray::get_by_address` (g1BiasedArray.hpp:130-133) is `*biased_base_at((uintptr_t)value >> shift_by())`, using a pre-biased base (`_biased_base = base - bias*elem_size`, line 52).

---

# Synthesis

**Per-block live count — only 3 of 10 keep one, and they are the closest precedents.** mimalloc `mi_page_t::used` (types.h:341), TigerBeetle `Message::references` (message_pool.zig:135), G1 `_pinned_object_count` / `_garbage_bytes` (g1HeapRegion.hpp:238,253). The five classic arenas (Zig arena, Zig FBA, protobuf, folly, pmr) keep **zero** liveness state — their contract is "reset discards everything, caller guarantees nothing is live." That contract is precisely what your design is *not* taking, so those five inform layout but not policy.

**Metadata layout.** Array-indexed-by-block-id: mimalloc (`segment->slices[idx]`, in-band at segment head, id derived by shift) and G1 (`_regions`, id-indexed, but holding *pointers* to separately-allocated `G1HeapRegion` objects). Parallel side arrays: TigerBeetle (`messages[]` + `buffers[]`). In-band header at block **start**: Zig arena `BufNode`, protobuf `ArenaBlock`, folly `Block`. In-band header at block **end**: libstdc++ `_Chunk` (verified, memory_resource.cc:260). Out-of-band side vector: mtrebi `StackAllocator::m_markers`.

**Flat hot cursor — near-universal.** protobuf (`ptr_`/`limit_` with the explicit comment *"We keep these here to reduce indirection"*, serial_arena.h:415-417), folly (`ptr_`/`end_`), pmr (`_M_current_buf`/`_M_avail`), Zig FBA (`end_index`/`buffer`), HotSpot TLAB (`_start`/`_top`/`_end` flat in a by-value member of `Thread`). The one that does **not** is Zig's arena: it keeps `end_index` flat but re-derives the limit from the block header on every allocation. Your "cursor/limit flat, block id separate" split is the majority design.

**Finding the next block.** Prepend-and-forget: Zig arena, protobuf, pmr (old blocks never revisited). Forward iterator over a reusable list: folly (`currentBlock_++`, Arena.h:102). List walk with a full-page eviction queue: mimalloc (`mi_page_queue_find_free_ex`). Array/free-list search: G1. Refill from a shared source: HotSpot TLAB. Nobody uses a bitmask scan — that part of your design has no precedent in this set, but 8 blocks fits in a byte, so the cost question is different from all of these.

**Closest precedent: mimalloc.** It is the only one with all four of your properties. `uint16_t used` (types.h:341) is the per-block live count; `mi_page_all_free(page) { return page->used == 0; }` (internal.h:674-677) is the reset-only-when-empty gate; `if (mi_page_all_free(page)) { _mi_page_free(...) } else { _mi_page_abandon(page, pq); }` (page.c:454-459) is exactly "a block with live > 0 is pinned and skipped"; and `mi_slice_t slices[MI_SLICES_PER_SEGMENT+1]` (types.h:504) indexed by `idx = (p - segment) >> MI_SEGMENT_SLICE_SHIFT` (internal.h:585-590) is the metadata-array-indexed-by-block-id. One design detail worth stealing: `_mi_page_retire` (page.c:493-512) refuses to release an empty page when `pq->last==page && pq->first==page`, setting `retire_expire` instead — the "keep one block" hysteresis you already landed for chunks. **Second-closest: TigerBeetle**, for the *Java-shaped* reason — `messages: []Message` + `buffers: []...` is the parallel-array split you are proposing, with `references: u32` as the live count and `unref_base` returning to the free list only at zero (message_pool.zig:288-297).

**TLABs: what you share, what you don't.** Shared: a flat cursor in per-thread state refilled from a shared source, with the cursor laid out at a fixed offset specifically so the fast path can address it as a constant — C2 emits the bump from `JavaThread::tlab_top_offset()`/`tlab_end_offset()` (barrierSetC2.cpp:764-765,810), and that is the strongest argument for your "cursor/limit flat in the allocator struct" decision. Also shared: adaptive sizing driven by refill frequency (`resize()`, threadLocalAllocBuffer.cpp:161; the 16x boost in `compute_size`), and a retain-vs-discard threshold (`tlab.free() > tlab.refill_waste_limit()`, memAllocator.cpp:276) rather than always discarding. What differs: a TLAB has **no free operation and no live count** — `retire()` writes a dummy filler over the tail and hands the buffer back (threadLocalAllocBuffer.cpp:131-137,145), because a tracing collector will later find the live objects and, in G1, **relocate** them (`do_copy_to_survivor_space`, g1ParScanThreadState.cpp:470). You cannot relocate; a Java `ByteBuf`'s address is visible to the caller. So the live count and the pinned-block state are doing the job relocation does for the JVM, and the only JVM-side analogue to your pinned block is G1's pinned region — which the collector also cannot move and therefore also just leaves alone (g1YoungCollector.cpp:640-641).

**One caveat on your design worth flagging:** every allocator here that survives a "block still has live objects" situation reaches it via a *pointer* the holder already has (mimalloc's `mi_page_t*`, TigerBeetle's `*Message`) or via derived arithmetic (mimalloc's shift). Storing an `int block id` in the buffer is a third option none of these use, because in C/Zig the pointer is free. In Java it is the right call — but no source here validates it, so the id-vs-reference cost is yours to measure, not something I can cite.