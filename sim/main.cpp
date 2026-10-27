#include <chrono>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#if defined(USE_ARCILATOR)
#include "model.h"
#elif defined(USE_VERILATOR)
#include "Ve203_cpu_top.h"
#include "Ve203_cpu_top___024root.h"
#include "verilated.h"
#if VM_TRACE
#include "verilated_vcd_c.h"
#endif
#else
#error "Define USE_ARCILATOR or USE_VERILATOR"
#endif

namespace {

constexpr uint32_t kItcmBase = 0x80000000u;
constexpr uint32_t kItcmWords = 8192;
constexpr uint32_t kItcmBytes = kItcmWords * 8;
constexpr uint32_t kPcWriteTohost = 0x80000086u;
constexpr uint32_t kUartTxAddr = 0x10013000u;

struct Options {
  std::string testcase;
  uint64_t max_cycles = 20000000ull;
  std::string vcd_path;
  bool quiet = false;
};

Options parse_args(int argc, char **argv) {
  if (argc < 2)
    throw std::runtime_error(
        "usage: sim <testcase.verilog> [max_cycles] [--vcd <file>] [--quiet]");
  Options opt;
  opt.testcase = argv[1];
  bool have_max = false;
  for (int i = 2; i < argc; ++i) {
    std::string arg = argv[i];
    if (arg == "--vcd" && i + 1 < argc) {
      opt.vcd_path = argv[++i];
    } else if (arg == "--quiet") {
      opt.quiet = true;
    } else if (!have_max && !arg.empty() && arg[0] != '-') {
      opt.max_cycles = std::stoull(arg, nullptr, 0);
      have_max = true;
    } else {
      throw std::runtime_error("unknown argument: " + arg);
    }
  }
  return opt;
}

std::vector<uint8_t> load_verilog_hex(const std::string &path) {
  std::ifstream in(path);
  if (!in)
    throw std::runtime_error("cannot open testcase: " + path);
  std::vector<uint8_t> mem(kItcmBytes, 0);
  std::string tok;
  size_t addr = 0;
  while (in >> tok) {
    if (tok[0] == '@') {
      addr = std::stoul(tok.substr(1), nullptr, 16);
    } else {
      if (addr >= mem.size())
        throw std::runtime_error("program image exceeds 64 KB ITCM");
      mem[addr++] = static_cast<uint8_t>(std::stoul(tok, nullptr, 16));
    }
  }
  return mem;
}

} // namespace

