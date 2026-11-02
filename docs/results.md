# Results

All simulators compile the upstream `tb_top` testbench and complete E203 SoC (`e203_soc_top`: CPU core, ITCM/DTCM, CLINT, PLIC, AON/PMU, UART, QSPI, GPIO, I2C, PWM/timer, and debug module).

## Environment

| Item | Value |
| --- | --- |
| macOS host | Apple M1 Pro (10 cores, 32 GB, macOS 27.0.1), Apple clang 21.0.0 (`clang-2100.4.1.1`) |
| Linux host | AMD Ryzen 7 7800X3D (8 cores / 16 threads, 32 GB, CachyOS Linux 7.3.1), GCC 16.2.1 |
| E203 | `9f3e34f337f5d0a1236a285871ffa2032491617a` ([`patches/e203.patch`](../patches/e203.patch)) |
| CIRCT | `c914150104ad15efa6b16ec4e5e6f86736fe15d8` (LLVM 24.0.0git, slang 11.0.0; [`circt-infer-clock-ports.patch`](../patches/circt-infer-clock-ports.patch) on Linux) |
| Verilator | 5.028, 5.052 |
| Icarus Verilog | 12.0, 13.0 (`-g2012`) |

Native harnesses are compiled single-threaded with `-O2 -std=c++17`. Arcilator uses `LUT=false`, `opt -O2`, and `llc -O2` (`without opt -O2` sets `OPT_FLAGS=`); Verilator uses `OPT_FAST=OPT_SLOW=OPT_GLOBAL=-O2`.

## Throughput (`tb_top`, simulated `hfclk` cycles per host second)

Workload lengths on `tb_top`: Dhrystone = `184,228` cycles (`17,395` reset/boot cycles before main loop; `User_Cycle=911` across 2 runs); CoreMark = `1,081,994` cycles (`Total ticks=930,733`). Linux (7800X3D) columns will be populated when measured on the Linux host.

| Simulator (`tb_top`) | Metric | Dhrystone (M1 Pro) | CoreMark (M1 Pro) | Dhrystone (7800X3D) | CoreMark (7800X3D) |
| --- | --- | ---: | ---: | ---: | ---: |
| Verilator 5.028 | loop | **1.04 M** (0.177 s) | **1.11 M** (0.971 s) | TBD | TBD |
| Verilator 5.052 | loop | 1.00 M (0.184 s) | 1.07 M (1.012 s) | TBD | TBD |
| arcilator, `LUT=false` (`opt -O2` + `llc -O2`) | loop | **459 k** (0.402 s) | **453 k** (2.386 s) | TBD | TBD |
| arcilator, `LUT=false`, without `opt -O2` | loop | 329 k (0.561 s) | 326 k (3.315 s) | TBD | TBD |
| arcilator, `LUT=true` | loop | 281 k (0.655 s) | 281 k (3.847 s) | TBD | TBD |
| Icarus 13.0 | wall | 1.56 k (118.4 s) | 1.92 k (563.8 s) | TBD | TBD |
| Icarus 12.0 | wall | 1.14 k (161.5 s) | - | TBD | TBD |

- **Metric**: Native models report in-process simulation loop time (`HARNESS sim_s`), excluding process startup and image loading; Icarus reports `vvp` process wall time.
- **Runs**: Median of 5 timed runs after 1 warm-up run for native models; Icarus uses 3 timed runs for Dhrystone (12.0: 1 run) and 1 timed run for CoreMark.
- **Benchmark self-reports**: Dhrystone reports `1.249510 DMIPS/MHz` and CoreMark reports `2.148844 CoreMark/MHz` (identical across `arcilator`, Verilator, and Icarus).

### Observations

