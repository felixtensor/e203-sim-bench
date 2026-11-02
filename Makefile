.DEFAULT_GOAL := help
.DELETE_ON_ERROR:

SIM ?= arcilator
TOP ?= e203_cpu_top
TAG ?=
TEST ?= rv32ui-p-add
SMOKE ?= default
SIZE ?= small
REPEATS ?= 5
WAVE ?= 0
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

ifeq ($(filter $(TOP),e203_cpu_top e203_sim),)
$(error TOP must be e203_cpu_top or e203_sim)
endif

CORE = $(filter-out build/rtl/e203/core/config.v build/rtl/e203/core/e203_defines.v,$(sort $(wildcard build/rtl/e203/core/*.v)))
RTL_BASE = $(sort $(wildcard build/rtl/e203/general/*.v)) $(CORE) build/rtl/e203/subsys/e203_subsys_nice_core.v
RTL = $(RTL_BASE) $(if $(filter e203_sim,$(TOP)),sim/e203_sim.v)
WRAP_CPPFLAG = $(if $(filter e203_sim,$(TOP)),-DUSE_WRAPPER)
DEFINES = -DDISABLE_SV_ASSERTION=1 -DFPGA_SOURCE=1
INCLUDE = -Ibuild/rtl/e203/core

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
  compile arcilator verilator iverilog run smoke bench compare repro clean
help:
	@echo 'make setup                              prepare RTL and .tools/venv'
	@echo 'make doctor [SIM=<sim>|all]             verify toolchain'
	@echo 'make arcilator|verilator|iverilog       build one simulator (tool paths: see README)'
	@echo 'make run   SIM=<sim> TEST=rv32ui-p-add  run one test: ISA name, dhrystone, coremark, or .verilog path'
	@echo 'make smoke SIM=<sim>|all [SMOKE=all]    official RV32IMAC ISA tests (8 by default, 67 with SMOKE=all)'
	@echo 'make bench SIM=<sim>|all SIZE=small|large|all [TAG=name]  Dhrystone / CoreMark timing'
	@echo 'make compare                            table of all build/results/<TAG>/measurements.tsv'
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
build/rtl/.stamp: patches/remove-dff-delays.patch
	@[ -d ext/e203/rtl ] || git submodule update --init --depth=1 ext/e203
	mkdir -p build
	rm -rf build/rtl
	cp -R ext/e203/rtl build/rtl
	patch -p1 -d build/rtl < patches/remove-dff-delays.patch
	touch $@

# arcilator: Verilog -> Moore/Core -> explicit SRAMs -> flattened HW -> LLVM -> C++ header.
arcilator: check-arcilator build/arcilator/sim
build/arcilator/frontend.mlir: build/rtl/.stamp $(if $(filter e203_sim,$(TOP)),sim/e203_sim.v)
	mkdir -p build/arcilator
	"$(CIRCT_VERILOG)" --single-unit --timescale=1ns/10ps \
	  --Xslang=--translate-off-format --Xslang=synopsys,translate_off,translate_on \
	  --Xslang=-Wno-unconnected-output-port $(DEFINES) $(INCLUDE) \
	  --top=$(TOP) $(RTL) -o $@
	"$(ARCILATOR)" --version > build/arcilator/version.txt
build/arcilator/ram.mlir: build/arcilator/frontend.mlir scripts/rewrite-ram.awk
	awk -f scripts/rewrite-ram.awk $< > $@
build/arcilator/flat.mlir: build/arcilator/ram.mlir
	"$(CIRCT_OPT)" $< --hw-flatten-modules --canonicalize --cse -o $@
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
build/arcilator/sim: build/arcilator/model.o build/arcilator/model.h sim/main.cpp
	$(CXX) $(CXXFLAGS) -DUSE_ARCILATOR $(WRAP_CPPFLAG) -Ibuild/arcilator -I"$(ARCILATOR_DIR)" \
	  sim/main.cpp build/arcilator/model.o -o $@

# Verilator: compile TOP directly against the unified C++ harness.
verilator: check-verilator build/verilator/obj/sim
build/verilator/obj/V$(TOP).mk: build/rtl/.stamp sim/main.cpp $(if $(filter e203_sim,$(TOP)),sim/e203_sim.v)
	rm -rf build/verilator/obj
	mkdir -p build/verilator
	"$(VERILATOR)" --cc --exe --top-module $(TOP) -Wno-fatal --timescale 1ns/10ps \
	  $(if $(filter 1,$(WAVE)),--trace) $(DEFINES) $(INCLUDE) $(VERILATOR_FLAGS) \
	  -Mdir $(ROOT)/build/verilator/obj -o sim $(RTL) $(ROOT)/sim/main.cpp
	"$(VERILATOR)" --version > build/verilator/version.txt
build/verilator/obj/sim: build/verilator/obj/V$(TOP).mk sim/main.cpp
	$(MAKE) -C build/verilator/obj -f V$(TOP).mk -j$(JOBS) \
	  CXX="$(CXX)" LINK="$(CXX)" AR="$(AR)" OPT_FAST=-O2 OPT_SLOW=-O2 OPT_GLOBAL=-O2 \
	  USER_CPPFLAGS="$(CXXFLAGS) -DUSE_VERILATOR $(WRAP_CPPFLAG)"

# Icarus Verilog: compile e203_cpu_top with the Verilog testbench.
iverilog: check-iverilog build/iverilog/sim.vvp
build/iverilog/sim.vvp: build/rtl/.stamp sim/tb.v
	mkdir -p build/iverilog
	"$(IVERILOG)" -g2012 $(DEFINES) $(INCLUDE) -s tb_top -o $@ $(RTL_BASE) sim/tb.v
	"$(IVERILOG)" -V > build/iverilog/version.txt 2>&1

ifeq ($(SIM),all)
compile: check-env arcilator verilator iverilog
smoke: compile
	@$(MAKE) smoke SIM=arcilator TOP=$(TOP) SMOKE=$(SMOKE) WAVE=$(WAVE)
	@$(MAKE) smoke SIM=verilator TOP=$(TOP) SMOKE=$(SMOKE) WAVE=$(WAVE)
	@$(MAKE) smoke SIM=iverilog TOP=$(TOP) SMOKE=$(SMOKE) WAVE=$(WAVE)
bench: compile
	@$(MAKE) bench SIM=arcilator TOP=$(TOP) SIZE=$(SIZE) REPEATS=$(REPEATS)
	@$(MAKE) bench SIM=verilator TOP=$(TOP) SIZE=$(SIZE) REPEATS=$(REPEATS)
	@$(MAKE) bench SIM=iverilog TOP=$(TOP) SIZE=$(SIZE) REPEATS=$(REPEATS)
	@$(MAKE) compare
else
compile: check-env $(EXE)
run: compile
	SIM_EXE=$(EXE) TAG="$(or $(TAG),$(SIM)-run)" VVP="$(VVP)" WAVE=$(WAVE) scripts/run.sh $(SIM) run $(TEST)
smoke: compile
	SIM_EXE=$(EXE) TAG="$(or $(TAG),$(SIM))" VVP="$(VVP)" SMOKE=$(SMOKE) WAVE=$(WAVE) scripts/run.sh $(SIM) smoke
bench: compile
	SIM_EXE=$(EXE) TAG="$(or $(TAG),$(SIM))" VVP="$(VVP)" SIZE=$(SIZE) REPEATS=$(REPEATS) WAVE=0 scripts/run.sh $(SIM) bench
endif

compare:
	@awk -f scripts/compare.awk build/results/*/measurements.tsv

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
