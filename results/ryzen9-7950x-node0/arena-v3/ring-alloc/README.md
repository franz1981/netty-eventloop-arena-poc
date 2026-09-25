# ring-alloc - RESULTS.md section 8

Raw data for [RESULTS.md section 8](../../RESULTS.md#8-the-provided-buffer-ring-allocator-iterated-measured-2026-0925-26-2300-mhz-node-0),
"The provided-buffer-ring allocator, iterated". Measured 2026-09-25/26, netty `d04ac1f4ec`
(`expt/event-loop-arena`), CPU ceiling 2300 MHz, server on NUMA node 0 and h2load on node 1.

Every cell in every directory ran under `cell.sh`, which is the wrapper the per-cell provenance lines
come from: it refuses to run if a JVM or load generator that is not this study's is up (by exact
`/proc/<pid>/cmdline` scan), sets every CPU's `scaling_max_freq` and **reads it back**, aborting on any
mismatch, and samples the instantaneous runnable count (field 4 of `/proc/loadavg`) six times,
aborting above the limit. `restorefreq.sh` put the ceiling back to 4300000 at the end. The shared
mutex that serialises cells is outside this directory (it is session state, not a result); `cell.sh`
is called from inside it. Three cells aborted on a transient runnable spike and were re-run; the
aborts are in the provenance logs.

| directory | what |
|---|---|
| `e2e/` | the ten-candidate e2e matrix, h1 and h2, 20 s each, one 14 s async-profiler CPU profile per cell (`*.collapsed`) |
| `topology/` | W1 / W3 / W5 for the same ten candidates, with the JFR window and its reduction (`*.txt`) |
| `micro/` | the JMH microbenchmark of the ring allocator alone: `owner.json` (owner thread, both the sliced and the no-slice shape, 7 candidates x 2 in-flight depths), `noslice.json` (a repeat), `foreign.json` (allocate here / release there, plus the queue-only control). 3 forks, `-prof perfnorm` |
| `variants/` | the two netty instruments: `*-handoff.*` is `noSliceHandoff=true`, `*-timehist.*` is the nanosecond in-flight histogram, and the `refCntTele` cells |
| `sizepolicy/` | the slot-size policy comparison: W3 and e2e with `-Diouring.slabSizePolicy=rate` against `=run` |
| `w5rss/` | four runs each of W5 with `adaptive` and with `slab3fixed`, because the single-run RSS difference was not reproducible |

`run-provenance.log` in each directory holds the per-cell freq read-back and runnable samples.
Reduce with `tools/ring-alloc-table.py` (e2e), `tools/ring-alloc-topo-table.py` (topology),
`tools/asprof-alloc-share.py` and `tools/asprof-loop-breakdown.py` (profiles).
