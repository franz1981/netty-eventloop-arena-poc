import re,collections,math,sys
path=sys.argv[1]; label=sys.argv[2] if len(sys.argv)>2 else path
UNIT={'bytes':1,'B':1,'kB':1000,'KB':1000,'MB':1000000}
def size(v):
    parts=v.replace(',','').split(); n=float(parts[0]); u=parts[1] if len(parts)>1 else 'bytes'; return int(n*UNIT.get(u,1))
live={}; percount=collections.Counter(); same=other=unpaired=allocs=0; lifeops=[]; sizes=collections.Counter(); opsBySize=collections.defaultdict(list); cur=None; kind=None
def flush():
    global same,other,unpaired,allocs
    if not cur or 'address' not in cur: return
    a=cur['address']; th=cur.get('eventThread','?')
    if kind=='alloc': allocs+=1; percount[th]+=1; live[a]=(th,percount[th],cur.get('size',0))
    else:
        x=live.pop(a,None)
        if x is None: unpaired+=1; return
        th0,n0,sz=x
        if th==th0: same+=1
        else: other+=1
        ops=percount[th0]-n0; lifeops.append(ops); sizes[sz]+=1; opsBySize[sz].append(ops)
with open(path,errors='replace') as f:
    for line in f:
        if line.startswith('io.netty.AllocateBuffer'): flush(); cur={}; kind='alloc'; continue
        if line.startswith('io.netty.FreeBuffer'): flush(); cur={}; kind='free'; continue
        if cur is None: continue
        m=re.match(r'\s+(eventThread|address|size)\s*=\s*(.+?)\s*$',line)
        if m:
            k,v=m.group(1),m.group(2)
            if k=='eventThread': v=v.split('"')[1] if '"' in v else v
            elif k=='address': v=int(v,16) if v.startswith('0x') else int(v)
            elif k=='size': v=size(v)
            cur[k]=v
flush(); n=same+other
print('%s: allocs=%d paired=%d unpaired=%d live at end=%d threads=%d'%(label,allocs,n,unpaired,len(live),len(percount)))
print('released on the allocating thread: %.4f%% (other thread: %d)'%(100.0*same/n,other))
lifeops.sort(); q=lambda arr,p: arr[min(len(arr)-1,int(p*len(arr)))]
print('allocations-in-between: p50=%d p90=%d p99=%d p99.9=%d p99.99=%d max=%d'%(q(lifeops,.5),q(lifeops,.9),q(lifeops,.99),q(lifeops,.999),q(lifeops,.9999),lifeops[-1]))
hist=collections.Counter()
for v in lifeops: hist[0 if v==0 else 1<<int(math.log2(v))]+=1
print('histogram:',' '.join('%s:%.2f%%'%(k,100.0*c/n) for k,c in sorted(hist.items())))
print('sizes:',' '.join('%d=%.1f%%'%(k,100.0*c/n) for k,c in sizes.most_common(8)))
for sz,_ in sizes.most_common(6):
    a=sorted(opsBySize[sz]); print('   size %6d: in-between p50=%d p90=%d p99=%d p99.9=%d max=%d'%(sz,q(a,.5),q(a,.9),q(a,.99),q(a,.999),a[-1]))
