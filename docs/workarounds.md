# Arcilator Workarounds for E203 (`tb_top`)

`circt-verilog` + `arcilator` cannot compile unmodified E203 RTL out of the box. Compiling `tb_top` and its complete SoC (`e203_soc_top`) requires the workarounds below for the pinned CIRCT pipeline. All three simulators compile the same staged `build/rtl` and `build/tb/tb_top.v` tree.

Tested versions:
- E203 (`ext/e203`): `9f3e34f337f5d0a1236a285871ffa2032491617a`
- CIRCT: `c914150104ad15efa6b16ec4e5e6f86736fe15d8` (LLVM 24.0.0git, slang 11.0.0)

## Summary of Required Workarounds

| # | Failure without Workaround | Workaround Applied | Location |
| --- | --- | --- | --- |
| 1 | `sirv_gnrl_dffs.v` and `i2c_master_byte_ctrl.v` use `<= #1` non-blocking delays; `circt-verilog` lowers them to timed `llhd.process` + `llhd.wait` blocks rejected by `arcilator` | Strip `#1` intra-assignment delays in the staged RTL tree (`build/rtl`) | [`patches/e203.patch`](../patches/e203.patch) (`make prepare`) |
| 2 | `e203_clkgate.v` instantiates a latch-based ASIC clock gate when `FPGA_SOURCE` is unset | Pass `-DFPGA_SOURCE=1` so `e203_clkgate` uses the upstream FPGA clock pass-through | [`Makefile`](../Makefile) (`DEFINES`) |
| 3 | `sirv_sim_ram.v` writes byte lanes in a `for` loop; `ImportVerilog` leaves residual `llhd.prb` / `llhd.drv` ops that fail legalization in `arcilator` | Replace the two `sirv_sim_ram` modules (ITCM 8192×64, DTCM 16384×32) with `arc.memory` plus masked `arc.memory_write_port` / `arc.memory_read_port` ops | [`scripts/rewrite-ram.awk`](../scripts/rewrite-ram.awk) (`build/arcilator/ram.mlir`) |
| 4 | Packed-vector signals across module boundaries (`e203_lsu_ctrl`, `e203_biu`, `e203_exu`, `sirv_qspi_arbiter`) and register-file array probes cause `arcilator` legalization / `SplitLoops` failures | Run `circt-opt --hw-flatten-modules --llhd-combine-drives --llhd-sig2reg --hw-aggregate-to-comb --canonicalize --cse` before `arcilator`, and scalarize the 3-bit QSPI CS mux in `sirv_qspi_arbiter.v` | [`Makefile`](../Makefile) (`build/arcilator/flat.mlir`), [`patches/e203.patch`](../patches/e203.patch) |
| 5 | `arcilator` rejects asynchronous resets on `seq.firreg` | Pass `--async-resets-as-sync` and use the upstream startup reset (released at 120 ns) | [`Makefile`](../Makefile) (`build/arcilator/model.ll`) |
| 6 | On Linux (`glibc`), `circt-verilog` fails in `seq-infer-clock-ports` (`'hw.instance' op result type #... must be 'i1', but got '!seq.clock'`) due to a temporary `BitVector` use-after-free on modules with >64 ports | Materialize `clockOutputs.lookup(target)` and `clockInputs.lookup(target)` before iterating `.set_bits()` in `InferClockPorts.cpp` | [`patches/circt-infer-clock-ports.patch`](../patches/circt-infer-clock-ports.patch) |
| 7 | Peripheral reset `for` loops (GPIO, UART/SPI FIFOs) and an inferred UART TX payload latch remain as unlegalized `llhd.process` blocks | Replace reset loops with whole-vector/array resets and default `fifo_tx_data` to zero when `fifo_tx_valid` is low | [`patches/e203.patch`](../patches/e203.patch) |

## Build Pipeline

```text
ext/e203/{rtl,tb} ──(patches/e203.patch)──► build/{rtl,tb}
  ──(circt-verilog --top=tb_top -DE203_NATIVE -DFPGA_SOURCE=1)──► build/arcilator/frontend.mlir
  ──(scripts/rewrite-ram.awk)──► build/arcilator/ram.mlir
  ──(circt-opt --hw-flatten-modules --llhd-combine-drives --llhd-sig2reg
       --hw-aggregate-to-comb --canonicalize --cse)──► build/arcilator/flat.mlir
  ──(arcilator --async-resets-as-sync --lookup-tables=false --no-runtime
       --no-generate-driver --state-file=model.json)──► build/arcilator/model.ll + model.json
  ──(arcilator-header-cpp.py)──► build/arcilator/model.h
  ──(opt -O2 + llc -O2 + c++)──► build/arcilator/sim
```

All three simulators compile the same patched `build/rtl` and `build/tb/tb_top.v` tree with `-DDISABLE_SV_ASSERTION=1 -DFPGA_SOURCE=1`. Native builds externalize clock generation and image loading (`-DE203_NATIVE`); Icarus runs those blocks in Verilog.

## Details

### 1. SRAM Byte-Enable Lowering (`scripts/rewrite-ram.awk`)

