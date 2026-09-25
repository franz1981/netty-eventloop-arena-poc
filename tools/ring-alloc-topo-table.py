#!/usr/bin/env python3
"""Reduce one ring-allocator topology sweep (ring-alloc-topology.sh output) to a markdown table.

usage: ring-alloc-topo-table.py <results-dir> [w1 w3 w5]

Per cell: req/s from the h2load log, the ring counters from the server log, and from the JFR
reduction (topology.py's .txt) the two lines that say what the GENERAL allocator's buffers did -
"released on the allocating thread" and the lifetime-in-iterations percentiles.  Note what the JFR
events can and cannot see: they are netty buffer events, so the slab's own slots never appear in them
(a SlabBuf is an UnpooledUnsafeDirectByteBuf the allocator recycles itself).  The slab's in-flight
behaviour is in SLAB2TELE's lifeSeq/occupancy instead.
"""
import os
import re
import sys

ORDER = ['adaptive', 'builtinadaptive', 'slab', 'slab2fixed', 'slab2', 'slab3fixed', 'slab3',
         'slab3huge', 'arena-ringfalse', 'arena-ringtrue']


def grab(path, pattern, cast=str, default=None):
    try:
        m = re.search(pattern, open(path, errors='replace').read(), re.M)
    except OSError:
        return default
    return cast(m.group(1)) if m else default


def lines(path, prefix):
    try:
        return [l.rstrip('\n') for l in open(path, errors='replace') if l.startswith(prefix)]
    except OSError:
        return []


def field(s, key, cast=str):
    m = re.search(r'\b' + re.escape(key) + r'=(\S+)', s or '')
    return cast(m.group(1)) if m else None


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    d = argv[0]
    workloads = argv[1:] or ['w1', 'w3', 'w5']
    for w in workloads:
        rows = []
        for tag in ORDER:
            base = os.path.join(d, '%s-io_uring-adaptive-ra-%s' % (w, tag))
            rps = grab(base + '-load.log', r'^finished in [^,]*, ([0-9.]+) req/s', float)
            if rps is None:
                continue
            srv = base + '-server.log'
            ring = (lines(srv, 'RINGTELE') or [''])[0]
            s2 = (lines(srv, 'RINGTELE') or [''])[0]
            rows.append({
                'tag': tag, 'rps': rps,
                'ringAllocs': field(ring, 'ringAllocs', int),
                'ringReads': field(ring, 'ringReads', int),
                'readBytes': field(ring, 'ringReadBytes', int),
                'fallbacks': field(ring, 'slabFallbacks', int) if 'slabFallbacks' in ring
                             else field(ring, 'fallbacks', int),
                'exhaustions': field(ring, 'exhaustions', int),
                'reprovSize': field(ring, 'reprovSize', int),
                'reprovGrow': field(ring, 'reprovGrow', int),
                'slots': field(ring, 'finalSlots'),
                'maxInFlight': field(ring, 'maxInFlight', int),
                'foreign': field(ring, 'foreignReleases', int) if 'foreignReleases' in ring
                           else field(ring, 'slabForeignReleases', int),
                'thp': field((lines(srv, 'THPTELE') or [''])[0], 'anonHugePagesKb', int),
                'crossthread': grab(base + '.txt', r'released on the allocating thread: ([0-9.]+)%'),
                'iters': grab(base + '.txt', r'(iters p50=\S+ p90=\S+ p99=\S+ p99\.9=\S+ max=\S+)'),
                'sizes': grab(base + '.txt', r'^     (8192=.*|4096=.*|65536=.*|262144=.*)$'),
                'ring_line': ring,
            })
        if not rows:
            continue
        print('### topology %s' % w)
        print('| ring served by | req/s | MB/s read | ringAllocs | ringReads | fallbacks | exhaust | '
              'reprov size/grow | slots | maxInFlight | foreign rel | AnonHugePages kB |')
        print('|---|---|---|---|---|---|---|---|---|---|---|---|')
        for r in rows:
            mb = (r['readBytes'] or 0) / 1e6 / 8.0
            print('| %s | %s | %.0f | %s | %s | %s | %s | %s | %s | %s | %s | %s |' % (
                r['tag'], '{:,.0f}'.format(r['rps']), mb,
                '{:,}'.format(r['ringAllocs'] or 0), '{:,}'.format(r['ringReads'] or 0),
                r['fallbacks'] if r['fallbacks'] is not None else '-',
                r['exhaustions'] if r['exhaustions'] is not None else '-',
                '%s/%s' % (r['reprovSize'], r['reprovGrow']) if r['reprovSize'] is not None else '-',
                (r['slots'] or '-').split('/')[0] + ('...' if r['slots'] and '/' in r['slots'] else ''),
                r['maxInFlight'] if r['maxInFlight'] is not None else '-',
                r['foreign'] if r['foreign'] is not None else '-',
                r['thp']))
        print()
        for r in rows:
            print('%-16s %s' % (r['tag'], r['ring_line']))
            print('%-16s JFR: same-thread release %s%%  %s' % ('', r['crossthread'], r['iters']))
        print()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