- **Full SoC (`tb_top`) vs core-only**: Moving from `e203_cpu_top` to the complete SoC (`tb_top`) adds dual clock domains (`#2 clk` and `#33 lfextclk` in `e203_soc_top`) and peripheral subsystems (UART, QSPI, GPIO, I2C, AON/PMU, CLINT, PLIC). On M1 Pro, Verilator runs CoreMark at **1.07–1.11 M cycles/s** and `arcilator` at **453 k cycles/s** (~2.4× faster in Verilator).
- **Arcilator flags on `tb_top`**: Compiling `tb_top` with `arcilator` produces 240 functions (`989 KB` LLVM IR with `LUT=false`). Running `opt -O2` before `llc -O2` inlines split arc evaluation functions and improves throughput by **+39%** on CoreMark (`326 k` $\rightarrow$ `453 k cycles/s`). Disabling lookup tables (`--lookup-tables=false`, project default) improves throughput by **+61%** over `LUT=true` (`281 k` $\rightarrow$ `453 k cycles/s`).
- **Icarus Verilog**: Icarus 13.0 is **1.37×** faster than Icarus 12.0 on Dhrystone (`1.56 k` vs `1.14 k cycles/s`) and ~240–580× slower than native compiled models.

These results cover one SoC, fixed tool revisions, and single-threaded builds; they are not a general simulator ranking.

## Correctness

With `tb_top`, all 67 RV32IMAC ISA images, Dhrystone, and CoreMark pass on arcilator, Verilator 5.052, and Icarus 13.0 on the local M1 Pro with identical cycle counts (e.g., `rv32ui-p-add` = 23,424; `rv32uc-p-rvc` = 23,157; Dhrystone = 184,228; CoreMark = 1,081,994). The eight default native VCDs match on all 13 observations (`make compare-vcd`). This establishes observed agreement on these images, not formal equivalence.
With `tb_top`, all 67 official RV32IMAC ISA tests (`rv32{ui,um,ua,uc,mi}-p-*`), Dhrystone, and CoreMark pass on `arcilator`, Verilator (5.028 and 5.052), and Icarus (12.0 and 13.0) with identical cycle counts (e.g., `rv32ui-p-add` = `23,424`; `rv32uc-p-rvc` = `23,157`; Dhrystone = `184,228`; CoreMark = `1,081,994`). The eight default smoke VCD waveforms from `arcilator` and Verilator match across all 13 testbench observations (`make compare-vcd`). This establishes observed agreement on these workloads, not formal equivalence.

## Reproduce

```sh
# Default run across all three simulators
make bench SIM=all SIZE=all CIRCT_BIN=/path/to/circt/build/bin

# Native simulator variants (5 timed runs after 1 warm-up)
make -B bench SIM=verilator SIZE=all VERILATOR=/path/to/5.052/bin/verilator TAG=verilator-5.052
make -B bench SIM=verilator SIZE=all VERILATOR=/path/to/5.028/bin/verilator TAG=verilator-5.028
make -B bench SIM=arcilator SIZE=all CIRCT_BIN=/path/to/circt/build/bin TAG=arcilator
make -B bench SIM=arcilator SIZE=all OPT_FLAGS= CIRCT_BIN=/path/to/circt/build/bin TAG=arcilator-no-opt
make -B bench SIM=arcilator SIZE=all LUT=true CIRCT_BIN=/path/to/circt/build/bin TAG=arcilator-lut-on

# Icarus Verilog (Dhrystone + CoreMark)
make -B bench SIM=iverilog SIZE=small REPEATS=3 TAG=iverilog-13.0 \
  IVERILOG=/path/to/13.0/bin/iverilog VVP=/path/to/13.0/bin/vvp
make -B bench SIM=iverilog SIZE=small REPEATS=1 TAG=iverilog-12.0 \
  IVERILOG=/path/to/12.0/bin/iverilog VVP=/path/to/12.0/bin/vvp

make compare
```

Per-run logs, commands, timers, and versions are saved under `build/results/<TAG>/`. Medians are computed by [`scripts/compare.awk`](../scripts/compare.awk).
