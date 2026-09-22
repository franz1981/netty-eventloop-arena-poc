#!/usr/bin/env python3
"""Print the tables for this PoC from JMH json (+ the matching .data for peak RSS).

    ./summarize.py out/                 # every json under out/
    ./summarize.py out/cycle.json results/<machine>/harness/*.json

CycleScopedAllocBenchmark: the score is one cycle of k buffers, so the per-buffer number is
score / k.  That division is the only arithmetic done here.
ByteBufAllocatorAllocPatternBenchmark: score is ns/op; peak RSS is read from the sibling .data
file, where the harness prints "cRSS-pRSS:[cur, peak]" once per iteration.  Peak RSS is reported
per fork AND as the maximum - a single "peak" number hides forks that disagree.
"""
import json, os, re, sys, glob

RSS = re.compile(r'cRSS-pRSS:\[\s*\d+\s*,\s*(\d+)\s*\]')


def num(v):
    """JMH writes "NaN" (a string) for scoreError when a single fork/iteration gives no spread."""
    try:
        return float(v)
    except (TypeError, ValueError):
        return float('nan')


def peak_rss(json_path):
    data = os.path.splitext(json_path)[0] + '.data'
    if not os.path.exists(data):
        return []
    with open(data, errors='replace') as f:
        return [int(m.group(1)) for m in RSS.finditer(f.read())]


def collect(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            files += sorted(glob.glob(os.path.join(p, '**', '*.json'), recursive=True))
        else:
            files += sorted(glob.glob(p))
    rows = []
    for f in files:
        try:
            with open(f) as fh:
                doc = json.load(fh)
        except (ValueError, OSError) as e:
            print('skipped %s: %s' % (f, e), file=sys.stderr)
            continue
        if not isinstance(doc, list):
            continue
        for b in doc:
            rows.append((f, b))
    return rows


def fmt(v, w, prec=1):
    return ('%*.*f' % (w, prec, v)) if v is not None else ' ' * w


def main(argv):
    rows = collect(argv or ['out'])
    if not rows:
        print('no JMH json found in: %s' % (argv or ['out'],))
        return 1

    cycle = [(f, b) for f, b in rows if 'CycleScopedAllocBenchmark' in b['benchmark']]
    harness = [(f, b) for f, b in rows if 'ByteBufAllocatorAllocPatternBenchmark' in b['benchmark']]
    other = [(f, b) for f, b in rows if (f, b) not in cycle and (f, b) not in harness]

    if cycle:
        print('== CycleScopedAllocBenchmark: allocate k, use, release all k ==')
        print('%-11s %-5s %-4s %-6s %-6s %8s %8s %7s %5s' %
              ('alloc', 'bench', 'k', 'order', 'sizes', 'ns/cycle', '+/-', 'ns/buf', 'forks'))
        def key(fb):
            p = fb[1]['params']
            return (fb[1]['benchmark'].split('.')[-1], p.get('sizes'), int(p.get('k', 0)),
                    p.get('releaseOrder'), p.get('allocatorType'))
        for f, b in sorted(cycle, key=key):
            p = b['params']; m = b['primaryMetric']
            k = int(p.get('k', 1)) or 1
            print('%-11s %-5s %-4s %-6s %-6s %8.1f %8.1f %7.1f %5d' % (
                p.get('allocatorType', '?'), b['benchmark'].split('.')[-1].replace('cycle', ''),
                k, p.get('releaseOrder', '?'), p.get('sizes', '?'),
                num(m['score']), num(m['scoreError']), num(m['score']) / k, b.get('forks', 0)))
        print()

    if harness:
        print('== ByteBufAllocatorAllocPatternBenchmark: steady-state live set ==')
        print('%-11s %-12s %-7s %-4s %-3s %8s %8s %5s  %s' %
              ('alloc', 'pattern', 'live', 'thr', 'rw', 'ns/op', '+/-', 'forks', 'peak RSS MB per fork'))
        print('   (system properties such as -Darena.maxBlocks are NOT in the json: the file name is'
              ' the only record of them)')
        def key(fb):
            p = fb[1]['params']
            return (p.get('sizePattern', ''), int(p.get('MAX_LIVE_BUFFERS', 0)),
                    fb[1].get('threads', 0), p.get('allocatorType', ''))
        for f, b in sorted(harness, key=key):
            p = b['params']; m = b['primaryMetric']
            rss = peak_rss(f)
            rss_s = ('max=%d  %s' % (max(rss), ' '.join(str(v) for v in rss))) if rss else '(no .data)'
            print('%-11s %-12s %-7s %-4d %-3s %8.1f %8.1f %5d  %s' % (
                p.get('allocatorType', '?'), p.get('sizePattern', '?'),
                p.get('MAX_LIVE_BUFFERS', '?'), b.get('threads', 0),
                str(p.get('enableReadWrite', '?'))[:1], num(m['score']), num(m['scoreError']),
                b.get('forks', 0), rss_s + '   [' + os.path.basename(f) + ']'))
        print()

    for f, b in other:
        print('%s: %s %.1f %s' % (os.path.basename(f), b['benchmark'].split('.')[-1],
                                  num(b['primaryMetric']['score']), b['primaryMetric']['scoreUnit']))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
