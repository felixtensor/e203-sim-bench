#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

sim=$1
mode=$2
selected=${3:-rv32ui-p-add}
tag=${TAG:-$sim}
exe=${SIM_EXE:?set SIM_EXE to the compiled simulator}
wave=${WAVE:-0}
smoke_set=${SMOKE:-default}
size=${SIZE:-small}
repeats=${REPEATS:-5}

[[ "$repeats" =~ ^[1-9][0-9]*$ ]] || { echo "REPEATS must be positive" >&2; exit 1; }
[[ "$size" == small || "$size" == large || "$size" == all ]] || {
  echo "SIZE must be small, large, or all" >&2
  exit 1
}

isa_dir="ext/e203/riscv-tools/riscv-tests/isa/generated"
fpga_dir="ext/e203/riscv-tools/fpga_test4sim"

resolve_case() {
  local name=$1
  case "$name" in
    dhrystone|dhrystone4sim)
      echo "dhrystone $fpga_dir/dhrystone4sim/dhrystone4sim.verilog 166667" ;;
    coremark|coremark4sim)
      echo "coremark $fpga_dir/coremark4sim/coremark4sim.verilog 1069745" ;;
    rv32ui-p-add)      echo "$name $isa_dir/$name.verilog 17995" ;;
    rv32ui-p-lw)       echo "$name $isa_dir/$name.verilog 17817" ;;
    rv32ui-p-sw)       echo "$name $isa_dir/$name.verilog 18094" ;;
    rv32um-p-mul)      echo "$name $isa_dir/$name.verilog 18809" ;;
    rv32um-p-div)      echo "$name $isa_dir/$name.verilog 17804" ;;
    rv32ua-p-amoadd_w) echo "$name $isa_dir/$name.verilog 17589" ;;
    rv32uc-p-rvc)      echo "$name $isa_dir/$name.verilog 17728" ;;
    rv32mi-p-csr)      echo "$name $isa_dir/$name.verilog 17603" ;;
    *)
      if [[ -f "$name" ]]; then
        echo "$(basename "$name" .verilog) $name -"
      elif [[ -f "$isa_dir/$name.verilog" ]]; then
        echo "$name $isa_dir/$name.verilog -"
      else
        echo "unknown testcase: $name" >&2
        return 1
      fi
      ;;
  esac
}

cases=()
case "$mode" in
  run)
    cases+=("$(resolve_case "$selected")")
    ;;
  smoke)
    if [[ "$smoke_set" == all ]]; then
      for f in "$isa_dir"/rv32{ui,um,ua,uc,mi}-p-*.verilog; do
        cases+=("$(resolve_case "$(basename "$f" .verilog)")")
      done
    else
      for t in rv32ui-p-add rv32ui-p-lw rv32ui-p-sw rv32um-p-mul rv32um-p-div \
               rv32ua-p-amoadd_w rv32uc-p-rvc rv32mi-p-csr; do
        cases+=("$(resolve_case "$t")")
      done
    fi
    ;;
  bench)
    [[ "$size" == small || "$size" == all ]] && cases+=("$(resolve_case dhrystone)")
    [[ "$size" == large || "$size" == all ]] && cases+=("$(resolve_case coremark)")
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 1
    ;;
esac

out="build/results/$tag"
mkdir -p "$out"
if [[ -f "build/$sim/version.txt" ]]; then
  cp "build/$sim/version.txt" "$out/version.txt"
fi
tsv="$out/measurements.tsv"
if [[ "$mode" == bench && ! -f "$tsv" ]]; then
  printf 'sim\ttest\trepeat\tcycles\tloop_s\twall_s\n' > "$tsv"
fi

for entry in "${cases[@]}"; do
  read -r test verilog expected_cycles <<< "$entry"
  mkdir -p "$out/$test"
  vcd="$out/$test/wave.vcd"

  if [[ "$sim" == iverilog ]]; then
    cmd=("${VVP:-vvp}" "$exe" "+TESTCASE=$verilog" +MAXCYCLES=20000000)
    [[ "$mode" != run ]] && cmd+=(+QUIET=1)
    [[ "$wave" == 1 ]] && cmd+=("+VCD=$vcd")
  else
    cmd=("$exe" "$verilog" 20000000)
    [[ "$mode" != run ]] && cmd+=(--quiet)
    [[ "$wave" == 1 ]] && cmd+=(--vcd "$vcd")
  fi

  { printf '+ '; printf '%q ' "${cmd[@]}"; printf '\n'; } > "$out/$test/command.txt"

  if [[ "$mode" == bench && -f "$tsv" ]]; then
    awk -F'\t' -v t="$test" '$2 != t' "$tsv" > "$tsv.tmp"
    mv "$tsv.tmp" "$tsv"
    rm -f "$out/$test"/run-*.log "$out/$test"/run-*.time
  fi

  last=0
  [[ "$mode" == bench ]] && last=$repeats
  for ((run=0; run<=last; run++)); do
    log="$out/$test/run-$run"
    if { time -p "${cmd[@]}"; } > "$log.log" 2> "$log.time"; then rc=0; else rc=$?; fi
    summary=$(grep -E '^PASS=' "$log.log" || true)
    cycles=$(sed -nE 's/^PASS=1 cycles=([0-9]+).*/\1/p' <<< "$summary")
    if [[ "$rc" != 0 || -z "$cycles" || ( "$expected_cycles" != "-" && "$cycles" != "$expected_cycles" ) ]]; then
      cat "$log.log" "$log.time" >&2
      echo "FAILED $test (rc=$rc, expected cycles=$expected_cycles, got: ${summary:-none})" >&2
      exit 1
    fi
    if [[ "$mode" == bench && "$run" -gt 0 ]]; then
      loop=$(sed -nE 's/.*HARNESS sim_s=([0-9.]+).*/\1/p' "$log.time")
      wall=$(awk '$1=="real" {print $2}' "$log.time")
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$test" "$run" "$cycles" "${loop:--}" "$wall" >> "$tsv"
    fi
  done
  echo "[$tag] $test: $summary"
done

if [[ "$mode" == bench ]]; then
  awk -f scripts/compare.awk "$tsv"
fi
