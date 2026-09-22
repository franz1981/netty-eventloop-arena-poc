#!/bin/bash
# END-TO-END: a real netty example server (the same pipelines as HttpSnoopServer / Http2Server),
# one allocator per run, driven by h2load.  Reports req/s, h2load's "time for request" line, RSS
# sampled every 0.5 s, young GC count, and - for the arena - the allocator counters printed by
# E2EServer's shutdown hook.
#
#   ./run-e2e.sh                       # h1, all three allocators, defaults below
#   PROTO=h2 ALLOCATORS="adaptive arena" DURATION=20 ./run-e2e.sh
#
# Knobs (all with defaults, nothing machine-specific):
#   PROTO=h1|h2  ALLOCATORS="adaptive mimalloc arena"  DURATION=20  PORT=8080  LOOPS=8
#   CONNS (h1 64, h2 16)  STREAMS (h2 32)  LOAD_THREADS=4  BODY_SIZE=4096
#   ARENA_MAX_BLOCKS (passed as -Darena.maxBlocks when set)  JVM_OPTS  SUT_PIN_CMD  LOADGEN_PIN_CMD
#   LOGBACK_CONFIG (default e2e/logback-off.xml; set empty to keep the examples' own logging)
#   ARENA_PROPS: extra -D flags for the arena, e.g. ARENA_PROPS="-Darena.cap=16384 -Darena.debug=true".
#     The pinned build's knobs are arena.blockSize / maxBlocks / cap / maxObjects / debug / jfr.period.
#     Its two memory variants are:  heap  JVM_OPTS=-Dio.netty.noPreferDirect=true      direct  (nothing)
#   The -Darena.release / -Darena.hook / readCompleteHook variants of RESULTS.md section 5 belonged to the
#   v2 build and do NOT exist at the pinned commit: the arena is closed by the event loop's tail-task hook.
#
# The example pipelines log every HTTP/2 frame at INFO.  That logging, not the allocator, is the
# bottleneck of these servers - adaptive on h2 measured 23,507 req/s with it and 670,768 without -
# so run-e2e.sh turns logging OFF by default.  Set LOGBACK_CONFIG= to measure the servers as the
# examples ship them.
#
# The arena now serves heap AND direct buffers, so nothing is forced here: pass
# JVM_OPTS=-Dio.netty.noPreferDirect=true to exercise the heap path.  Note that
# AbstractByteBufAllocator.ioBuffer(), which the receive-buffer allocator calls, returns a direct
# buffer whenever direct buffers can be reliably freed and never consults that property.
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"
require_tools java mvn h2load

: "${PROTO:=h1}"
: "${ALLOCATORS:=adaptive mimalloc arena}"
: "${DURATION:=20}"
: "${PORT:=8080}"
: "${LOOPS:=8}"
: "${LOAD_THREADS:=4}"
: "${BODY_SIZE:=4096}"
: "${STREAMS:=32}"
: "${LOGBACK_CONFIG:=$ROOT/e2e/logback-off.xml}"
: "${ARENA_PROPS:=}"
case "$PROTO" in
    h1) : "${CONNS:=64}" ;;
    h2) : "${CONNS:=16}" ;;
    *)  echo "PROTO must be h1 or h2" >&2; exit 1 ;;
esac

[ -e "$ROOT/netty/pom.xml" ] || { echo "the netty submodule is empty" >&2; exit 1; }
NETTY_VERSION="$(netty_version)"
mkdir -p "$RESULTS_DIR"

# --- classpath: the example module's dependencies + the example jar + the mimalloc module jar ----
EXAMPLE_JAR="$ROOT/netty/example/target/netty-example-$NETTY_VERSION.jar"
[ -f "$EXAMPLE_JAR" ] || { echo "no $EXAMPLE_JAR - run ./build.sh (without --no-example)" >&2; exit 1; }
MIMALLOC_JAR="$(ls "$ROOT"/netty-allocator/mimalloc/target/mimalloc-*.jar 2>/dev/null | grep -v -- '-sources\|-javadoc' | head -1 || true)"
[ -n "$MIMALLOC_JAR" ] || { echo "no mimalloc jar - run ./build.sh" >&2; exit 1; }
DEP_CP_FILE="$ROOT/target/e2e-classpath.txt"
if [ ! -s "$DEP_CP_FILE" ]; then
    mkdir -p "$ROOT/target"
    (cd "$ROOT/netty/example" && mvn $MVN_FLAGS dependency:build-classpath -Dmdep.outputFile="$DEP_CP_FILE")
fi
CP="$EXAMPLE_JAR:$MIMALLOC_JAR:$(cat "$DEP_CP_FILE")"

BODY="$RESULTS_DIR/body-$BODY_SIZE.bin"
[ -s "$BODY" ] || head -c "$BODY_SIZE" /dev/zero | tr '\0' 'x' > "$BODY"

