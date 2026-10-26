#!/usr/bin/env bash
# Convert arcilator's state-layout JSON into the small C++ interface used by main.cpp.
set -euo pipefail
input=$1
output=$2
jq -e 'length == 1 and .[0].name == "e203_sim" and
       ((.[0].initialFnSym // "") == "") and ((.[0].finalFnSym // "") == "")' "$input" >/dev/null
{
  cat <<'CPP'
#pragma once
#include <cstdint>
#include <cstring>
#include <vector>
extern "C" void e203_sim_eval(void*);
struct Model {
CPP
  jq -r '.[0] | "std::vector<uint8_t> state = std::vector<uint8_t>(\(.numStateBytes), 0);"' "$input"
  echo 'void eval() { e203_sim_eval(state.data()); }'
  while IFS=$'\t' read -r name offset bits kind; do
    [[ "$bits" -le 32 ]] || { echo "unsupported port width: $name" >&2; exit 1; }
    type=uint32_t
    [[ "$bits" -le 8 ]] && type=uint8_t
    echo "$type $name() const { $type v; std::memcpy(&v, state.data()+$offset, sizeof(v)); return v; }"
    if [[ "$kind" == input ]]; then
      echo "void $name($type v) { std::memcpy(state.data()+$offset, &v, sizeof(v)); }"
    fi
  done < <(jq -r '.[0].states[] | select(.type == "input" or .type == "output") | [.name,.offset,.numBits,.type] | @tsv' "$input")
  for tcm in itcm dtcm; do
    if [[ "$tcm" == itcm ]]; then bits=64; stride=8; depth=8192; else bits=32; stride=4; depth=16384; fi
    offset=$(jq -er --arg tcm "$tcm" --argjson bits "$bits" --argjson stride "$stride" --argjson depth "$depth" '
      [.[0].states[] | select(.type == "memory" and (.name | contains("/u_e203_" + $tcm + "_ram/")))] |
      if length == 1 and .[0].numBits == $bits and .[0].stride == $stride and .[0].depth == $depth
      then .[0].offset else error("unexpected SRAM layout") end' "$input")
    echo "static constexpr size_t ${tcm}Offset = $offset;"
    echo "static constexpr size_t ${tcm}Size = 65536;"
  done
  echo '};'
} > "$output"