int main(int argc, char **argv) try {
  const Options opt = parse_args(argc, argv);
  const std::vector<uint8_t> itcm_bytes = load_verilog_hex(opt.testcase);

#if defined(USE_ARCILATOR)
  e203_cpu_top model;
  auto &dut = model.view;
  auto itcm_word = [&](size_t i) -> uint64_t & {
    return model.view.internal.u_e203_srams.u_e203_itcm_ram
        .u_e203_itcm_gnrl_ram.u_sirv_sim_ram.mem_r.words[i]
        .data;
  };
  std::ofstream vcd_stream;
  std::unique_ptr<ValueChangeDump<e203_cpu_topLayout>> vcd;
  if (!opt.vcd_path.empty()) {
    vcd_stream.open(opt.vcd_path);
    if (!vcd_stream)
      throw std::runtime_error("cannot open VCD file: " + opt.vcd_path);
    vcd = std::make_unique<ValueChangeDump<e203_cpu_topLayout>>(
        vcd_stream, &model.storage[0]);
    vcd->writeHeader(false);
    vcd->writeDumpvars();
  }
  auto dump_wave = [&](uint64_t) {
    if (vcd)
      vcd->writeTimestep(5);
  };
#elif defined(USE_VERILATOR)
  VerilatedContext ctx;
  Ve203_cpu_top model(&ctx, "e203_cpu_top");
  auto &dut = model;
  auto itcm_word = [&](size_t i) -> uint64_t & {
    return model.rootp->e203_cpu_top__DOT__u_e203_srams__DOT__u_e203_itcm_ram__DOT__u_e203_itcm_gnrl_ram__DOT__u_sirv_sim_ram__DOT__mem_r[i];
  };
#if VM_TRACE
  std::unique_ptr<VerilatedVcdC> vcd;
  if (!opt.vcd_path.empty()) {
    ctx.traceEverOn(true);
    vcd = std::make_unique<VerilatedVcdC>();
    model.trace(vcd.get(), 1);
    vcd->open(opt.vcd_path.c_str());
  }
  auto dump_wave = [&](uint64_t sim_time) {
    if (vcd)
      vcd->dump(sim_time);
  };
#else
  if (!opt.vcd_path.empty())
    throw std::runtime_error("VCD needs a traced model: make -B verilator WAVE=1");
  auto dump_wave = [&](uint64_t) {};
#endif
#endif

  // Pack bytes into 64-bit ITCM SRAM words matching ext/e203/tb/tb_top.v.
  for (size_t i = 0; i < kItcmWords; ++i) {
    uint64_t w = 0;
    for (size_t b = 0; b < 8; ++b)
      w |= static_cast<uint64_t>(itcm_bytes[i * 8 + b]) << (b * 8);
    itcm_word(i) = w;
  }

  auto read_itcm_u32 = [&](uint32_t byte_off) -> uint32_t {
    uint64_t w = itcm_word((byte_off >> 3) & (kItcmWords - 1));
    return static_cast<uint32_t>(w >> ((byte_off & 4) * 8));
  };
  auto read_itcm_u16 = [&](uint32_t byte_off) -> uint16_t {
    uint64_t w = itcm_word((byte_off >> 3) & (kItcmWords - 1));
    return static_cast<uint16_t>(w >> ((byte_off & 6) * 8));
  };

  dut.pc_rtvec = kItcmBase;
  dut.ext2itcm_icb_rsp_ready = 1;
  dut.ext2dtcm_icb_rsp_ready = 1;
  dut.ppi_icb_cmd_ready = 1;
  dut.clint_icb_cmd_ready = 1;
  dut.plic_icb_cmd_ready = 1;
  dut.fio_icb_cmd_ready = 1;
  dut.mem_icb_cmd_ready = 1;

  uint64_t sim_time = 0;
  dut.rst_n = 0;
  for (int i = 0; i < 8; ++i) {
    dut.clk = 0;
    model.eval();
    dump_wave(sim_time += 5);
    dut.clk = 1;
    model.eval();
    dump_wave(sim_time += 5);
  }
  dut.rst_n = 1;

  uint32_t tohost_hits = 0;
  uint64_t end_cycle = 0;
  uint32_t prev_pc = 0xffffffffu;
  uint32_t same_pc_hits = 0;
  std::string uart_out;

  const auto start_time = std::chrono::steady_clock::now();
  uint64_t cycle = 0;
  bool pass = false;
  uint32_t x3 = 0;

  for (; cycle < opt.max_cycles; ++cycle) {
    dut.clk = 0;
    model.eval();
    dump_wave(sim_time += 5);

    const uint32_t pc = dut.inspect_pc;
    if (pc == kPcWriteTohost) {
      if (tohost_hits == 0)
        end_cycle = cycle;
      if (++tohost_hits == 8) {
        const uint32_t tohost_off = ((read_itcm_u32(0x8c) >> 12) & 0xffu) << 12;
        x3 = read_itcm_u32(tohost_off);
        pass = (x3 == 1);
        ++cycle;
        break;
      }
    }
    if (pc == prev_pc) {
      if (++same_pc_hits >= 16 && pc >= kItcmBase &&
          pc < kItcmBase + kItcmBytes) {
        if (read_itcm_u16(pc - kItcmBase) == 0xa001u) {
          end_cycle = cycle;
          pass = (uart_out.find("Program has exited with code:0x00000000") !=
                  std::string::npos);
          x3 = pass ? 1 : 0;
          ++cycle;
          break;
        }
      }
    } else {
      prev_pc = pc;
      same_pc_hits = 0;
    }

    const uint8_t ppi_cmd = dut.ppi_icb_cmd_valid;
    const uint8_t ppi_read = dut.ppi_icb_cmd_read;
    const uint32_t ppi_addr = dut.ppi_icb_cmd_addr;
    const uint32_t ppi_wdata = dut.ppi_icb_cmd_wdata;
    const uint8_t clint_cmd = dut.clint_icb_cmd_valid;
    const uint8_t plic_cmd = dut.plic_icb_cmd_valid;
    const uint8_t fio_cmd = dut.fio_icb_cmd_valid;
    const uint8_t mem_cmd = dut.mem_icb_cmd_valid;

    if (ppi_cmd && !ppi_read && ppi_addr == kUartTxAddr)
      uart_out.push_back(static_cast<char>(ppi_wdata & 0xffu));

    dut.clk = 1;
    model.eval();
    dump_wave(sim_time += 5);

    dut.ppi_icb_rsp_valid = ppi_cmd;
    dut.clint_icb_rsp_valid = clint_cmd;
    dut.clint_icb_rsp_rdata = static_cast<uint32_t>(cycle);
    dut.plic_icb_rsp_valid = plic_cmd;
    dut.fio_icb_rsp_valid = fio_cmd;
    dut.mem_icb_rsp_valid = mem_cmd;
  }

#if defined(USE_VERILATOR)
#if VM_TRACE
  if (vcd)
    vcd->close();
#endif
  model.final();
#endif

  const double sim_s = std::chrono::duration<double>(
                           std::chrono::steady_clock::now() - start_time)
                           .count();
  if (!opt.quiet && !uart_out.empty())
    std::cout << uart_out;

  std::fprintf(stderr, "HARNESS sim_s=%.9f\n", sim_s);
  std::printf("PASS=%d cycles=%llu end_cycle=%llu x3=%u pc=0x%08x\n",
              pass ? 1 : 0, static_cast<unsigned long long>(cycle),
              static_cast<unsigned long long>(end_cycle), x3, dut.inspect_pc);
  return pass ? 0 : 1;
} catch (const std::exception &e) {
  std::fprintf(stderr, "ERROR: %s\n", e.what());
  return 2;
}
