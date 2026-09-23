#!/bin/bash
# The ring gates. Sequential, pinned to node 0, 2300 MHz, nothing else on the box.
set -u
R=/home/forked_franz/IdeaProjects/netty-bench/results/h2h-merged-x86-2026-09-22/arena-v3/ring
SP=/tmp/claude-1000/-home-forked-franz-IdeaProjects-netty/01a26e43-89a8-433b-a89e-c560138e4359/scratchpad
J=$R/bench-ring.jar
BEFORE=$SP/benchmarks-before.jar
cd /home/forked_franz/IdeaProjects/netty-bench/results/h2h-merged-x86-2026-09-22 || exit 1   # e-commerce.jfr
mkdir -p $R/prof
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do echo 2300000 | sudo -n tee $c >/dev/null; done
echo "freq cpu0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq) start $(date +%T)"
N="numactl --cpunodebind=0 --preferred=0"
CYC='CycleScopedAllocBenchmark.cycle(Heap|Direct)'
ECO='ByteBufAllocatorAllocPatternBenchmark.(heap|direct)Allocation'

# ---------------- (A1) cycle cell, 3 forks: ring=true vs ring=false ----------------
for ring in true false; do
  $N java -jar $J "$CYC" -f 3 -wi 10 -i 10 \
    -p k=64 -p releaseOrder=FIFO -p sizes=SMALL -p allocatorType=ARENA \
    -jvmArgsAppend -XX:MaxRAM=60g -jvmArgsAppend -Darena.ring=$ring \
    -rf json -rff $R/cycle-ring-$ring.json > $R/cycle-ring-$ring.log 2>&1
  echo "A1 ring=$ring exit=$? $(date +%T)"
done

# ---------------- (A2) perfnorm, 1 fork: before / ring=false / ring=true ----------------
$N java -jar $BEFORE "$CYC" -f 1 -wi 10 -i 10 \
  -p k=64 -p releaseOrder=FIFO -p sizes=SMALL -p allocatorType=ARENA \
  -jvmArgsAppend -XX:MaxRAM=60g -prof perfnorm \
  -rf json -rff $R/prof/perfnorm-before.json > $R/prof/perfnorm-before.log 2>&1
echo "A2 before exit=$? $(date +%T)"
for ring in false true; do
  $N java -jar $J "$CYC" -f 1 -wi 10 -i 10 \
    -p k=64 -p releaseOrder=FIFO -p sizes=SMALL -p allocatorType=ARENA \
    -jvmArgsAppend -XX:MaxRAM=60g -jvmArgsAppend -Darena.ring=$ring -prof perfnorm \
    -rf json -rff $R/prof/perfnorm-ring-$ring.json > $R/prof/perfnorm-ring-$ring.log 2>&1
  echo "A2 ring=$ring exit=$? $(date +%T)"
done

# ---------------- (B) E_COMMERCE, 32 threads, 3 forks ----------------
ECOP="-t 32 -p sizePattern=E_COMMERCE -p enableReadWrite=true -p MAX_LIVE_BUFFERS=128,1024,4096 -p allocatorType=ARENA"
for hook in 0 64; do
  $N java -jar $J "$ECO" -f 3 -wi 10 -i 10 $ECOP \
    -jvmArgsAppend -XX:MaxRAM=60g -jvmArgsAppend -Darena.ring=true -jvmArgsAppend -Dexpt.hookEvery=$hook \
    -rf json -rff $R/ecommerce-ring-hook$hook.json > $R/ecommerce-ring-hook$hook.log 2>&1
  echo "B ring=true hookEvery=$hook exit=$? $(date +%T)"
done

# ---------------- (B-stats) the same cells with -Darena.ringStats=true, 1 fork ----------------
# The stall walk perturbs ns/op: these runs are for the stranded/hole counters ONLY.
for hook in 0 64; do
  $N java -jar $J "$ECO" -f 1 -wi 5 -i 5 $ECOP \
    -jvmArgsAppend -XX:MaxRAM=60g -jvmArgsAppend -Darena.ring=true \
    -jvmArgsAppend -Darena.ringStats=true -jvmArgsAppend -Dexpt.hookEvery=$hook \
    -rf json -rff $R/ecommerce-stats-hook$hook.json > $R/ecommerce-stats-hook$hook.log 2>&1
  echo "B-stats hookEvery=$hook exit=$? $(date +%T)"
done
$N java -jar $J "$CYC" -f 1 -wi 5 -i 5 \
  -p k=64 -p releaseOrder=FIFO -p sizes=SMALL -p allocatorType=ARENA \
  -jvmArgsAppend -XX:MaxRAM=60g -jvmArgsAppend -Darena.ring=true -jvmArgsAppend -Darena.ringStats=true \
  -rf json -rff $R/cycle-stats.json > $R/cycle-stats.log 2>&1
echo "A-stats exit=$? $(date +%T)"

for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do echo 4300000 | sudo -n tee $c >/dev/null; done
echo "RING RUNS DONE freq restored cpu0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq) $(date +%T)"
