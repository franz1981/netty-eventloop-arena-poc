#!/bin/bash
# Run ONE benchmark cell under the SHARED bench lock, with the process scan as a second check taken
# INSIDE the lock: if a foreign JVM benchmark or load generator is up, release the lock and retry,
# so a batch that has not adopted the lock yet still cannot overlap us.
#   cell.sh <owner-name> <command...>
set -u
S=/tmp/claude-1000/-home-forked-franz-IdeaProjects-netty/01a26e43-89a8-433b-a89e-c560138e4359/scratchpad
LOCK="$S/BENCH.lock"
OWNER=$1; shift
: "${TARGET_FREQ:=2300000}"
: "${MAX_LOAD:=1.0}"
: > "$LOCK" 2>/dev/null || true

foreign() {   # 0 = something that is not mine is running
  local p c
  for p in $(pgrep -x java 2>/dev/null); do
    c=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$c" in
      *TopoServer*|*E2EServer*) continue ;;              # mine
      "") continue ;;
      *) echo "  foreign JVM $p: $(echo "$c" | cut -c1-90)"; return 0 ;;
    esac
  done
  for p in $(pgrep -x h2load 2>/dev/null); do
    echo "  foreign/leftover h2load $p"; return 0
  done
  return 1
}

exec 9>"$LOCK"
while :; do
    flock 9
    if foreign; then
        echo "  LOCK HELD BUT BOX NOT FREE ($OWNER) - releasing and retrying at $(date +%T)"
        flock -u 9
        sleep 30
        continue
    fi
    echo "$OWNER $(date +%T) $*" > "$S/BENCH.owner"
    echo "== cell start ($OWNER) $(date +%T)"
    # Frequency: SET it inside the lock, then READ IT BACK and refuse to run the cell if any CPU
    # disagrees.  Reading alone was not enough - the ceiling was moved back to 4300000 between two
    # of my cells, and the cells that ran then are not comparable with anything.
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
        echo "$TARGET_FREQ" | sudo -n tee "$f" > /dev/null 2>&1
    done
    seen=$(for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do cat "$f"; done | sort -u | tr '\n' ',')
    echo "== scaling_max_freq set=$TARGET_FREQ readback=$seen governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
    if [ "$seen" != "$TARGET_FREQ," ]; then
        echo "!! ABORT ($OWNER): the CPU ceiling is $seen, not $TARGET_FREQ - this cell is not run"
        flock -u 9
        exit 88
    fi
    # Load: a quiet process table is not a quiet box.  Runnable/uninterruptible work left over from
    # something else (a mass kill, a page-cache flush) still steals cycles from my server, and a
    # pgrep scan cannot see it.  Read the 1-minute average INSIDE the lock, log it, and if it is
    # above MAX_LOAD release the lock and retry rather than measure through it.
    load1=$(cut -d" " -f1 /proc/loadavg)
    echo "== loadavg $(cat /proc/loadavg)"
    # Two checks, because they catch different things.
    # (a) STRICT_LOAD=1 (the first cell of a batch): the 1-minute average must be below MAX_LOAD.
    #     This is the cold-start check - the box must be quiet before I measure anything at all.
    #     It is NOT applied to later cells: the 1-minute average still carries MY OWN previous
    #     cell's load, and waiting it out would cost ~2 minutes per cell for no information.
    # (b) every cell: the INSTANTANEOUS runnable count (field 4 of /proc/loadavg, before the slash),
    #     sampled repeatedly. It has no 60-second memory, so between my cells it reads 1-2, and any
    #     foreign runnable work shows up immediately - which is what the 1-minute average cannot do.
    if [ "${STRICT_LOAD:-0}" = 1 ] && awk -v l="$load1" -v m="$MAX_LOAD" 'BEGIN{exit !(l>m)}'; then
        echo "!! LOAD TOO HIGH ($OWNER): 1-min $load1 > $MAX_LOAD - releasing the lock, retrying at $(date +%T)"
        flock -u 9; sleep 30; continue
    fi
    runmax=0; runsamples=""
    for _ in 1 2 3 4 5 6; do
        r=$(cut -d" " -f4 /proc/loadavg | cut -d/ -f1)
        runsamples="$runsamples $r"; [ "$r" -gt "$runmax" ] && runmax=$r
        sleep 0.5
    done
    echo "== runnable samples:$runsamples max=$runmax (limit ${MAX_RUNNABLE:-2})"
    if [ "$runmax" -gt "${MAX_RUNNABLE:-2}" ]; then
        echo "!! RUNNABLE TOO HIGH ($OWNER): $runmax > ${MAX_RUNNABLE:-2} - releasing the lock, retrying at $(date +%T)"
        flock -u 9; sleep 30; continue
    fi
    "$@"; rc=$?
    echo "== cell end   ($OWNER) $(date +%T) rc=$rc"
    flock -u 9
    exit $rc
done
