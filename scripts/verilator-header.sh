#!/usr/bin/env bash
# Expose only the SRAM arrays, then read their generated C++ member names.
set -euo pipefail
if [[ "$1" == --annotate ]]; then
  awk '/reg \[DW-1:0\] mem_r \[0:DP-1\];/ {
         print "    /*verilator public_flat_rw_on*/"; print;
         print "    /*verilator public_off*/"; n++; next
       } {print} END {if(n!=1) exit 1}' "$2" > "$3"
  exit
fi
input=$1
output=$2
{
  echo '#pragma once'
  for tcm in ITCM DTCM; do
    field=$(sed -nE '/u_sirv_sim_ram__DOT__mem_r/ s/.*> ([A-Za-z_][A-Za-z0-9_]*);.*/\1/p' "$input" | grep -i "_${tcm}[_A-Z]")
    [[ $(printf '%s\n' "$field" | wc -l | tr -d ' ') == 1 && -n "$field" ]]
    echo "#define E203_${tcm}_MEM_FIELD $field"
    if [[ "$tcm" == ITCM ]]; then
      echo '#define E203_ITCM_WORDS 8192'
      echo '#define E203_ITCM_WORD_BYTES 8'
    else
      echo '#define E203_DTCM_WORDS 16384'
      echo '#define E203_DTCM_WORD_BYTES 4'
    fi
  done
} > "$output"
