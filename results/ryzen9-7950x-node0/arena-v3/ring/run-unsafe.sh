#!/bin/bash
# The task's fallback for (a): the flat bitmap WITHOUT the bounds check (PlatformDependent/Unsafe).
set -u
SP=/tmp/claude-1000/-home-forked-franz-IdeaProjects-netty/01a26e43-89a8-433b-a89e-c560138e4359/scratchpad
NETTY=/home/forked_franz/IdeaProjects/netty-sc-arena
R=/home/forked_franz/IdeaProjects/netty-bench/results/h2h-merged-x86-2026-09-22/arena-v3/ring/flat
source $SP/waitidle.sh
until grep -aq 'FLAT A/B DONE' $SP/run-flat2.out 2>/dev/null; do sleep 15; done
echo "A/B done $(date +%T)"
python3 $SP/patch-unsafe.py || exit 1
wait_idle
cd $NETTY && mvn -o -pl buffer -am clean install -DskipTests -Dcheckstyle.skip=true -Drevapi.skip=true \
    -Dmaven.javadoc.skip=true -T1C > $SP/unsafe-install.log 2>&1
echo "install exit=$? $(grep -c 'BUILD SUCCESS' $SP/unsafe-install.log) $(date +%T)"
wait_idle
cd $SP/lao-cab && mvn -q -o -DskipTests -Dnetty.version=4.2.17.Final-SNAPSHOT clean package > $SP/unsafe-harness.log 2>&1
echo "harness exit=$? $(date +%T)"
cp $SP/lao-cab/benchmark/target/benchmarks.jar $SP/jars/bench-unsafe.jar
rm -rf $SP/verify6 && mkdir -p $SP/verify6 && cd $SP/verify6 \
  && unzip -o -q $SP/jars/bench-unsafe.jar 'io/netty/buffer/CycleArenaAllocator$Space.class' \
  && javap -p -c -classpath . 'io.netty.buffer.CycleArenaAllocator$Space' | grep -c 'PlatformDependent.putLong'
cd /home/forked_franz/IdeaProjects/netty-bench/results/h2h-merged-x86-2026-09-22 || exit 1
N="numactl --cpunodebind=0 --preferred=0"
P="-p k=64 -p releaseOrder=FIFO -p sizes=SMALL -p allocatorType=ARENA"
for r in false true; do
  wait_idle
  $N java -jar $SP/jars/bench-unsafe.jar 'CycleScopedAllocBenchmark.cycle(Heap|Direct)' -f 1 -wi 10 -i 10 $P \
    -jvmArgsAppend -XX:MaxRAM=60g -jvmArgsAppend -Darena.ring=$r -prof perfnorm \
    -rf json -rff $R/pn-unsafe-$r.json > $R/pn-unsafe-$r.log 2>&1
  echo "pn-unsafe-$r exit=$? freq=$(freq_now) $(date +%T)"
done
echo "UNSAFE DONE $(date +%T)"
