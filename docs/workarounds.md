# Arcilator Workarounds for E203 (`e203_cpu_top`)

`circt-verilog` + `arcilator` cannot compile and simulate unmodified E203 RTL out of the box. Five specific workarounds and compiler options are required in [`Makefile`](../Makefile) to bring up `e203_cpu_top` and obtain cycle-exact agreement with Verilator and Icarus Verilog on the official images in this repository. This is observed agreement on those tests, not a formal RTL or ISA equivalence proof.

Tested versions:
- E203 (`ext/e203`): `9f3e34f337f5d0a1236a285871ffa2032491617a`
- CIRCT: `c914150104ad15efa6b16ec4e5e6f86736fe15d8` (LLVM 24.0.0git, slang 11.0.0)

## Summary of Required Workarounds

| # | Failure without Workaround | Workaround Applied | Location |
| --- | --- | --- | --- |
| 1 | `sirv_gnrl_dffs.v` uses `<= #1` non-blocking delays; `circt-verilog` lowers them to timed `llhd.process` + `llhd.wait` blocks rejected by `arcilator` | Strip `#1` intra-assignment delays in a copied RTL tree (`build/rtl`) | [`patches/remove-dff-delays.patch`](../patches/remove-dff-delays.patch) (`make prepare`) |
| 2 | `e203_clkgate.v` instantiates a latch-based ASIC clock gate when `FPGA_SOURCE` is unset | Pass `-DFPGA_SOURCE=1` so `e203_clkgate` uses the upstream FPGA clock pass-through | [`Makefile`](../Makefile) (`DEFINES`) |
| 3 | `sirv_sim_ram.v` writes byte lanes in a `for` loop; `ImportVerilog` leaves residual `llhd.prb` / `llhd.drv` ops that fail legalization in `arcilator` | Replace the two `sirv_sim_ram` modules (ITCM 8192×64, DTCM 16384×32) with `arc.memory` plus masked `arc.memory_write_port` / `arc.memory_read_port` ops | [`scripts/rewrite-ram.awk`](../scripts/rewrite-ram.awk) (`build/arcilator/ram.mlir`) |
| 4 | Packed-vector signals across module boundaries (`e203_lsu_ctrl`, `e203_biu`, `e203_exu`) cause `arcilator` `SplitLoops` to fail (`loop splitting did not eliminate all loops`) | Run `circt-opt --hw-flatten-modules --canonicalize --cse` before `arcilator` so per-bit dependencies are simplified before `ConvertToArcs` | [`Makefile`](../Makefile) (`build/arcilator/flat.mlir`) |
| 5 | `arcilator` rejects asynchronous resets on `seq.firreg` | Pass `--async-resets-as-sync` and hold `rst_n` low for 8 clock cycles in the harness | [`Makefile`](../Makefile) (`build/arcilator/model.ll`) |

## Build Pipeline

```text
ext/e203/rtl ──(patches/remove-dff-delays.patch)──► build/rtl
  ──(circt-verilog --top=e203_cpu_top -DFPGA_SOURCE=1)──► build/arcilator/frontend.mlir
  ──(scripts/rewrite-ram.awk)──► build/arcilator/ram.mlir
  ──(circt-opt --hw-flatten-modules --canonicalize --cse)──► build/arcilator/flat.mlir
  ──(arcilator --async-resets-as-sync --lookup-tables=false --no-runtime \
       --no-generate-driver --state-file=model.json)──► build/arcilator/model.ll + model.json
  ──(arcilator-header-cpp.py)──► build/arcilator/model.h
  ──(opt -O2 + llc -O2 + clang++)──► build/arcilator/sim
```

All three simulators (`arcilator`, `verilator`, `iverilog`) compile the exact same patched `build/rtl` tree with `-DDISABLE_SV_ASSERTION=1 -DFPGA_SOURCE=1` and top module `e203_cpu_top`.

## Details

### 1. SRAM Byte-Enable Lowering (`scripts/rewrite-ram.awk`)

`sirv_sim_ram` models ITCM (`DP=8192, DW=64, MW=8`) and DTCM (`DP=16384, DW=32, MW=4`) with byte-masked writes inside a Verilog `for` loop. `circt-verilog` lowers this pattern to `llhd.sig` + per-byte `llhd.drv` / `llhd.prb` instead of a single memory primitive, causing `arcilator` to fail with `failed to legalize operation 'llhd.prb'`.

[`scripts/rewrite-ram.awk`](../scripts/rewrite-ram.awk) rewrites the two specialized `sirv_sim_ram` modules in `frontend.mlir` into `arc.memory` memories with a registered read address (`addr_r`) and byte-expanded write masks (`arc.memory_write_port ... mask = %wmask`), matching the cycle behavior of `sirv_sim_ram.v`.

### 2. Early Module Flattening (`circt-opt --hw-flatten-modules --canonicalize --cse`)

When `e203_cpu_top` is passed to `arcilator` without prior flattening, module ports carry packed vectors whose individual bits depend on different logic stages across `e203_lsu_ctrl`, `e203_biu`, and `e203_exu`. `arcilator` runs `ConvertToArcs` before flattening, creating apparent cyclic dependencies between module ports that `SplitLoops` cannot break. Flattening and running `--canonicalize --cse` at the `hw`/`comb`/`seq` level resolves the bit-level dataflow before `ConvertToArcs`.

### 3. Performance options (not required for correctness)

These two options are not needed to make E203 simulate correctly. They only make it faster:

- `opt -O2` before `llc -O2`: `e203_cpu_top` has 108 top-level ports, so `SplitLoops` splits combinational cones after `InlineArcs` has already run. That leaves about 40 `define internal @e203_cpu_top_arc_*_split_*` functions in `model.ll`. `llc` alone does not inline them; `opt -O2` does. Result: 0.94 M → 1.11 M cycles/s (+17% on both Dhrystone and CoreMark). To reproduce the baseline, run `make -B bench SIM=arcilator SIZE=all OPT_FLAGS= TAG=arcilator-no-opt CIRCT_BIN=...`.
- `--lookup-tables=false` (`LUT=false`, this repo's default): 0.88 M → 1.11 M cycles/s (+25%) compared with arcilator's own default `LUT=true`.

Both were measured on Dhrystone and CoreMark; see [results.md](results.md).

## Standalone Reproducers (`repro/`)

Two minimal SystemVerilog testcases isolate the compiler gaps without needing the full E203 RTL:

```sh
make repro CIRCT_BIN=/path/to/circt/build/bin
```

- [`repro/packed-loop.sv`](../repro/packed-loop.sv): Demonstrates a false combinational loop across a child module driving one bit of a 2-bit packed vector while reading the other bit. Direct `arcilator` fails with `combinational loop`; `circt-opt --hw-flatten-modules --canonicalize --cse` followed by `arcilator` succeeds.
- [`repro/masked-ram.sv`](../repro/masked-ram.sv): Demonstrates a byte-masked write array that leaves an unlegalized `llhd.prb` in `arcilator`.
