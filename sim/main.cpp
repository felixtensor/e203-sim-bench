// Shared native simulation loop. Backend headers provide ModelAdapter only.
#include "model_adapter.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr uint32_t externalBase = 0x20000000;
constexpr uint32_t itcmBase = 0x80000000;
constexpr uint32_t dtcmBase = 0x90000000;
constexpr uint32_t mailbox = 0x20002000;
constexpr size_t memoryBytes = 0x10000;
constexpr std::array<uint8_t, 12> signature = {55,   0,    0,   0, 0x80, 0,
                                               0x2e, 0xfb, 165, 0, 0,    0};

uint32_t number(const char *text) {
  size_t end = 0;
  const auto value = std::stoull(text, &end, 0);
  if (!*text || text[end] || value > UINT32_MAX)
    throw std::runtime_error("invalid numeric argument");
  return uint32_t(value);
}

struct Options {
  const char *program;
  uint32_t boot, scratch, latency, stall, maxCycles = 20000;
  const char *vcd = nullptr;
};

Options parse(int argc, char **argv) {
  if (argc < 6)
    throw std::runtime_error("usage: sim PROGRAM BOOT SCRATCH LATENCY "
                             "STALL_PERIOD [MAXCYCLES] [--vcd FILE]");
  Options options{argv[1], number(argv[2]), number(argv[3]), number(argv[4]),
                  number(argv[5])};
  bool haveMaxCycles = false;
  for (int i = 6; i < argc; ++i) {
    if (std::string(argv[i]) == "--vcd" && i + 1 < argc)
      options.vcd = argv[++i];
    else if (!haveMaxCycles && argv[i][0] != '-') {
      options.maxCycles = number(argv[i]);
      haveMaxCycles = true;
    } else
      throw std::runtime_error("unexpected or incomplete argument");
  }
  if (!options.latency || !options.maxCycles)
    throw std::runtime_error("latency and MAXCYCLES must be positive");
  if (options.boot != itcmBase && options.boot != externalBase)
    throw std::runtime_error("unsupported boot address");
  if (options.scratch != dtcmBase && options.scratch != itcmBase + 0x1000 &&
      options.scratch != externalBase + 0x1000)
    throw std::runtime_error("unsupported scratch address");
  return options;
}

// The text layout matches the archived top-port VCDs, including both phases.
class Trace {
public:
  explicit Trace(const char *path) : out(path, std::ios::binary) {
    if (!out)
      throw std::runtime_error("cannot open VCD");
    out << "$timescale 1ns $end\n$scope module e203_sim $end\n"
           "$var wire 1 c clk $end\n$var wire 1 r rst_n $end\n"
           "$var wire 32 p pc $end\n$var wire 1 v cmd_valid $end\n"
           "$var wire 1 y cmd_ready $end\n$var wire 32 a cmd_addr $end\n"
           "$var wire 1 d cmd_read $end\n$var wire 32 w cmd_wdata $end\n"
           "$var wire 4 m cmd_wmask $end\n$var wire 1 s rsp_valid $end\n"
           "$var wire 1 t rsp_ready $end\n$var wire 32 q rsp_rdata $end\n"
           "$upscope $end\n$enddefinitions $end\n";
  }
  void sample(uint64_t time, const ModelAdapter &model) {
    out << '#' << time << '\n';
    bits(model.clk(), 1, "c");
    bits(model.rst_n(), 1, "r");
    bits(model.pc(), 32, "p");
    bits(model.cmd_valid(), 1, "v");
    bits(model.cmd_ready(), 1, "y");
    bits(model.cmd_addr(), 32, "a");
    bits(model.cmd_read(), 1, "d");
    bits(model.cmd_wdata(), 32, "w");
    bits(model.cmd_wmask(), 4, "m");
    bits(model.rsp_valid(), 1, "s");
    bits(model.rsp_ready(), 1, "t");
    bits(model.rsp_rdata(), 32, "q");
  }

private:
  void bits(uint32_t value, unsigned width, const char *id) {
    out << 'b';
    for (unsigned i = width; i; --i)
      out << ((value >> (i - 1)) & 1);
    out << ' ' << id << '\n';
  }
  std::ofstream out;
};
} // namespace

