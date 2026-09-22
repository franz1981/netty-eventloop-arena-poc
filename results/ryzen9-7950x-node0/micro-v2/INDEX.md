# micro-v2 — raw evidence for the JMH microbenchmark section

Harness: scratchpad clone of `lao` branch `cycle-arena-bench`, built with
`-Dnetty.version=4.2.17.Final-SNAPSHOT` against the netty-sc-arena worktree.
Run from this directory (`e-commerce.jfr` lives here), `numactl --cpunodebind=0 --preferred=0`,
CPU pinned to **2300 MHz**, `-p sizePattern=E_COMMERCE -p MAX_LIVE_BUFFERS=1024
-p enableReadWrite=true -t 1 -f 3 -wi 10 -i 10 -w 1 -r 1`.

## HONEST GAP: no JMH .json/.data exist
I ran JMH without `-rf json`/`-rff`, so there are **no result files to copy** for the five quoted
cells (ARENA heap 44.280 +- 0.729, ARENA direct 43.296 +- 0.456, pre-change control 40.869 +- 0.168,
ADAPTIVE heap 83.990 +- 0.293, ADAPTIVE direct 79.740 +- 0.377). Those numbers exist only as the
console summary lines quoted in the report. `quoted-scores.txt` is a transcription of those console
lines, not a machine-written artifact — treat it as such. Re-running with `-rf json` would produce
the real files; I was asked not to run anything new.

## perfasm (the evidence that named the regression)
| file | report claim |
|---|---|
| `perfasm-new-v1-cardmarks.txt` | first direct-capable build (this run's own Result line: 48.510 ns/op; the report quotes 47.2 from the regression walk below): G1 card-table barriers (`shr $0x9` / `movabs` / `cmpb $0x2,(%rdi)`) on `putfield reserved` in `Space::reserve` and `putfield root` in `ArenaBuf::moveTo` — hottest region 1, 24.69% |
| `perfasm-new-v2-after-barrier-fix.txt` | after removing both stores (Result line 47.591 ns/op; report quotes 45.6): the barriers are gone; the surviving 4.06% line is the `cmp {metadata('UnpooledUnsafeHeapByteBuf')}` klass guard on `root` in `_getByte` |
| `perfasm-old-control.txt` | pre-change heap-only PoC (Result line 40.991 ns/op; report quotes 40.5), same harness: no klass guard (field typed as the final `Root` class), no extra barriers |
All three: `-prof "perfasm:event=cycles"` (never `cycles:P` on this Ryzen).

## perfnorm
Not saved to disk — only the grepped console rows quoted in the report
(new 367.9 insn/op, 109.1 cyc/op vs old 339.3 / 94.6 for the v1 build; 346.8 / 107.4 vs 339.3 / 91.9
after the barrier fix). `quoted-scores.txt` transcribes these too, with the same caveat.
