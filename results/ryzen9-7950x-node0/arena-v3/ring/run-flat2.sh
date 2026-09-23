#!/bin/bash
# Part 1(a) gate, A/B in ONE session: committed long[][] (bench-ring.jar) vs flat long[] (bench-flat.jar).
set -u
R=/home/forked_franz/IdeaProjects/netty-bench/results/h2h-merged-x86-2026-09-22/arena-v3/ring/flat
SP=/tmp/claude-1000/-home-forked-franz-IdeaProjects-netty/01a26e43-89a8-433b-a89e-c560138e4359/scratchpad
mkdir -p $R
cd /home/forked_franz/IdeaProjects/netty-bench/results/h2h-merged-x86-2026-09-22 || exit 1
source /tmp/claude-1000/-home-forked-franz-IdeaProjects-netty/01a26e43-89a8-433b-a89e-c560138e4359/scratchpad/waitidle.sh
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do echo 2300000 | sudo -n tee $c >/dev/null; done
echo "freq cpu0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq) start $(date +%T)"
N="numactl --cpunodebind=0 --preferred=0"
CYC='CycleScopedAllocBenchmark.cycle(Heap|Direct)'
P="-p k=64 -p releaseOrder=FIFO -p sizes=SMALL -p allocatorType=ARENA"
run() { # <tag> <jar> <ring> <forks> [extra...]
  local tag=$1 jar=$2 ring=$3 forks=$4; shift 4
  wait_idle
  $N java -jar $jar "$CYC" -f $forks -wi 10 -i 10 $P \
    -jvmArgsAppend -XX:MaxRAM=60g -jvmArgsAppend -Darena.ring=$ring "$@" \
    -rf json -rff $R/$tag.json > $R/$tag.log 2>&1
  echo "$tag exit=$? failures=$(grep -c '<failure>' $R/$tag.log) freq=$(freq_now) $(date +%T)"
}
for v in ring flat; do for r in false true; do
  run pn-$v-$r $SP/jars/bench-$v.jar $r 1 -prof perfnorm
done; done
for v in ring flat; do for r in false true; do
  run ns-$v-$r $SP/jars/bench-$v.jar $r 3
done; done
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do echo 4300000 | sudo -n tee $c >/dev/null; done
echo "FLAT A/B DONE freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq) $(date +%T)"