int main(int argc, char **argv) try {
  const Options options = parse(argc, argv);
  std::ifstream input(options.program, std::ios::binary);
  std::vector<uint8_t> program((std::istreambuf_iterator<char>(input)), {});
  if (program.empty() || program.size() > memoryBytes)
    throw std::runtime_error("missing or oversized program");

  ModelAdapter model;
  std::vector<uint8_t> external(memoryBytes, 0);
  std::copy(program.begin(), program.end(),
            options.boot == itcmBase ? model.itcm() : external.data());
  std::unique_ptr<Trace> trace;
  if (options.vcd)
    trace = std::make_unique<Trace>(options.vcd);
  model.boot_addr(options.boot);
  model.rsp_err(0);
  bool pending = false;
  uint32_t responseData = 0;
  uint64_t responseAt = 0, reads = 0, writes = 0;
  const auto start = std::chrono::steady_clock::now();
  auto reportTime = [&] {
    const double seconds =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - start)
            .count();
    std::fprintf(stderr, "HARNESS sim_s=%.9f threads=%u\n", seconds,
                 model.threads());
  };
  for (uint64_t cycle = 0; cycle < options.maxCycles; ++cycle) {
    const bool running = cycle >= 16;
    model.rst_n(running);
    model.clk(0);
    model.cmd_ready(running && !pending &&
                    (!options.stall || cycle % options.stall != 0));
    model.rsp_valid(pending && cycle >= responseAt);
    model.rsp_rdata(responseData);
    model.eval();
    if (trace)
      trace->sample(cycle * 10, model);
    // Snapshot acceptance before the rising edge updates the model's outputs.
    const bool command = model.cmd_valid() && model.cmd_ready();
    const bool response = model.rsp_valid() && model.rsp_ready();
    const uint32_t address = model.cmd_addr(), data = model.cmd_wdata();
    const uint8_t mask = model.cmd_wmask();
    const bool read = model.cmd_read();
    model.clk(1);
    model.eval();
    if (trace)
      trace->sample(cycle * 10 + 5, model);
    if (response)
      pending = false;
    if (!command)
      continue;
    if (pending)
      throw std::runtime_error("more than one outstanding ICB command");
    if (address < externalBase || address >= externalBase + memoryBytes)
      throw std::runtime_error("unexpected external address " +
                               std::to_string(address));
    pending = true;
    responseAt = cycle + options.latency;
    responseData = 0;
    const size_t offset = (address & ~3u) - externalBase;
    if (read) {
      ++reads;
      for (unsigned i = 0; i < 4; ++i)
        responseData |= uint32_t(external[offset + i]) << (i * 8);
    } else {
      ++writes;
      for (unsigned i = 0; i < 4; ++i)
        if (mask & (1u << i))
          external[offset + i] = uint8_t(data >> (i * 8));
    }
    if (read || address != mailbox)
      continue;
    if (mask != 0xf || (data != 1 && data != 2))
      throw std::runtime_error("malformed mailbox write");
    if (data == 2) {
      reportTime();
      std::printf("FAIL cpu_self_check cycles=%llu\n",
                  (unsigned long long)cycle);
      return 1;
    }
    const uint8_t *actual = options.scratch == dtcmBase ? model.dtcm()
                            : options.scratch == itcmBase + 0x1000
                                ? model.itcm() + 0x1000
                                : external.data() + 0x1000;
    if (!std::equal(signature.begin(), signature.end(), actual))
      throw std::runtime_error("memory signature mismatch");
    reportTime();
    std::printf("PASS cycles=%llu external_reads=%llu external_writes=%llu\n",
                (unsigned long long)cycle, (unsigned long long)reads,
                (unsigned long long)writes);
    return 0;
  }
  reportTime();
  std::fprintf(stderr, "TIMEOUT pc=0x%08x\n", model.pc());
  return 1;
} catch (const std::exception &error) {
  std::fprintf(stderr, "ERROR: %s\n", error.what());
  return 2;
}
