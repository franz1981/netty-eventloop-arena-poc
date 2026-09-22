#!/usr/bin/env python3
"""Cross-workload summary tables, built from the same TSVs as topology.py."""
import os, sys, re, collections
import topology as T

def headline(q):
    if q['it'] == 0:
        return 'i-same-iter-LIFO' if q['nest'] in ('youngest', 'only') else 'ii-same-iter-out-of-order'
    if q['cause'] == 'write-completion': return 'iii-cross-iter-write-completion'
    if q['cause'] in ('decoder/cumulation', 'aggregator'): return 'iv-cross-iter-cumulation/aggregation'
    if q['cause'] == 'h2-flow-control': return 'v-cross-iter-h2-flow-control'
    return 'vi-cross-iter-other'

_labels = 'labels.txt' if os.path.exists('labels.txt') \
          else os.path.join(os.path.dirname(os.path.abspath(__file__)), 'labels.txt')
WL = [l.strip().split('|') for l in open(_labels) if l.strip()]
rows = []
for w, lab in WL:
    recs = [e for e in T.read_tsv(w + '.tsv')]
    for i, e in enumerate(recs): e['i'] = i
    recs.sort(key=lambda e: (e['t'], e['i']))
    c = T.core(recs)
    pairs = c['pairs']; n = len(pairs)
    els = [t for t in c['itc'] if c['itc'][t] > 0]
    alll = [v for t in els for v in c['liveAtIter'][t]]
    allpa = [v for t in els for v in c['perIterAllocs'][t]]
    span_ns = recs[-1]['t'] - recs[0]['t']
    xp = [q for q in pairs if q['it'] > 0]
    wall = sorted(q['ns'] for q in pairs)
    qf = lambda a, pp: a[min(len(a) - 1, int(pp * len(a)))] / 1e3
    rows.append({
        'w': w, 'lab': lab, 'n': n,
        'hist': collections.Counter(T.bucket_iter(q['it']) for q in pairs),
        'nest': collections.Counter(q['nest'] for q in pairs),
        'cause': collections.Counter(q['cause'] for q in pairs),
        'head': collections.Counter(headline(q) for q in pairs),
        'xthread': sum(1 for q in pairs if not q['same']),
        'bytes': sum(q['sz'] for q in pairs),
        'xbytes': sum(q['sz'] for q in xp),
        'avgLive': sum(alll) / len(alll) if alll else 0.0,
        'maxLive': max(alll) if alll else 0,
        'allocPerIter': sum(allpa) / len(allpa) if allpa else 0.0,
        'itPerSecPerThread': (len(alll) / len(els)) / (span_ns / 1e9) if els and span_ns else 0.0,
        'wall': [qf(wall, .5), qf(wall, .9), qf(wall, .99), qf(wall, .999), wall[-1] / 1e3],
    })

def p(c, n): return 100.0 * c / n if n else 0.0
hdr = '%-5s %9s %8s %8s %8s %8s %8s %8s' % ('wl', 'pairs', '0', '1', '2-3', '4-7', '8+', 'x-thread')
print('LIFETIME IN EVENT-LOOP ITERATIONS (share of paired buffers)')
print(hdr)
for r in rows:
    n = r['n']; h = r['hist']
    print('%-5s %9d %7.2f%% %7.2f%% %7.2f%% %7.2f%% %7.2f%% %7.2f%%'
          % (r['w'], n, p(h['0'], n), p(h['1'], n), p(h['2-3'], n), p(h['4-7'], n), p(h['8+'], n), p(r['xthread'], n)))
print()
print('NESTING CLASS AT RELEASE (share of paired buffers)')
print('%-5s %9s %9s %9s %9s' % ('wl', 'only', 'youngest', 'oldest', 'middle'))
for r in rows:
    n = r['n']; c = r['nest']
    print('%-5s %8.2f%% %8.2f%% %8.2f%% %8.2f%%' % (r['w'], p(c['only'], n), p(c['youngest'], n), p(c['oldest'], n), p(c['middle'], n)))
print()
allc = []
for r in rows:
    for k in r['cause']:
        if k not in allc: allc.append(k)
print('RELEASE CAUSE (share of paired buffers)')
print('%-5s %s' % ('wl', ' '.join('%18s' % c[:18] for c in allc)))
for r in rows:
    n = r['n']
    print('%-5s %s' % (r['w'], ' '.join('%17.2f%%' % p(r['cause'][c], n) for c in allc)))
print()
print('HEADLINE CLASSES (share of paired buffers)')
keys = ['i-same-iter-LIFO', 'ii-same-iter-out-of-order', 'iii-cross-iter-write-completion',
        'iv-cross-iter-cumulation/aggregation', 'v-cross-iter-h2-flow-control']
print('%-5s %s %9s' % ('wl', ' '.join('%10s' % k.split('-')[0] for k in keys), 'vi-other'))
for r in rows:
    n = r['n']; hc = r['head']
    other = n - sum(hc[k] for k in keys)
    print('%-5s %s %8.2f%%' % (r['w'], ' '.join('%9.2f%%' % p(hc[k], n) for k in keys), p(other, n)))
print()
print('BYTES AND OCCUPANCY')
print('%-5s %12s %12s %10s %9s %9s %9s %9s' % ('wl', 'MiB alloc', 'MiB crossing', '%bytes', 'avgLive', 'maxLive', 'alloc/it', 'it/s/thr'))
for r in rows:
    print('%-5s %12.1f %12.1f %9.2f%% %9.2f %9d %9.2f %9.0f'
          % (r['w'], r['bytes'] / 1048576.0, r['xbytes'] / 1048576.0,
             p(r['xbytes'], r['bytes']), r['avgLive'], r['maxLive'], r['allocPerIter'], r['itPerSecPerThread']))
print()
print('WALL-CLOCK LIFETIME (us)')
print('%-5s %10s %10s %10s %10s %12s' % ('wl', 'p50', 'p90', 'p99', 'p99.9', 'max'))
for r in rows:
    q = r['wall']
    print('%-5s %10.1f %10.1f %10.1f %10.1f %12.1f' % (r['w'], q[0], q[1], q[2], q[3], q[4]))
print()
for w, lab in WL:
    print('%-5s %s' % (w, lab))
