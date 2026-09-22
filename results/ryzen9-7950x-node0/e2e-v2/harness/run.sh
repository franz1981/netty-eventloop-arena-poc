#!/bin/bash
# usage: run.sh <alloc> <proto> <outdir-tag> [extra jvm args...]
set -u
SC=/tmp/claude-1000/-home-forked-franz-IdeaProjects-netty/01a26e43-89a8-433b-a89e-c560138e4359/scratchpad
ALLOC=$1; PROTO=$2; TAG=$3; shift 3
OUT=$SC/e2e/out/$TAG; mkdir -p "$OUT"
CP="$SC/e2e/classes:$(cat $SC/e2e/cp.txt)"
BODY=/home/forked_franz/IdeaProjects/netty-bench/results/h2h-merged-x86-2026-09-22/lifetimes/body4k.bin

# make sure nothing is holding 8080
for p in $(pgrep -x java); do
  if tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | grep -q E2EServer; then echo "stale server $p, killing"; kill -9 $p; fi
done
sleep 1

numactl --cpunodebind=0 --membind=0 java \
  -cp "$CP" \
  -Dio.netty.leakDetection.level=disabled -Dlogback.configurationFile=/tmp/claude-1000/-home-forked-franz-IdeaProjects-netty/01a26e43-89a8-433b-a89e-c560138e4359/scratchpad/e2e/logback-quiet.xml \
  -Xmx2g -Xms2g -Xlog:gc:file=$OUT/gc.log \
  "$@" \
  E2EServer $ALLOC $PROTO 8080 8 > $OUT/server.log 2>&1 &
SRV=$!
for i in $(seq 1 60); do grep -q READY $OUT/server.log 2>/dev/null && break; sleep 0.5; done
grep -q READY $OUT/server.log || { echo "SERVER FAILED"; tail -30 $OUT/server.log; kill -9 $SRV; exit 1; }

# RSS sampler
( while kill -0 $SRV 2>/dev/null; do grep VmRSS /proc/$SRV/status 2>/dev/null | awk '{print $2}'; sleep 0.5; done ) > $OUT/rss.txt &
RSSP=$!

if [ "$PROTO" = h1 ]; then
  numactl --cpunodebind=1 h2load --h1 -c 64 -t 4 -D 20 -d $BODY http://127.0.0.1:8080/ > $OUT/h2load.txt 2>&1
else
  numactl --cpunodebind=1 h2load -c 16 -m 32 -t 4 -D 20 -d $BODY http://127.0.0.1:8080/ > $OUT/h2load.txt 2>&1
fi

kill $RSSP 2>/dev/null
kill -TERM $SRV; wait $SRV 2>/dev/null
sleep 1
echo "=== $TAG ==="
grep -a "finished in\|time for request" $OUT/h2load.txt
grep -a ARENATELE $OUT/server.log
awk 'NR==1{min=$1;max=$1} {if($1<min)min=$1; if($1>max)max=$1} END{printf "RSS min=%.0fMiB max=%.0fMiB n=%d\n", min/1024, max/1024, NR}' $OUT/rss.txt
echo "GC pauses: $(grep -c 'Pause Young\|Pause Full' $OUT/gc.log)"
