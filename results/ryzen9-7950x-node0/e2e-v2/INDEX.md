# e2e-v2 — raw evidence for the CycleArenaAllocator e2e tables

Branch `expt/event-loop-arena` @ `26bd14b195` (worktree netty-sc-arena) unless noted.
Every `runs/<tag>/` holds `h2load.txt` (client), `server.log` (READY line + `ARENATELE` counters
from the shutdown hook), `rss.txt` (VmRSS in KiB, sampled every 0.5 s) and `gc.log` (`-Xlog:gc`).
Server pinned `numactl --cpunodebind=0 --membind=0`, `-Xmx2g -Xms2g`, 8 event loops;
h2load from node 1. CPU at 4300 MHz.

## Final tables in the report (quiet logging, final build)
| run dir | report row |
|---|---|
| `runs/f-h2-adaptive` | h2, adaptive — 671,887 req/s, 720 us, 92/1471 MiB, 34 GC |
| `runs/f-h2-arena-heap` | h2, arena `-Dio.netty.noPreferDirect=true` — 676,928 req/s, 709 us, 93/1457, 30 |
| `runs/f-h2-arena-direct` | h2, arena direct — 672,233 req/s, 711 us, 93/1448, 32 |
| `runs/f-h2-arena-hookiter` | h2, `-Darena.release=hook` + `-Darena.hook=iteration` — 671,800 req/s |
| `runs/f-h2-arena-hookrc` | h2, `-Darena.release=hook -Darena.hook=off -Darena.e2e.readCompleteHook=true` — 666,754 req/s |
| `runs/f-h1-adaptive` | h1, adaptive — 298,586 req/s, 218 us, 93/1437, 92 |
| `runs/f-h1-arena-direct` | h1, arena direct — 300,662 req/s, 216 us, 92/1447, 92 |
| `runs/f-h1-arena-heap` | h1, arena heap — 302,460 req/s, 214 us, 92/1436, 73 |

## HTTP/2 control experiment (noisy logging, as the original harness ran it)
| run dir | report claim |
|---|---|
| `runs/repro-old-h2-arena` | pre-fix `dec589d0eb` classes overlaid — **0.00 req/s**, shared root NIO view |
| `runs/repro-h2-arena` | branch HEAD `05604aa1c2` — **52,257 req/s** (also carries a JFR recording flag) |
| `runs/ref-h2-adaptive` | adaptive in the same noisy harness — **53,402 req/s** |
Their `server.log` is TRUNCATED (head 40 + ARENATELE + tail 40): the originals were up to 6.9M
lines of logback INFO frame logging, which is itself the finding that logging dominated the old
23,507 req/s adaptive number.

## Intermediate build (quiet logging, before the card-mark and Space-threadlocal fixes)
`runs/q-*` — the first quiet-logging matrix; same conclusions, kept because the report's
"adaptive 23,507 -> 671,887 with logging off" comparison came from `runs/q-h2-adaptive-heap`.

## harness/
`E2EServer.java` (scratchpad copy actually run; netty-bench/tools/e2e/E2EServer.java is untouched),
`logback-quiet.xml` (root level OFF), `run.sh` (the driver: flags, h2load lines, RSS sampler),
`cp.txt` (exact classpath, worktree `buffer/target/classes` first).
