#!/bin/bash
set -u
R=/home/forked_franz/IdeaProjects/netty-bench/results/h2h-merged-x86-2026-09-22/arena-v3/ring
SP=/tmp/claude-1000/-home-forked-franz-IdeaProjects-netty/01a26e43-89a8-433b-a89e-c560138e4359/scratchpad
J=$R/bench-ring.jar
BEFORE=$SP/benchmarks-before.jar
cd /home/forked_franz/IdeaProjects/netty-bench/results/h2h-merged-x86-2026-09-22 || exit 1
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do echo 2300000 | sudo -n tee $c >/dev/null; done
echo "freq cpu0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq) start $(date +%T)"
N="numactl --cpunodebind=0 --preferred=0"
P="-p k=64 -p releaseOrder=FIFO -p sizes=SMALL -p allocatorType=ARENA"
# AMD Zen 4: perfasm with event=cycles, NEVER cycles:P (IBS hides memory stalls).
for bm in cycleDirect cycleHeap; do
  $N java -jar $BEFORE "CycleScopedAllocBenchmark.$bm" -f 1 -wi 5 -i 5 $P \
    -jvmArgsAppend -XX:MaxRAM=60g -prof "perfasm:events=cycles;tooBigThreshold=4000" \
    > $R/prof/perfasm-before-$bm.log 2>&1; echo "perfasm before $bm exit=$? $(date +%T)"
  for ring in false true; do
    $N java -jar $J "CycleScopedAllocBenchmark.$bm" -f 1 -wi 5 -i 5 $P \
      -jvmArgsAppend -XX:MaxRAM=60g -jvmArgsAppend -Darena.ring=$ring \
      -prof "perfasm:events=cycles;tooBigThreshold=4000" \
      > $R/prof/perfasm-ring-$ring-$bm.log 2>&1; echo "perfasm ring=$ring $bm exit=$? $(date +%T)"
  done
done
# PrintInlining: (1) before and (2) ring=false
$N java -jar $BEFORE 'CycleScopedAllocBenchmark.cycle(Heap|Direct)' -f 1 -wi 3 -i 3 $P \
  -jvmArgsAppend -XX:MaxRAM=60g -jvmArgsAppend -XX:+UnlockDiagnosticVMOptions -jvmArgsAppend -XX:+PrintInlining \
  > $R/prof/inlining-before.log 2>&1; echo "inlining before exit=$? $(date +%T)"
$N java -jar $J 'CycleScopedAllocBenchmark.cycle(Heap|Direct)' -f 1 -wi 3 -i 3 $P \
  -jvmArgsAppend -XX:MaxRAM=60g -jvmArgsAppend -Darena.ring=false -jvmArgsAppend -XX:+UnlockDiagnosticVMOptions -jvmArgsAppend -XX:+PrintInlining \
  > $R/prof/inlining-ring-false.log 2>&1; echo "inlining ring=false exit=$? $(date +%T)"
$N java -jar $J 'CycleScopedAllocBenchmark.cycle(Heap|Direct)' -f 1 -wi 3 -i 3 $P \
  -jvmArgsAppend -XX:MaxRAM=60g -jvmArgsAppend -Darena.ring=true -jvmArgsAppend -XX:+UnlockDiagnosticVMOptions -jvmArgsAppend -XX:+PrintInlining \
  > $R/prof/inlining-ring-true.log 2>&1; echo "inlining ring=true exit=$? $(date +%T)"
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do echo 4300000 | sudo -n tee $c >/dev/null; done
echo "PROF DONE freq cpu0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq) $(date +%T)"
