#!/bin/bash
# Shared setup for the lifecycle-topology runs.  Sourced, not run.
#
# Classpath: the netty submodule's example module and its dependencies, exactly as run-e2e.sh builds
# it.  The original measurements used a FROZEN classpath snapshot (another agent was rebuilding the
# netty worktree at the time); that snapshot and its checksums are recorded in
# results/<machine>/topology/{cp-frozen.txt,provenance.txt} and are NOT reproduced here - a rerun
# measures whatever the submodule is pinned at.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/env.sh"
TOPO="$ROOT/topology"
CLASSES="$ROOT/target/topology-classes"

topo_cp() {
    local dep_file="$ROOT/target/e2e-classpath.txt"
    local version; version="$(netty_version)"
    local example_jar="$ROOT/netty/example/target/netty-example-$version.jar"
    [ -f "$example_jar" ] || { echo "no $example_jar - run ./build.sh first" >&2; return 1; }
    if [ ! -s "$dep_file" ]; then
        mkdir -p "$ROOT/target"
        (cd "$ROOT/netty/example" && mvn $MVN_FLAGS dependency:build-classpath -Dmdep.outputFile="$dep_file") || return 1
    fi
    # the mimalloc module (TopoServer can run it too) and the native transports, which are not
    # dependencies of netty-example: the classpath is the same for every TRANSPORT.
    local mi native
    mi="$(ls "$ROOT"/netty-allocator/mimalloc/target/mimalloc-*.jar 2>/dev/null \
          | grep -v -- '-sources\|-javadoc' | head -1 || true)"
    native="$(native_transport_cp)" || return 1
    echo "$CLASSES:$example_jar:${mi:+$mi:}$native:$(cat "$dep_file")"
}

topo_compile() {
    mkdir -p "$CLASSES"
    if [ "$TOPO/TopoServer.java" -nt "$CLASSES/TopoServer.class" ] \
       || [ "$ROOT/lib/java/Transports.java" -nt "$CLASSES/Transports.class" ] \
       || [ "$TOPO/Dump.java" -nt "$CLASSES/Dump.class" ]; then
        # topo_cp resolves the dependency classpath the first time it is called; calling it here is
        # what makes a fresh clone work, where target/e2e-classpath.txt does not exist yet.
        local cp; cp="$(topo_cp)" || return 1
        javac -nowarn -d "$CLASSES" -cp "$cp" "$TOPO/TopoServer.java" "$ROOT/lib/java/Transports.java" \
            "$TOPO/Dump.java" || return 1
    fi
}

topo_bodies() {   # the POST bodies the loads send
    local d="${1:-$RESULTS_DIR}"
    mkdir -p "$d"
    [ -s "$d/body4k"   ] || head -c 4096   /dev/zero | tr '\0' 'x' > "$d/body4k"
    [ -s "$d/body64k"  ] || head -c 65536  /dev/zero | tr '\0' 'x' > "$d/body64k"
    [ -s "$d/body256k" ] || head -c 262144 /dev/zero | tr '\0' 'x' > "$d/body256k"
}

# Stop a TopoServer only by matching it inside /proc/<pid>/cmdline.  Never pkill -f.
topo_pids() {
    local p
    for p in $(pgrep -x java 2>/dev/null); do
        tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- 'TopoServer' && echo "$p"
    done
}
topo_stop_all() {
    local p
    for p in $(topo_pids); do kill "$p" 2>/dev/null || true; done
    for _ in $(seq 1 60); do [ -z "$(topo_pids)" ] && return 0; sleep 0.2; done
    for p in $(topo_pids); do kill -9 "$p" 2>/dev/null || true; done
}
