#!/usr/bin/env bash
set -u

verbose=0
if [[ ${1:-} == --verbose ]]; then
  verbose=1
  shift
fi
sim=${1:-arcilator}

case $sim in
  arcilator|verilator|iverilog|all) ;;
  *)
    echo "error: unknown SIM: $sim" >&2
    exit 2
    ;;
esac

: "${CIRCT_BIN:=}"
: "${CIRCT_VERILOG:=circt-verilog}"
: "${CIRCT_OPT:=circt-opt}"
: "${ARCILATOR:=arcilator}"
: "${ARCILATOR_HEADER_CPP:=}"
: "${ARCILATOR_RUNTIME_H:=}"
: "${OPT:=opt}"
: "${LLC:=llc}"
: "${VERILATOR:=verilator}"
: "${IVERILOG:=iverilog}"
: "${VVP:=vvp}"
: "${CXX:=c++}"
: "${AR:=ar}"
: "${PYTHON:=python3}"
: "${VENV:=.tools/venv}"

fail=0
need_circt=0
need_python=0
need_verilator=0
need_iverilog=0
need_cxx=0

version_summary() {
  local path=$1 style=$2

  case $style in
    nover) ;;
    iverilog) "$path" -V 2>&1 | head -n 1 ;;
    circt)
      "$path" --version 2>&1 | awk '
        /LLVM version/ { llvm = $0; sub(/^[ \t]+/, "", llvm) }
        /CIRCT/ { circt = $0 }
        END {
          if (circt != "") print circt
          else if (llvm != "") print llvm
        }'
      ;;
    *) "$path" --version 2>&1 | head -n 1 ;;
  esac
}

check() {
  local label=$1 tool=$2 group=$3 style=${4:-}
  local path version

  if ! path=$(command -v "$tool" 2>/dev/null); then
    printf 'error: %s not found: %s\n' "$label" "$tool" >&2
    fail=1
    case $group in
      circt) need_circt=1 ;;
      python) need_python=1 ;;
      verilator) need_verilator=1 ;;
      iverilog) need_iverilog=1 ;;
      cxx) need_cxx=1 ;;
    esac
    return 0
  fi

  if ((verbose)); then
    printf '%-24s %s\n' "$label:" "$path"
    version=$(version_summary "$path" "$style")
    [[ -n $version ]] && printf '%-24s %s\n' '' "$version"
  fi
}

check_python() {
  local path version jinja

  if ! path=$(command -v "$PYTHON" 2>/dev/null); then
    printf 'error: python not found: %s\n' "$PYTHON" >&2
    fail=1
    need_python=1
    return 0
  fi

  if ! "$path" -c 'import jinja2' >/dev/null 2>&1; then
    printf 'error: %s lacks jinja2\n' "$path" >&2
    fail=1
    need_python=1
    return 0
  fi

  if ((verbose)); then
    version=$("$path" --version 2>&1 | head -n 1)
    jinja=$("$path" -c 'import jinja2; print(jinja2.__version__)' 2>/dev/null)
    printf '%-24s %s\n' "python:" "$path"
    [[ -n $version ]] && printf '%-24s %s\n' '' "$version"
    [[ -n $jinja ]] && printf '%-24s jinja2 %s\n' '' "$jinja"
  fi
}

check_file() {
  local label=$1 file=$2

  if [[ -z $file || ! -f $file ]]; then
    printf 'error: %s not found: %s\n' "$label" "${file:-<empty>}" >&2
    fail=1
    need_circt=1
    return 0
  fi

  if ((verbose)); then
    printf '%-24s %s\n' "$label:" "$file"
  fi
}

check_headers() {
  local header=${ARCILATOR_HEADER_CPP:-}
  local runtime=${ARCILATOR_RUNTIME_H:-}

  if [[ -n $CIRCT_BIN ]]; then
    header=${header:-$CIRCT_BIN/arcilator-header-cpp.py}
    runtime=${runtime:-$CIRCT_BIN/arcilator-runtime.h}
  fi

  check_file arcilator-header-cpp.py "$header"
  check_file arcilator-runtime.h "$runtime"
}

if ((verbose)) && [[ -n $CIRCT_BIN ]]; then
  printf '%-24s %s\n' "CIRCT_BIN:" "$CIRCT_BIN"
fi

if [[ $sim == arcilator || $sim == all ]]; then
  check circt-verilog "$CIRCT_VERILOG" circt circt
  check circt-opt "$CIRCT_OPT" circt circt
  check arcilator "$ARCILATOR" circt circt
  check opt "$OPT" circt circt
  check llc "$LLC" circt circt
  check_headers
  check_python
fi

if [[ $sim == verilator || $sim == all ]]; then
  check verilator "$VERILATOR" verilator
  check c++ "$CXX" cxx
  check ar "$AR" cxx nover
fi

if [[ $sim == iverilog || $sim == all ]]; then
  check iverilog "$IVERILOG" iverilog iverilog
  check vvp "$VVP" iverilog iverilog
fi

if ((fail)); then
  echo >&2
  if ((need_circt)); then
    echo 'hint: set CIRCT_BIN to the CIRCT build/bin directory, or add the CIRCT tools to PATH (docs/setup.md)' >&2
  fi
  if ((need_python)); then
    echo "hint: run 'make setup' to create $VENV, or set PYTHON to an interpreter with jinja2" >&2
  fi
  if ((need_verilator)); then
    echo 'hint: install Verilator or set VERILATOR=/path/to/verilator' >&2
  fi
  if ((need_iverilog)); then
    echo 'hint: install Icarus Verilog or set IVERILOG=/path/to/iverilog and VVP=/path/to/vvp' >&2
  fi
  if ((need_cxx)); then
    echo 'hint: install a C++17 compiler and ar (Xcode Command Line Tools or build-essential)' >&2
  fi
  exit 1
fi

if ((verbose)); then
  echo
  echo "Environment OK for SIM=$sim."
fi
