# Lifecycle topology - raw outputs

What produced these: `topology/run.sh` (W1-W5), `topology/run6.sh` (W6a, W6b) and
`topology/control.sh`, then `topology/topology.py` per workload and `topology/summary.py` across
them. `labels.txt` names the workloads, `summary.txt` is the cross-workload table, `wN.txt` the
per-workload analysis, `control.txt` the instrumentation-cost control.

## The .jfr recordings are NOT here

Each window is 34-88 MB of JFR and the set is 706 MB, so none of it is committed. The originals are
on the box that produced them, at
`/home/forked_franz/IdeaProjects/netty-bench/results/h2h-merged-x86-2026-09-22/topology/` -
`w1.jfr`, `w2.jfr`, `w3.jfr`, `w3-depth12.jfr`, `w4.jfr`, `w4-nosndbuf.jfr`, `w5.jfr`, `w6a.jfr`,
`w6b.jfr`. `topology/run.sh` regenerates one from scratch, and an existing recording can be
re-analysed without rerunning the load:

```
java -cp target/topology-classes Dump wN.jfr wN.tsv
python3 topology/topology.py wN.tsv "<label>"
cd <dir with the tsvs> && python3 <repo>/topology/summary.py       # PYTHONPATH must reach topology/
```

`w4-nosndbuf.jfr` (W4 without the 16 KiB `SO_SNDBUF`) exists on that box but **no analysis text was
produced from it**, so there is nothing to copy for it here.

## What was actually measured, and how it differs from a rerun

`provenance.txt` is the record and it matters: the measurements used a **frozen classpath**
(`cp-frozen.txt`, snapshotted while another agent was rebuilding the netty worktree). The jar it
names corresponds to `expt/event-loop-arena` at **`cfb23bcf63`**, not the `3dad84f578` this
repository pins - that commit, and the two builds between them, landed after the snapshot. The allocator under measurement was
`-Dio.netty.allocator.type=adaptive`, and on this branch that is the size-classed variant of the
PR-17151 line, not upstream 4.2 adaptive.

`topology/common.sh` does **not** reproduce the frozen classpath: a rerun resolves the classpath
from the pinned submodule and therefore measures whatever is pinned. That is deliberate, and it
means a rerun is not bit-for-bit the same experiment as these files.

The exact h2load flags of the original W1/W2/W3/W5 runs were not recorded. The invocations in the
header of `topology/run.sh` are **reconstructed** from `labels.txt` and the connection/thread counts
printed in the `*-load.log` files; W3's `-w 12` in particular is an inference from "4 KiB client
flow-control windows" and is not attested.
