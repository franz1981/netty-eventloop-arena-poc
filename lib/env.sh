#!/bin/bash
# Every machine-specific knob of this PoC, as an environment variable with a neutral default.
# Source it, do not run it.  Nothing here is specific to the box the reference results came from:
# the reference machine's settings are in results/<machine>/RESULTS.md and are set from the outside.
#
# java and mvn are taken from PATH (install them with your SDK manager of choice).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- pinning and frequency -----------------------------------------------------------------------
# Two DISJOINT core sets: one for the system under test, one for the load generator.  Empty = no
# pinning.  Run ./topology.sh for a suggestion derived from this machine's own lscpu output.
# Rules that matter more than the exact numbers:
#   - never share a core, or an SMT sibling of a core, between the load generator and the server;
#   - keep both sets inside one NUMA node;
#   - fix the CPU frequency if you can (CPU_FREQ_HOOK).
#   example: SUT_PIN_CMD="taskset -c 0-3"          LOADGEN_PIN_CMD="taskset -c 4-7"
#   example: SUT_PIN_CMD="numactl --physcpubind=0-3 --membind=0"
: "${SUT_PIN_CMD:=}"
: "${LOADGEN_PIN_CMD:=}"
# PIN_CMD was the single knob before the split; honour it as the SUT set if someone still sets it.
: "${PIN_CMD:=}"
[ -z "$SUT_PIN_CMD" ] && [ -n "$PIN_CMD" ] && SUT_PIN_CMD="$PIN_CMD"
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

# --- native transports ----------------------------------------------------------------------------
# TRANSPORT selects the event loop the PoC servers use: nio (default), epoll or io_uring.
: "${TRANSPORT:=nio}"

# The epoll and io_uring modules are NOT dependencies of netty-example, so their classes are added to
# the classpath explicitly - for EVERY transport, so that the classpath is identical across the three
# and only the -Dtransport property differs.  The java classes come from each module's target/classes;
# the native libraries come from the OS-classifier jar of the transport-native-* modules, because
# that is where the build puts META-INF/native/libnetty_transport_native_*.so - target/classes does
# NOT contain it.  Every native jar picked here is checked to really carry such a library, so a
# silently missing .so cannot turn into an UnsatisfiedLinkError at run time.
native_transport_cp() {
    local version; version="$(netty_version)" || return 1
    local n="$ROOT/netty" out="" m dir jar found
    for m in transport-native-unix-common transport-classes-epoll transport-classes-io_uring; do
        dir="$n/$m/target/classes"
        [ -d "$dir" ] || { echo "missing $m build output in $n/$m/target - run ./build.sh" >&2; return 1; }
        out="$out:$dir"
    done
    for m in transport-native-epoll transport-native-io_uring; do
        found=""
        for jar in "$n/$m/target/netty-$m-$version"-*.jar; do
            case "$jar" in *-sources.jar|*-javadoc.jar|*\*.jar) continue ;; esac
            if unzip -l "$jar" 2>/dev/null | grep -q 'META-INF/native/libnetty_transport_native_.*\.so'; then
                found="$jar"; break
            fi
        done
        [ -n "$found" ] || {
            echo "no $m jar carrying META-INF/native/*.so in $n/$m/target - run ./build.sh" >&2; return 1; }
        out="$out:$found"
    done
    echo "${out#:}"
}
