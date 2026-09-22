#!/bin/bash
# CycleScopedAllocBenchmark: allocate k buffers, use each, release all k - the scope-aligned case.
# All three allocators unless restricted.  Any extra argument is passed straight to JMH, so a single
# cell is:
#
#   FORKS=1 WI=1 I=1 ./run-cycle.sh -p k=8 -p sizes=SMALL -p releaseOrder=FIFO -p allocatorType=ARENA
#
# Env: see lib/env.sh (PIN_CMD, CPU_FREQ_HOOK, JVM_OPTS, FORKS/WI/I/W/R/THREADS, RESULTS_DIR).
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"
require_tools java

: "${NAME:=cycle}"
: "${BENCH:=CycleScopedAllocBenchmark}"
JAR="$ROOT/target/benchmarks.jar"
[ -f "$JAR" ] || { echo "no $JAR - run ./build.sh first" >&2; exit 1; }

mkdir -p "$RESULTS_DIR"
JSON="$RESULTS_DIR/$NAME.json"
DATA="$RESULTS_DIR/$NAME.data"

JVM_ARGS=()
[ -n "$JVM_OPTS" ] && JVM_ARGS=(-jvmArgsAppend "$JVM_OPTS")

freq_hook pin
trap 'freq_hook restore' EXIT

echo "==> $BENCH  f=$FORKS wi=$WI i=$I t=$THREADS  -> $JSON"
set -x
$PIN_CMD java -jar "$JAR" "$BENCH" \
    -t "$THREADS" -f "$FORKS" -wi "$WI" -i "$I" -w "$W" -r "$R" \
    "${JVM_ARGS[@]}" \
    -rf json -rff "$JSON" "$@" > "$DATA" 2>&1
rc=$?
set +x
echo "==> rc=$rc  data=$DATA  json=$JSON"
exit $rc
