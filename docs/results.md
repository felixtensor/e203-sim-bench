# Results

All timing numbers below come from `make bench`; correctness numbers come from `make smoke` and `make bench`. Both use the same patched `e203_cpu_top` RTL (see [workarounds.md](workarounds.md)) and the same official E203 `.verilog` images. Measured 2026-10-27. Every recorded benchmark and default smoke run is checked for `PASS=1` and an exact cycle count, and the stored logs are kept under `build/results/<TAG>/`. Each column therefore simulates the same work.

## Environment

| Item | Value |
| --- | --- |
| Host | Apple M1 Pro, 10 cores, 32 GB, macOS 27.0.1 |
| C++ compiler | Apple clang 21.0.0 (`clang-2100.3.34.2`), `-O2 -std=c++17`, single-threaded |
| E203 | `9f3e34f337f5d0a1236a285871ffa2032491617a` |
| CIRCT | `c914150104ad15efa6b16ec4e5e6f86736fe15d8` (LLVM 24.0.0git, slang 11.0.0) |
| Verilator | 5.028, 5.052 (conda-forge builds) |
| Icarus Verilog | 12.0, 13.0 (`-g2012`) |

Native build flags: arcilator uses this repo's default `LUT=false`, then `opt -O2` followed by `llc -O2`; Verilator's generated code is built with `OPT_FAST=OPT_SLOW=OPT_GLOBAL=-O2` (Verilator's own default for fast/global code is `-Os`). All native code is therefore compiled with `-O2`. The `without opt -O2` row uses `OPT_FLAGS=` and `llc -O2` only.

## Throughput (simulated cycles per host second, higher is better)

| Simulator | Dhrystone (166,667 cycles) | CoreMark (1,069,745 cycles) |
| --- | ---: | ---: |
| Verilator 5.052 | **2.28 M** (0.073 s) | **2.31 M** (0.463 s) |
| Verilator 5.028 | 1.54 M (0.108 s) | 1.57 M (0.682 s) |
| arcilator, `LUT=false` (project default) | 1.11 M (0.151 s) | 1.11 M (0.965 s) |
| arcilator, without `opt -O2` | 0.94 M (0.177 s) | 0.95 M (1.128 s) |
| arcilator, `LUT=true` | 0.88 M (0.188 s) | 0.89 M (1.202 s) |
| Icarus 13.0 | 2.25 k (74.2 s) | 2.82 k (379 s) |
| Icarus 12.0 | 1.52 k (109.5 s) | - |

- Native models (arcilator, Verilator) report the in-process simulation loop time (`HARNESS sim_s`), which excludes process startup, image loading and reset. arcilator and Verilator share the same C++ harness; Icarus uses `sim/tb.v`. Icarus reports `vvp` wall time, which includes process startup and image loading. The Icarus startup cost is small relative to its 74–379 s runs, but the two metrics are not identical in scope.
- Median of 5 timed runs after 1 warm-up for native models. Icarus uses 3 timed runs for Dhrystone and 1 for CoreMark. `SIM=all` with the default `REPEATS=5` takes roughly 45 minutes on this host because of the Icarus rows.
- No VCD is written in benchmark runs. Verilator is built without `--trace` unless `WAVE=1`; arcilator only dumps when `--vcd` is passed.
- For Dhrystone and CoreMark, cycle counts are post-reset harness cycles until the exit signature. They include benchmark startup, UART printing and the 16-cycle exit spin; they are not retired instructions or the benchmarks' internal `User_Cycle` / `Total ticks`.
- The official Dhrystone image runs only 2 loops and self-reports `User_Cycle=911`; the other ~165,000 harness cycles are startup, output and exit overhead. Treat the Dhrystone column as an end-to-end simulator workload, not as a Dhrystone core-performance measurement. CoreMark's internal `Total ticks` is 930,733 of the 1,069,745 harness cycles, so it is dominated by the benchmark itself.
- Benchmark self-reports: Dhrystone `1.249510 DMIPS/MHz`, CoreMark `2.148844 CoreMark/MHz` (identical on all simulators).

Observations:

- On this core, Verilator 5.052 is about 2.1× faster than arcilator with `LUT=false`. Verilator 5.028 → 5.052 gains about 47–48%.
- For arcilator, `--lookup-tables=false` is about 25% faster than arcilator's own default (`LUT=true`), and adding `opt -O2` before `llc -O2` gains about 17% on both benchmarks (0.94 M → 1.11 M; see [workarounds.md](workarounds.md)).
- Icarus 13.0 is about 1.5× faster than 12.0 on Dhrystone. It remains roughly three orders of magnitude slower than the native models: about 500× slower than arcilator and 1,000× slower than Verilator 5.052 on Dhrystone, and about 400×/830× on CoreMark.

These results cover one core, one host, one compiler and fixed build flags. They are not a general ranking of the simulators. Short native runs (0.07–1.2 s) and background host load limit how much to infer from small differences; the large gaps above are stable across the recorded runs.

## Correctness

All 67 official RV32IMAC ISA tests (`rv32{ui,um,ua,uc,mi}-p-*`) pass on arcilator, Verilator and Icarus 13.0 with identical cycle counts (`make smoke SIM=all SMOKE=all`). For example, `rv32ui-p-add` = 17,995 cycles and `rv32uc-p-rvc` = 17,728 cycles on all three. Dhrystone and CoreMark also finish at exactly the same cycle on all three simulators. In total, all 69 recorded cases (67 ISA tests plus the two benchmarks) agree across the three simulators.

These tests establish observed agreement on these images; they are not a formal proof of RTL or ISA equivalence.

## Reproduce

```sh
make bench SIM=all SIZE=all CIRCT_BIN=/path/to/circt/build/bin   # 3-way table
make -B bench SIM=verilator SIZE=all VERILATOR=/path/to/5.028/bin/verilator TAG=verilator-5.028
make -B bench SIM=arcilator SIZE=all LUT=true TAG=arcilator-lut-on CIRCT_BIN=...
make -B bench SIM=arcilator SIZE=all OPT_FLAGS= TAG=arcilator-no-opt CIRCT_BIN=...

# Icarus table rows use 3 Dhrystone and 1 CoreMark sample.
make -B bench SIM=iverilog SIZE=small REPEATS=3 TAG=iverilog-12.0 \
  IVERILOG=/path/to/12.0/iverilog VVP=/path/to/12.0/vvp
make -B bench SIM=iverilog SIZE=small REPEATS=3 TAG=iverilog
make bench SIM=iverilog SIZE=large REPEATS=1 TAG=iverilog

make compare                                                       # all tags side by side
```

`TAG` is not supported with `SIM=all`; run one simulator at a time when comparing versions or configurations. The Icarus rows in the table used `REPEATS=3` for Dhrystone and `REPEATS=1` for CoreMark; each run also has one untimed warm-up. The three-way `SIM=all` command uses the default `REPEATS=5` for every simulator and is much slower.

Per-run logs, commands, timers and the simulator version are written to `build/results/<TAG>/` (ignored by Git). Medians are computed by [`scripts/compare.awk`](../scripts/compare.awk).
