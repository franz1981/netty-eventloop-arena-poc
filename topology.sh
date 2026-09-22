#!/bin/bash
# Suggest two disjoint CPU sets - one for the server, one for the load generator - from this
# machine's own lscpu output.  It only SUGGESTS; export the variables yourself.
#
# Rules it applies: physical cores only (one CPU per core id, the SMT siblings are left idle), both
# sets inside a single NUMA node, the two sets disjoint.
set -euo pipefail
command -v lscpu > /dev/null || { echo "lscpu not found" >&2; exit 1; }

lscpu -e=CPU,NODE,CORE | awk -v have_numactl="$(command -v numactl > /dev/null && echo 1 || echo 0)" '
NR == 1 { next }
{ cpu = $1 + 0; node = $2 + 0; core = $3 + 0
  key = node "," core
  if (!(key in first)) { first[key] = cpu; order[node] = order[node] " " cpu; ncore[node]++ }
  else { sib[key] = sib[key] " " cpu }
  nodes[node] = 1 }
END {
  n = 0
  for (node in nodes) { nodelist[n++] = node + 0 }
  for (i = 0; i < n; i++) for (j = i + 1; j < n; j++) if (nodelist[j] < nodelist[i]) { t = nodelist[i]; nodelist[i] = nodelist[j]; nodelist[j] = t }
  for (i = 0; i < n; i++) {
    node = nodelist[i]
    printf "NUMA node %d: %d physical cores\n", node, ncore[node]
    printf "  first CPU of each core:%s\n", order[node]
    s = ""
    for (key in first) { split(key, a, ","); if (a[1] + 0 == node && sib[key] != "") s = s sib[key] }
    printf "  SMT siblings (leave idle):%s\n", (s == "" ? " none" : s)
    m = split(substr(order[node], 2), cpus, " ")
    if (m < 2) { print "  too few physical cores on this node to split"; continue }
    half = int(m / 2)
    sut = ""; lg = ""
    for (k = 1; k <= half; k++) sut = sut (sut == "" ? "" : ",") cpus[k]
    for (k = half + 1; k <= m; k++) lg = lg (lg == "" ? "" : ",") cpus[k]
    printf "  suggestion:\n"
    printf "    export SUT_PIN_CMD=\"taskset -c %s\"\n", sut
    printf "    export LOADGEN_PIN_CMD=\"taskset -c %s\"\n", lg
    if (have_numactl == 1) {
      printf "    # or, binding memory to the node as well:\n"
      printf "    export SUT_PIN_CMD=\"numactl --physcpubind=%s --membind=%d\"\n", sut, node
      printf "    export LOADGEN_PIN_CMD=\"numactl --physcpubind=%s --membind=%d\"\n", lg, node
    }
    print ""
  }
  print "These are suggestions only.  Do not share a core or an SMT sibling between the load"
  print "generator and the server, and keep both sets inside one NUMA node."
}'
