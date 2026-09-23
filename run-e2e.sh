#!/bin/bash
# END-TO-END: a real netty example server (the same pipelines as HttpSnoopServer / Http2Server),
# one allocator per run, driven by h2load.  Reports req/s, h2load's "time for request" line, RSS
# sampled every 0.5 s, young GC count, and - for the arena - the allocator counters printed by
# E2EServer's shutdown hook.
#
#   ./run-e2e.sh                       # h1, all three allocators, defaults below
#   PROTO=h2 ALLOCATORS="adaptive arena" DURATION=20 ./run-e2e.sh
#   TRANSPORT=io_uring ./run-e2e.sh    # nio (default) | epoll | io_uring
#
# Knobs (all with defaults, nothing machine-specific):
#   PROTO=h1|h2  ALLOCATORS="adaptive mimalloc arena"  DURATION=20  PORT=8080  LOOPS=8
#   TRANSPORT=nio|epoll|io_uring  (passed to the server as -Dtransport; io_uring registers a provided
#     buffer ring per worker loop, filled by the allocator under test, and sets the buffer-group-id
#     and write-zero-copy-threshold child options - see lib/java/Transports.java and the README)
#   BUFFER_RING=on|off  (io_uring only, default on)  off = no IoUringBufferRingConfig and no
#     IO_URING_BUFFER_GROUP_ID: recv takes its buffer from the channel allocator.  Zero-copy writes,
#     single issuer, multishot accept/poll are unchanged; multishot RECV is unreachable without a
#     provided buffer ring, so off also means one-shot recv.
#   BUFFER_RING_ALLOC=same|adaptive|builtin|slab  (io_uring, BUFFER_RING=on only) who fills the ring.
#   CONNS (h1 64, h2 16)  STREAMS (h2 32)  LOAD_THREADS=4  BODY_SIZE=4096
#   ARENA_MAX_BLOCKS (passed as -Darena.maxBlocks when set)  JVM_OPTS  SUT_PIN_CMD  LOADGEN_PIN_CMD
#   LOGBACK_CONFIG (default e2e/logback-off.xml; set empty to keep the examples' own logging)
#   ASPROF=<path to asprof> PROFILE_SECS=14 PROFILE_INTERVAL=1ms TAG_SUFFIX=-prof  (one CPU profile
#     per allocator, collapsed stacks next to the other outputs; reduce with tools/asprof-*.py)
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
require_tools java javac mvn h2load

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
: "${TRANSPORT:=nio}"
: "${TAG_SUFFIX:=}"
: "${ASPROF:=}"          # path to async-profiler's asprof: when set, one CPU profile per allocator
: "${PROFILE_SECS:=14}"
: "${PROFILE_INTERVAL:=1ms}"
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
NATIVE_CP="$(native_transport_cp)" || exit 1
CP="$EXAMPLE_JAR:$MIMALLOC_JAR:$NATIVE_CP:$(cat "$DEP_CP_FILE")"

# The launcher and the shared transport helper are compiled once (they used to be run in java source
# mode, which cannot see a second source file).
E2E_CLASSES="$ROOT/target/e2e-classes"
mkdir -p "$E2E_CLASSES"
if [ "$ROOT/e2e/E2EServer.java" -nt "$E2E_CLASSES/E2EServer.class" ] \
   || [ "$ROOT/lib/java/Transports.java" -nt "$E2E_CLASSES/Transports.class" ] \
   || [ "$ROOT/lib/java/RegisteredSlabBufferRingAllocator.java" \
        -nt "$E2E_CLASSES/RegisteredSlabBufferRingAllocator.class" ]; then
    javac -nowarn -d "$E2E_CLASSES" -cp "$CP" "$ROOT/e2e/E2EServer.java" "$ROOT/lib/java/Transports.java" \
        "$ROOT/lib/java/RegisteredSlabBufferRingAllocator.java"
fi
CP="$E2E_CLASSES:$CP"

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

SUMMARY="$RESULTS_DIR/e2e-$TRANSPORT-$PROTO-summary.txt"
: > "$SUMMARY"

for A in $ALLOCATORS; do
    TAG="$TRANSPORT-$PROTO-$A$TAG_SUFFIX"
    SRV="$RESULTS_DIR/$TAG.server.log"; GC="$RESULTS_DIR/$TAG.gc"
    RSS="$RESULTS_DIR/$TAG.rss";        LOAD="$RESULTS_DIR/$TAG.h2load"

    [ -n "$(server_pids)" ] && stop_server
    echo "==> $TAG: server, $LOOPS event loops, port $PORT, transport $TRANSPORT"
    ARENA_OPT=()
    [ -n "${ARENA_MAX_BLOCKS:-}" ] && ARENA_OPT=("-Darena.maxBlocks=$ARENA_MAX_BLOCKS")
    [ -n "$LOGBACK_CONFIG" ] && ARENA_OPT+=("-Dlogback.configurationFile=$LOGBACK_CONFIG")
    # shellcheck disable=SC2206
    [ -n "$ARENA_PROPS" ] && ARENA_OPT+=($ARENA_PROPS)
    ARENA_OPT+=("-Dtransport=$TRANSPORT")
    [ -n "${BUFFER_RING:-}" ] && ARENA_OPT+=("-DbufferRing=$BUFFER_RING")
    [ -n "${BUFFER_RING_ALLOC:-}" ] && ARENA_OPT+=("-DbufferRingAlloc=$BUFFER_RING_ALLOC")
    # shellcheck disable=SC2086
    $SUT_PIN_CMD java -cp "$CP" $JVM_OPTS "${ARENA_OPT[@]}" \
        "-Xlog:gc:file=$GC" E2EServer "$A" "$PROTO" "$PORT" "$LOOPS" \
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
    if [ -n "$ASPROF" ]; then
        # async-profiler attaches to the live server and writes collapsed CPU stacks.  It is started
        # 3 s into the load so that the profile covers steady state, and it exits on its own.
        ( sleep 3; "$ASPROF" -d "$PROFILE_SECS" -e cpu -i "$PROFILE_INTERVAL" -o collapsed \
            -f "$RESULTS_DIR/$TAG.collapsed" "$PID" > "$RESULTS_DIR/$TAG-asprof.log" 2>&1 ) &
        PROF=$!
    fi
    echo "   h2load ${H2LOAD_ARGS[*]} http://127.0.0.1:$PORT/"
    # shellcheck disable=SC2086
    $LOADGEN_PIN_CMD h2load "${H2LOAD_ARGS[@]}" "http://127.0.0.1:$PORT/" > "$LOAD" 2>&1 \
        || echo "   (h2load rc=$? - see $LOAD)"

    [ -n "$ASPROF" ] && { wait "$PROF" 2>/dev/null || true; }
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
    RING="$(grep -m1 '^RINGTELE' "$SRV" || true)"
    printf '%-9s %14s req/s | %s | RSS %s | %s young GCs%s%s\n' \
        "$A" "${RPS:-0}" "${LAT:-(no latency line)}" "$RSSS" "${GCN:-0}" \
        "${RING:+ | $RING}" "${CNT:+ | $CNT}" >> "$SUMMARY"
done

trap 'freq_hook restore' EXIT
echo
STREAM_TXT=""
[ "$PROTO" = h2 ] && STREAM_TXT=" x $STREAMS streams"
echo "== end to end, $PROTO, $TRANSPORT, ${DURATION}s, $CONNS connections$STREAM_TXT, $LOOPS event loops =="
cat "$SUMMARY"
echo "raw logs in $RESULTS_DIR"
