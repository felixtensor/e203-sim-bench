# Environment Setup

Run these commands from the `e203-sim-bench` repository root. They prepare the tools used by the [Quick Start](../README.md#quick-start); `make setup` itself only prepares E203's RTL. Keep using the same shell so the exported paths remain available.

## System Tools

The benchmark uses Git, Make, Bash, and standard Unix utilities. The native arcilator and Verilator harnesses need a C++17 compiler. Building CIRCT with its slang frontend also needs CMake 3.28+, Ninja, Python 3, and a C++20 compiler (GCC 11+ or Clang 17+; on macOS, use recent Xcode Command Line Tools). See the [slang build requirements](https://sv-lang.com/building.html) for compiler details.

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
sudo apt-get install -y build-essential git cmake ninja-build python3 python3-venv verilator iverilog
```

Package versions vary by distribution. The [recorded results](results.md#environment) used Verilator 5.028/5.052 and Icarus 12.0/13.0; use matching versions when comparing timings. The CIRCT revision below matches the recorded results and the SRAM rewrite in this repository.

## Python Environment

The arcilator C++ header generator requires `jinja2`. Create an isolated environment under the Git-ignored `.tools/` directory:

```sh
python3 -m venv .tools/venv
.tools/venv/bin/python3 -m pip install jinja2==3.1.6
export PYTHON="$PWD/.tools/venv/bin/python3"
```

If an existing Python environment already provides `jinja2`, set `PYTHON` to that interpreter's absolute path instead. Installing it into another Python environment will not make it available to the interpreter selected by `PYTHON`.

## CIRCT and LLVM

If you already have a build of CIRCT revision `c914150104ad15efa6b16ec4e5e6f86736fe15d8` with the slang frontend enabled, set `CIRCT_BIN` to its absolute `build/bin` path and skip to the checks below.

Otherwise, build the pinned CIRCT revision and its LLVM submodule together, following the [upstream build configuration](https://github.com/llvm/circt/blob/c914150104ad15efa6b16ec4e5e6f86736fe15d8/README.md#getting-started):

```sh
export CIRCT_SRC="$PWD/.tools/circt"
git clone https://github.com/llvm/circt.git "$CIRCT_SRC"
git -C "$CIRCT_SRC" checkout --detach c914150104ad15efa6b16ec4e5e6f86736fe15d8
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

Configuration downloads the pinned slang sources and their dependencies. LLVM/CIRCT compilation is a substantial one-time build; lower `--parallel` if memory is limited. `CIRCT_SLANG_FRONTEND_ENABLED=ON` is required to build `circt-verilog`. The build also copies `arcilator-header-cpp.py` and `arcilator-runtime.h` into `build/bin`; this repository needs both alongside the executables.

Use `opt` and `llc` from the same LLVM build as CIRCT. Setting `CIRCT_BIN` selects all five tools together, without needing to add them to `PATH`.

## Check the Environment

```sh
(
set -e
"$PYTHON" -c 'import jinja2; print("jinja2", jinja2.__version__)'
for tool in circt-verilog circt-opt arcilator opt llc; do
  "$CIRCT_BIN/$tool" --version
done
test -f "$CIRCT_BIN/arcilator-header-cpp.py"
test -f "$CIRCT_BIN/arcilator-runtime.h"
verilator --version
iverilog -V
vvp -V
c++ --version
)
```

Return to the [Quick Start](../README.md#quick-start) after these checks succeed. In a new shell, export `PYTHON` and `CIRCT_BIN` again. If the simulators are installed outside `PATH`, pass `VERILATOR=/absolute/path/to/verilator`, or both `IVERILOG=/absolute/path/to/iverilog` and `VVP=/absolute/path/to/vvp`, to Make. Keep `iverilog` and `vvp` from the same installation.
