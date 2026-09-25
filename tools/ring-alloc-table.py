#!/usr/bin/env python3
"""Reduce one ring-allocator e2e sweep (ring-alloc-e2e.sh output) to a markdown table.

usage: ring-alloc-table.py <results-dir> [h1|h2 ...]

For every cell it takes req/s and the latency line out of the h2load log, RSS out of the sampler,
the young-GC count out of the -Xlog:gc file, the RINGTELE / SLABTELE / SLAB2TELE / BUFRINGTELE /
ARENATELE counters out of the server log, and the filter B / C / D shares out of the collapsed
async-profiler file with the same tag (filters are defined in tools/asprof-alloc-share.py and are
imported from it, so the two tools can never disagree).
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from importlib import import_module
share = import_module('asprof-alloc-share'.replace('-', '_')) if False else None
# the module name has dashes, so load it by path
import importlib.util
spec = importlib.util.spec_from_file_location('share', os.path.join(HERE, 'asprof-alloc-share.py'))
share = importlib.util.module_from_spec(spec)
spec.loader.exec_module(share)

ORDER = ['adaptive', 'builtinadaptive', 'slab', 'slab2fixed', 'slab2', 'slab3fixed', 'slab3',
         'slab3huge', 'arena-ringfalse', 'arena-ringtrue']


def num(path, pattern, cast=float, default=None):
    try:
        with open(path, errors='replace') as f:
            m = re.search(pattern, f.read(), re.M)
    except OSError:
        return default
    return cast(m.group(1)) if m else default


def line(path, prefix):
    try:
        with open(path, errors='replace') as f:
            for l in f:
                if l.startswith(prefix):
                    return l.rstrip('\n')
    except OSError:
        pass
    return ''


def field(s, key, cast=str):
    m = re.search(r'\b' + re.escape(key) + r'=(\S+)', s)
    return cast(m.group(1)) if m else None


def rss(path):
    try:
        vals = [int(l.split()[1]) for l in open(path) if len(l.split()) == 2 and l.split()[1].isdigit()]
    except OSError:
        return None
    return max(vals) // 1024 if vals else None


def cell(d, proto, tag):
    base = os.path.join(d, 'io_uring-%s-adaptive-ra-%s' % (proto, tag))
    out = {'tag': tag, 'proto': proto}
    out['rps'] = num(base + '.h2load', r'^finished in [^,]*, ([0-9.]+) req/s')
    out['lat'] = num(base + '.h2load', r'^time for request: +(\S+)', str)
    out['codes'] = num(base + '.h2load', r'status codes: (\d+) 2xx', int)
    out['fail'] = num(base + '.h2load', r'(\d+) failed, \d+ errored', int)
    out['rss'] = rss(base + '.rss')
    try:
        out['gc'] = sum(1 for l in open(base + '.gc') if 'Pause Young' in l)
    except OSError:
        out['gc'] = None
    srv = base + '.server.log'
    out['ring'] = line(srv, 'RINGTELE')
    out['thp'] = line(srv, 'THPTELE')
    out['bufring'] = line(srv, 'BUFRINGTELE')
    out['arena'] = line(srv, 'ARENATELE')
    coll = base + '.collapsed'
    if os.path.exists(coll):
        total, counts = share.measure(coll)
        out['shares'] = {k: (100.0 * v[1] / v[0] if v[0] else float('nan')) for k, v in counts.items()}
        out['loopsamples'] = counts['B narrow'][0]
    else:
        out['shares'] = {}
        out['loopsamples'] = None
    return out


def main(argv):
    if not argv:
        print(__doc__)
        return 1
    d = argv[0]
    protos = argv[1:] or ['h1', 'h2']
    for proto in protos:
        rows = [cell(d, proto, t) for t in ORDER]
        rows = [r for r in rows if r['rps'] is not None]
        if not rows:
            continue
        print('### e2e %s' % proto)
        print('| ring served by | req/s | mean lat | RSS max | young GC | B | C ring-alloc | D ring-total '
              '| ringAllocs | ringReads |')
        print('|---|---|---|---|---|---|---|---|---|---|')
        for r in rows:
            s = r['shares']
            print('| %s | %s | %s | %s MB | %s | %s | %s | %s | %s | %s |' % (
                r['tag'],
                '{:,.0f}'.format(r['rps']),
                r['lat'] or '-',
                r['rss'],
                r['gc'],
                '%.2f%%' % s['B narrow'] if s else '-',
                '%.2f%%' % s['C ringalloc'] if s else '-',
                '%.2f%%' % s['D ringtotal'] if s else '-',
                '{:,}'.format(int(field(r['ring'], 'ringAllocs', int) or 0)),
                '{:,}'.format(int(field(r['ring'], 'ringReads', int) or 0))))
        print()
        for r in rows:
            print('%-16s %s' % (r['tag'], r['ring']))
            for k in ('thp', 'bufring', 'arena'):
                if r[k]:
                    print('%-16s %s' % ('', r[k]))
            print('%-16s h2load: %s 2xx, %s failed, loop samples %s' % ('', r['codes'], r['fail'],
                                                                       r['loopsamples']))
        print()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
