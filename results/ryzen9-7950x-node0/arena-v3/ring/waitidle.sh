# Sourced, never run. Wait until no other build/benchmark is on the box, THEN pin the frequency:
# another agent's script may restore 4300000 while we wait, so the pin belongs next to the run,
# not at the top of the script.
FREQ_RUN=${FREQ_RUN:-2300000}
pin_freq() {
  for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_max_freq; do
    echo "$1" | sudo -n tee $c >/dev/null
  done
}
wait_idle() {
  local busy c p
  while :; do
    busy=0
    for p in $(pgrep -x java); do
      c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
      case "$c" in
        *ForkedMain*|*jmh*|*JMH*|*benchmarks.jar*|*bench-*.jar*|*Benchmark*|*plexus-classworlds*|*E2EServer*|*TopoServer*) busy=1;;
      esac
    done
    pgrep -x h2load >/dev/null 2>&1 && busy=1
    if [ "$busy" -eq 0 ]; then
      pin_freq "$FREQ_RUN"
      return 0
    fi
    echo "  ... waiting for the box $(date +%T)"
    sleep 30
  done
}
# The frequency ACTUALLY in force, to be printed with every reported cell.
freq_now() { cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq; }
