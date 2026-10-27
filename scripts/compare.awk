# Native C++ simulators use the in-process loop timer; Icarus uses process wall time.
BEGIN {
  FS = "\t"
}
$1 == "sim" { next }
NF == 0 { next }
NF != 6 {
  print "malformed row in " FILENAME ": " $0 > "/dev/stderr"
  bad = 1
  next
}
{
  sim = $1
  test = $2
  key = sim SUBSEP test
  this_metric = ($5 == "-" ? "wall" : "loop")
  duration = ($5 == "-" ? $6 : $5)
  if (duration <= 0) {
    print "invalid duration in " FILENAME > "/dev/stderr"
    bad = 1
    next
  }
  if (!(sim in seen_sim)) {
    sims[++nsims] = sim
    metric[sim] = this_metric
  } else if (metric[sim] != this_metric) {
    print "mixed timing metrics for " sim " in " FILENAME > "/dev/stderr"
    bad = 1
  }
  seen_sim[sim] = 1
  if (!(test in seen_test)) {
    tests[++ntests] = test
    cycles[test] = $4
  } else if (cycles[test] != $4) {
    print "cycle mismatch for " test " in " FILENAME ": " $4 \
          ", first recorded " cycles[test] > "/dev/stderr"
    bad = 1
  }
  seen_test[test] = 1
  sample[key, ++count[key]] = duration
}
function median(key, i, j, tmp) {
  for (i = 1; i <= count[key]; i++)
    for (j = i + 1; j <= count[key]; j++)
      if (sample[key, i] > sample[key, j]) {
        tmp = sample[key, i]
        sample[key, i] = sample[key, j]
        sample[key, j] = tmp
      }
  i = int(count[key] / 2) + 1
  return count[key] % 2 ? sample[key, i] : (sample[key, i - 1] + sample[key, i]) / 2
}
END {
  printf "| Simulator | Metric |"
  for (t = 1; t <= ntests; t++)
    printf " %s (%d cyc) |", tests[t], cycles[tests[t]]
  print ""
  printf "| --- | --- |"
  for (t = 1; t <= ntests; t++)
    printf " ---: |"
  print ""
  for (s = 1; s <= nsims; s++) {
    sim = sims[s]
    printf "| %s | %s |", sim, metric[sim]
    for (t = 1; t <= ntests; t++) {
      test = tests[t]
      key = sim SUBSEP test
      if (count[key])
        printf " %.0f cycles/s (%.3fs) |", cycles[test] / median(key), median(key)
      else
        printf " - |"
    }
    print ""
  }
  print "\nMedian of timed runs after one warm-up run."
  if (bad)
    exit 1
}
