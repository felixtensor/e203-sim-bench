#pragma once

#include <cstddef>
#include <cstdint>
#include <fstream>
#include <stdexcept>
#include <string>

// Observations from the shared upstream testbench adapter.
#define E203_VCD_SIGNALS(X) \
  X(clk, 1) \
  X(lfextclk, 1) \
  X(rst_n, 1) \
  X(result_pc, 32) \
  X(result_pc_valid, 1) \
  X(result_x3, 32) \
  X(result_cycles, 32) \
  X(result_hits, 32) \
  X(result_end_cycle, 32) \
  X(result_benchmark_done, 1) \
  X(result_benchmark_pass, 1) \
  X(result_uart_valid, 1) \
  X(result_uart_data, 8)

class PortableVcd {
public:
  explicit PortableVcd(const std::string &path) {
    if (path.empty())
      return;
    out_.open(path, std::ios::binary);
    if (!out_)
      throw std::runtime_error("cannot open VCD file: " + path);
    enabled_ = true;
    out_ << "$timescale 1ns $end\n$scope module tb_top $end\n";
    char id = 'a';
#define E203_VCD_DECL(name, width)                                             \
  out_ << "$var wire " << (width) << ' ' << id++ << ' ' << #name << " $end\n";
    E203_VCD_SIGNALS(E203_VCD_DECL)
#undef E203_VCD_DECL
    out_ << "$upscope $end\n$enddefinitions $end\n";
  }

  template <typename Dut> void sample(uint64_t time, const Dut &dut) {
    if (!enabled_)
      return;
    const uint32_t vals[kNumSignals] = {
#define E203_VCD_VAL(name, width) static_cast<uint32_t>(dut.name),
        E203_VCD_SIGNALS(E203_VCD_VAL)
#undef E203_VCD_VAL
    };
    bool wrote_time = false;
    for (size_t i = 0; i < kNumSignals; ++i) {
      if (!first_ && vals[i] == prev_[i])
        continue;
      if (!wrote_time) {
        out_ << '#' << time << '\n';
        wrote_time = true;
      }
      prev_[i] = vals[i];
      emit(vals[i], kWidths[i], static_cast<char>('a' + i));
    }
    first_ = false;
  }

  void close() {
    if (!enabled_)
      return;
    out_.close();
    if (!out_)
      throw std::runtime_error("failed writing VCD file");
  }

private:
  static constexpr uint8_t kWidths[] = {
#define E203_VCD_WIDTH(name, width) width,
      E203_VCD_SIGNALS(E203_VCD_WIDTH)
#undef E203_VCD_WIDTH
  };
  static constexpr size_t kNumSignals = sizeof(kWidths) / sizeof(kWidths[0]);

  void emit(uint32_t val, uint8_t width, char id) {
    char buf[40];
    char *p = buf;
    if (width == 1) {
      *p++ = static_cast<char>('0' + (val & 1u));
      *p++ = id;
    } else {
      *p++ = 'b';
      for (uint8_t b = width; b > 0; --b)
        *p++ = static_cast<char>('0' + ((val >> (b - 1)) & 1u));
      *p++ = ' ';
      *p++ = id;
    }
    *p++ = '\n';
    out_.write(buf, p - buf);
  }

  std::ofstream out_;
  uint32_t prev_[kNumSignals] = {};
  bool enabled_ = false;
  bool first_ = true;
};

#undef E203_VCD_SIGNALS
