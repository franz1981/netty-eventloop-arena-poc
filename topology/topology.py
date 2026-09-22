#!/usr/bin/env python3
"""Pair io.netty.AllocateBuffer/FreeBuffer JFR events and classify the release topology
relative to netty.IterationEnd markers emitted at the end of every event loop iteration.

usage: topology.py <file.tsv> [label]
Input is the TSV produced by Dump.java from the .jfr (nanosecond timestamps).
"""
import sys, os, re, math, heapq, subprocess, collections

JFR = os.environ.get('JFR_BIN', 'jfr')
UNIT = {'bytes': 1, 'B': 1, 'kB': 1000, 'KB': 1024, 'MB': 1024 * 1024, 'GB': 1024 ** 3}

def parse_size(v):
    p = v.replace(',', '').split()
    return int(float(p[0]) * UNIT.get(p[1] if len(p) > 1 else 'bytes', 1))

PLUMBING = {'release', 'release0', 'deallocate', 'handleRelease', 'safeRelease',
             'releaseLater', 'touch', 'recycle', 'unguardedRecycle', 'free', 'freeIfNecessary'}

def read_tsv(path):
    """yield dicts in FILE order from the Dump.java TSV (nanosecond timestamps)."""
    with open(path, errors='replace') as f:
        for line in f:
            if line.startswith('#'):
                continue
            p = line.rstrip('\n').split('\t')
            if len(p) < 8:
                continue
            e = {'t': int(p[0]), 'k': p[1], 'th': p[2]}
            if p[1] == 'I':
                e['reads'] = int(p[5])
            else:
                e['a'] = int(p[3]); e['sz'] = int(p[4])
                if p[1] == 'R':
                    e['frames'] = ['io.netty.buffer.AdaptiveByteBuf.capacity']
                if p[1] == 'F':
                    e['trunc'] = p[6] == '1'
                    e['frames'] = [x for x in p[7].split('|') if x]
            yield e

CAUSE_RULES = [
    ('write-completion',   re.compile(r'ChannelOutboundBuffer')),
    ('h2-flow-control',    re.compile(r'Http2RemoteFlowController|StreamByteDistributor|Http2ConnectionHandler|Http2FrameCodec')),
    ('aggregator',         re.compile(r'MessageAggregator|HttpObjectAggregator')),
    ('decoder/cumulation', re.compile(r'ByteToMessageDecoder|CompositeByteBuf|Http\w*Decoder|HttpObjectDecoder|Http2FrameReader|DefaultHttp2FrameReader')),
    ('codec-encoder',      re.compile(r'\w*Encoder')),
    ('realloc-grow',       re.compile(r'AdaptiveByteBuf\.capacity')),
    ('read-path',          re.compile(r'AbstractNioByteChannel|NioSocketChannel|AbstractChannel|NioIoHandler|AdaptiveRecvByteBufAllocator')),
    ('handler',            re.compile(r'TopoServer|HttpSnoopServerHandler|SimpleChannelInboundHandler|ChannelInboundHandlerAdapter|DefaultChannelPipeline|Http2MultiplexHandler|AbstractHttp2StreamChannel|DefaultHttp2Connection')),
]

RETAINER_RULES = [                       # unambiguous holders: match anywhere in the chain
    ('aggregator',        re.compile(r'MessageAggregator|HttpObjectAggregator')),
    ('h2-flow-control',   re.compile(r'Http2RemoteFlowController|StreamByteDistributor|FlowControlledData')),
    ('write-completion',  re.compile(r'ChannelOutboundBuffer')),
]

def classify(frames):
    if not frames:
        return ('other:no-site', '(no stack)')
    joined = '|'.join(frames)
    for name, rx in RETAINER_RULES:
        if rx.search(joined):
            for f in frames:
                if rx.search(f):
                    return (name, f)
    site = None
    for f in frames:
        if f.rsplit('.', 1)[-1] in PLUMBING:
            continue
        site = f
        break
    if site is None:
        return ('other:no-site', frames[0])
    for name, rx in CAUSE_RULES:
        if rx.search(site):
            return (name, site)
    return ('other:' + site, site)

