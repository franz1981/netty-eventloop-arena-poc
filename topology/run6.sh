#!/bin/bash
# W6: a TCP proxy in front of an h1snoop backend, with the outbound channel on the inbound
# channel's own event loop (proxy, W6a) or on a separate group (proxy2, W6b).
#
#   topology/run6.sh <name> <proxy|proxy2> <window_start_s> <window_len_s>
set -u
source "$(dirname "$0")/common.sh"
require_tools java javac h2load jcmd || exit 1

NAME=$1; PIPE=$2; WSTART=$3; WLEN=$4
mkdir -p "$RESULTS_DIR"
topo_bodies "$RESULTS_DIR" || exit 1
topo_compile || exit 1
CP="$(topo_cp)" || exit 1
JVM="$JVM_OPTS -Xms2g -Xmx4g -XX:+UseParallelGC -Dio.netty.allocator.type=adaptive"
JVM="$JVM -XX:FlightRecorderOptions:stackdepth=${STACKDEPTH:-32}"

[ -n "$(topo_pids)" ] && topo_stop_all
trap 'topo_stop_all' EXIT

# shellcheck disable=SC2086
$SUT_PIN_CMD java $JVM -cp "$CP" TopoServer h1snoop 18081 2 > "$RESULTS_DIR/$NAME-back.log" 2>&1 &
# shellcheck disable=SC2086
$SUT_PIN_CMD java $JVM -cp "$CP" TopoServer "$PIPE" 18443 4 18081 > "$RESULTS_DIR/$NAME-server.log" 2>&1 &
SRV=$!
for _ in $(seq 1 60); do
    grep -q READY "$RESULTS_DIR/$NAME-server.log" 2>/dev/null &&
    grep -q READY "$RESULTS_DIR/$NAME-back.log" 2>/dev/null && break
    sleep 0.5
done
grep -h READY "$RESULTS_DIR/$NAME-back.log" "$RESULTS_DIR/$NAME-server.log" || {
    echo FAILED; cat "$RESULTS_DIR/$NAME-server.log" "$RESULTS_DIR/$NAME-back.log"; exit 1; }

( sleep "$WSTART"
  jcmd $SRV JFR.start name=topo settings="$TOPO/topo.jfc" filename="$RESULTS_DIR/$NAME.jfr" > /dev/null 2>&1
  sleep "$WLEN"
  jcmd $SRV JFR.stop name=topo > /dev/null 2>&1
  echo "WINDOW DONE" ) &
WIN=$!

# shellcheck disable=SC2086
$LOADGEN_PIN_CMD h2load --h1 -c 64 -t 4 -D 8 -d "$RESULTS_DIR/body4k" http://127.0.0.1:18443/ \
    > "$RESULTS_DIR/$NAME-load.log" 2>&1
wait $WIN; sleep 1
topo_stop_all
trap - EXIT

ls -l "$RESULTS_DIR/$NAME.jfr" 2>/dev/null || { echo "NO JFR"; exit 1; }
grep -E "finished in|requests:|status codes" "$RESULTS_DIR/$NAME-load.log"

LABEL="$(awk -F'|' -v w="$NAME" '$1==w {print $2}' "$TOPO/labels.txt")"
java -cp "$CLASSES" Dump "$RESULTS_DIR/$NAME.jfr" "$RESULTS_DIR/$NAME.tsv"
( cd "$RESULTS_DIR" && python3 "$TOPO/topology.py" "$NAME.tsv" "${LABEL:-$NAME}" ) | tee "$RESULTS_DIR/$NAME.txt"