# Stop ONLY by matching E2EServer inside /proc/<pid>/cmdline.  pkill -f would match this shell.
server_pids() {
    local p
    for p in $(pgrep -x java 2>/dev/null); do
        tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- 'E2EServer' && echo "$p"
    done
}
stop_server() {
    local p
    for p in $(server_pids); do kill "$p" 2>/dev/null || true; done
    for _ in $(seq 1 60); do [ -z "$(server_pids)" ] && return 0; sleep 0.2; done
    for p in $(server_pids); do kill -9 "$p" 2>/dev/null || true; done
}

freq_hook pin
trap 'stop_server; freq_hook restore' EXIT

SUMMARY="$RESULTS_DIR/e2e-$PROTO-summary.txt"
: > "$SUMMARY"

for A in $ALLOCATORS; do
    TAG="$PROTO-$A"
    SRV="$RESULTS_DIR/$TAG.server.log"; GC="$RESULTS_DIR/$TAG.gc"
    RSS="$RESULTS_DIR/$TAG.rss";        LOAD="$RESULTS_DIR/$TAG.h2load"

    [ -n "$(server_pids)" ] && stop_server
    echo "==> $TAG: server, $LOOPS event loops, port $PORT"
    ARENA_OPT=()
    [ -n "${ARENA_MAX_BLOCKS:-}" ] && ARENA_OPT=("-Darena.maxBlocks=$ARENA_MAX_BLOCKS")
    [ -n "$LOGBACK_CONFIG" ] && ARENA_OPT+=("-Dlogback.configurationFile=$LOGBACK_CONFIG")
    # shellcheck disable=SC2206
    [ -n "$ARENA_PROPS" ] && ARENA_OPT+=($ARENA_PROPS)
    # shellcheck disable=SC2086
    $SUT_PIN_CMD java -cp "$CP" $JVM_OPTS "${ARENA_OPT[@]}" \
        "-Xlog:gc:file=$GC" "$ROOT/e2e/E2EServer.java" "$A" "$PROTO" "$PORT" "$LOOPS" \
        > "$SRV" 2>&1 &

    for _ in $(seq 1 300); do grep -q '^READY ' "$SRV" 2>/dev/null && break; sleep 0.2; done
    grep -q '^READY ' "$SRV" || { echo "   server never printed READY - see $SRV"; stop_server; continue; }
    PID="$(server_pids | head -1)"
    echo "   READY pid=$PID"

    # RSS sampler: "<epoch>.<frac> <rss_kb>" every 0.5 s
    : > "$RSS"
    ( while kill -0 "$PID" 2>/dev/null; do
          echo "$(date +%s.%N | cut -c1-14) $(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ')" >> "$RSS"
          sleep 0.5
      done ) &
    SAMPLER=$!

    if [ "$PROTO" = h1 ]; then
        H2LOAD_ARGS=(--h1 -c "$CONNS" -t "$LOAD_THREADS" -D "$DURATION" -d "$BODY")
    else
        H2LOAD_ARGS=(-c "$CONNS" -m "$STREAMS" -t "$LOAD_THREADS" -D "$DURATION" -d "$BODY")
    fi
    echo "   h2load ${H2LOAD_ARGS[*]} http://127.0.0.1:$PORT/"
    # shellcheck disable=SC2086
    $LOADGEN_PIN_CMD h2load "${H2LOAD_ARGS[@]}" "http://127.0.0.1:$PORT/" > "$LOAD" 2>&1 \
        || echo "   (h2load rc=$? - see $LOAD)"

    kill "$SAMPLER" 2>/dev/null || true; wait "$SAMPLER" 2>/dev/null || true
    stop_server
    sleep 0.5

    RPS="$(sed -n 's/^finished in [^,]*, \([0-9.]*\) req\/s.*/\1/p' "$LOAD" | head -1)"
    LAT="$(sed -n 's/^time for request: *//p' "$LOAD" | head -1)"
    GCN="$(grep -c 'Pause Young' "$GC" 2>/dev/null || true)"
    RSSS="$(awk '{if (n==0) mn=$2; if ($2>mx) mx=$2; if ($2<mn) mn=$2; s+=$2; n++}
                 END{ if (n) printf "%.0f->%.0f MB (mean %.0f, %d samples)", mn/1024, mx/1024, s/n/1024, n;
                      else printf "no samples" }' "$RSS")"
    CNT="$(grep -m1 '^ARENATELE' "$SRV" || true)"
    printf '%-9s %14s req/s | %s | RSS %s | %s young GCs%s\n' \
        "$A" "${RPS:-0}" "${LAT:-(no latency line)}" "$RSSS" "${GCN:-0}" \
        "${CNT:+ | $CNT}" >> "$SUMMARY"
done

trap 'freq_hook restore' EXIT
echo
STREAM_TXT=""
[ "$PROTO" = h2 ] && STREAM_TXT=" x $STREAMS streams"
echo "== end to end, $PROTO, ${DURATION}s, $CONNS connections$STREAM_TXT, $LOOPS event loops =="
cat "$SUMMARY"
echo "raw logs in $RESULTS_DIR"