def bucket_iter(n):
    if n == 0: return '0'
    if n == 1: return '1'
    if n <= 3: return '2-3'
    if n <= 7: return '4-7'
    return '8+'

def sizeb(sz):
    if sz <= 0: return '0'
    return '%d' % (1 << (sz - 1).bit_length())

def pct(c, n): return 100.0 * c / n if n else 0.0

def core(recs):
    live = {}                                   # address -> record
    liveByThread = collections.defaultdict(dict)   # thread -> {seq: addr}
    maxh = collections.defaultdict(list); minh = collections.defaultdict(list)
    seqc = collections.Counter()                # thread -> allocation seq
    itc = collections.Counter()                 # thread -> IterationEnd count
    ritc = collections.Counter()                # thread -> IterationEnd count with reads>0
    allocsThisIter = collections.Counter()
    perIterAllocs = collections.defaultdict(list)
    liveAtIter = collections.defaultdict(list)
    readsPerIter = collections.defaultdict(list)

    pairs = []
    unpaired_free = 0; trunc_stacks = 0; reuse = 0
    threads_alloc = collections.Counter()

    def top(h, livemap):
        while h and h[0] not in livemap: heapq.heappop(h)
        return h[0] if h else None

    for e in recs:
        k = e['k']; th = e.get('th', '?')
        if k == 'I':
            itc[th] += 1
            r = e.get('reads', 0)
            if r > 0: ritc[th] += 1
            perIterAllocs[th].append(allocsThisIter[th]); allocsThisIter[th] = 0
            liveAtIter[th].append(len(liveByThread[th]))
            readsPerIter[th].append(r)
        elif k == 'A':
            a = e.get('a')
            if a is None: continue
            old = live.pop(a, None)
            if old is not None:                      # address reused with no Free/Realloc seen
                reuse += 1
                liveByThread[old['owner']].pop(old['seq'], None)
            seqc[th] += 1; s = seqc[th]
            e['seq'] = s; e['iter0'] = itc[th]; e['riter0'] = ritc[th]; e['owner'] = th
            live[a] = e
            liveByThread[th][s] = a
            heapq.heappush(maxh[th], -s); heapq.heappush(minh[th], s)
            allocsThisIter[th] += 1; threads_alloc[th] += 1
        else:                                        # 'F' or 'R' (a realloc frees the old segment)
            a = e.get('a')
            al = live.pop(a, None) if a is not None else None
            if al is None: unpaired_free += 1; continue
            if e.get('trunc'): trunc_stacks += 1
            oth = al['owner']; s = al['seq']
            lb = liveByThread[oth]
            # nesting class computed BEFORE removing this entry
            mx = top(maxh[oth], lb); mn = top(minh[oth], lb)
            mx = -mx if mx is not None else None
            only = (len(lb) == 1)
            if only: nest = 'only'
            elif s == mx: nest = 'youngest'
            elif s == mn: nest = 'oldest'
            else: nest = 'middle'
            lb.pop(s, None)
            if k == 'R':
                cause, site = ('realloc-grow', 'io.netty.buffer.AdaptiveByteBuf.capacity')
            else:
                cause, site = classify(e.get('frames', []))
            pairs.append({
                'it': itc[oth] - al['iter0'],
                'rit': ritc[oth] - al['riter0'],
                'same': th == oth,
                'nest': nest,
                'sz': al.get('sz', 0),
                'cause': cause,
                'site': site,
                'ns': e['t'] - al['t'],
                'oth': oth, 'fth': th,
            })

    return {'pairs': pairs, 'live': live, 'reuse': reuse, 'unpaired_free': unpaired_free,
            'trunc_stacks': trunc_stacks, 'itc': itc, 'ritc': ritc,
            'perIterAllocs': perIterAllocs, 'liveAtIter': liveAtIter, 'readsPerIter': readsPerIter}


