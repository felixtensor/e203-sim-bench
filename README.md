# E203 simulation benchmark

One E203 design, the same programs, three simulators: **arcilator, Verilator, Icarus Verilog**. All compilation commands are in [Makefile](Makefile); execution is in [scripts/run.sh](scripts/run.sh).

## Reproduce

Install GNU Make, Bash, a C++17 compiler, jq, and LLVM tools with the RISC-V assembler enabled (`llvm-mc`, `llvm-objcopy`). Install Verilator and Icarus, and use a CIRCT build containing `circt-verilog`, `circt-opt`, `arcilator`, and `llc`.

```sh
git clone --recurse-submodules https://github.com/felixtensor/e203-sim-bench.git
cd e203-sim-bench
make setup

make smoke SIM=arcilator CIRCT_BIN=/path/to/circt/build/bin WAVE=1
make smoke SIM=verilator WAVE=1
make smoke SIM=iverilog

make bench SIM=arcilator CIRCT_BIN=/path/to/circt/build/bin
make bench SIM=verilator
make bench SIM=iverilog
make compare
```

`make bench` validates seven smoke tests, then runs the same three small benchmarks: one warm-up and five measured runs each. Icarus is considerably slower. Use `REPEATS=1` for a quick check; `SIZE=large` selects the longer programs. Timing runs disable waveforms.

To run one test: `make run SIM=verilator TEST=smoke-itcm-dtcm WAVE=1`. Native smoke VCDs must match the recorded traces byte-for-byte. The failing smoke program must exit with failure; the runner checks that too.

## Tool paths

All tools default to `PATH`. Icarus and Verilator are configured in the same way:

| Make variable | Default / purpose |
| --- | --- |
| `VERILATOR` | `verilator` executable |
| `IVERILOG`, `VVP` | `iverilog`, `vvp` executables |
| `CIRCT_BIN` | Optional directory for the four CIRCT tools |
| `LLVM_MC`, `LLVM_OBJCOPY` | `llvm-mc`, `llvm-objcopy` for the RISC-V programs |
| `CXX`, `CXXFLAGS` | Native compiler; `-O2 -std=c++17` |
| `JOBS` | Verilator C++ build jobs, default 4 |

Examples:

```sh
make verilator VERILATOR=/path/to/bin/verilator CXX=clang++
make iverilog IVERILOG=/path/to/bin/iverilog VVP=/path/to/bin/vvp
make setup LLVM_MC=/path/to/full-llvm/bin/llvm-mc LLVM_OBJCOPY=/path/to/full-llvm/bin/llvm-objcopy
```

On macOS, Homebrew provides `llvm`, `jq`, `verilator`, and `icarus-verilog`; put its LLVM `bin` directory on `PATH`. Apple's system Clang and a host-only CIRCT LLVM build do not supply a RISC-V assembler. [Build the tested CIRCT revision](docs/toolchain.md) if needed. Repository scripts use Bash, awk and jq.

Use `make -n arcilator` to inspect commands. After changing compiler flags or tool versions, rebuild with `make -B compile SIM=...`. `make clean` removes generated output.

## Results and workarounds

[Results and measurement method](docs/results.md) contains the three-way comparison, tool versions, and timing definitions. Default runs use identical small programs for all three simulators. Historical larger native runs are listed separately.

Arcilator requires five workarounds. [docs/workarounds.md](docs/workarounds.md) maps each one to the exact patch, command, or script that applies it. `make repro CIRCT_BIN=...` runs two small compiler-failure examples.

## Layout

- `Makefile`: all three build flows and run targets.
- `sim/`: native testbench, two model-access headers, and Icarus Verilog testbench.
- `rtl/e203_sim.v`: the shared wrapper. `ext/e203/` is a pinned upstream submodule.
- `programs/`: two readable RISC-V assembly programs, case parameters, expected hashes.
- `patches/`, `scripts/`, `repro/`: DFF patch, Shell/awk helpers, and compiler reproducers.
- `data/`: archived measurements and reference traces. `build/`: generated files, ignored by Git.

Optional prebuilt models are downloaded from release assets, never committed to Git; see [docs/releases.md](docs/releases.md). Repository-authored code is Apache-2.0; dependencies retain their upstream licenses.
