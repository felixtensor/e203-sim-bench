.DEFAULT_GOAL := help
.DELETE_ON_ERROR:

SIM ?= arcilator
TAG ?=
TEST ?= rv32ui-p-add
SMOKE ?= default
SIZE ?= small
REPEATS ?= 5
VCD_REFERENCE ?=
WAVE ?= $(if $(strip $(VCD_REFERENCE)),1,0)
JOBS ?= 4

VENV ?= .tools/venv
VENV_PYTHON = $(VENV)/bin/python3
PYTHON_BOOTSTRAP ?= python3
JINJA2_VERSION ?= 3.1.6
# Explicit PYTHON wins; otherwise use the setup venv when present.
PYTHON_SET_BY_USER := $(if $(strip $(PYTHON)),1,0)
PYTHON ?= $(if $(wildcard $(VENV_PYTHON)),$(VENV_PYTHON),$(PYTHON_BOOTSTRAP))
CIRCT_BIN ?=
CIRCT_VERILOG ?= $(if $(CIRCT_BIN),$(CIRCT_BIN)/)circt-verilog
CIRCT_OPT ?= $(if $(CIRCT_BIN),$(CIRCT_BIN)/)circt-opt
ARCILATOR ?= $(if $(CIRCT_BIN),$(CIRCT_BIN)/)arcilator
ARCILATOR_DIR ?= $(if $(CIRCT_BIN),$(CIRCT_BIN),$(patsubst %/,%,$(dir $(shell command -v "$(ARCILATOR)" 2>/dev/null))))
ARCILATOR_HEADER_CPP ?= $(if $(ARCILATOR_DIR),$(ARCILATOR_DIR)/)arcilator-header-cpp.py
ARCILATOR_RUNTIME_H ?= $(if $(ARCILATOR_DIR),$(ARCILATOR_DIR)/)arcilator-runtime.h
OPT ?= $(if $(CIRCT_BIN),$(CIRCT_BIN)/)opt
LLC ?= $(if $(CIRCT_BIN),$(CIRCT_BIN)/)llc
VERILATOR ?= verilator
IVERILOG ?= iverilog
VVP ?= vvp
CXX ?= c++
AR ?= ar
CXXFLAGS ?= -O2 -std=c++17
VERILATOR_FLAGS ?=
OPT_FLAGS ?= -O2
LUT ?= false

ROOT := $(CURDIR)
HOST_TARGET = $(if $(filter Darwin,$(shell uname -s)),-mtriple=$(shell uname -m)-apple-macos,)

