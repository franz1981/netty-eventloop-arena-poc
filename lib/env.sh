#!/bin/bash
# Every machine-specific knob of this PoC, as an environment variable with a neutral default.
# Source it, do not run it.  Nothing here is specific to the box the reference results came from:
# the reference machine's settings are in results/<machine>/RESULTS.md and are set from the outside.
#
# java and mvn are taken from PATH (install them with your SDK manager of choice).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- pinning and frequency -----------------------------------------------------------------------
# PIN_CMD is prefixed to every JVM launch.  Empty = no pinning.
#   example: PIN_CMD="numactl --cpunodebind=0 --preferred=0"
#   example: PIN_CMD="taskset -c 0-15"
: "${PIN_CMD:=}"
# CPU_FREQ_HOOK is an executable taking one argument, "pin" before a run and "restore" after it.
# Empty = the frequency is left alone (fine for a smoke run, not for a measurement).
: "${CPU_FREQ_HOOK:=}"

# --- JVM ------------------------------------------------------------------------------------------
# Appended to every forked JMH JVM.  Empty by default: no memory ceiling is assumed.
#   example: JVM_OPTS="-XX:MaxRAM=60g"
: "${JVM_OPTS:=}"

# --- JMH shape --------------------------------------------------------------------------------------
: "${FORKS:=3}"      # -f  : 3 is the floor for a reportable number on this benchmark
: "${WI:=10}"        # -wi : warmup iterations
: "${I:=10}"         # -i  : measurement iterations
: "${W:=1}"          # -w  : warmup iteration seconds
: "${R:=1}"          # -r  : measurement iteration seconds
: "${THREADS:=1}"    # -t

# --- build and output ---------------------------------------------------------------------------
: "${MVN_FLAGS:=-q}"                 # add -o to build offline
: "${RESULTS_DIR:=$ROOT/out}"        # where run-*.sh write json/data/logs

require_tools() {
    local missing=""
    for t in "$@"; do command -v "$t" > /dev/null 2>&1 || missing="$missing $t"; done
    if [ -n "$missing" ]; then
        echo "missing from PATH:$missing" >&2
        return 1
    fi
}

freq_hook() {   # $1 = pin | restore
    [ -n "$CPU_FREQ_HOOK" ] || return 0
    "$CPU_FREQ_HOOK" "$1" || echo "warning: CPU_FREQ_HOOK $1 failed" >&2
}

# The netty version the submodule builds, read from its pom - never hardcoded.
netty_version() {
    sed -n '0,/<\/parent>/d; /<version>/{s/.*<version>\(.*\)<\/version>.*/\1/p; q}' "$ROOT/netty/pom.xml" \
        || return 1
}

# Peak RSS per fork out of a JMH .data file: the harness prints "cRSS-pRSS:[cur, peak]" per iteration
# and the forks appear in order, so the per-fork maximum is what a "peak RSS" number means here.
peak_rss() {
    grep -o 'cRSS-pRSS:\[[0-9]*, *[0-9]*\]' "$1" 2>/dev/null \
        | sed 's/.*, *\([0-9]*\)\]/\1/' \
        | awk '{v[n++]=$1; if ($1>mx) mx=$1} END{ if (!n) { print "no cRSS-pRSS samples"; exit }
                 s="per fork:"; for (i=0;i<n;i++) s=s" "v[i]; printf "max=%d MB  %s", mx, s }'
}
