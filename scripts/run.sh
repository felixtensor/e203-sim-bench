#!/usr/bin/env bash
# Execute the commands below against the cases in programs/cases.tsv.
set -euo pipefail
cd "$(dirname "$0")/.."
sim=$1
mode=$2
selected=${3:-smoke-itcm-dtcm}
exe=${SIM_EXE:?set SIM_EXE to the compiled simulator}
wave=${WAVE:-0}
size=${SIZE:-small}
repeats=${REPEATS:-5}
[[ "$repeats" =~ ^[1-9][0-9]*$ ]] || { echo 'REPEATS must be positive' >&2; exit 1; }
[[ "$size" == small || "$size" == large ]] || { echo 'SIZE must be small or large' >&2; exit 1; }
out="build/results/$sim"
mkdir -p "$out"
if [[ "$mode" == bench ]]; then
  printf 'sim\ttest\trepeat\tcycles\tloop_s\twall_s\n' > "$out/measurements.tsv"
fi
found=0
while read -r test boot scratch latency stall cycles reads writes status; do
  [[ -z "$test" || "$test" == \#* ]] && continue
  case "$mode" in
    run) [[ "$test" == "$selected" ]] || continue ;;
    smoke) [[ "$test" == smoke-* ]] || continue ;;
    bench)
      [[ "$test" == bench-* ]] || continue
      if [[ "$size" == small ]]; then [[ "$test" == bench-small-* ]] || continue
      else [[ "$test" != bench-small-* ]] || continue; fi ;;
    *) echo "unknown mode: $mode" >&2; exit 1 ;;
  esac
  found=1
  mkdir -p "$out/$test"
  program="build/programs/$test.bin"
  vcd="$out/$test/wave.vcd"
  if [[ "$sim" == iverilog ]]; then
    cmd=("${VVP:-vvp}" "$exe" "+PROGRAM=$program" "+BOOT=$((boot))" "+SCRATCH=$((scratch))"
         "+LATENCY=$latency" "+STALL=$stall" +MAXCYCLES=20000000)
    [[ "$wave" == 1 ]] && cmd+=("+VCD=$vcd")
  else
    cmd=("$exe" "$program" "$boot" "$scratch" "$latency" "$stall" 20000000)
    [[ "$wave" == 1 ]] && cmd+=(--vcd "$vcd")
  fi
  { printf '+ '; printf '%q ' "${cmd[@]}"; printf '\n'; } | tee "$out/$test/command.txt"
  last=0
  [[ "$mode" == bench ]] && last=$repeats
  for ((run=0; run<=last; run++)); do
    log="$out/$test/run-$run"
    if { time -p "${cmd[@]}"; } > "$log.log" 2> "$log.time"; then rc=0; else rc=$?; fi
    expected_rc=0
    [[ "$status" == FAIL ]] && expected_rc=1
    expected="$status cycles=$cycles"
    [[ "$status" == FAIL ]] && expected="FAIL cpu_self_check cycles=$cycles"
    [[ "$status" == PASS ]] && expected+=" external_reads=$reads external_writes=$writes"
    actual=$(grep -E '^(PASS|FAIL)' "$log.log" || true)
    if [[ "$rc" != "$expected_rc" || "$actual" != "$expected" ]]; then
      cat "$log.log" "$log.time" >&2
      echo "expected exit=$expected_rc: $expected" >&2
      exit 1
    fi
    # Native traces use the exact historical text format and both clock phases.
    if [[ "$wave" == 1 && "$sim" != iverilog && "$test" == smoke-* ]]; then
      cmp "$vcd" "data/smoke-vcd/${test#smoke-}.vcd"
    fi
    if [[ "$mode" == bench && "$run" -gt 0 ]]; then
      loop=$(sed -nE 's/.*HARNESS sim_s=([0-9.]+).*/\1/p' "$log.time")
      wall=$(awk '$1=="real" {print $2}' "$log.time")
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sim" "$test" "$run" "$cycles" "${loop:--}" "$wall" >> "$out/measurements.tsv"
    fi
  done
  echo "$test: $actual"
done < programs/cases.tsv
[[ "$found" == 1 ]] || { echo "test not found: $selected" >&2; exit 1; }
if [[ "$mode" == bench ]]; then
  awk -f scripts/compare.awk "$out/measurements.tsv"
fi