RTL = $(sort $(wildcard build/rtl/e203/*/*.v build/rtl/e203/*/*/*.v)) build/tb/tb_top.v
DEFINES = -DDISABLE_SV_ASSERTION=1 -DFPGA_SOURCE=1
INCLUDE = -Ibuild/rtl/e203/core -Ibuild/rtl/e203/perips -Ibuild/rtl/e203/perips/apb_i2c

OUT_arcilator = build/arcilator/sim
OUT_verilator = build/verilator/obj/sim
OUT_iverilog = build/iverilog/sim.vvp
EXE = $(OUT_$(SIM))

ifeq ($(filter $(SIM),arcilator verilator iverilog all),)
$(error SIM must be arcilator, verilator, iverilog, or all)
endif

ifeq ($(SIM),all)
ifneq ($(strip $(TAG)),)
$(error TAG is not supported with SIM=all; run one SIM at a time)
endif
endif

CHECK_ENV = CIRCT_BIN="$(CIRCT_BIN)" CIRCT_VERILOG="$(CIRCT_VERILOG)" CIRCT_OPT="$(CIRCT_OPT)" \
  ARCILATOR="$(ARCILATOR)" ARCILATOR_HEADER_CPP="$(ARCILATOR_HEADER_CPP)" \
  ARCILATOR_RUNTIME_H="$(ARCILATOR_RUNTIME_H)" \
  OPT="$(OPT)" LLC="$(LLC)" VERILATOR="$(VERILATOR)" \
  IVERILOG="$(IVERILOG)" VVP="$(VVP)" CXX="$(CXX)" AR="$(AR)" \
  PYTHON="$(PYTHON)" VENV="$(VENV)"

.PHONY: help setup prepare python-env doctor check-env check-arcilator check-verilator check-iverilog \
  compile arcilator verilator iverilog run smoke bench compare compare-vcd repro clean
help:
	@echo 'make setup                              prepare RTL and .tools/venv'
	@echo 'make doctor [SIM=<sim>|all]             verify toolchain'
	@echo 'make arcilator|verilator|iverilog       build one simulator (tool paths: see README)'
	@echo 'make run   SIM=<sim> TEST=rv32ui-p-add  run one test: ISA name, dhrystone, coremark, or .verilog path'
	@echo 'make smoke SIM=<sim>|all [SMOKE=all]    official RV32IMAC ISA tests (8 by default, 67 with SMOKE=all)'
	@echo 'make bench SIM=<sim>|all SIZE=small|large|all [TAG=name]  Dhrystone / CoreMark timing'
	@echo 'make compare                            table of all build/results/<TAG>/measurements.tsv'
	@echo 'make compare-vcd REFERENCE=... CANDIDATE=...  compare VCD files or result directories'
	@echo 'make repro                              standalone CIRCT/arcilator reproducers'

setup: prepare python-env
	@echo 'Ready. Next: make doctor SIM=all'

python-env:
	@VENV="$(VENV)" PYTHON="$(PYTHON)" PYTHON_SET_BY_USER="$(PYTHON_SET_BY_USER)" \
	  PYTHON_BOOTSTRAP="$(PYTHON_BOOTSTRAP)" JINJA2_VERSION="$(JINJA2_VERSION)" \
	  scripts/setup-python.sh

check-env:
	@$(CHECK_ENV) scripts/check-env.sh $(SIM)

check-arcilator:
	@$(CHECK_ENV) scripts/check-env.sh arcilator

check-verilator:
	@$(CHECK_ENV) scripts/check-env.sh verilator

check-iverilog:
	@$(CHECK_ENV) scripts/check-env.sh iverilog

doctor:
	@$(CHECK_ENV) scripts/check-env.sh --verbose $(SIM)

prepare: build/rtl/.stamp
build/rtl/.stamp: patches/e203.patch
	@[ -d ext/e203/rtl ] || git submodule update --init --depth=1 ext/e203
	mkdir -p build
	rm -rf build/rtl build/tb
	cp -R ext/e203/rtl build/rtl
	cp -R ext/e203/tb build/tb
	patch -p1 -d build < patches/e203.patch
	touch $@

# arcilator: Verilog -> Moore/Core -> explicit SRAMs -> flattened HW -> LLVM -> C++ header.
arcilator: check-arcilator build/arcilator/sim
build/arcilator/frontend.mlir: build/rtl/.stamp
	mkdir -p build/arcilator
	"$(CIRCT_VERILOG)" --single-unit --timescale=1ns/10ps \
	  --Xslang=--translate-off-format --Xslang=synopsys,translate_off,translate_on \
	  --Xslang=-Wno-unconnected-output-port $(DEFINES) -DE203_NATIVE $(INCLUDE) \
	  --top=tb_top $(RTL) -o $@
	"$(ARCILATOR)" --version > build/arcilator/version.txt
build/arcilator/ram.mlir: build/arcilator/frontend.mlir scripts/rewrite-ram.awk
	awk -f scripts/rewrite-ram.awk $< > $@
build/arcilator/flat.mlir: build/arcilator/ram.mlir
	"$(CIRCT_OPT)" $< --hw-flatten-modules --llhd-combine-drives --llhd-sig2reg \
	  --hw-aggregate-to-comb --canonicalize --cse -o $@
build/arcilator/model.ll: build/arcilator/flat.mlir
	"$(ARCILATOR)" $< --async-resets-as-sync --no-runtime --no-generate-driver \
	  --lookup-tables=$(LUT) --state-file=build/arcilator/model.json -o $@
build/arcilator/model.h: build/arcilator/model.ll
	"$(PYTHON)" "$(ARCILATOR_HEADER_CPP)" build/arcilator/model.json > $@
build/arcilator/model.o: build/arcilator/model.ll
	@set -e; if [ -n "$(strip $(OPT_FLAGS))" ]; then \
	  "$(OPT)" $(OPT_FLAGS) $< -o build/arcilator/model.opt.bc; \
	  opt_ir=build/arcilator/model.opt.bc; \
	else \
	  opt_ir="$<"; \
	fi; \
	"$(LLC)" -O2 -filetype=obj $(HOST_TARGET) "$$opt_ir" -o $@
build/arcilator/sim: build/arcilator/model.o build/arcilator/model.h sim/main.cpp sim/vcd.h
	$(CXX) $(CXXFLAGS) -DUSE_ARCILATOR -Ibuild/arcilator -I"$(ARCILATOR_DIR)" \
	  sim/main.cpp build/arcilator/model.o -o $@

# Verilator: compile tb_top directly against the unified C++ harness.
verilator: check-verilator build/verilator/obj/sim
build/verilator/obj/Vtb_top.mk: build/rtl/.stamp sim/main.cpp sim/vcd.h
	rm -rf build/verilator/obj
	mkdir -p build/verilator
	"$(VERILATOR)" --cc --exe --top-module tb_top -Wno-fatal --timescale 1ns/10ps \
	  $(DEFINES) -DE203_NATIVE $(INCLUDE) $(VERILATOR_FLAGS) \
	  -Mdir $(ROOT)/build/verilator/obj -o sim $(RTL) $(ROOT)/sim/main.cpp
	"$(VERILATOR)" --version > build/verilator/version.txt
build/verilator/obj/sim: build/verilator/obj/Vtb_top.mk sim/main.cpp sim/vcd.h
	$(MAKE) -C build/verilator/obj -f Vtb_top.mk -j$(JOBS) \
	  CXX="$(CXX)" LINK="$(CXX)" AR="$(AR)" OPT_FAST=-O2 OPT_SLOW=-O2 OPT_GLOBAL=-O2 \
	  USER_CPPFLAGS="$(CXXFLAGS) -DUSE_VERILATOR"

# Icarus Verilog: compile tb_top with the upstream Verilog testbench.
iverilog: check-iverilog build/iverilog/sim.vvp
build/iverilog/sim.vvp: build/rtl/.stamp
	mkdir -p build/iverilog
	"$(IVERILOG)" -g2012 $(DEFINES) $(INCLUDE) -s tb_top -o $@ $(RTL)
	"$(IVERILOG)" -V > build/iverilog/version.txt 2>&1

ifeq ($(SIM),all)
compile: check-env arcilator verilator iverilog
smoke: compile
	@$(MAKE) smoke SIM=arcilator SMOKE=$(SMOKE) WAVE=$(WAVE) VCD_REFERENCE="$(VCD_REFERENCE)"
	@$(MAKE) smoke SIM=verilator SMOKE=$(SMOKE) WAVE=$(WAVE) VCD_REFERENCE="$(VCD_REFERENCE)"
	@$(MAKE) smoke SIM=iverilog SMOKE=$(SMOKE) WAVE=$(WAVE)
bench: compile
	@$(MAKE) bench SIM=arcilator SIZE=$(SIZE) REPEATS=$(REPEATS)
	@$(MAKE) bench SIM=verilator SIZE=$(SIZE) REPEATS=$(REPEATS)
	@$(MAKE) bench SIM=iverilog SIZE=$(SIZE) REPEATS=$(REPEATS)
	@$(MAKE) compare
else
compile: check-env $(EXE)
run: compile
	SIM_EXE=$(EXE) TAG="$(or $(TAG),$(SIM)-run)" VVP="$(VVP)" PYTHON="$(PYTHON)" VCD_REFERENCE="$(VCD_REFERENCE)" WAVE=$(WAVE) scripts/run.sh $(SIM) run $(TEST)
smoke: compile
	SIM_EXE=$(EXE) TAG="$(or $(TAG),$(SIM))" VVP="$(VVP)" PYTHON="$(PYTHON)" VCD_REFERENCE="$(VCD_REFERENCE)" SMOKE=$(SMOKE) WAVE=$(WAVE) scripts/run.sh $(SIM) smoke
bench: compile
	SIM_EXE=$(EXE) TAG="$(or $(TAG),$(SIM))" VVP="$(VVP)" SIZE=$(SIZE) REPEATS=$(REPEATS) WAVE=0 scripts/run.sh $(SIM) bench
endif

compare:
	@awk -f scripts/compare.awk build/results/*/measurements.tsv

compare-vcd:
	@test -n "$(REFERENCE)" && test -n "$(CANDIDATE)" || { echo 'usage: make compare-vcd REFERENCE=... CANDIDATE=...' >&2; exit 2; }
	@$(PYTHON) scripts/compare-vcd.py "$(REFERENCE)" "$(CANDIDATE)"

# Standalone CIRCT/arcilator compiler gap reproducers.
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
