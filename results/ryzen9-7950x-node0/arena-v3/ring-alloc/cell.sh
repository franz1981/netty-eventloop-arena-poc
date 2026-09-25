#!/bin/bash
# ONE benchmark cell, run INSIDE the shared bench lock (benchlock.sh already holds it, so this script
# must never take it itself - two flocks on the same file from two open file descriptions deadlock).
#   benchlock.sh run ringalloc ringcell.sh <command...>
# It does, in this order:
#   1. refuse to run if a JVM or load generator that is not mine is up (exact /proc/<pid>/cmdline scan)
#   2. set every CPU's scaling_max_freq to TARGET_FREQ and READ IT BACK; abort on any mismatch
#   3. sample /proc/loadavg field 4 (the instantaneous runnable count) six times; abort above MAX_RUNNABLE
#   4. run the command
# Provenance (freq read-back, runnable samples) goes to stdout, which the caller tees into the log.
set -u
: "${TARGET_FREQ:=2300000}"
: "${MAX_RUNNABLE:=3}"

foreign() {
  local p c
  for p in $(pgrep -x java 2>/dev/null); do
    c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$c" in
      *TopoServer*|*E2EServer*|*org.openjdk.jmh.Main*|*RingAllocBench*) continue ;;   # mine
      "") continue ;;
      *) echo "  foreign JVM $p: $(echo "$c" | cut -c1-100)"; return 0 ;;
    esac
  done
  for p in $(pgrep -x h2load 2>/dev/null); do echo "  foreign/leftover h2load $p"; return 0; done
  return 1
}

echo "== cell start $(date +%T) :: $*"
if foreign; then echo "!! ABORT: the box is not free"; exit 87; fi
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
    echo "$TARGET_FREQ" | sudo -n tee "$f" > /dev/null 2>&1
done
seen=$(for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do cat "$f"; done | sort -u | tr '\n' ',')
ncpu=$(ls -d /sys/devices/system/cpu/cpu[0-9]* | wc -l)
echo "== scaling_max_freq set=$TARGET_FREQ readback=$seen cpus=$ncpu governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
if [ "$seen" != "$TARGET_FREQ," ]; then
    echo "!! ABORT: the CPU ceiling is $seen, not $TARGET_FREQ - this cell is not run"; exit 88
fi
echo "== loadavg $(cat /proc/loadavg)"
runmax=0; runsamples=""
for _ in 1 2 3 4 5 6; do
    r=$(cut -d" " -f4 /proc/loadavg | cut -d/ -f1)
    runsamples="$runsamples $r"; [ "$r" -gt "$runmax" ] && runmax=$r
    sleep 0.5
done
echo "== runnable samples:$runsamples max=$runmax (limit $MAX_RUNNABLE)"
if [ "$runmax" -gt "$MAX_RUNNABLE" ]; then
    echo "!! ABORT: runnable $runmax > $MAX_RUNNABLE"; exit 89
fi
"$@"; rc=$?
echo "== cell end $(date +%T) rc=$rc"
exit $rc