`sirv_sim_ram` models ITCM (`DP=8192, DW=64, MW=8`) and DTCM (`DP=16384, DW=32, MW=4`) with byte-masked writes in a Verilog `for` loop. `circt-verilog` lowers this to `llhd.sig` + per-byte `llhd.drv` / `llhd.prb` instead of a memory primitive, failing in `arcilator` with `failed to legalize operation 'llhd.prb'`. [`scripts/rewrite-ram.awk`](../scripts/rewrite-ram.awk) rewrites both specialized modules into `arc.memory` ops with a registered read address (`addr_r`) and byte-expanded write masks (`arc.memory_write_port ... mask = %wmask`), preserving cycle behavior.

### 2. Flattening, Signal Promotion, and Aggregate Lowering (`circt-opt`)

Without prior flattening, module ports carry packed vectors whose bits depend on different logic stages across `e203_lsu_ctrl`, `e203_biu`, and `e203_exu`. Flattening and simplifying at the `hw`/`comb`/`seq` level resolves bit-level dataflow first. In the complete SoC, `--llhd-combine-drives --llhd-sig2reg` promotes the register-file array (`rf_r`) probed by `tb_top` for `x3`, and `--hw-aggregate-to-comb` lowers 1-element AON queue arrays (`!hw.array<1xiN>`) so `arcilator`'s `InferStateProperties` pass can legalize all state registers cleanly.

### 3. `InferClockPorts` Temporary `BitVector` Lifetime (`patches/circt-infer-clock-ports.patch`)

In CIRCT `c91415010`, `InferClockPortsPass::rewriteModule` iterates over `clockOutputs.lookup(target).set_bits()` and `clockInputs.lookup(target).set_bits()`. Because `DenseMap::lookup` returns a temporary `BitVector` by value and `.set_bits()` holds a pointer to it, the temporary is destroyed before the C++17 range-`for` body runs. When a module has >64 ports (`e203_cpu` has 65 inputs and 90 outputs), `BitVector` heap-allocates and `glibc` `free()` overwrites the freed chunk with `tcache` pointers, corrupting random ports to `!seq.clock`.

### 4. Performance Options (Not Required for Correctness)

The speedups below are retained from the earlier core-only measurements; remeasure them for the complete SoC.

- `TOP=e203_sim` (previous wrapper configuration): Exposing all 108 `e203_cpu_top` ports prevents constant propagation across unused debug/DMA/ICB inputs and causes `SplitLoops` to emit 84 functions (`303 KB` IR). Tying off the 91 unused pins in `e203_sim` lets `circt-opt --canonicalize` fold dead cones, reducing `model.ll` to 17 functions (`205 KB`) and raising CoreMark throughput from 1.10 M to **2.80 M cycles/s** (+155%) on M1 Pro and from 0.99 M to **2.38 M cycles/s** (+139%) on 7800X3D.
- `opt -O2` before `llc -O2`: Inlines the `@*_arc_*_split_*` functions emitted by `SplitLoops` after `InlineArcs` (`llc` alone leaves them outlined). Gains +17–30% on `e203_cpu_top` and +7–8% on `e203_sim`.
- `--lookup-tables=false` (`LUT=false`, project default): `LUT=true` allocates and re-initializes a ~5.4 KB stack LUT on every `eval()` call. Disabling it gains +23–24% on `e203_cpu_top` and +51–65% on `e203_sim`.

### 5. SoC Peripheral and Testbench Adaptations (`patches/e203.patch`)

Upstream `tb_top` instantiates `e203_soc_top`, adding UART, SPI, GPIO, I2C, and AON. In addition to stripping `#1` in `sirv_gnrl_dffs.v`, [`patches/e203.patch`](../patches/e203.patch) includes:

| Component | Adaptation | Reason |
| --- | --- | --- |
| `e203_defines.v` | Add `` `timescale 1ns/10ps `` | Provide a consistent default timescale for event-driven builds. |
| `apb_gpio.v` | Replace the 32-entry pad reset loop with `{32{6'b000010}}` | Expose the reset value directly for register lowering. |
| `io_generic_fifo.v`, `spi_master_fifo.v` | Pack the buffer array and reset it with `'0` | Avoid residual array-reset processes while keeping indexed accesses. |
| `i2c_master_byte_ctrl.v` | Remove 60 `<= #1` intra-assignment delays | Eliminate timed processes, matching `sirv_gnrl_dffs.v`. |
| `apb_uart.v` | Default `fifo_tx_data` to `8'b0` when `fifo_tx_valid` is low | Eliminate an inferred payload latch. |
| `sirv_qspi_arbiter.v` | Unpack 3-bit `T_406` (`{cs_set, cs_clear, cs_hold}`) into scalar muxes | Prevent a false combinational loop between `cs_set` and `cs_clear` in `arcilator`. |
| `tb/tb_top.v` | Guard clock/reset/image blocks with `E203_NATIVE` and add UART benchmark exit detection | Allow native C++ drivers and Icarus Verilog to share the exact upstream `tb_top` module. |

## Standalone Reproducers (`repro/`)

```sh
make repro CIRCT_BIN=/path/to/circt/build/bin
```

- [`repro/packed-loop.sv`](../repro/packed-loop.sv): False combinational loop across a child module driving one bit of a 2-bit packed vector while reading the other; resolved by `--hw-flatten-modules --canonicalize --cse`.
- [`repro/masked-ram.sv`](../repro/masked-ram.sv): Byte-masked array writes leaving an unlegalized `llhd.prb` in `arcilator`.
