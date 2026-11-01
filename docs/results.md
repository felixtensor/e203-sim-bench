# Results

All timing numbers come from `make bench`; correctness numbers come from `make smoke` and `make bench`. Every run uses the same patched E203 RTL (see [workarounds.md](workarounds.md)) and official `.verilog` images, and is checked for `PASS=1` and an exact cycle count under `build/results/<TAG>/`.

## Environment

| Item | Value |
| --- | --- |
| Host | Apple M1 Pro, 10 cores, 32 GB, macOS 27.0.1 |
| C++ compiler | Apple clang 21.0.0 (`clang-2100.3.34.2`), `-O2 -std=c++17`, single-threaded |
| E203 | `9f3e34f337f5d0a1236a285871ffa2032491617a` |
| CIRCT | `c914150104ad15efa6b16ec4e5e6f86736fe15d8` (LLVM 24.0.0git, slang 11.0.0) |
| Verilator | 5.028, 5.052 (conda-forge builds) |
| Icarus Verilog | 12.0, 13.0 (`-g2012`) |

Native build flags: arcilator uses `LUT=false`, `opt -O2`, and `llc -O2` (`without opt -O2` sets `OPT_FLAGS=`); Verilator uses `OPT_FAST=OPT_SLOW=OPT_GLOBAL=-O2`.

## Throughput (simulated cycles per host second, higher is better)

### Default Top (`TOP=e203_cpu_top`, 108 ports)

| Simulator | Dhrystone (166,667 cycles) | CoreMark (1,069,745 cycles) |
| --- | ---: | ---: |
| Verilator 5.052 | **2.26 M** (0.074 s) | **2.30 M** (0.465 s) |
| Verilator 5.028 | 1.54 M (0.108 s) | 1.57 M (0.680 s) |
| arcilator, `LUT=false` (project default) | 1.10 M (0.152 s) | 1.10 M (0.975 s) |
| arcilator, without `opt -O2` | 0.94 M (0.177 s) | 0.94 M (1.137 s) |
| arcilator, `LUT=true` | 0.88 M (0.189 s) | 0.89 M (1.206 s) |
| Icarus 13.0 | 2.25 k (74.2 s) | 2.82 k (379 s) |
| Icarus 12.0 | 1.52 k (109.5 s) | - |

### Static Tie-Off Wrapper (`TOP=e203_sim`, 17 ports)

[`sim/e203_sim.v`](../sim/e203_sim.v) ties off the 91 unused debug, interrupt, external-TCM, and unused-ICB pins in Verilog, exposing only the 17 active harness pins:

| Simulator (`TOP=e203_sim`) | Dhrystone (166,667 cycles) | CoreMark (1,069,745 cycles) | vs `e203_cpu_top` (CoreMark) |
| --- | ---: | ---: | ---: |
| Verilator 5.052 | **3.20 M** (0.052 s) | **3.27 M** (0.327 s) | +42% |
| Verilator 5.028 | 3.05 M (0.055 s) | 3.17 M (0.338 s) | +101% |
| arcilator, `LUT=false` (`opt -O2` + `llc -O2`) | 2.80 M (0.060 s) | 2.80 M (0.382 s) | +155% |
| arcilator, `LUT=false`, without `opt -O2` | 2.57 M (0.065 s) | 2.62 M (0.408 s) | +179% |
| arcilator, `LUT=true` | 1.69 M (0.099 s) | 1.70 M (0.629 s) | +92% |

- Native models report in-process loop time (`HARNESS sim_s`), excluding process startup, image loading, and reset; Icarus reports `vvp` wall time.
- Median of 5 timed runs after 1 warm-up for native models (Icarus: 3 for Dhrystone, 1 for CoreMark). No VCD is written during benchmarks.
- Cycle counts are post-reset harness cycles until the exit signature (including startup, UART output, and exit spin). The official Dhrystone image runs 2 loops (`User_Cycle=911` of 166,667 cycles); CoreMark is dominated by the benchmark loop (`Total ticks=930,733` of 1,069,745 cycles).
- Benchmark self-reports: Dhrystone `1.249510 DMIPS/MHz`, CoreMark `2.148844 CoreMark/MHz` (identical across all simulators and both tops).

