#!/bin/bash
# One lifecycle-topology workload: start TopoServer with a pipeline, record a JFR window in the
# middle of a load run, then pair the buffer events against the iteration markers.
#
#   topology/run.sh <name> <pipeline> <port> <loops> <window_start_s> <window_len_s> -- <load cmd...>
#
# pipeline: h1snoop | h2hello | h2echo | h1echo | h1agg   (proxy/proxy2 -> run6.sh)
# Env: SUT_PIN_CMD pins the server, LOADGEN_PIN_CMD the load.  RESULTS_DIR holds the output.
#      EXTRA_JVM, STACKDEPTH (12), BACKPORT.
#      ALLOC=adaptive|arena|mimalloc (-Dtopo.alloc), TRANSPORT=nio|epoll|io_uring (-Dtransport).
#      Put both in <name> when you run more than one cell, e.g. name=w1-io_uring-arena.
#
# The workloads of the reference run (their exact original flags were NOT recorded; these are
# reconstructed from labels.txt and the h2load logs - see results/<machine>/topology/README.md):
#   W1  run.sh w1 h1snoop 18080 4 3 1.5 -- h2load --h1 -c 64 -t 4 -D 8 -d $RESULTS_DIR/body4k   http://127.0.0.1:18080/
#   W2  run.sh w2 h2hello 18080 4 3 1.5 -- h2load -c 16 -m 32 -t 4 -D 8 -d $RESULTS_DIR/body4k   http://127.0.0.1:18080/
#   W3  run.sh w3 h2echo  18080 4 3 1.5 -- h2load -c 8 -m 16 -t 4 -D 8 -w 12 -d $RESULTS_DIR/body64k http://127.0.0.1:18080/
#   W4  run.sh w4 h1echo  18080 4 3 1.5 -- python3 topology/slowread.py 18080 64 8     (with -Dtopo.sndbuf=16384)
#   W5  run.sh w5 h1agg   18080 4 3 1.5 -- h2load --h1 -c 64 -t 4 -D 8 -d $RESULTS_DIR/body256k http://127.0.0.1:18080/
set -u
source "$(dirname "$0")/common.sh"
require_tools java javac h2load python3 jcmd || exit 1

[ $# -ge 8 ] && [ "$7" = "--" ] || {
    echo "usage: topology/run.sh <name> <pipeline> <port> <loops> <window_start_s> <window_len_s> -- <load cmd...>" >&2
    echo "       pipeline: h1snoop | h2hello | h2echo | h1echo | h1agg   (proxy/proxy2 -> run6.sh)" >&2
    exit 1
}
NAME=$1; PIPE=$2; PORT=$3; LOOPS=$4; WSTART=$5; WLEN=$6; shift 7   # shift past the --

mkdir -p "$RESULTS_DIR"
topo_bodies "$RESULTS_DIR" || exit 1
topo_compile || exit 1
CP="$(topo_cp)" || exit 1
JVM="${EXTRA_JVM:-} $JVM_OPTS -Xms2g -Xmx4g -XX:+UseParallelGC -Dio.netty.allocator.type=adaptive"
JVM="$JVM -Dtopo.alloc=${ALLOC:-adaptive} -Dtransport=${TRANSPORT:-nio}"
JVM="$JVM -XX:FlightRecorderOptions:stackdepth=${STACKDEPTH:-12}"

[ -n "$(topo_pids)" ] && topo_stop_all
trap 'topo_stop_all' EXIT

# shellcheck disable=SC2086
$SUT_PIN_CMD java $JVM -cp "$CP" TopoServer "$PIPE" "$PORT" "$LOOPS" ${BACKPORT:-} \
    > "$RESULTS_DIR/$NAME-server.log" 2>&1 &
SRV=$!
for _ in $(seq 1 60); do grep -q READY "$RESULTS_DIR/$NAME-server.log" 2>/dev/null && break; sleep 0.5; done
grep -q READY "$RESULTS_DIR/$NAME-server.log" || {
    echo "SERVER FAILED"; cat "$RESULTS_DIR/$NAME-server.log"; exit 1; }
head -1 "$RESULTS_DIR/$NAME-server.log"

( sleep "$WSTART"
  jcmd $SRV JFR.start name=topo settings="$TOPO/topo.jfc" filename="$RESULTS_DIR/$NAME.jfr" > /dev/null 2>&1
  sleep "$WLEN"
  jcmd $SRV JFR.stop name=topo > /dev/null 2>&1
  echo "WINDOW DONE" ) &
WIN=$!

# shellcheck disable=SC2086
$LOADGEN_PIN_CMD "$@" > "$RESULTS_DIR/$NAME-load.log" 2>&1
wait $WIN
sleep 1
topo_stop_all
trap - EXIT

ls -l "$RESULTS_DIR/$NAME.jfr" 2>/dev/null || { echo "NO JFR"; exit 1; }
tail -20 "$RESULTS_DIR/$NAME-load.log"

LABEL="$(awk -F'|' -v w="$NAME" '$1==w {print $2}' "$TOPO/labels.txt")"
java -cp "$CLASSES" Dump "$RESULTS_DIR/$NAME.jfr" "$RESULTS_DIR/$NAME.tsv"
( cd "$RESULTS_DIR" && python3 "$TOPO/topology.py" "$NAME.tsv" "${LABEL:-$NAME}" ) | tee "$RESULTS_DIR/$NAME.txt"
