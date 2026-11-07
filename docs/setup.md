# Environment Setup

Run these commands from the repository root.

## System Tools

The benchmark uses Git, Make, Bash, Patch, and standard Unix utilities. The native arcilator and Verilator harnesses need a C++17 compiler. Building CIRCT with its slang frontend also needs CMake 3.28+, Ninja, Python 3, and a C++20 compiler (GCC 11+ or Clang 17+; on macOS, use recent Xcode Command Line Tools). See the [slang build requirements](https://sv-lang.com/building.html) for compiler details.

### macOS

Install Xcode Command Line Tools if they are not already installed:

```sh
xcode-select --install
```

With [Homebrew](https://brew.sh/) available:

```sh
brew install git cmake ninja python verilator icarus-verilog
```

The simulator packages provide [`verilator`](https://formulae.brew.sh/formula/verilator), [`iverilog` and `vvp`](https://formulae.brew.sh/formula/icarus-verilog).

### Ubuntu 24.04 or Later

```sh
sudo apt-get update
sudo apt-get install -y build-essential git cmake ninja-build python3 python3-venv patch verilator iverilog
```

Package versions vary by distribution. The [recorded results](results.md#environment) used Verilator 5.028/5.052 and Icarus 12.0/13.0; use matching versions (e.g., built from upstream release tarballs under `.tools/`) when comparing timings. The pinned CIRCT revision below matches the SRAM rewrite in this repository.

## Python Environment

`make setup` creates `.tools/venv` with `jinja2==3.1.6` for the arcilator header generator; later `make` calls use it automatically. To reuse another interpreter with `jinja2`, export it before setup:

```sh
export PYTHON=/absolute/path/to/python3
make setup
```

## CIRCT and LLVM

If you already have a build of CIRCT revision `fcd8507a3c876ba0c9f3d435310023173f2a7434` with the slang frontend enabled, set `CIRCT_BIN` to its absolute `build/bin` path and skip to the checks below.

Otherwise, build the pinned CIRCT revision and its LLVM submodule together, following the [upstream build configuration](https://github.com/llvm/circt/blob/fcd8507a3c876ba0c9f3d435310023173f2a7434/README.md#getting-started):

```sh
export CIRCT_SRC="$PWD/.tools/circt"
export PYTHON="${PYTHON:-$PWD/.tools/venv/bin/python3}"
git clone https://github.com/llvm/circt.git "$CIRCT_SRC"
git -C "$CIRCT_SRC" checkout --detach fcd8507a3c876ba0c9f3d435310023173f2a7434
git -C "$CIRCT_SRC" submodule update --init --recursive

cmake -G Ninja -S "$CIRCT_SRC/llvm/llvm" -B "$CIRCT_SRC/build" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DLLVM_TARGETS_TO_BUILD=host \
  -DLLVM_ENABLE_PROJECTS=mlir \
  -DLLVM_EXTERNAL_PROJECTS=circt \
  -DLLVM_EXTERNAL_CIRCT_SOURCE_DIR="$CIRCT_SRC" \
  -DCIRCT_SLANG_FRONTEND_ENABLED=ON \
  -DCIRCT_SLANG_BUILD_FROM_SOURCE=ON \
  -DLLVM_PARALLEL_LINK_JOBS=1 \
  -DPython3_EXECUTABLE="$PYTHON"

cmake --build "$CIRCT_SRC/build" \
  --target circt-verilog circt-opt arcilator opt llc --parallel 4

export CIRCT_BIN="$CIRCT_SRC/build/bin"
```

Configuration downloads the pinned slang sources. LLVM/CIRCT is a substantial one-time build; lower `--parallel` if memory is limited. `CIRCT_SLANG_FRONTEND_ENABLED=ON` is required for `circt-verilog`. The build places `arcilator-header-cpp.py` and `arcilator-runtime.h` in `build/bin`.

Use `opt` and `llc` from the same LLVM build as CIRCT.

## Check the Environment

```sh
make doctor            # arcilator
make doctor SIM=all    # all simulators
```

`make doctor` prints resolved paths and versions and exits non-zero with hints for missing tools; `bench`/`smoke` run it automatically. For non-PATH installs, pass `VERILATOR=...` or `IVERILOG=... VVP=...`; `CIRCT_BIN` covers all CIRCT tools.

Return to the [Quick Start](../README.md#quick-start).
