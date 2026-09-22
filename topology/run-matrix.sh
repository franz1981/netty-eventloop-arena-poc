#!/bin/bash
# The six lifecycle-topology workloads (seven cells: W6 has two variants), for one transport and one
# or more allocators.  The per-workload load commands are the ones documented at the top of run.sh;
# this script only loops over them so that a transport x allocator matrix is one command.
#
#   RESULTS_DIR=... TRANSPORT=io_uring ALLOCS="adaptive arena" topology/run-matrix.sh
#   WORKLOADS="w1 w5" ALLOCS=arena EXTRA_PROPS="-Darena.ring=false" NAME_SUFFIX=ringfalse \
#       topology/run-matrix.sh
#
# Names (and therefore every output file) are "<workload>-<transport>-<allocator>[-<suffix>]".
set -u
source "$(dirname "$0")/common.sh"

: "${TRANSPORT:=nio}"
: "${ALLOCS:=adaptive arena}"
: "${WORKLOADS:=w1 w2 w3 w4 w5 w6a w6b}"
: "${NAME_SUFFIX:=}"
: "${EXTRA_PROPS:=}"
: "${WSTART:=3}"
: "${WLEN:=1.5}"
export TRANSPORT

mkdir -p "$RESULTS_DIR"
topo_bodies "$RESULTS_DIR" || exit 1

for A in $ALLOCS; do
    export ALLOC="$A"
    for W in $WORKLOADS; do
        NAME="$W-$TRANSPORT-$A${NAME_SUFFIX:+-$NAME_SUFFIX}"
        echo "=== $NAME"
        case "$W" in
            w1) EXTRA_JVM="$EXTRA_PROPS" "$TOPO/run.sh" "$NAME" h1snoop 18080 4 "$WSTART" "$WLEN" -- \
                    h2load --h1 -c 64 -t 4 -D 8 -d "$RESULTS_DIR/body4k" http://127.0.0.1:18080/ ;;
            w2) EXTRA_JVM="$EXTRA_PROPS" "$TOPO/run.sh" "$NAME" h2hello 18080 4 "$WSTART" "$WLEN" -- \
                    h2load -c 16 -m 32 -t 4 -D 8 -d "$RESULTS_DIR/body4k" http://127.0.0.1:18080/ ;;
            w3) EXTRA_JVM="$EXTRA_PROPS" "$TOPO/run.sh" "$NAME" h2echo 18080 4 "$WSTART" "$WLEN" -- \
                    h2load -c 8 -m 16 -t 4 -D 8 -w 12 -d "$RESULTS_DIR/body64k" http://127.0.0.1:18080/ ;;
            w4) EXTRA_JVM="-Dtopo.sndbuf=16384 $EXTRA_PROPS" "$TOPO/run.sh" "$NAME" h1echo 18080 4 "$WSTART" "$WLEN" -- \
                    python3 "$TOPO/slowread.py" 18080 64 8 ;;
            w5) EXTRA_JVM="$EXTRA_PROPS" "$TOPO/run.sh" "$NAME" h1agg 18080 4 "$WSTART" "$WLEN" -- \
                    h2load --h1 -c 64 -t 4 -D 8 -d "$RESULTS_DIR/body256k" http://127.0.0.1:18080/ ;;
            w6a) JVM_OPTS="${JVM_OPTS:-} $EXTRA_PROPS" "$TOPO/run6.sh" "$NAME" proxy  "$WSTART" "$WLEN" ;;
            w6b) JVM_OPTS="${JVM_OPTS:-} $EXTRA_PROPS" "$TOPO/run6.sh" "$NAME" proxy2 "$WSTART" "$WLEN" ;;
            *) echo "unknown workload $W" >&2; exit 1 ;;
        esac
    done
done

echo
echo "== ARENATELE / RINGTELE lines, $TRANSPORT =="
grep -h -E '^(ARENATELE|RINGTELE)' "$RESULTS_DIR"/*-"$TRANSPORT"-*-server.log 2>/dev/null || echo "(none)"
