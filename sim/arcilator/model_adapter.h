#pragma once
#include "model.h"

class ModelAdapter {
public:
  void eval() { model.eval(); }
  unsigned threads() const { return 1; }
  uint8_t *itcm() { return model.state.data() + Model::itcmOffset; }
  uint8_t *dtcm() { return model.state.data() + Model::dtcmOffset; }
#define INPUT(name, type)                                                      \
  void name(type value) { model.name(value); }                                 \
  type name() const { return model.name(); }
  INPUT(clk, uint8_t)
  INPUT(rst_n, uint8_t)
  INPUT(boot_addr, uint32_t)
  INPUT(cmd_ready, uint8_t)
  INPUT(rsp_valid, uint8_t)
  INPUT(rsp_err, uint8_t)
  INPUT(rsp_rdata, uint32_t)
#undef INPUT
#define OUTPUT(name, type)                                                     \
  type name() const { return model.name(); }
  OUTPUT(pc, uint32_t)
  OUTPUT(cmd_valid, uint8_t)
  OUTPUT(cmd_addr, uint32_t)
  OUTPUT(cmd_read, uint8_t)
  OUTPUT(cmd_wdata, uint32_t)
  OUTPUT(cmd_wmask, uint8_t)
  OUTPUT(rsp_ready, uint8_t)
#undef OUTPUT
private:
  Model model;
};
