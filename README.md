# E203 Simulator Benchmark

Compare CIRCT `arcilator`, Verilator, and Icarus Verilog on the upstream Hummingbird E203 `e203_cpu_top` with E203's official `.verilog` ISA tests, Dhrystone, and CoreMark. Results: [docs/results.md](docs/results.md). Arcilator workarounds: [docs/workarounds.md](docs/workarounds.md).

## Quick Start

```sh
git clone --recurse-submodules https://github.com/felixtensor/e203-sim-bench.git
cd e203-sim-bench
```

Follow [Environment Setup](docs/setup.md) to install the tools and set `CIRCT_BIN` and `PYTHON`, then run in the same shell:

```sh
make setup

make smoke SIM=all
make bench SIM=all SIZE=small REPEATS=1
make compare
```

`make setup` prepares the submodule and patched RTL; it does not install tools. Tools default to `PATH` unless overridden.

## Commands

| Command | Purpose |
| --- | --- |
| `make smoke SIM=all SMOKE=all` | all 67 RV32IMAC ISA tests (slow on Icarus) |
| `make bench SIM=arcilator SIZE=all` | Dhrystone + CoreMark |
| `make run SIM=iverilog TEST=coremark WAVE=1` | one test, optional VCD |
| `make compare` | median table from `build/results/*/measurements.tsv` |
| `make repro CIRCT_BIN=...` | standalone CIRCT/arcilator reproducers |

`SIZE=all SIM=all` with the default five runs takes ~45 min, mostly in Icarus; use `REPEATS=1` for a quick pass.

## Configuration

| Variable | Meaning |
| --- | --- |
| `SIM` | `arcilator` (default), `verilator`, `iverilog`, `all` |
| `SIZE` | `small` = Dhrystone (default), `large` = CoreMark, `all` = both |
| `SMOKE` | `default` = 8 tests, `all` = 67 |
| `REPEATS` | Timed runs after one warm-up (`5`) |
| `TAG` | `build/results/<TAG>/`; defaults to `<sim>` (`<sim>-run` for `make run`); not allowed with `SIM=all` |
| `CIRCT_BIN` | CIRCT `bin` directory, including `arcilator-header-cpp.py` and `arcilator-runtime.h` |

`WAVE=1` writes `<TAG>/<test>/wave.vcd` (Verilator needs `-B WAVE=1`). `LUT` (default `false`; arcilator default `true`) and `OPT_FLAGS` (default `-O2`; empty = `llc -O2` only) tune arcilator. `PYTHON` must provide `jinja2`; `VERILATOR`/`IVERILOG`/`VVP` override tool paths.

Use `-B` when switching tool versions or build flags. Per-version runs need their own `TAG`:

```sh
make -B bench SIM=verilator SIZE=all VERILATOR=/opt/verilator-5.028/bin/verilator TAG=verilator-5.028
make -B bench SIM=arcilator SIZE=all LUT=true TAG=arcilator-lut-on CIRCT_BIN=...
```

## Arcilator Note

`circt-verilog` + `arcilator` cannot compile unmodified E203 RTL directly. Five fixes are required: strip DFF `#1` delays, `FPGA_SOURCE=1`, lower `sirv_sim_ram` byte masks to `arc.memory`, flatten HW modules before `arcilator`, and `--async-resets-as-sync`. `LUT`/`OPT_FLAGS` only affect speed. Details: [docs/workarounds.md](docs/workarounds.md).

## Layout

- `Makefile` — build and benchmark targets
- `sim/` — native harness (`main.cpp`) and Icarus testbench (`tb.v`)
- `scripts/` — test/bench runner, median table, RAM rewrite
- `patches/` — DFF delay removal
- `docs/` — environment setup, results and arcilator workarounds
- `repro/` — standalone CIRCT/arcilator reproducers
- `ext/e203/` — upstream E203 submodule
