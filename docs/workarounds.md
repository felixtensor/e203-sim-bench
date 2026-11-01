# Arcilator Workarounds for E203 (`e203_cpu_top`)

`circt-verilog` + `arcilator` cannot compile unmodified E203 RTL out of the box. Five RTL/pipeline workarounds in [`Makefile`](../Makefile) (plus one CIRCT C++ fix on Linux) are required to bring up `e203_cpu_top` and achieve cycle-exact agreement with Verilator and Icarus Verilog on the official images.

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
| 6 | On Linux (`glibc`), `circt-verilog` fails in `seq-infer-clock-ports` (`'hw.instance' op result type #... must be 'i1', but got '!seq.clock'`) due to a temporary `BitVector` use-after-free on modules with >64 ports | Materialize `clockOutputs.lookup(target)` and `clockInputs.lookup(target)` before iterating `.set_bits()` in `InferClockPorts.cpp` | [`patches/circt-infer-clock-ports.patch`](../patches/circt-infer-clock-ports.patch) |

## Build Pipeline

```text
ext/e203/rtl ──(patches/remove-dff-delays.patch)──► build/rtl
  ──(circt-verilog --top=$(TOP) -DFPGA_SOURCE=1)──► build/arcilator/frontend.mlir
  ──(scripts/rewrite-ram.awk)──► build/arcilator/ram.mlir
  ──(circt-opt --hw-flatten-modules --canonicalize --cse)──► build/arcilator/flat.mlir
  ──(arcilator --async-resets-as-sync --lookup-tables=false --no-runtime \
       --no-generate-driver --state-file=model.json)──► build/arcilator/model.ll + model.json
  ──(arcilator-header-cpp.py)──► build/arcilator/model.h
  ──(opt -O2 + llc -O2 + c++)──► build/arcilator/sim
```

All three simulators compile the same patched `build/rtl` tree with `-DDISABLE_SV_ASSERTION=1 -DFPGA_SOURCE=1` and top `e203_cpu_top` (or optional wrapper `TOP=e203_sim` for native models).

## Details

### 1. SRAM Byte-Enable Lowering (`scripts/rewrite-ram.awk`)

`sirv_sim_ram` models ITCM (`DP=8192, DW=64, MW=8`) and DTCM (`DP=16384, DW=32, MW=4`) with byte-masked writes in a Verilog `for` loop. `circt-verilog` lowers this to `llhd.sig` + per-byte `llhd.drv` / `llhd.prb` instead of a memory primitive, failing in `arcilator` with `failed to legalize operation 'llhd.prb'`. [`scripts/rewrite-ram.awk`](../scripts/rewrite-ram.awk) rewrites both specialized modules into `arc.memory` ops with a registered read address (`addr_r`) and byte-expanded write masks (`arc.memory_write_port ... mask = %wmask`), preserving cycle behavior.

### 2. Early Module Flattening (`circt-opt --hw-flatten-modules --canonicalize --cse`)

Without prior flattening, module ports carry packed vectors whose bits depend on different logic stages across `e203_lsu_ctrl`, `e203_biu`, and `e203_exu`. Because `arcilator` runs `ConvertToArcs` before flattening, port-level dependencies form apparent cycles that `SplitLoops` cannot break. Flattening and simplifying at the `hw`/`comb`/`seq` level resolves bit-level dataflow first.

### 3. `InferClockPorts` Temporary `BitVector` Lifetime (`patches/circt-infer-clock-ports.patch`)

In CIRCT `c91415010`, `InferClockPortsPass::rewriteModule` iterates over `clockOutputs.lookup(target).set_bits()` and `clockInputs.lookup(target).set_bits()`. Because `DenseMap::lookup` returns a temporary `BitVector` by value and `.set_bits()` holds a pointer to it, the temporary is destroyed before the C++17 range-`for` body runs. When a module has >64 ports (`e203_cpu` has 65 inputs and 90 outputs), `BitVector` heap-allocates and `glibc` `free()` overwrites the freed chunk with `tcache` pointers, corrupting random ports to `!seq.clock`.

### 4. Performance Options (Not Required for Correctness)

- `TOP=e203_sim` ([`sim/e203_sim.v`](../sim/e203_sim.v)): Exposing all 108 `e203_cpu_top` ports prevents constant propagation across unused debug/DMA/ICB inputs and causes `SplitLoops` to emit 84 functions (`303 KB` IR). Tying off the 91 unused pins in `e203_sim` lets `circt-opt --canonicalize` fold dead cones, reducing `model.ll` to 17 functions (`205 KB`) and raising CoreMark throughput from 1.10 M to **2.80 M cycles/s** (+155%) on M1 Pro and from 0.99 M to **2.38 M cycles/s** (+139%) on 7800X3D.
- `opt -O2` before `llc -O2`: Inlines the `@*_arc_*_split_*` functions emitted by `SplitLoops` after `InlineArcs` (`llc` alone leaves them outlined). Gains +17–30% on `e203_cpu_top` and +7–8% on `e203_sim`.
- `--lookup-tables=false` (`LUT=false`, project default): `LUT=true` allocates and re-initializes a ~5.4 KB stack LUT on every `eval()` call. Disabling it gains +23–24% on `e203_cpu_top` and +51–65% on `e203_sim`.

## Standalone Reproducers (`repro/`)

```sh
make repro CIRCT_BIN=/path/to/circt/build/bin
```

- [`repro/packed-loop.sv`](../repro/packed-loop.sv): False combinational loop across a child module driving one bit of a 2-bit packed vector while reading the other; resolved by `--hw-flatten-modules --canonicalize --cse`.
- [`repro/masked-ram.sv`](../repro/masked-ram.sv): Byte-masked array writes leaving an unlegalized `llhd.prb` in `arcilator`.
