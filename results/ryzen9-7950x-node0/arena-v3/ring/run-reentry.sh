#!/bin/bash
# Part 1(b) gate: the E_COMMERCE t32 ladder with hookEvery=0 and ring=true - re-entry build vs the
# committed ring build - plus the cycle cell, to prove re-entry costs the hot path nothing.
set -u
R=/home/forked_franz/IdeaProjects/netty-bench/results/h2h-merged-x86-2026-09-22/arena-v3/ring/reentry
SP=/tmp/claude-1000/-home-forked-franz-IdeaProjects-netty/01a26e43-89a8-433b-a89e-c560138e4359/scratchpad
mkdir -p $R
cd /home/forked_franz/IdeaProjects/netty-bench/results/h2h-merged-x86-2026-09-22 || exit 1
source /tmp/claude-1000/-home-forked-franz-IdeaProjects-netty/01a26e43-89a8-433b-a89e-c560138e4359/scratchpad/waitidle.sh
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do echo 2300000 | sudo -n tee $c >/dev/null; done
echo "freq cpu0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq) start $(date +%T)"
N="numactl --cpunodebind=0 --preferred=0"
ECO='ByteBufAllocatorAllocPatternBenchmark.(heap|direct)Allocation'
CYC='CycleScopedAllocBenchmark.cycle(Heap|Direct)'
ECOP="-t 32 -p sizePattern=E_COMMERCE -p enableReadWrite=true -p MAX_LIVE_BUFFERS=128,1024,4096 -p allocatorType=ARENA"
CYCP="-p k=64 -p releaseOrder=FIFO -p sizes=SMALL -p allocatorType=ARENA"

wait_idle
$N java -jar $SP/jars/bench-reentry.jar "$ECO" -f 3 -wi 10 -i 10 $ECOP \
  -jvmArgsAppend -XX:MaxRAM=60g -jvmArgsAppend -Darena.ring=true -jvmArgsAppend -Dexpt.hookEvery=0 \
  -rf json -rff $R/ecommerce-reentry-hook0.json > $R/ecommerce-reentry-hook0.log 2>&1
echo "ladder reentry exit=$? failures=$(grep -c '<failure>' $R/ecommerce-reentry-hook0.log) freq=$(freq_now) $(date +%T)"

for ring in false true; do
  wait_idle
  $N java -jar $SP/jars/bench-reentry.jar "$CYC" -f 3 -wi 10 -i 10 $CYCP \
    -jvmArgsAppend -XX:MaxRAM=60g -jvmArgsAppend -Darena.ring=$ring \
    -rf json -rff $R/cycle-reentry-$ring.json > $R/cycle-reentry-$ring.log 2>&1
  echo "cycle reentry ring=$ring exit=$? freq=$(freq_now) $(date +%T)"
done
wait_idle
$N java -jar $SP/jars/bench-reentry.jar "$CYC" -f 1 -wi 10 -i 10 $CYCP \
  -jvmArgsAppend -XX:MaxRAM=60g -jvmArgsAppend -Darena.ring=true -prof perfnorm \
  -rf json -rff $R/perfnorm-reentry-true.json > $R/perfnorm-reentry-true.log 2>&1
echo "perfnorm reentry ring=true exit=$? freq=$(freq_now) $(date +%T)"
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do echo 4300000 | sudo -n tee $c >/dev/null; done
echo "REENTRY DONE $(date +%T)"
