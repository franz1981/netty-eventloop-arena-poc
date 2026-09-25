#!/bin/bash
# Section 7 of RESULTS.md: the lifecycle-topology half.  W1 (4 KiB HTTP/1.1 snoop), W3 (64 KiB HTTP/2
# echo) and W5 (256 KiB HTTP/1.1 aggregator - the drought case) for each provided-buffer-ring
# allocator candidate, channel allocator held at ADAPTIVE, zero-copy writes OFF.  W3 is the cell where
# the buffer SIZE decides the result (RESULTS.md 6.2) and W5 the one where a fixed population ran dry.
#
#   RESULTS_DIR=... CANDIDATES="slab slab3" WORKLOADS="w1 w3 w5" ./ring-alloc-topology.sh
#
# Knobs: CANDIDATES, WORKLOADS, LOOPS (4), CELL_WRAPPER, EXTRA_PROPS, ZC (-1 = zero copy off).
set -u
cd "$(dirname "$0")"
source lib/env.sh
source topology/common.sh

: "${CANDIDATES:=adaptive builtinadaptive slab slab2fixed slab2 slab3fixed slab3 slab3huge arena arenaring}"
: "${WORKLOADS:=w1 w3 w5}"
: "${LOOPS:=4}"
: "${ZC:=-1}"
: "${CELL_WRAPPER:=}"
: "${EXTRA_PROPS:=}"
: "${NAME_SUFFIX:=}"     # appended to every cell name, so repeats do not overwrite each other
: "${WSTART:=3}"
: "${WLEN:=1.5}"
: "${PROV:=$RESULTS_DIR/run-provenance.log}"

mkdir -p "$RESULTS_DIR"
topo_bodies "$RESULTS_DIR" || exit 1

for RA in $CANDIDATES; do
  case "$RA" in
    arena)      RAV=arena; P="-Darena.ring=false"; TAG="arena-ringfalse" ;;
    arenaring)  RAV=arena; P="-Darena.ring=true";  TAG="arena-ringtrue"  ;;
    *)          RAV="$RA"; P=""; TAG="$RA" ;;
  esac
  for W in $WORKLOADS; do
    NAME="$W-io_uring-adaptive-ra-$TAG${NAME_SUFFIX:+-$NAME_SUFFIX}"
    echo "############ topology $W ring=$TAG"
    case "$W" in
      w1) PIPE=h1snoop; LOAD=(h2load --h1 -c 64 -t 4 -D 8 -d "$RESULTS_DIR/body4k"   http://127.0.0.1:18080/) ;;
      w3) PIPE=h2echo;  LOAD=(h2load -c 8 -m 16 -t 4 -D 8 -w 12 -d "$RESULTS_DIR/body64k" http://127.0.0.1:18080/) ;;
      w5) PIPE=h1agg;   LOAD=(h2load --h1 -c 64 -t 4 -D 8 -d "$RESULTS_DIR/body256k" http://127.0.0.1:18080/) ;;
      *)  echo "unknown workload $W" >&2; exit 1 ;;
    esac
    {
      echo "### cell $NAME  $(date -Is)"
      # shellcheck disable=SC2086
      env RESULTS_DIR="$RESULTS_DIR" ALLOC=adaptive TRANSPORT=io_uring BUFFER_RING=on \
          BUFFER_RING_ALLOC="$RAV" \
          EXTRA_JVM="-Diouring.zeroCopyThreshold=$ZC $P $EXTRA_PROPS" \
          SUT_PIN_CMD="${SUT_PIN_CMD:-}" LOADGEN_PIN_CMD="${LOADGEN_PIN_CMD:-}" \
          $CELL_WRAPPER topology/run.sh "$NAME" "$PIPE" 18080 "$LOOPS" "$WSTART" "$WLEN" -- "${LOAD[@]}"
    } 2>&1 | tee -a "$PROV"
  done
done

echo
echo "== RINGTELE / THPTELE / BUFRINGTELE / ARENATELE =="
grep -h -E '^(RINGTELE|THPTELE|BUFRINGTELE|ARENATELE)' "$RESULTS_DIR"/*-ra-*-server.log 2>/dev/null || echo "(none)"
