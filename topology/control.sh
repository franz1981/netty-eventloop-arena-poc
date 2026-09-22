#!/bin/bash
# How much the instrumentation itself costs: the same workloads with the IterationEnd tail task on
# and off, no JFR recording, server CPU read from /proc/<pid>/stat (utime+stime).
# This is the measurement behind the "use wall-clock on W4, not the iteration column" caveat.
set -u
source "$(dirname "$0")/common.sh"
require_tools java javac h2load python3 bc || exit 1

mkdir -p "$RESULTS_DIR"
topo_bodies "$RESULTS_DIR" || exit 1
topo_compile || exit 1
CP="$(topo_cp)" || exit 1
trap 'topo_stop_all' EXIT

run() {   # name pipeline markers loadcmd...
    local nm=$1 pipe=$2 mk=$3; shift 3
    # shellcheck disable=SC2086
    $SUT_PIN_CMD java $JVM_OPTS -Xms2g -Xmx4g -XX:+UseParallelGC \
        -Dio.netty.allocator.type=adaptive -Dtopo.markers=$mk -Dtopo.sndbuf=${SND:-0} \
        -cp "$CP" TopoServer "$pipe" 18080 4 > "$RESULTS_DIR/ctl-$nm.log" 2>&1 &
    local srv=$!
    for _ in $(seq 1 60); do grep -q READY "$RESULTS_DIR/ctl-$nm.log" && break; sleep 0.5; done
    local c0; c0=$(awk '{print $14+$15}' /proc/$srv/stat)
    # shellcheck disable=SC2086
    $LOADGEN_PIN_CMD "$@" > "$RESULTS_DIR/ctl-$nm-load.log" 2>&1
    local c1; c1=$(awk '{print $14+$15}' /proc/$srv/stat)
    echo "$nm markers=$mk serverCPU=$(( c1 - c0 ))ticks ($(echo "scale=2;($c1-$c0)/100" | bc)s) $(grep -oE 'finished in [^,]*, [0-9.]+ req/s' "$RESULTS_DIR/ctl-$nm-load.log" || grep -oE 'requests=[0-9]+' "$RESULTS_DIR/ctl-$nm-load.log")"
    kill $srv 2>/dev/null; wait $srv 2>/dev/null
}

run w1-mk h1snoop true  h2load --h1 -c 64 -t 4 -D 8 -d "$RESULTS_DIR/body4k" http://127.0.0.1:18080/
run w1-no h1snoop false h2load --h1 -c 64 -t 4 -D 8 -d "$RESULTS_DIR/body4k" http://127.0.0.1:18080/
SND=16384
run w4-mk h1echo true  python3 "$TOPO/slowread.py" 18080 64 8
run w4-no h1echo false python3 "$TOPO/slowread.py" 18080 64 8
