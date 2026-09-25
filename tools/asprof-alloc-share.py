#!/usr/bin/env python3
"""Allocator share of event-loop CPU samples in an async-profiler collapsed file.

usage: asprof-alloc-share.py <file.collapsed> [<file.collapsed> ...]

A collapsed line is "frame;frame;...;frame <samples>".  Two filters are applied to every line and
both are reported, because they do not give the same number and the difference is the point:

  A ("wide", the one used for the arena-v3 e2e report, 2026-09-22)
      loop      = stack contains NioEventLoop.run  OR  SingleThreadEventExecutor
      allocator = loop stack also contains CycleArena | AdaptivePoolingAllocator | SizeClass
                  | Recycler | AbstractReferenceCountedByteBuf | AbstractByteBufAllocator
  B ("narrow", the cross-check filter)
      loop      = stack contains SingleThreadIoEventLoop.run
      allocator = loop stack also contains AdaptivePoolingAllocator | AdaptiveByteBufAllocator
                  | CycleArenaAllocator | ArenaBuf
  C ("ring-alloc", added 2026-09-25 for RESULTS.md section 7)
      loop      = stack contains SingleThreadIoEventLoop.run
      allocator = loop stack also contains a frame of a class that IS the provided-buffer-ring
                  allocator: RegisteredSlabBufferRingAllocator | SlabV2BufferRingAllocator (and its
                  SlabBuf wrapper) | AbstractIoUringBufferRingAllocator |
                  IoUringFixedBufferRingAllocator | IoUringAdaptiveBufferRingAllocator |
                  AdaptiveCalculator | FixedSizeRingAllocator | CountingRingAllocator.
                  NOTE what this does NOT match: the general-purpose allocator BEHIND candidates R0/R1
                  (AdaptivePoolingAllocator's own frames are filter B's) and IoUringBufferRing itself.
                  So C is "the ring allocator's own code", and for R0/R1 most of the work is in B, not C.
  D ("ring-total")
      loop      = stack contains SingleThreadIoEventLoop.run
      allocator = C, plus IoUringBufferRing (fill / add / useBuffer / expand), plus the slice object
                  the ring hands the pipeline (UnpooledSlicedByteBuf / AbstractUnpooledSlicedByteBuf),
                  plus the general allocator frames of filter B.  D is "everything the provided
                  buffer ring's own buffer handling costs on the loop", which is the number a
                  candidate has to reduce; C is the part that is the candidate's own code.

Share = allocator samples / loop samples.  No filter is "right": A counts the recycler and the
reference-count helpers as allocator work and accepts any single-thread executor as a loop, B counts
only frames of the two allocator classes on an IO event loop, C sees only the ring allocator's own
frames and D adds the ring machinery around it.
"""
import re
import sys

FILTERS = {
    'A wide': (
        re.compile(r'NioEventLoop\.run|SingleThreadEventExecutor'),
        re.compile(r'CycleArena|AdaptivePoolingAllocator|SizeClass|Recycler'
                   r'|AbstractReferenceCountedByteBuf|AbstractByteBufAllocator'),
    ),
    'B narrow': (
        re.compile(r'SingleThreadIoEventLoop\.run'),
        re.compile(r'AdaptivePoolingAllocator|AdaptiveByteBufAllocator|CycleArenaAllocator|ArenaBuf'),
    ),
    'C ringalloc': (
        re.compile(r'SingleThreadIoEventLoop\.run'),
        re.compile(r'RegisteredSlabBufferRingAllocator|SlabV2BufferRingAllocator|SlabBuf'
                   r'|AbstractIoUringBufferRingAllocator|IoUringFixedBufferRingAllocator'
                   r'|IoUringAdaptiveBufferRingAllocator|AdaptiveCalculator'
                   r'|FixedSizeRingAllocator|CountingRingAllocator'),
    ),
    'D ringtotal': (
        re.compile(r'SingleThreadIoEventLoop\.run'),
        re.compile(r'RegisteredSlabBufferRingAllocator|SlabV2BufferRingAllocator|SlabBuf'
                   r'|AbstractIoUringBufferRingAllocator|IoUringFixedBufferRingAllocator'
                   r'|IoUringAdaptiveBufferRingAllocator|AdaptiveCalculator'
                   r'|FixedSizeRingAllocator|CountingRingAllocator'
                   r'|IoUringBufferRing|UnpooledSlicedByteBuf|AbstractUnpooledSlicedByteBuf'
                   r'|AdaptivePoolingAllocator|AdaptiveByteBufAllocator|CycleArenaAllocator|ArenaBuf'),
    ),
}


def measure(path):
    counts = {}
    total = 0
    for name in FILTERS:
        counts[name] = [0, 0]           # loop samples, allocator samples
    with open(path, errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            cut = line.rfind(' ')
            if cut < 0:
                continue
            stack, n = line[:cut], line[cut + 1:]
            try:
                n = int(n)
            except ValueError:
                continue
            total += n
            for name, (loop_re, alloc_re) in FILTERS.items():
                if loop_re.search(stack):
                    counts[name][0] += n
                    if alloc_re.search(stack):
                        counts[name][1] += n
    return total, counts


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    for name, (loop_re, alloc_re) in FILTERS.items():
        print("filter %-9s loop=/%s/" % (name, loop_re.pattern))
        print("%-17s allocator=/%s/" % ('', alloc_re.pattern))
    print()
    print("%-34s %8s %10s %10s %8s" % ("file", "total", "loop", "allocator", "share"))
    for path in argv:
        total, counts = measure(path)
        for name in FILTERS:
            loop, alloc = counts[name]
            share = (100.0 * alloc / loop) if loop else float('nan')
            print("%-34s %8d %10d %10d %7.2f%%  [%s]"
                  % (path.split('/')[-1], total, loop, alloc, share, name))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
