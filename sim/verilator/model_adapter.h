#pragma once
#include "Ve203_sim.h"
#include "Ve203_sim___024root.h"
#include "e203_mem_access.h"
#include "verilated.h"
#include <cstdint>
#include <memory>

class ModelAdapter {
public:
  ModelAdapter() {
    model = std::make_unique<Ve203_sim>(&context, "TOP");
  }
  void eval() { model->eval(); }
  unsigned threads() const { return 1; }
  uint8_t *itcm() {
    auto &memory = model->rootp->E203_ITCM_MEM_FIELD;
    static_assert(sizeof(memory[0]) == E203_ITCM_WORD_BYTES);
    return reinterpret_cast<uint8_t *>(&memory[0]);
  }
  uint8_t *dtcm() {
    auto &memory = model->rootp->E203_DTCM_MEM_FIELD;
    static_assert(sizeof(memory[0]) == E203_DTCM_WORD_BYTES);
    return reinterpret_cast<uint8_t *>(&memory[0]);
  }
#define INPUT(name, type)                                                      \
  void name(type value) { model->name = value; }                               \
  type name() const { return model->name; }
  INPUT(clk, uint8_t)
  INPUT(rst_n, uint8_t)
  INPUT(boot_addr, uint32_t)
  INPUT(cmd_ready, uint8_t)
  INPUT(rsp_valid, uint8_t)
  INPUT(rsp_err, uint8_t)
  INPUT(rsp_rdata, uint32_t)
#undef INPUT
#define OUTPUT(name, type)                                                     \
  type name() const { return model->name; }
  OUTPUT(pc, uint32_t)
  OUTPUT(cmd_valid, uint8_t)
  OUTPUT(cmd_addr, uint32_t)
  OUTPUT(cmd_read, uint8_t)
  OUTPUT(cmd_wdata, uint32_t)
  OUTPUT(cmd_wmask, uint8_t)
  OUTPUT(rsp_ready, uint8_t)
#undef OUTPUT
private:
  VerilatedContext context;
  std::unique_ptr<Ve203_sim> model;
};
