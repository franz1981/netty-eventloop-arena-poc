#!/bin/bash
# ByteBufAllocatorAllocPatternBenchmark: a steady-state live set of MAX_LIVE_BUFFERS buffers with a
# random release order - the case the arena is NOT designed for.  It is here because it is the
# honest comparison: the arena must not be quoted only on the workload that suits it.
#
#   ./run-harness.sh [pattern] [live] [threads] ["ALLOC1 ALLOC2"] [-- extra JMH args]
#   PATTERN=E_COMMERCE LIVE=4096 THREADS=32 ALLOCATORS="ADAPTIVE ARENA" ./run-harness.sh
#
# METHOD (default heapAllocation; the arena serves heap buffers only - directAllocation measures the
# fallback), RW (enableReadWrite, default true).
# E_COMMERCE needs the file e-commerce.jfr in the working directory (see README).
# Peak RSS is parsed out of the .data: the harness prints "cRSS-pRSS:[cur, peak]" per iteration.
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"
require_tools java

PATTERN="${1:-${PATTERN:-E_COMMERCE}}"
LIVE="${2:-${LIVE:-1024}}"
THREADS="${3:-$THREADS}"
ALLOCATORS="${4:-${ALLOCATORS:-ADAPTIVE MIMALLOC ARENA}}"
: "${METHOD:=heapAllocation}"
: "${RW:=true}"
[ $# -gt 4 ] && shift 4 || shift $#
[ "${1:-}" = "--" ] && shift

JAR="$ROOT/target/benchmarks.jar"
[ -f "$JAR" ] || { echo "no $JAR - run ./build.sh first" >&2; exit 1; }
mkdir -p "$RESULTS_DIR"
if [ "$PATTERN" = "E_COMMERCE" ] && [ ! -f e-commerce.jfr ]; then
    echo "E_COMMERCE needs e-commerce.jfr in $(pwd) - see README" >&2; exit 1
fi

freq_hook pin
trap 'freq_hook restore' EXIT

for A in $ALLOCATORS; do
    NAME="harness-t$THREADS-$PATTERN-$LIVE-$A"
    JSON="$RESULTS_DIR/$NAME.json"
    DATA="$RESULTS_DIR/$NAME.data"
    JVM_ARGS=(-jvmArgsAppend "-Xlog:gc")
    [ -n "$JVM_OPTS" ] && JVM_ARGS+=(-jvmArgsAppend "$JVM_OPTS")
    echo "==> $NAME  f=$FORKS wi=$WI i=$I t=$THREADS"
    $PIN_CMD java -jar "$JAR" "ByteBufAllocatorAllocPatternBenchmark.$METHOD" \
        -t "$THREADS" -f "$FORKS" -wi "$WI" -i "$I" -w "$W" -r "$R" \
        -p allocatorType="$A" -p sizePattern="$PATTERN" \
        -p MAX_LIVE_BUFFERS="$LIVE" -p enableReadWrite="$RW" \
        "${JVM_ARGS[@]}" \
        -rf json -rff "$JSON" "$@" > "$DATA" 2>&1 || echo "   (rc=$? - see $DATA)"
    echo "    peak RSS: $(peak_rss "$DATA")"
done
echo "==> $RESULTS_DIR ; summarize with: ./summarize.py $RESULTS_DIR"
