# E203 Simulator Benchmark

Compare CIRCT `arcilator`, Verilator, and Icarus Verilog using the upstream Hummingbird E203 `tb_top.v` and complete SoC with E203's official `.verilog` ISA tests, Dhrystone, and CoreMark. Results: [docs/results.md](docs/results.md). Arcilator workarounds: [docs/workarounds.md](docs/workarounds.md).

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

`SIZE=all SIM=all` takes substantially longer on Icarus; use `REPEATS=1` for a quick pass.

## Configuration

| Variable | Meaning |
| --- | --- |
| `SIM` | `arcilator` (default), `verilator`, `iverilog`, `all` |
| `SIZE` | `small` = Dhrystone (default), `large` = CoreMark, `all` = both |
| `SMOKE` | `default` = 8 tests, `all` = 67 |
| `REPEATS` | Timed runs after one warm-up (`5`) |
| `TAG` | `build/results/<TAG>/`; defaults to `<sim>` (`<sim>-run` for `make run`); not allowed with `SIM=all` |
| `CIRCT_BIN` | CIRCT `build/bin` (tools and arcilator headers) |
| `PYTHON` | Python 3 with `jinja2`; defaults to `.tools/venv/bin/python3` |

All three simulators compile the upstream `tb_top` testbench (`build/tb/tb_top.v`) and complete SoC (`e203_soc_top`). Native builds (`-DE203_NATIVE`) drive clocks and load images from C++ (`sim/main.cpp`), while Icarus runs the Verilog clock/reset and `$readmemh` blocks directly.

`WAVE=1` writes `build/results/<TAG>/<test>/wave.vcd` (13 testbench observations for native models; RTL hierarchy for Icarus). Pass `VCD_REFERENCE=<dir|file>` during `make run` or `make smoke` (or run `make compare-vcd`) to compare native waveform transitions:

```sh
make smoke SIM=arcilator WAVE=1 TAG=vcd-arcilator CIRCT_BIN=/path/to/circt/build/bin
make smoke SIM=verilator TAG=vcd-verilator VCD_REFERENCE=build/results/vcd-arcilator
```

`LUT` (default `false`; arcilator default `true`) and `OPT_FLAGS` (default `-O2`; empty = `llc -O2` only) tune arcilator. `VERILATOR`/`IVERILOG`/`VVP` override tool paths.

Use `-B` when switching tool versions or build flags. Per-version runs need their own `TAG`:

```sh
make -B bench SIM=verilator SIZE=all VERILATOR=/opt/verilator-5.028/bin/verilator TAG=verilator-5.028
make -B bench SIM=arcilator SIZE=all LUT=true TAG=arcilator-lut-on CIRCT_BIN=...
make -B bench SIM=arcilator SIZE=all OPT_FLAGS= TAG=arcilator-no-opt CIRCT_BIN=...
```

## Arcilator Note

`circt-verilog` + `arcilator` cannot compile unmodified E203 RTL directly. `make prepare` stages `ext/e203/{rtl,tb}` into `build/` and applies [`patches/e203.patch`](patches/e203.patch). All three simulators compile the same staged RTL and `tb_top.v`. Details: [docs/workarounds.md](docs/workarounds.md).

## Layout

- `Makefile` — build and benchmark targets
- `sim/` — C++ driver (`main.cpp`) and portable VCD writer (`vcd.h`)
- `scripts/` — test/bench runner, VCD/metric comparison, SRAM lowering, and env setup
- `patches/` — E203 RTL/testbench patch
- `docs/` — environment setup, results, and arcilator workarounds
- `repro/` — standalone CIRCT/arcilator reproducers
- `ext/e203/` — upstream E203 submodule
