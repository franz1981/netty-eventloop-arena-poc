#!/bin/bash
# JMH microbenchmark of the PROVIDED-BUFFER-RING allocator alone (bench/RingAllocBench.java).
# One op = one buffer's whole trip through the ring: allocate -> what add() reads -> lastBytesRead ->
# retainedSlice -> the ring's release -> the pipeline's release.
#
#   ./run-ringbench.sh                                  # all candidates, avgt + perfnorm
#   PROF=perfnorm ALLOCS='slab,slab3' ./run-ringbench.sh
#   FORKS=1 PROF=none ./run-ringbench.sh                # smoke
#
# Knobs: ALLOCS (comma list for -p alloc), INFLIGHT (-p inFlight), BENCH (regexp), FORKS, WI, I,
#        PROF=none|perfnorm|perfasm, OUT (json), JVM_OPTS, SUT_PIN_CMD.
# Everything is built into target/ringbench-classes with the jmh jars out of ~/.m2 - this script does
# NOT touch the netty-allocator harness jar.
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"
require_tools java javac

: "${ALLOCS:=adaptive,builtinadaptive,slab,slab2,slab2fixed,slab3,slab3fixed}"
: "${INFLIGHT:=1,32}"
: "${BENCH:=RingAllocBench.ownerCycle}"
: "${PARAMS:=alloc,inFlight}"    # comma list of the @Param names to pass; empty = pass none
: "${PROF:=perfnorm}"
: "${JMH_VERSION:=1.37}"
: "${OUT:=$RESULTS_DIR/ringbench.json}"

M2="$HOME/.m2/repository"
JMH_CP="$M2/org/openjdk/jmh/jmh-core/$JMH_VERSION/jmh-core-$JMH_VERSION.jar"
JMH_AP="$M2/org/openjdk/jmh/jmh-generator-annprocess/$JMH_VERSION/jmh-generator-annprocess-$JMH_VERSION.jar"
JOPT="$(ls "$M2"/net/sf/jopt-simple/jopt-simple/*/jopt-simple-*.jar | grep -v -- '-sources\|-javadoc' | tail -1)"
MATH="$(ls "$M2"/org/apache/commons/commons-math3/*/commons-math3-*.jar | grep -v -- '-sources\|-javadoc' | tail -1)"
for j in "$JMH_CP" "$JMH_AP" "$JOPT" "$MATH"; do
    [ -f "$j" ] || { echo "missing $j - JMH $JMH_VERSION is not in ~/.m2" >&2; exit 1; }
done

NETTY_VERSION="$(netty_version)"
EXAMPLE_JAR="$ROOT/netty/example/target/netty-example-$NETTY_VERSION.jar"
[ -f "$EXAMPLE_JAR" ] || { echo "no $EXAMPLE_JAR - run ./build.sh" >&2; exit 1; }
DEP_CP_FILE="$ROOT/target/e2e-classpath.txt"
[ -s "$DEP_CP_FILE" ] || { echo "no $DEP_CP_FILE - run ./run-e2e.sh once, or ./build.sh" >&2; exit 1; }
NATIVE_CP="$(native_transport_cp)" || exit 1
BASE_CP="$EXAMPLE_JAR:$NATIVE_CP:$(cat "$DEP_CP_FILE")"

CLASSES="$ROOT/target/ringbench-classes"
rm -rf "$CLASSES"; mkdir -p "$CLASSES" "$RESULTS_DIR"
javac -nowarn -proc:full -processorpath "$JMH_AP:$JMH_CP" -d "$CLASSES" \
    -cp "$JMH_CP:$BASE_CP" \
    "$ROOT/bench/RingAllocBench.java" "$ROOT/bench/RingAllocForeignBench.java" \
    "$ROOT/bench/RingAllocs.java" "$ROOT/lib/java/RegisteredSlabBufferRingAllocator.java" \
    "$ROOT/lib/java/SlabV2BufferRingAllocator.java"

RUN_CP="$CLASSES:$JMH_CP:$JOPT:$MATH:$BASE_CP"
ARGS=(-f "${FORKS:-3}" -wi "${WI:-5}" -i "${I:-5}" -w 1 -r 1 -rf json -rff "$OUT")
case ",$PARAMS," in *,alloc,*) ARGS+=(-p "alloc=$ALLOCS") ;; esac
case ",$PARAMS," in *,inFlight,*) ARGS+=(-p "inFlight=$INFLIGHT") ;; esac
[ "$PROF" != none ] && ARGS+=(-prof "$PROF")

echo "== ringbench: $BENCH  alloc=$ALLOCS inFlight=$INFLIGHT forks=${FORKS:-3} prof=$PROF"
# shellcheck disable=SC2086
exec $SUT_PIN_CMD java $JVM_OPTS -cp "$RUN_CP" org.openjdk.jmh.Main "${ARGS[@]}" "$BENCH"
