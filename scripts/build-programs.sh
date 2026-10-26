#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mc=${1:-llvm-mc}
objcopy=${2:-llvm-objcopy}
mkdir -p build/programs
while read -r test _boot scratch _latency _stall _cycles _reads _writes status; do
  [[ -z "$test" || "$test" == \#* ]] && continue
  source=programs/benchmark.s
  iterations=20000
  [[ "$test" == *-small-* ]] && iterations=2000
  [[ "$test" == smoke-* ]] && source=programs/smoke.s
  expected=55
  [[ "$status" == FAIL ]] && expected=54
  echo "$test: $source SCRATCH=$scratch ITERATIONS=$iterations EXPECT_SUM=$expected"
  "$mc" -triple=riscv32 -mattr=+m,+a,+c -filetype=obj \
    --defsym="SCRATCH=$scratch" --defsym="ITERATIONS=$iterations" \
    --defsym="EXPECT_SUM=$expected" "$source" -o "build/programs/$test.o"
  "$objcopy" -O binary --only-section=.text "build/programs/$test.o" "build/programs/$test.bin"
done < programs/cases.tsv
cd build/programs
shasum -a 256 -c ../../programs/SHA256SUMS
