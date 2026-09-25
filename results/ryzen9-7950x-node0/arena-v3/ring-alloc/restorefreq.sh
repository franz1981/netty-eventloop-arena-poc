#!/bin/bash
# Put the CPU ceiling back where it was found (4300000) and read it back.  Run INSIDE the lock.
set -u
: "${RESTORE_FREQ:=4300000}"
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
    echo "$RESTORE_FREQ" | sudo -n tee "$f" > /dev/null 2>&1
done
echo "== restored scaling_max_freq readback=$(for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do cat "$f"; done | sort -u | tr '\n' ',')"
