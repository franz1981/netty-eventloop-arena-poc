#!/usr/bin/env python3
"""Break an async-profiler collapsed CPU profile into event-loop components.

Usage: asprof-loop-breakdown.py file.collapsed [file2.collapsed ...]
Denominator: samples whose stack contains SingleThreadIoEventLoop.run.
Classification is by PRIORITY of regexes over the whole stack (first match wins), so a sample with both a
socket write frame and an allocator frame counts as 'socket write'. 'allocator inclusive' is reported separately:
any loop stack containing an allocator frame, regardless of the other categories.
Written 2026-09-22 for the profiles in results/<machine>/arena-v3/e2e; NIO transport frame names.
"""
import re, sys, collections
ALLOC = r'AdaptivePoolingAllocator|AdaptiveByteBufAllocator|CycleArenaAllocator|ArenaBuf'
RULES = [
    ('select/epoll_wait', r'epoll_wait|epoll_pwait|EPollSelectorImpl.doSelect|SelectorImpl.select'),
    ('socket read (syscall incl.)', r'SocketDispatcher.read|SocketChannelImpl.read|IOUtil.read|recvmsg|tcp_recvmsg|readAddress'),
    ('socket write (syscall incl.)', r'SocketDispatcher.write|SocketChannelImpl.write|IOUtil.write|sendmsg|tcp_sendmsg|writev|writeAddress'),
    ('allocator', ALLOC),
    ('http2 codec', r'codec/http2|codec\.http2'),
    ('http1 codec', r'codec/http|codec\.http'),
    ('user handler', r'E2EServer'),
]
def cls(s):
    if 'SingleThreadIoEventLoop.run' not in s: return 'non-loop'
    for name, rx in RULES:
        if re.search(rx, s): return name
    return 'loop other (pipeline, channel, tasks)'
for f in sys.argv[1:]:
    by = collections.Counter(); leaf = collections.defaultdict(collections.Counter); alloc = 0; tot = 0
    for line in open(f):
        line = line.rstrip('\n'); i = line.rfind(' '); s = line[:i]; c = int(line[i+1:]); tot += c
        k = cls(s); by[k] += c; leaf[k][s.rsplit(';', 1)[-1].split('/')[-1][:48]] += c
        if k != 'non-loop' and re.search(ALLOC, s): alloc += c
    loop = tot - by['non-loop']
    print(f"{f}: total={tot} loop={loop}")
    for k, v in sorted(by.items(), key=lambda x: -x[1]):
        if k == 'non-loop': continue
        top = ', '.join(f"{n} {c}" for n, c in leaf[k].most_common(2))
        print(f"   {k:38s} {v:6d} {100*v/loop:5.1f}%   top leaves: {top}")
    print(f"   allocator inclusive (any loop stack)   {alloc:6d} {100*alloc/loop:5.2f}%")
