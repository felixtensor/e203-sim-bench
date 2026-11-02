#include "vcd.h"
#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <stdexcept>
#include <string>
#if defined(USE_ARCILATOR)
#include "model.h"
#elif defined(USE_VERILATOR)
#include "Vtb_top.h"
#include "Vtb_top___024root.h"
#include "verilated.h"
#endif

constexpr uint64_t kHfHalf = 2;
constexpr uint64_t kLfHalf = 33;
constexpr uint64_t kResetTime = 120;
constexpr uint64_t kExitSettle = 10;

int main(int argc, char **argv) try {
  if (argc < 2)
    throw std::runtime_error("usage: sim <image.verilog> [max_cycles] "
                             "[--quiet] [--benchmark] [--vcd file]");
  uint64_t max_cycles = 20000000;
  bool quiet = false, benchmark = false;
  std::string wave;
  for (int i = 2; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--quiet")
      quiet = true;
    else if (arg == "--benchmark")
      benchmark = true;
    else if (arg == "--vcd" && i + 1 < argc)
      wave = argv[++i];
    else if (arg.size() && arg[0] != '-')
      max_cycles = std::stoull(arg);
    else
      throw std::runtime_error("unknown argument: " + arg);
  }
#if defined(USE_ARCILATOR)
  tb_top model;
  auto &d = model.view;
  auto &memory = d.internal.u_e203_soc_top.u_e203_subsys_top.u_e203_subsys_main
                     .u_e203_cpu_top.u_e203_srams.u_e203_itcm_ram
                     .u_e203_itcm_gnrl_ram.u_sirv_sim_ram.mem_r;
  auto word = [&](size_t i) -> uint64_t & { return memory.words[i].data; };
#else
  VerilatedContext context;
  Vtb_top model(&context);
  auto &d = model;
  auto &memory =
      model.rootp
          ->tb_top__DOT__u_e203_soc_top__DOT__u_e203_subsys_top__DOT__u_e203_subsys_main__DOT__u_e203_cpu_top__DOT__u_e203_srams__DOT__u_e203_itcm_ram__DOT__u_e203_itcm_gnrl_ram__DOT__u_sirv_sim_ram__DOT__mem_r;
  auto word = [&](size_t i) -> uint64_t & { return memory[i]; };
#endif
  std::ifstream input(argv[1]);
  if (!input)
    throw std::runtime_error("cannot open image");
  for (size_t i = 0; i < 8192; ++i)
    word(i) = 0;
  size_t address = 0;
  std::string token;
  while (input >> token) {
    if (token[0] == '@')
      address = std::stoul(token.substr(1), nullptr, 16);
    else {
      if (address >= 65536)
        throw std::runtime_error("image exceeds ITCM");
      word(address / 8) |= uint64_t(std::stoul(token, nullptr, 16))
                           << ((address % 8) * 8);
      ++address;
    }
  }
  PortableVcd vcd(wave);
  d.benchmark_mode = benchmark;
  d.clk = d.lfextclk = d.rst_n = 0;
  model.eval();
  vcd.sample(0, d);
  uint64_t time = 0, next_hf = kHfHalf, next_lf = kLfHalf;
  uint64_t finish_time = 0;
  const uint64_t limit = kResetTime + max_cycles * 2 * kHfHalf;
  const auto start = std::chrono::steady_clock::now();
  while (time < limit) {
    uint64_t next = std::min(next_hf, next_lf);
    if (time < kResetTime)
      next = std::min(next, kResetTime);
    if (finish_time)
      next = std::min(next, finish_time);
    time = std::min(next, limit);
    const bool rising = time == next_hf && !d.clk;
    if (rising && d.rst_n && d.result_uart_valid && !quiet)
      std::putchar(d.result_uart_data);
    if (time == next_hf) {
      d.clk ^= 1;
      next_hf += kHfHalf;
    }
    if (time == next_lf) {
      d.lfextclk ^= 1;
      next_lf += kLfHalf;
    }
    d.rst_n = time >= kResetTime;
    model.eval();
    vcd.sample(time, d);
    if (!finish_time &&
        (benchmark ? d.result_benchmark_done : d.result_hits >= 8))
      finish_time = time + kExitSettle;
    if (finish_time && time >= finish_time)
      break;
  }
  const bool completed = finish_time && time >= finish_time;
  const bool pass =
      completed && (benchmark ? d.result_benchmark_pass : d.result_x3 == 1);
  vcd.close();
#if defined(USE_VERILATOR)
  model.final();
#endif
  const double seconds =
      std::chrono::duration<double>(std::chrono::steady_clock::now() - start)
          .count();
  std::fprintf(stderr, "HARNESS sim_s=%.9f\n", seconds);
  std::printf("\nPASS=%d cycles=%u end_cycle=%u x3=%u pc=0x%08x\n", pass,
              unsigned(d.result_cycles), unsigned(d.result_end_cycle),
              unsigned(d.result_x3), unsigned(d.result_pc));
  return pass ? 0 : 1;
} catch (const std::exception &error) {
  std::fprintf(stderr, "ERROR: %s\n", error.what());
  return 2;
}
