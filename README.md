# E203 Simulator Benchmark

Compare CIRCT `arcilator`, Verilator, and Icarus Verilog on the upstream Hummingbird E203 `e203_cpu_top` with E203's official `.verilog` ISA tests, Dhrystone, and CoreMark. Results: [docs/results.md](docs/results.md). Arcilator workarounds: [docs/workarounds.md](docs/workarounds.md).

## Quick Start

```sh
git clone --recurse-submodules https://github.com/felixtensor/e203-sim-bench.git
cd e203-sim-bench
```

Install the system packages and CIRCT as described in [Environment Setup](docs/setup.md), then:

```sh
make setup
export CIRCT_BIN=/path/to/circt/build/bin
make doctor SIM=all
make smoke SIM=all
make bench SIM=all SIZE=small REPEATS=1
make compare
```

`make setup` does not install CIRCT, Verilator, or Icarus.

## Commands

| Command | Purpose |
| --- | --- |
| `make setup` | submodule, patched RTL, `.tools/venv` |
| `make doctor [SIM=<sim>|all]` | verify toolchain |
| `make smoke SIM=all SMOKE=all` | all 67 RV32IMAC ISA tests (slow on Icarus) |
| `make bench SIM=arcilator SIZE=all` | Dhrystone + CoreMark |
| `make run SIM=verilator TEST=rv32ui-p-add WAVE=1` | one test, optional VCD |
| `make compare` | median table from `build/results/*/measurements.tsv` |
| `make compare-vcd REFERENCE=... CANDIDATE=...` | compare VCD files or result directories |
| `make repro CIRCT_BIN=...` | standalone CIRCT/arcilator reproducers |

`SIZE=all SIM=all` with the default five runs takes ~45 min, mostly in Icarus; use `REPEATS=1` for a quick pass.

## Configuration

| Variable | Meaning |
| --- | --- |
| `SIM` | `arcilator` (default), `verilator`, `iverilog`, `all` |
| `TOP` | `e203_cpu_top` (default, 108 ports) or `e203_sim` (17-port wrapper for native sims) |
| `SIZE` | `small` = Dhrystone (default), `large` = CoreMark, `all` = both |
| `SMOKE` | `default` = 8 tests, `all` = 67 |
| `REPEATS` | Timed runs after one warm-up (`5`) |
| `TAG` | `build/results/<TAG>/`; defaults to `<sim>` (`<sim>-run` for `make run`); not allowed with `SIM=all` |
| `CIRCT_BIN` | CIRCT `build/bin` (tools and arcilator headers) |
| `PYTHON` | Python 3 with `jinja2`; defaults to `.tools/venv/bin/python3` |

`WAVE=1` writes `build/results/<TAG>/<test>/wave.vcd` (17 active harness signals for native models; RTL hierarchy for Icarus). Pass `VCD_REFERENCE=<dir|file>` during `make run` or `make smoke` (or run `make compare-vcd`) to verify native waveform equivalence:

```sh
make smoke SIM=arcilator WAVE=1 TAG=vcd-arcilator CIRCT_BIN=/path/to/circt/build/bin
make smoke SIM=verilator TAG=vcd-verilator VCD_REFERENCE=build/results/vcd-arcilator
```

`LUT` (default `false`; arcilator default `true`) and `OPT_FLAGS` (default `-O2`; empty = `llc -O2` only) tune arcilator. `VERILATOR`/`IVERILOG`/`VVP` override tool paths.

Use `-B` when switching tool versions, `TOP`, or build flags. Per-version runs need their own `TAG`:

```sh
make -B bench SIM=verilator SIZE=all VERILATOR=/opt/verilator-5.028/bin/verilator TAG=verilator-5.028
make -B bench SIM=arcilator SIZE=all LUT=true TAG=arcilator-lut-on CIRCT_BIN=...
make -B bench SIM=arcilator TOP=e203_sim SIZE=all TAG=arcilator-wrap CIRCT_BIN=...
```

## Arcilator Note

`circt-verilog` + `arcilator` cannot compile unmodified E203 RTL directly. Five RTL/pipeline fixes (plus a CIRCT `InferClockPorts` lifetime patch on Linux) are required: strip DFF `#1` delays, `FPGA_SOURCE=1`, lower `sirv_sim_ram` byte masks to `arc.memory`, flatten HW modules before `arcilator`, and `--async-resets-as-sync`. `TOP=e203_sim`, `LUT`, and `OPT_FLAGS` only affect speed. Details: [docs/workarounds.md](docs/workarounds.md).

## Layout

- `Makefile` — build and benchmark targets
- `sim/` — native harness (`main.cpp`, `vcd.h`), tie-off wrapper (`e203_sim.v`), and Icarus testbench (`tb.v`)
- `scripts/` — test/bench runner, VCD/metric comparison, RAM rewrite, Python/env setup
- `patches/` — RTL and CIRCT patches
- `docs/` — environment setup, results and arcilator workarounds
- `repro/` — standalone CIRCT/arcilator reproducers
- `ext/e203/` — upstream E203 submodule
