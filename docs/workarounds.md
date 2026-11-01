# Arcilator Workarounds for E203 (`e203_cpu_top`)

`circt-verilog` + `arcilator` cannot compile unmodified E203 RTL out of the box. Five workarounds in [`Makefile`](../Makefile) are required to bring up `e203_cpu_top` and achieve cycle-exact agreement with Verilator and Icarus Verilog on the official images.

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
  ──(circt-verilog --top=$(TOP) -DFPGA_SOURCE=1)──► build/arcilator/frontend.mlir
  ──(scripts/rewrite-ram.awk)──► build/arcilator/ram.mlir
  ──(circt-opt --hw-flatten-modules --canonicalize --cse)──► build/arcilator/flat.mlir
  ──(arcilator --async-resets-as-sync --lookup-tables=false --no-runtime \
       --no-generate-driver --state-file=model.json)──► build/arcilator/model.ll + model.json
  ──(arcilator-header-cpp.py)──► build/arcilator/model.h
  ──(opt -O2 + llc -O2 + clang++)──► build/arcilator/sim
```

All three simulators compile the same patched `build/rtl` tree with `-DDISABLE_SV_ASSERTION=1 -DFPGA_SOURCE=1` and top `e203_cpu_top` (or optional wrapper `TOP=e203_sim` for native models).

## Details

### 1. SRAM Byte-Enable Lowering (`scripts/rewrite-ram.awk`)

`sirv_sim_ram` models ITCM (`DP=8192, DW=64, MW=8`) and DTCM (`DP=16384, DW=32, MW=4`) with byte-masked writes in a Verilog `for` loop. `circt-verilog` lowers this to `llhd.sig` + per-byte `llhd.drv` / `llhd.prb` instead of a memory primitive, failing in `arcilator` with `failed to legalize operation 'llhd.prb'`. [`scripts/rewrite-ram.awk`](../scripts/rewrite-ram.awk) rewrites both specialized modules into `arc.memory` ops with a registered read address (`addr_r`) and byte-expanded write masks (`arc.memory_write_port ... mask = %wmask`), preserving cycle behavior.

### 2. Early Module Flattening (`circt-opt --hw-flatten-modules --canonicalize --cse`)

Without prior flattening, module ports carry packed vectors whose bits depend on different logic stages across `e203_lsu_ctrl`, `e203_biu`, and `e203_exu`. Because `arcilator` runs `ConvertToArcs` before flattening, port-level dependencies form apparent cycles that `SplitLoops` cannot break. Flattening and simplifying at the `hw`/`comb`/`seq` level resolves bit-level dataflow first.

### 3. Performance Options (Not Required for Correctness)

- `TOP=e203_sim` ([`sim/e203_sim.v`](../sim/e203_sim.v)): Exposing all 108 `e203_cpu_top` ports prevents constant propagation across unused debug/DMA/ICB inputs and causes `SplitLoops` to emit 84 functions (`303 KB` IR). Tying off the 91 unused pins in `e203_sim` lets `circt-opt --canonicalize` fold dead cones, reducing `model.ll` to 17 functions (`205 KB`) and raising CoreMark throughput from 1.10 M to **2.80 M cycles/s** (+155%).
- `opt -O2` before `llc -O2`: Inlines the `@*_arc_*_split_*` functions emitted by `SplitLoops` after `InlineArcs` (`llc` alone leaves them outlined). Gains +17% on `e203_cpu_top` (0.94 M → 1.10 M) and +7% on `e203_sim` (2.62 M → 2.80 M).
- `--lookup-tables=false` (`LUT=false`, project default): `LUT=true` allocates and re-initializes a ~5.4 KB stack LUT on every `eval()` call. Disabling it gains +24% on `e203_cpu_top` (0.89 M → 1.10 M) and +65% on `e203_sim` (1.70 M → 2.80 M).

## Standalone Reproducers (`repro/`)

```sh
make repro CIRCT_BIN=/path/to/circt/build/bin
```

- [`repro/packed-loop.sv`](../repro/packed-loop.sv): False combinational loop across a child module driving one bit of a 2-bit packed vector while reading the other; resolved by `--hw-flatten-modules --canonicalize --cse`.
- [`repro/masked-ram.sv`](../repro/masked-ram.sv): Byte-masked array writes leaving an unlegalized `llhd.prb` in `arcilator`.
