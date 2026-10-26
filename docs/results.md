# Results and measurement method

Recorded dataset: [data/2026-10-24](../data/2026-10-24/). Date: 2026-10-24. Host: Apple M1 Pro, 10 cores, 32 GB, macOS 27.0.1, AC power. Native models/driver: Apple clang 21.0.0, `-O2`, single-threaded. One warm-up, five measured runs, no waveforms.

| Component | Recorded version |
| --- | --- |
| E203 | `9f3e34f337f5d0a1236a285871ffa2032491617a` |
| CIRCT | `c914150104ad15efa6b16ec4e5e6f86736fe15d8`; LLVM 24.0.0git; slang 11.0.0+0; assertions enabled |
| Verilator | 5.028 / 5.052 |
| Icarus | 12.0 / 13.0 |

## Identical small-input comparison

Each row runs the same binaries. Units: simulated cycles per host second.

| Configuration | ITCM/DTCM | External | External with stalls |
| --- | ---: | ---: | ---: |
| arcilator, LUT off | 2.67 M | 2.65 M | 2.64 M |
| arcilator, default LUT | 1.70 M | 1.71 M | 1.70 M |
| Verilator 5.028 | 2.57 M | 2.41 M | 2.42 M |
| Verilator 5.052 | 2.65 M | 2.63 M | 2.55 M |
| Icarus 12.0 | 4.91 k | 6.21 k | 7.20 k |
| Icarus 13.0 | 6.45 k | 7.90 k | 9.11 k |

Native throughput uses the driver/model loop timer, excluding process startup and program loading. Icarus uses process wall time. `make compare` labels those metrics explicitly. Background host load and short native runs limit how much to infer from small differences.

## Longer native runs

| Configuration | ITCM/DTCM | External | External with stalls |
| --- | ---: | ---: | ---: |
| arcilator, LUT off | 2.650 M | 2.643 M | 2.634 M |
| arcilator, default LUT | 1.707 M | 1.694 M | 1.693 M |
| Verilator 5.028 | 2.569 M | 2.406 M | 2.429 M |
| Verilator 5.052 | 2.642 M | 2.636 M | 2.595 M |

Arcilator with LUT off and Verilator 5.052 have similar throughput for these workloads. This is not a general simulator ranking. Recorded clean model builds took 1.62 s for arcilator LUT-off, 2.67/3.20 s for Verilator, and 0.20/0.22 s for Icarus. These are individual observations, excluding tool installation/download time.

## What is simulated

`e203_cpu_top` with 64 KiB ITCM, 64 KiB DTCM, NICE configuration, and a 64 KiB external ICB memory. Debug, interrupts, and unused peripherals are tied off. All tools use the shared wrapper, FPGA mode, and five removed DFF delays.

The testbench applies inputs while the clock is low, snapshots handshakes, then raises the clock. Reset lasts 16 cycles. One external command may be outstanding. Responses appear after the selected latency; command-ready is suppressed periodically for stall cases.

Smoke programs check arithmetic, loops, multiplication/division, mixed 16/32-bit fetch boundaries, signed/unsigned byte and halfword loads, and word accesses. Success requires a CPU write to `0x20002000` and the scratch signature `37 00 00 00 80 00 2e fb a5 00 00 00`. The negative program must write failure. Expected outcomes and cycles are listed in `programs/cases.tsv`.

Timing programs execute a checksum loop with add, multiply, unsigned division, and load/store operations. The small input uses 2,000 iterations; large uses 20,000. Cycle counts are 124,095 / 192,174 / 267,289 for small and 1,239,908 / 1,919,990 / 2,670,016 for large. Counts include startup/reset and are zero-based, not retired instructions.

## Repeat measurements

```sh
make bench SIM=arcilator CIRCT_BIN=/path/to/bin
make bench SIM=verilator
make bench SIM=iverilog
make compare
```

Commands, per-run output, and timers go to `build/results/<sim>/`; measured samples are in `measurements.tsv`. `scripts/run.sh` validates every result before recording a sample. `scripts/compare.awk` computes medians and only compares matching program names.

The archived data predates this source cleanup. Current assembly reproduces the original 13 binary hashes, and native smoke traces match the archive. Rerun timing measurements for the current drivers/toolchain; do not present archived timings as measurements of modified code.

The six primary JSON files are at the dataset root; secondary optimization/threading runs are under `experiments/`, captured output under `logs/`. Personal paths in JSON were normalized, numerical measurements retained. Logs may contain historical paths. New builds and downloaded tools/models are ignored by Git. The tests establish selected observed behavior, not full RTL or ISA equivalence.
