#!/bin/bash
# Section 7 of RESULTS.md: the PROVIDED-BUFFER-RING allocator, iterated.  One e2e cell per candidate,
# the channel allocator held at ADAPTIVE and zero-copy writes OFF, so the only variable is who fills
# the ring.
#
#   RESULTS_DIR=... CANDIDATES="adaptive slab slab3" PROTOS="h1 h2" ./ring-alloc-e2e.sh
#
# Knobs:
#   CANDIDATES  values for BUFFER_RING_ALLOC (see lib/java/Transports.java)
#   PROTOS      h1 and/or h2
#   DURATION    h2load seconds per cell (default 20)
#   LOOPS       event loops (default 8)
#   ASPROF      path to asprof: one 14 s CPU profile per cell, started 3 s into the load
#   CELL_WRAPPER  the mutex + frequency + load wrapper each cell runs under, e.g.
#                 CELL_WRAPPER="/path/benchlock.sh run ringalloc /path/ringcell.sh"
#   EXTRA_PROPS   extra -D flags for every cell (e.g. -Dio.netty.iouring.bufferRing.noSliceHandoff=true)
#   ZC            zero-copy write threshold, default -1 = OFF (netty's default; the threshold-4096
#                 configuration is netty/netty#17632 and is NOT what this section measures)
set -u
cd "$(dirname "$0")"
source lib/env.sh

: "${CANDIDATES:=adaptive builtinadaptive slab slab2fixed slab2 slab3fixed slab3 slab3huge arena}"
: "${PROTOS:=h1 h2}"
: "${DURATION:=20}"
: "${LOOPS:=8}"
: "${ZC:=-1}"
: "${CELL_WRAPPER:=}"
: "${EXTRA_PROPS:=}"
: "${PROV:=$RESULTS_DIR/run-provenance.log}"

mkdir -p "$RESULTS_DIR"
: > "$RESULTS_DIR/cells.txt"

for P in $PROTOS; do
  for RA in $CANDIDATES; do
    PROPS="-Diouring.zeroCopyThreshold=$ZC $EXTRA_PROPS"
    # R6 has two shapes: the arena with its in-block ring off (its default) and on.
    case "$RA" in
      arena)      RAV=arena; PROPS="$PROPS -Darena.ring=false"; TAG="arena-ringfalse" ;;
      arenaring)  RAV=arena; PROPS="$PROPS -Darena.ring=true";  TAG="arena-ringtrue"  ;;
      *)          RAV="$RA"; TAG="$RA" ;;
    esac
    echo "############ e2e $P ring=$TAG"
    {
      echo "### cell e2e-$P-$TAG  $(date -Is)"
      # shellcheck disable=SC2086
      env RESULTS_DIR="$RESULTS_DIR" PROTO="$P" ALLOCATORS=adaptive DURATION="$DURATION" \
          LOOPS="$LOOPS" TRANSPORT=io_uring BUFFER_RING=on BUFFER_RING_ALLOC="$RAV" \
          TAG_SUFFIX="-ra-$TAG" SERVER_PROPS="$PROPS" \
          SUT_PIN_CMD="${SUT_PIN_CMD:-}" LOADGEN_PIN_CMD="${LOADGEN_PIN_CMD:-}" \
          ASPROF="${ASPROF:-}" \
          $CELL_WRAPPER ./run-e2e.sh
    } 2>&1 | tee -a "$PROV"
    echo "e2e-$P-$TAG" >> "$RESULTS_DIR/cells.txt"
  done
done

echo
echo "== RINGTELE / THPTELE / BUFRINGTELE =="
grep -h -E '^(RINGTELE|THPTELE|BUFRINGTELE|ARENATELE)' "$RESULTS_DIR"/io_uring-*-ra-*.server.log 2>/dev/null || echo "(none)"
