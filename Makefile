# Read the recipes below, or use `make -n arcilator` to inspect the full flow.
.DEFAULT_GOAL := help
.DELETE_ON_ERROR:

SIM ?= arcilator
TEST ?= smoke-itcm-dtcm
SIZE ?= small
REPEATS ?= 5
WAVE ?= 0
JOBS ?= 4
LLVM_MC ?= llvm-mc
LLVM_OBJCOPY ?= llvm-objcopy
CIRCT_BIN ?=
CIRCT_VERILOG ?= $(if $(CIRCT_BIN),$(CIRCT_BIN)/)circt-verilog
CIRCT_OPT ?= $(if $(CIRCT_BIN),$(CIRCT_BIN)/)circt-opt
ARCILATOR ?= $(if $(CIRCT_BIN),$(CIRCT_BIN)/)arcilator
LLC ?= $(if $(CIRCT_BIN),$(CIRCT_BIN)/)llc
VERILATOR ?= verilator
IVERILOG ?= iverilog
VVP ?= vvp
CXXFLAGS ?= -O2 -std=c++17
VERILATOR_FLAGS ?=
LUT ?= false

ROOT := $(CURDIR)
PREFIX_MAP = -ffile-prefix-map=$(HOME)=HOME -ffile-prefix-map=$(ROOT)=.
HOST_TARGET = $(if $(filter Darwin,$(shell uname -s)),-mtriple=$(shell uname -m)-apple-macos,)
# Recursive variables: these expand after `prepare` has copied the RTL.
CORE = $(filter-out build/rtl/e203/core/config.v build/rtl/e203/core/e203_defines.v,$(sort $(wildcard build/rtl/e203/core/*.v)))
RTL = $(sort $(wildcard build/rtl/e203/general/*.v)) $(CORE) build/rtl/e203/subsys/e203_subsys_nice_core.v rtl/e203_sim.v
RAM = build/rtl/e203/general/sirv_sim_ram.v
DEFINES = -DDISABLE_SV_ASSERTION=1 -DFPGA_SOURCE=1
INCLUDE = -Ibuild/rtl/e203/core
OUT_arcilator = build/arcilator/sim
OUT_verilator = build/verilator/obj/sim
OUT_iverilog = build/iverilog/sim.vvp
EXE = $(OUT_$(SIM))

ifeq ($(filter $(SIM),arcilator verilator iverilog),)
$(error SIM must be arcilator, verilator, or iverilog)
endif

.PHONY: help setup prepare programs compile arcilator verilator iverilog run smoke bench compare check repro clean
help:
	@echo 'make setup                         initialize E203 and generate inputs'
	@echo 'make arcilator CIRCT_BIN=/path/bin  build the arcilator model'
	@echo 'make verilator VERILATOR=/path/...  build the Verilator model'
	@echo 'make iverilog IVERILOG=/path/...    compile the Icarus testbench'
	@echo 'make run SIM=... TEST=... WAVE=1    run one test, optionally write VCD'
	@echo 'make smoke SIM=...                 validate all seven smoke tests'
	@echo 'make bench SIM=... SIZE=small       smoke gate, warm-up, five timed runs'
	@echo 'make compare                       compare measurements in build/results'
	@echo 'make check / make repro             check program hashes / small CIRCT reproducers'

setup: prepare programs
ext/e203/.git:
	git submodule update --init --depth=1 ext/e203

prepare: build/rtl/.stamp
build/rtl/.stamp: ext/e203/.git patches/remove-dff-delays.patch
	mkdir -p build
	rm -rf build/rtl
	cp -R ext/e203/rtl build/rtl
	patch -p1 -d build/rtl < patches/remove-dff-delays.patch
	touch $@

programs: build/programs/.stamp
build/programs/.stamp: programs/smoke.s programs/benchmark.s programs/cases.tsv programs/SHA256SUMS scripts/build-programs.sh
	mkdir -p build/programs
	scripts/build-programs.sh "$(LLVM_MC)" "$(LLVM_OBJCOPY)"
	touch $@

# arcilator: Verilog -> LLHD/HW -> explicit SRAMs -> flattened HW -> LLVM.
arcilator: build/arcilator/sim
build/arcilator/frontend.mlir: build/rtl/.stamp rtl/e203_sim.v
	mkdir -p build/arcilator
	"$(CIRCT_VERILOG)" --single-unit --timescale=1ns/10ps \
	  --Xslang=--translate-off-format --Xslang=synopsys,translate_off,translate_on \
	  --Xslang=-Wno-unconnected-output-port $(DEFINES) $(INCLUDE) \
	  --top=e203_sim $(RTL) -o $@
	"$(ARCILATOR)" --version > build/arcilator/version.txt
build/arcilator/ram.mlir: build/arcilator/frontend.mlir scripts/rewrite-ram.awk
	awk -f scripts/rewrite-ram.awk $< > $@
build/arcilator/flat.mlir: build/arcilator/ram.mlir
	"$(CIRCT_OPT)" $< --hw-flatten-modules --canonicalize --cse -o $@
build/arcilator/model.ll: build/arcilator/flat.mlir
	"$(ARCILATOR)" $< --async-resets-as-sync --no-runtime --no-generate-driver \
	  --observe-memories --lookup-tables=$(LUT) --state-file=build/arcilator/model.json -o $@
build/arcilator/model.h: build/arcilator/model.ll scripts/arcilator-header.sh
	scripts/arcilator-header.sh build/arcilator/model.json $@
build/arcilator/model.o: build/arcilator/model.ll
	"$(LLC)" -O2 -filetype=obj $(HOST_TARGET) $< -o $@
build/arcilator/sim: build/arcilator/model.o build/arcilator/model.h sim/main.cpp sim/arcilator/model_adapter.h
	$(CXX) $(CXXFLAGS) $(PREFIX_MAP) -Ibuild/arcilator -Isim/arcilator \
	  sim/main.cpp build/arcilator/model.o -o $@

# Verilator: expose only SRAM arrays for program loading; ordinary C++ model.
verilator: build/verilator/obj/sim
build/verilator/sirv_sim_ram.v: build/rtl/.stamp scripts/verilator-header.sh
	mkdir -p build/verilator
	scripts/verilator-header.sh --annotate $(RAM) $@
build/verilator/obj/Ve203_sim.mk: build/verilator/sirv_sim_ram.v rtl/e203_sim.v sim/main.cpp sim/verilator/model_adapter.h
	"$(VERILATOR)" --cc --exe --top-module e203_sim -Wno-fatal --timescale 1ns/10ps \
	  $(DEFINES) $(INCLUDE) $(VERILATOR_FLAGS) -Mdir $(ROOT)/build/verilator/obj -o sim \
	  $(filter-out $(RAM),$(RTL)) build/verilator/sirv_sim_ram.v $(ROOT)/sim/main.cpp
	scripts/verilator-header.sh build/verilator/obj/Ve203_sim___024root.h build/verilator/obj/e203_mem_access.h
	"$(VERILATOR)" --version > build/verilator/version.txt
build/verilator/obj/sim: build/verilator/obj/Ve203_sim.mk
	$(MAKE) -C build/verilator/obj -f Ve203_sim.mk -j$(JOBS) \
	  CXX="$(CXX)" LINK="$(CXX)" OPT_FAST=-O2 OPT_SLOW=-O2 OPT_GLOBAL=-O2 \
	  USER_CPPFLAGS="$(CXXFLAGS) -I$(ROOT)/build/verilator/obj -I$(ROOT)/sim/verilator $(PREFIX_MAP)"

# Icarus: elaborate the same RTL with the Verilog clock/ICB testbench.
iverilog: build/iverilog/sim.vvp
build/iverilog/sim.vvp: build/rtl/.stamp rtl/e203_sim.v sim/iverilog/tb.v
	mkdir -p build/iverilog
	"$(IVERILOG)" -g2012 $(DEFINES) $(INCLUDE) -s tb_e203_bench -o $@ \
	  sim/iverilog/tb.v $(RTL)
	"$(IVERILOG)" -V > build/iverilog/version.txt 2>&1

compile: $(EXE)
run: compile programs
	SIM_EXE=$(EXE) VVP="$(VVP)" WAVE=$(WAVE) scripts/run.sh $(SIM) run $(TEST)
smoke: compile programs
	SIM_EXE=$(EXE) VVP="$(VVP)" WAVE=$(WAVE) scripts/run.sh $(SIM) smoke
bench: compile programs
	SIM_EXE=$(EXE) VVP="$(VVP)" WAVE=0 scripts/run.sh $(SIM) smoke
	SIM_EXE=$(EXE) VVP="$(VVP)" SIZE=$(SIZE) REPEATS=$(REPEATS) WAVE=0 scripts/run.sh $(SIM) bench
compare:
	@awk -f scripts/compare.awk build/results/*/measurements.tsv
check: programs
	cd build/programs && shasum -a 256 -c ../../programs/SHA256SUMS

# Two standalone compiler gaps, followed by the early-flatten workaround.
repro:
	mkdir -p build/repro
	"$(CIRCT_VERILOG)" repro/packed-loop.sv --top=packed_loop -o build/repro/packed.mlir
	! "$(ARCILATOR)" build/repro/packed.mlir --no-runtime --no-generate-driver -o build/repro/packed.ll 2>build/repro/packed.log
	grep 'combinational loop' build/repro/packed.log
	"$(CIRCT_OPT)" build/repro/packed.mlir --hw-flatten-modules --canonicalize --cse -o build/repro/flat.mlir
	"$(ARCILATOR)" build/repro/flat.mlir --no-runtime --no-generate-driver -o build/repro/flat.ll
	"$(CIRCT_VERILOG)" repro/masked-ram.sv --top=masked_ram -o build/repro/ram.mlir
	! "$(ARCILATOR)" build/repro/ram.mlir --no-runtime --no-generate-driver -o build/repro/ram.ll 2>build/repro/ram.log
	grep "failed to legalize operation 'llhd.prb'" build/repro/ram.log

clean:
	rm -rf build

# Optional release assets; all output stays under ignored build/.
.PHONY: package-models download-models quick
package-models: arcilator verilator programs
	mkdir -p build/reference
	cp build/arcilator/sim build/reference/sim-arcilator
	cp build/verilator/obj/sim build/reference/sim-verilator
	cp build/programs/bench-itcm-dtcm.bin build/reference/
	! strings build/reference/sim-arcilator build/reference/sim-verilator | grep -E '/(Users|home)/[^/]+/'
	cd build/reference && shasum -a 256 sim-arcilator sim-verilator bench-itcm-dtcm.bin > SHA256SUMS
	tar -czf build/e203-models-macos-arm64.tar.gz -C build/reference sim-arcilator sim-verilator bench-itcm-dtcm.bin SHA256SUMS
	shasum -a 256 build/e203-models-macos-arm64.tar.gz
download-models:
	scripts/download-models.sh "$(MODEL_URL)" "$(MODEL_SHA256)"
quick:
	build/reference/sim-arcilator build/reference/bench-itcm-dtcm.bin 0x80000000 0x90000000 1 0 20000000
	build/reference/sim-verilator build/reference/bench-itcm-dtcm.bin 0x80000000 0x90000000 1 0 20000000
