# Build the tested CIRCT tools

Requires Git, CMake, Ninja, a C++ compiler, and LLVM's build dependencies (including Python 3). Python is an upstream build dependency; this repository's scripts use Shell. Existing tool installations can be selected through the README's Make variables.

Run from the benchmark repository root:

```sh
git clone --no-checkout https://github.com/llvm/circt.git .tools/circt
git -C .tools/circt checkout c914150104ad15efa6b16ec4e5e6f86736fe15d8
git -C .tools/circt submodule update --init --recursive
cmake -G Ninja -S .tools/circt/llvm/llvm -B .tools/circt/build \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DLLVM_ENABLE_ASSERTIONS=ON -DLLVM_TARGETS_TO_BUILD=host \
  -DLLVM_ENABLE_PROJECTS=mlir -DLLVM_EXTERNAL_PROJECTS=circt \
  -DLLVM_EXTERNAL_CIRCT_SOURCE_DIR="$PWD/.tools/circt" \
  -DCIRCT_SLANG_FRONTEND_ENABLED=ON -DCIRCT_SLANG_BUILD_FROM_SOURCE=ON
cmake --build .tools/circt/build --target circt-verilog circt-opt arcilator llc -j4
make smoke SIM=arcilator CIRCT_BIN=.tools/circt/build/bin
```

This builds the unmodified upstream compiler with the slang frontend and assertions, matching the recorded configuration. Source builds need substantial disk space and RAM; reduce `-j4` if needed. Program assembly separately needs a full LLVM installation with RISC-V support. See [upstream requirements](https://circt.llvm.org/docs/GettingStarted/) for supported build environments.
