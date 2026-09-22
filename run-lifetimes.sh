#!/bin/bash
# Real-buffer lifetime study: run a netty example server under a JFR recording that enables only
# io.netty.AllocateBuffer / io.netty.FreeBuffer, drive it with h2load, then pair allocate/free by
# address (lifetimes/lifetimes.py) to get the same-thread ratio and the "allocations in between"
# distribution.
#
#   ./run-lifetimes.sh snoop  -- --h1 -c 64 -t 4 -n 0 -D 12 -d lifetimes/body4k.bin http://127.0.0.1:8080/
#   ./run-lifetimes.sh http2  -- -c 16 -m 32 -t 4 -D 12 http://127.0.0.1:8080/
#
# SERVER is "snoop" (HttpSnoopServer, HTTP/1.1) or "http2" (Http2Server, h2c).
# Everything after -- goes to h2load.  Do not use wrk: the jbang wrk on the reference box ignored the
# Lua body, so no POST bodies were sent and the inbound read buffers never appeared.
# KEEP_EVENTS=1 keeps the (multi-GB) text event dump.
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"
require_tools java h2load python3 jfr

SERVER="${1:-snoop}"; shift || true
[ "${1:-}" = "--" ] && shift
case "$SERVER" in
    snoop) MAIN=io.netty.example.http.snoop.HttpSnoopServer ;;
    http2) MAIN=io.netty.example.http2.helloworld.server.Http2Server ;;
    *)     echo "unknown server '$SERVER' (snoop|http2)" >&2; exit 1 ;;
esac
H2LOAD_ARGS=("$@")
[ ${#H2LOAD_ARGS[@]} -gt 0 ] || { echo "no h2load arguments given (see the header of this script)" >&2; exit 1; }

mkdir -p "$RESULTS_DIR"
OUT="$RESULTS_DIR/lifetimes-$SERVER"
JFR="$OUT.jfr"; EVENTS="$OUT-events.txt"; SRV="$OUT-server.log"; LOAD="$OUT-h2load.log"; SUM="$OUT.txt"

# classpath of the netty example module, from the submodule build
CP_FILE="$ROOT/target/example-classpath.txt"
if [ ! -s "$CP_FILE" ]; then
    echo "==> resolving the example classpath"
    mkdir -p "$ROOT/target"
    (cd "$ROOT/netty" && mvn $MVN_FLAGS -pl example dependency:build-classpath -Dmdep.outputFile="$CP_FILE")
fi
CP="$ROOT/netty/example/target/classes:$(cat "$CP_FILE")"

# never pkill -f: it matches this shell's own command line.  Match the main class inside /proc/<pid>/cmdline.
server_pids() {
    local p
    for p in $(pgrep -x java 2>/dev/null); do
        tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "$MAIN" && echo "$p"
    done
}
stop_server() {
    local p
    for p in $(server_pids); do kill "$p" 2>/dev/null || true; done
    for _ in $(seq 1 50); do [ -z "$(server_pids)" ] && return 0; sleep 0.2; done
    for p in $(server_pids); do kill -9 "$p" 2>/dev/null || true; done
}

[ -n "$(server_pids)" ] && { echo "a $MAIN is already running - stopping it"; stop_server; }

echo "==> starting $MAIN with JFR (lifetimes/buf.jfc)"
# shellcheck disable=SC2086
$PIN_CMD java -cp "$CP" $JVM_OPTS \
    "-XX:StartFlightRecording=settings=$ROOT/lifetimes/buf.jfc,filename=$JFR,dumponexit=true" \
    "$MAIN" > "$SRV" 2>&1 &
trap 'stop_server' EXIT
for _ in $(seq 1 100); do grep -q "BIND\|Open your" "$SRV" 2>/dev/null && break; sleep 0.2; done
sleep 1
[ -n "$(server_pids)" ] || { echo "the server did not start - see $SRV" >&2; exit 1; }

echo "==> h2load ${H2LOAD_ARGS[*]}"
h2load "${H2LOAD_ARGS[@]}" > "$LOAD" 2>&1 || echo "   (h2load rc=$? - see $LOAD)"
tail -12 "$LOAD"

echo "==> stopping the server (JFR dumps on exit)"
stop_server
trap - EXIT

echo "==> jfr summary"
jfr summary "$JFR" | sed -n '1,25p'

echo "==> pairing allocate/free by address"
jfr print --events io.netty.AllocateBuffer,io.netty.FreeBuffer "$JFR" > "$EVENTS"
python3 "$ROOT/lifetimes/lifetimes.py" "$EVENTS" "$SERVER" | tee "$SUM"
[ "${KEEP_EVENTS:-0}" = 1 ] || rm -f "$EVENTS"
echo "==> $SUM"
