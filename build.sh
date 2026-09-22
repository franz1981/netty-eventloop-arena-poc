#!/bin/bash
# Build the PoC: install the netty submodule's buffer+common modules (they carry CycleArenaAllocator)
# into ~/.m2, then build the harness against exactly that snapshot, then the netty example module
# (the lifetime study runs its HTTP servers).
#
#   MVN_FLAGS="-q -o" ./build.sh      # offline
#   ./build.sh --no-example           # skip the example module
set -euo pipefail
source "$(dirname "$0")/lib/env.sh"
require_tools java mvn

WITH_EXAMPLE=1
for a in "$@"; do [ "$a" = "--no-example" ] && WITH_EXAMPLE=0; done

[ -e "$ROOT/netty/pom.xml" ] && [ -e "$ROOT/netty-allocator/pom.xml" ] || {
    echo "submodules are empty: run 'git submodule update --init' (the branches must be pushed first)" >&2
    exit 1
}

NETTY_VERSION="$(netty_version)"
echo "==> netty version from netty/pom.xml: $NETTY_VERSION"
echo "==> netty      @ $(git -C "$ROOT/netty" rev-parse --short HEAD) ($(git -C "$ROOT/netty" rev-parse --abbrev-ref HEAD))"
echo "==> harness    @ $(git -C "$ROOT/netty-allocator" rev-parse --short HEAD) ($(git -C "$ROOT/netty-allocator" rev-parse --abbrev-ref HEAD))"

# 1. netty buffer + common -> ~/.m2.  This OVERWRITES any snapshot of the same version already there.
echo "==> installing netty buffer,common (this overwrites $NETTY_VERSION in ~/.m2)"
(cd "$ROOT/netty" && mvn $MVN_FLAGS -pl buffer,common -am install \
    -DskipTests -Dcheckstyle.skip -Drevapi.skip -Danimal.sniffer.skip)

# 2. the example module and its dependencies, for run-lifetimes.sh
if [ "$WITH_EXAMPLE" = 1 ]; then
    echo "==> installing netty example (+ dependencies) for the lifetime study"
    (cd "$ROOT/netty" && mvn $MVN_FLAGS -pl example -am install \
        -DskipTests -Dcheckstyle.skip -Drevapi.skip -Danimal.sniffer.skip)
fi

# 3. the JMH harness, against the snapshot just installed
echo "==> building the harness against $NETTY_VERSION"
(cd "$ROOT/netty-allocator" && mvn $MVN_FLAGS clean package -DskipTests -Dnetty.version="$NETTY_VERSION")

mkdir -p "$ROOT/target"
cp "$ROOT/netty-allocator/benchmark/target/benchmarks.jar" "$ROOT/target/benchmarks.jar"

# sanity: the arena class in the jar must be the netty one, and there must be no harness copy
if ! unzip -l "$ROOT/target/benchmarks.jar" | grep -q 'io/netty/buffer/CycleArenaAllocator\.class'; then
    echo "FAILED: io.netty.buffer.CycleArenaAllocator is not in the jar" >&2; exit 1
fi
if unzip -l "$ROOT/target/benchmarks.jar" | grep -q 'microbenchmark/CycleArenaAllocator\.class'; then
    echo "FAILED: a harness copy of CycleArenaAllocator is in the jar" >&2; exit 1
fi
echo "==> target/benchmarks.jar ready ($(du -h "$ROOT/target/benchmarks.jar" | cut -f1))"