def main():
    path = sys.argv[1]; label = sys.argv[2] if len(sys.argv) > 2 else path
    recs = []
    for e in read_tsv(path):
        recs.append(e)
    for i, e in enumerate(recs): e['i'] = i
    recs.sort(key=lambda e: (e['t'], e['i']))

    nA = sum(1 for e in recs if e['k'] == 'A')
    nF = sum(1 for e in recs if e['k'] == 'F')
    nR = sum(1 for e in recs if e['k'] == 'R')
    nI = sum(1 for e in recs if e['k'] == 'I')
    c = core(recs)
    pairs = c['pairs']; live = c['live']; reuse = c['reuse']
    unpaired_free = c['unpaired_free']; trunc_stacks = c['trunc_stacks']
    itc = c['itc']; ritc = c['ritc']
    perIterAllocs = c['perIterAllocs']; liveAtIter = c['liveAtIter']; readsPerIter = c['readsPerIter']

    n = len(pairs)
    out = []
    W = out.append
    W('=' * 96)
    W('WORKLOAD %s   (%s)' % (label, os.path.basename(path)))
    W('=' * 96)
    W('events: AllocateBuffer=%d FreeBuffer=%d ReallocateBuffer=%d IterationEnd=%d' % (nA, nF, nR, nI))
    W('pairs=%d  unpaired releases (alloc before window)=%d  still live at window end=%d  truncated stacks=%d  address reused with no release event=%d'
      % (n, unpaired_free, len(live), trunc_stacks, reuse))
    W('BALANCE CHECK: allocs(%d) - pairs(%d) - live-at-end(%d) - reuse(%d) = %d  (must be 0)'
      % (nA, n, len(live), reuse, nA - n - len(live) - reuse))
    if n == 0:
        print('\n'.join(out)); return
    elthreads = sorted([t for t in itc if itc[t] > 0])
    W('event-loop threads with markers: %d  iterations total=%d  with reads>0=%d (%.1f%%)'
      % (len(elthreads), sum(itc.values()), sum(ritc.values()),
         pct(sum(ritc.values()), sum(itc.values()))))
    W('')

    # --- lifetime in iterations ---
    hist = collections.Counter(bucket_iter(p['it']) for p in pairs)
    rhist = collections.Counter(bucket_iter(p['rit']) for p in pairs)
    W('(a) lifetime in event-loop ITERATIONS of the allocating thread')
    W('     iters : %s' % '  '.join('%s=%.2f%%' % (b, pct(hist[b], n)) for b in ['0', '1', '2-3', '4-7', '8+']))
    W('  read-its : %s   (only iterations that saw >=1 channelRead)'
      % '  '.join('%s=%.2f%%' % (b, pct(rhist[b], n)) for b in ['0', '1', '2-3', '4-7', '8+']))
    lif = sorted(p['it'] for p in pairs); q = lambda a, pp: a[min(len(a) - 1, int(pp * len(a)))]
    W('  iters p50=%d p90=%d p99=%d p99.9=%d max=%d' % (q(lif, .5), q(lif, .9), q(lif, .99), q(lif, .999), lif[-1]))
    wall = sorted(p['ns'] for p in pairs)
    W('  wall-clock lifetime us: p50=%.1f p90=%.1f p99=%.1f p99.9=%.1f max=%.1f'
      % (q(wall, .5) / 1e3, q(wall, .9) / 1e3, q(wall, .99) / 1e3, q(wall, .999) / 1e3, wall[-1] / 1e3))
    W('')

    # --- same thread ---
    st = sum(1 for p in pairs if p['same'])
    W('(b) released on the allocating thread: %.3f%%  (cross-thread: %d)' % (pct(st, n), n - st))
    if n - st:
        xt = collections.Counter((p['oth'], p['fth']) for p in pairs if not p['same'])
        for (o, f), c in xt.most_common(6):
            W('      %s -> %s : %d (%.2f%%)' % (o, f, c, pct(c, n)))
    W('')

    # --- nesting ---
    nest = collections.Counter(p['nest'] for p in pairs)
    W('(c) nesting class at release: %s' % '  '.join('%s=%.2f%%' % (k, pct(nest[k], n))
                                                     for k in ['only', 'youngest', 'oldest', 'middle']))
    n0 = [p for p in pairs if p['it'] == 0]
    nest0 = collections.Counter(p['nest'] for p in n0)
    W('     within same-iteration releases (%d, %.2f%% of all): %s'
      % (len(n0), pct(len(n0), n),
         '  '.join('%s=%.2f%%' % (k, pct(nest0[k], len(n0))) for k in ['only', 'youngest', 'oldest', 'middle'])))
    W('')

    # --- sizes ---
    szc = collections.Counter(sizeb(p['sz']) for p in pairs)
    W('(d) size bucket (power-of-two ceiling of the requested capacity)')
    W('     %s' % '  '.join('%s=%.2f%%' % (k, pct(c, n)) for k, c in
                            sorted(szc.items(), key=lambda kv: -int(kv[0]))[:10]))
    exact = collections.Counter(p['sz'] for p in pairs)
    W('     exact sizes: %s' % '  '.join('%d=%.2f%%' % (k, pct(c, n)) for k, c in exact.most_common(6)))
    W('')

    # --- causes ---
    cc = collections.Counter(p['cause'] for p in pairs)
    W('(e) release cause (first non-allocator frame of the FreeBuffer stack)')
    for k, c in cc.most_common():
        sites = collections.Counter(p['site'] for p in pairs if p['cause'] == k)
        W('     %-22s %7.3f%%  top site: %s' % (k, pct(c, n), sites.most_common(1)[0][0]))
    W('')

    W('    cause x lifetime-in-iterations (row %% of all pairs)')
    W('    %-22s %8s %8s %8s %8s %8s %9s' % ('cause', '0', '1', '2-3', '4-7', '8+', 'share'))
    for k, c in cc.most_common():
        h = collections.Counter(bucket_iter(p['it']) for p in pairs if p['cause'] == k)
        W('    %-22s %7.3f%% %7.3f%% %7.3f%% %7.3f%% %7.3f%% %8.3f%%'
          % (k, pct(h['0'], n), pct(h['1'], n), pct(h['2-3'], n), pct(h['4-7'], n), pct(h['8+'], n), pct(c, n)))
    W('')

    W('    cause x size bucket (row %% of all pairs)')
    tops = [k for k, _ in szc.most_common(6)]
    W('    %-22s %s' % ('cause', ' '.join('%9s' % t for t in tops)))
    for k, c in cc.most_common():
        h = collections.Counter(sizeb(p['sz']) for p in pairs if p['cause'] == k)
        W('    %-22s %s' % (k, ' '.join('%8.3f%%' % pct(h[t], n) for t in tops)))
    W('')

    mx = max(pairs, key=lambda p: p['it'])
    W('    max lifetime: %d iterations (%.1f us), size=%d, cause=%s, site=%s'
      % (mx['it'], mx['ns'] / 1e3, mx['sz'], mx['cause'], mx['site']))
    mw = max(pairs, key=lambda p: p['ns'])
    W('    max wall-clock: %.1f us (%d iterations), size=%d, cause=%s' % (mw['ns'] / 1e3, mw['it'], mw['sz'], mw['cause']))
    W('')

    # --- live at iteration end / allocs per iteration ---
    W('(f) live buffers at end of iteration, per event-loop thread')
    W('    %-28s %8s %8s %8s %10s %8s' % ('thread', 'iters', 'avgLive', 'maxLive', 'avgAlloc', 'maxAlloc'))
    for t in elthreads:
        la = liveAtIter[t]; pa = perIterAllocs[t]
        if not la: continue
        W('    %-28s %8d %8.2f %8d %10.2f %8d'
          % (t, len(la), sum(la) / len(la), max(la), sum(pa) / len(pa), max(pa)))
    alll = [v for t in elthreads for v in liveAtIter[t]]
    if alll:
        nz = sum(1 for v in alll if v > 0)
        alll_s = sorted(alll)
        W('    live-at-marker over all markers: mean=%.3f p50=%d p90=%d p99=%d p99.9=%d max=%d ; markers with >0 live=%d (%.2f%%)'
          % (sum(alll) / len(alll), q(alll_s, .5), q(alll_s, .9), q(alll_s, .99), q(alll_s, .999), alll_s[-1], nz, pct(nz, len(alll))))
    allpa = [v for t in elthreads for v in perIterAllocs[t]]
    if allpa:
        allpa.sort()
        zero = sum(1 for v in allpa if v == 0)
        W('    allocations per iteration (all EL threads): mean=%.2f p50=%d p90=%d p99=%d max=%d  zero-alloc iterations=%.1f%%'
          % (sum(allpa) / len(allpa), q(allpa, .5), q(allpa, .9), q(allpa, .99), allpa[-1], pct(zero, len(allpa))))
    allr = [v for t in elthreads for v in readsPerIter[t]]
    if allr:
        allr.sort()
        W('    channelReads per iteration: mean=%.2f p50=%d p90=%d p99=%d max=%d'
          % (sum(allr) / len(allr), q(allr, .5), q(allr, .9), q(allr, .99), allr[-1]))
    W('')

    xp = [p for p in pairs if p['it'] > 0]
    if xp:
        W('(g) the buffers that DO cross an iteration boundary (%d, %.3f%% of pairs)' % (len(xp), pct(len(xp), n)))
        xs = collections.Counter(p['site'] for p in xp)
        for k, c in xs.most_common(8):
            its = sorted(p['it'] for p in xp if p['site'] == k)
            byt = sum(p['sz'] for p in xp if p['site'] == k)
            W('     %-58s %6.3f%% of all  iters p50=%d p99=%d max=%d  bytes=%.1f MiB'
              % (k[:58], pct(c, n), q(its, .5), q(its, .99), its[-1], byt / 1048576.0))
        xsz = collections.Counter(sizeb(p['sz']) for p in xp)
        W('     sizes of the crossing buffers: %s'
          % '  '.join('%s=%.2f%%' % (k, pct(c, len(xp))) for k, c in sorted(xsz.items(), key=lambda kv: -int(kv[0]))[:8]))
        W('     bytes held across a boundary: %.1f MiB of %.1f MiB allocated in the window (%.2f%%)'
          % (sum(p['sz'] for p in xp) / 1048576.0, sum(p['sz'] for p in pairs) / 1048576.0,
             pct(sum(p['sz'] for p in xp), sum(p['sz'] for p in pairs))))
        W('')

    nosite = sum(1 for p in pairs if p['cause'] == 'other:no-site')
    xiter = sum(1 for p in pairs if p['it'] > 0)
    W('    diagnostics: pairs whose stack had no non-plumbing frame=%d (%.3f%%); pairs crossing >=1 marker=%d (%.3f%%)'
      % (nosite, pct(nosite, n), xiter, pct(xiter, n)))
    W('')

    # --- headline classification ---
    def cls(p):
        if p['it'] == 0:
            return 'i-same-iter-LIFO' if p['nest'] in ('youngest', 'only') else 'ii-same-iter-out-of-order'
        if p['cause'] == 'write-completion': return 'iii-cross-iter-write-completion'
        if p['cause'] in ('decoder/cumulation', 'aggregator'): return 'iv-cross-iter-cumulation/aggregation'
        if p['cause'] == 'h2-flow-control': return 'v-cross-iter-h2-flow-control'
        return 'vi-cross-iter-other:' + p['cause']
    hc = collections.Counter(cls(p) for p in pairs)
    W('HEADLINE CLASSIFICATION')
    for k, c in hc.most_common():
        W('    %-40s %7.3f%%  (%d)' % (k, pct(c, n), c))
    print('\n'.join(out))

if __name__ == '__main__':
    main()