Observations:

- **Top-level pin exposure (`e203_cpu_top` vs `e203_sim`)**: Keeping all 108 `e203_cpu_top` ports dynamic prevents constant folding of unused interfaces and causes `arcilator` `SplitLoops` to emit 84 functions (`303 KB` IR), leaving Verilator 5.052 about 2.1× faster (`2.30 M` vs `1.10 M`). Tying off the 91 unused pins in `e203_sim` shrinks `arcilator` IR to 17 functions (`205 KB`) and raises CoreMark throughput 2.55× to **2.80 M cycles/s** (`2.62 M` without `opt -O2`), while Verilator 5.028 and 5.052 reach `3.17 M` and `3.27 M` (within ~13–17% of arcilator).
- **Arcilator flags**: `--lookup-tables=false` gains +24% on `e203_cpu_top` (`0.89 M` → `1.10 M`) and +65% on `e203_sim` (`1.70 M` → `2.80 M`). Adding `opt -O2` before `llc -O2` gains +17% on `e203_cpu_top` and +7% on `e203_sim` (see [workarounds.md](workarounds.md)).
- **Icarus**: 13.0 is 1.5× faster than 12.0 on Dhrystone and ~3 orders of magnitude slower than native models.

These results cover one core, one host, and fixed flags; they are not a general simulator ranking.

## Correctness

All 67 official RV32IMAC ISA tests (`rv32{ui,um,ua,uc,mi}-p-*`), Dhrystone, and CoreMark pass on arcilator, Verilator, and Icarus 13.0 with identical cycle counts (`make smoke SIM=all SMOKE=all`, e.g., `rv32ui-p-add` = 17,995 and `rv32uc-p-rvc` = 17,728). Both `TOP=e203_cpu_top` and `TOP=e203_sim` produce identical cycle counts and outputs. This establishes observed agreement on these images, not formal equivalence.

## Reproduce

```sh
# Default top (TOP=e203_cpu_top)
make bench SIM=all SIZE=all CIRCT_BIN=/path/to/circt/build/bin
make -B bench SIM=verilator SIZE=all VERILATOR=/path/to/5.028/bin/verilator TAG=verilator-5.028
make -B bench SIM=arcilator SIZE=all LUT=true TAG=arcilator-lut-on CIRCT_BIN=...
make -B bench SIM=arcilator SIZE=all OPT_FLAGS= TAG=arcilator-no-opt CIRCT_BIN=...

# Static tie-off wrapper (TOP=e203_sim)
make -B bench SIM=arcilator TOP=e203_sim SIZE=all TAG=arcilator-wrap CIRCT_BIN=...
make -B bench SIM=arcilator TOP=e203_sim SIZE=all OPT_FLAGS= TAG=arcilator-wrap-no-opt CIRCT_BIN=...
make -B bench SIM=arcilator TOP=e203_sim SIZE=all LUT=true TAG=arcilator-wrap-lut-on CIRCT_BIN=...
make -B bench SIM=verilator TOP=e203_sim SIZE=all VERILATOR=/path/to/5.052/bin/verilator TAG=verilator-5.052-wrap
make -B bench SIM=verilator TOP=e203_sim SIZE=all VERILATOR=/path/to/5.028/bin/verilator TAG=verilator-5.028-wrap

# Icarus (3 Dhrystone and 1 CoreMark timed runs)
make -B bench SIM=iverilog SIZE=small REPEATS=3 TAG=iverilog-12.0 \
  IVERILOG=/path/to/12.0/iverilog VVP=/path/to/12.0/vvp
make -B bench SIM=iverilog SIZE=small REPEATS=3 TAG=iverilog
make bench SIM=iverilog SIZE=large REPEATS=1 TAG=iverilog

make compare
```

Per-run logs, commands, timers, and versions are saved under `build/results/<TAG>/`. Medians are computed by [`scripts/compare.awk`](../scripts/compare.awk).
