# Arcilator: what fails and where the workaround is applied

Tested CIRCT: `c914150104ad15efa6b16ec4e5e6f86736fe15d8`. E203: `9f3e34f337f5d0a1236a285871ffa2032491617a`. CIRCT source is unchanged.

| Failure / unsupported behavior | Actual application | Semantic effect |
| --- | --- | --- |
| Async `seq.firreg` reset rejected | `Makefile`, `model.ll` recipe: `--async-resets-as-sync` | Reset becomes synchronous; testbench holds it for 16 cycles |
| Five DFF `<= #1` assignments remain timed processes | `patches/remove-dff-delays.patch`, applied by the `prepare` recipe | Removes physical delay in the generated RTL copy |
| ASIC clock gate uses a latch | `FPGA_SOURCE=1` in the shared compile defines | Uses upstream clock pass-through; low-power behavior changes |
| Hierarchical packed-vector dependencies create a structural loop | `flat.mlir` recipe: `hw-flatten-modules → canonicalize → cse` | Exposes bit dependencies before conversion to Arc |
| SRAM byte writers leave residual `llhd.prb` | `scripts/rewrite-ram.awk`, called by the `ram.mlir` recipe | Replaces the two SRAM bodies with masked `arc.memory` |

The full build is visible with `make -n arcilator`:

```text
copy upstream RTL → apply DFF patch → circt-verilog
→ awk SRAM rewrite → circt-opt early flattening
→ arcilator → llc → C++ executable
```

All simulators use the same patched RTL and FPGA macro. Arcilator alone uses the reset approximation and SRAM IR replacement. The original submodule is not modified.

## SRAM replacement

ITCM is 8192 × 64 bits with eight byte enables. DTCM is 16384 × 32 bits with four. The awk helper checks these two specializations and emits:

```text
ren = cs & ~we
wen = cs & we
addr_r(next) = ren ? addr : addr_r
write on rising edge with each wem bit expanded to eight mask bits
read output = memory[addr_r]
```

The registered/held read address is retained. SRAM has no reset. Storage begins at zero, and program bytes are loaded before reset. `scripts/arcilator-header.sh` reads the generated JSON with jq; storage offsets are not hard-coded.

Verilator only needs public markers around the SRAM arrays for program loading. `scripts/verilator-header.sh` applies those comments and extracts their generated C++ member names. Hardware logic is unchanged; global `--public-flat-rw` is not used.

## Small reproducers

```sh
make repro CIRCT_BIN=/path/to/circt/build/bin
```

- `repro/packed-loop.sv`: `pair={a,y}` and `y=pair[1]=a`. Default compilation reports a loop; flattening and simplifying HW first succeeds.
- `repro/masked-ram.sv`: two disjoint byte writers to a four-word array reproduce the residual `llhd.prb` failure.

The small packed example demonstrates one dependency problem; it does not prove every edge in E203's larger diagnostic has the same cause. Original full-design diagnostics are retained under `data/bringup/`.

## LUT setting

`LUT=false` is the default for the arcilator recipe. In the recorded benchmark, disabling lookup-table generation improved throughput by about 55–56%; default-LUT throughput was about 36% lower. To inspect that ablation, rebuild with `make -B arcilator LUT=true` and rerun measurements. The earlier report attributed the overhead to repeated LUT initialization; regenerate and inspect the LLVM IR before making a root-cause claim.

This is a core-level bring-up/benchmark flow. Debug, interrupts, WFI, arbitrary reset sequences, four-state equivalence, and ISA compliance are not established by these tests.
