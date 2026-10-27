`timescale 1ns/10ps
`include "e203_defines.v"

module tb_top();

  reg clk;
  reg rst_n;

  `define ITCM u_e203_cpu_top.u_e203_srams.u_e203_itcm_ram.u_e203_itcm_gnrl_ram.u_sirv_sim_ram
  `define PC_WRITE_TOHOST `E203_PC_SIZE'h80000086

  wire [`E203_PC_SIZE-1:0] inspect_pc;

  wire ppi_icb_cmd_valid;
  wire [`E203_ADDR_SIZE-1:0] ppi_icb_cmd_addr;
  wire ppi_icb_cmd_read;
  wire [`E203_XLEN-1:0] ppi_icb_cmd_wdata;
  reg  ppi_icb_rsp_valid;

  wire clint_icb_cmd_valid;
  reg  clint_icb_rsp_valid;
  reg  [`E203_XLEN-1:0] clint_icb_rsp_rdata;

  wire plic_icb_cmd_valid;
  reg  plic_icb_rsp_valid;

  wire fio_icb_cmd_valid;
  reg  fio_icb_rsp_valid;

  wire mem_icb_cmd_valid;
  reg  mem_icb_rsp_valid;

  reg [8*512-1:0] testcase;
  reg [8*512-1:0] vcd_file;
  integer max_cycles;
  integer quiet;
  integer i;

  reg [7:0] itcm_mem [0:(`E203_ITCM_RAM_DP*8)-1];

  function [31:0] read_itcm_u32(input [31:0] byte_off);
    reg [63:0] w;
    begin
      w = `ITCM.mem_r[(byte_off >> 3) & 13'h1fff];
      read_itcm_u32 = (byte_off[2]) ? w[63:32] : w[31:0];
    end
  endfunction

  function [15:0] read_itcm_u16(input [31:0] byte_off);
    reg [63:0] w;
    begin
      w = `ITCM.mem_r[(byte_off >> 3) & 13'h1fff];
      case (byte_off[2:1])
        2'd0: read_itcm_u16 = w[15:0];
        2'd1: read_itcm_u16 = w[31:16];
        2'd2: read_itcm_u16 = w[47:32];
        2'd3: read_itcm_u16 = w[63:48];
      endcase
    end
  endfunction

  always #5 clk = ~clk;

  initial begin
    if (!$value$plusargs("TESTCASE=%s", testcase)) begin
      $display("ERROR: missing +TESTCASE=<path>");
      $finish(2);
    end
    if (!$value$plusargs("MAXCYCLES=%d", max_cycles))
      max_cycles = 20000000;
    if (!$value$plusargs("QUIET=%d", quiet))
      quiet = 0;
    if ($value$plusargs("VCD=%s", vcd_file)) begin
      $dumpfile(vcd_file);
      $dumpvars(1, u_e203_cpu_top);
    end

    for (i = 0; i < (`E203_ITCM_RAM_DP * 8); i = i + 1)
      itcm_mem[i] = 8'h00;

    $readmemh(testcase, itcm_mem);

    for (i = 0; i < `E203_ITCM_RAM_DP; i = i + 1) begin
      `ITCM.mem_r[i][00+7:00] = itcm_mem[i*8+0];
      `ITCM.mem_r[i][08+7:08] = itcm_mem[i*8+1];
      `ITCM.mem_r[i][16+7:16] = itcm_mem[i*8+2];
      `ITCM.mem_r[i][24+7:24] = itcm_mem[i*8+3];
      `ITCM.mem_r[i][32+7:32] = itcm_mem[i*8+4];
      `ITCM.mem_r[i][40+7:40] = itcm_mem[i*8+5];
      `ITCM.mem_r[i][48+7:48] = itcm_mem[i*8+6];
      `ITCM.mem_r[i][56+7:56] = itcm_mem[i*8+7];
    end

    clk = 1'b0;
    rst_n = 1'b0;
    ppi_icb_rsp_valid = 1'b0;
    clint_icb_rsp_valid = 1'b0;
    clint_icb_rsp_rdata = 32'b0;
    plic_icb_rsp_valid = 1'b0;
    fio_icb_rsp_valid = 1'b0;
    mem_icb_rsp_valid = 1'b0;

    repeat (8) @(posedge clk);
    #1 rst_n = 1'b1;
  end

  reg [31:0] cycle_count;
  reg [31:0] tohost_hits;
  reg [31:0] end_cycle;
  reg [31:0] prev_pc;
  reg [31:0] same_pc_hits;
  reg [31:0] tohost_off;
  reg [31:0] x3;
  reg [71:0] uart_tail;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cycle_count <= 32'd0;
      tohost_hits <= 32'd0;
      end_cycle <= 32'd0;
      prev_pc <= 32'hffffffff;
      same_pc_hits <= 32'd0;
      uart_tail <= 72'd0;
      ppi_icb_rsp_valid <= 1'b0;
      clint_icb_rsp_valid <= 1'b0;
      clint_icb_rsp_rdata <= 32'd0;
      plic_icb_rsp_valid <= 1'b0;
      fio_icb_rsp_valid <= 1'b0;
      mem_icb_rsp_valid <= 1'b0;
    end else begin
      if (inspect_pc == `PC_WRITE_TOHOST) begin
        if (tohost_hits == 32'd0)
          end_cycle = cycle_count;
        if (tohost_hits + 32'd1 == 32'd8) begin
          tohost_off = ((read_itcm_u32(32'h8c) >> 12) & 32'hff) << 12;
          x3 = read_itcm_u32(tohost_off);
          $display("PASS=%0d cycles=%0d end_cycle=%0d x3=%0d pc=0x%08x",
                   (x3 == 32'd1), cycle_count + 32'd1, end_cycle, x3, inspect_pc);
          $finish;
        end
        tohost_hits <= tohost_hits + 32'd1;
      end

      if (inspect_pc == prev_pc) begin
        if (same_pc_hits + 32'd1 >= 32'd16 &&
            inspect_pc >= 32'h80000000 && inspect_pc < 32'h80010000) begin
          if (read_itcm_u16(inspect_pc - 32'h80000000) == 16'ha001) begin
            x3 = ({uart_tail} == "x00000000") ? 32'd1 : 32'd0;
            $display("PASS=%0d cycles=%0d end_cycle=%0d x3=%0d pc=0x%08x",
                     x3, cycle_count + 32'd1, cycle_count, x3, inspect_pc);
            $finish;
          end
        end
        same_pc_hits <= same_pc_hits + 32'd1;
      end else begin
        prev_pc <= inspect_pc;
        same_pc_hits <= 32'd0;
      end

      if (ppi_icb_cmd_valid && !ppi_icb_cmd_read && ppi_icb_cmd_addr == 32'h10013000) begin
        if (!quiet)
          $write("%c", ppi_icb_cmd_wdata[7:0]);
        if (ppi_icb_cmd_wdata[7:0] != 8'h0d && ppi_icb_cmd_wdata[7:0] != 8'h0a)
          uart_tail <= {uart_tail[63:0], ppi_icb_cmd_wdata[7:0]};
      end

      ppi_icb_rsp_valid <= ppi_icb_cmd_valid;
      clint_icb_rsp_valid <= clint_icb_cmd_valid;
      clint_icb_rsp_rdata <= cycle_count;
      plic_icb_rsp_valid <= plic_icb_cmd_valid;
      fio_icb_rsp_valid <= fio_icb_cmd_valid;
      mem_icb_rsp_valid <= mem_icb_cmd_valid;

      if (cycle_count + 32'd1 >= max_cycles) begin
        $display("TIMEOUT cycles=%0d pc=0x%08x", cycle_count + 32'd1, inspect_pc);
        $finish(1);
      end
      cycle_count <= cycle_count + 32'd1;
    end
  end

  e203_cpu_top u_e203_cpu_top(
    .inspect_pc             (inspect_pc),
    .inspect_dbg_irq        (),
    .inspect_mem_cmd_valid  (),
    .inspect_mem_cmd_ready  (),
    .inspect_mem_rsp_valid  (),
    .inspect_mem_rsp_ready  (),
    .inspect_core_clk       (),
    .core_csr_clk           (),
    .core_wfi               (),
    .tm_stop                (),
    .pc_rtvec               (32'h80000000),
    .dbg_irq_r              (),
    .cmt_dpc                (),
    .cmt_dpc_ena            (),
    .cmt_dcause             (),
    .cmt_dcause_ena         (),
    .wr_dcsr_ena            (),
    .wr_dpc_ena             (),
    .wr_dscratch_ena        (),
    .wr_csr_nxt             (),
    .dcsr_r                 (32'b0),
    .dpc_r                  (32'b0),
    .dscratch_r             (32'b0),
    .dbg_mode               (1'b0),
    .dbg_halt_r             (1'b0),
    .dbg_step_r             (1'b0),
    .dbg_ebreakm_r          (1'b0),
    .dbg_stopcycle          (1'b0),
    .dbg_irq_a              (1'b0),
    .core_mhartid           (1'b0),
    .ext_irq_a              (1'b0),
    .sft_irq_a              (1'b0),
    .tmr_irq_a              (1'b0),
    .tcm_sd                 (1'b0),
    .tcm_ds                 (1'b0),
    .ext2itcm_icb_cmd_valid (1'b0),
    .ext2itcm_icb_cmd_ready (),
    .ext2itcm_icb_cmd_addr  (16'b0),
    .ext2itcm_icb_cmd_read  (1'b0),
    .ext2itcm_icb_cmd_wdata (32'b0),
    .ext2itcm_icb_cmd_wmask (4'b0),
    .ext2itcm_icb_rsp_valid (),
    .ext2itcm_icb_rsp_ready (1'b1),
    .ext2itcm_icb_rsp_err   (),
    .ext2itcm_icb_rsp_rdata (),
    .ext2dtcm_icb_cmd_valid (1'b0),
    .ext2dtcm_icb_cmd_ready (),
    .ext2dtcm_icb_cmd_addr  (16'b0),
    .ext2dtcm_icb_cmd_read  (1'b0),
    .ext2dtcm_icb_cmd_wdata (32'b0),
    .ext2dtcm_icb_cmd_wmask (4'b0),
    .ext2dtcm_icb_rsp_valid (),
    .ext2dtcm_icb_rsp_ready (1'b1),
    .ext2dtcm_icb_rsp_err   (),
    .ext2dtcm_icb_rsp_rdata (),
    .ppi_icb_cmd_valid      (ppi_icb_cmd_valid),
    .ppi_icb_cmd_ready      (1'b1),
    .ppi_icb_cmd_addr       (ppi_icb_cmd_addr),
    .ppi_icb_cmd_read       (ppi_icb_cmd_read),
    .ppi_icb_cmd_wdata      (ppi_icb_cmd_wdata),
    .ppi_icb_cmd_wmask      (),
    .ppi_icb_rsp_valid      (ppi_icb_rsp_valid),
    .ppi_icb_rsp_ready      (),
    .ppi_icb_rsp_err        (1'b0),
    .ppi_icb_rsp_rdata      (32'b0),
    .clint_icb_cmd_valid    (clint_icb_cmd_valid),
    .clint_icb_cmd_ready    (1'b1),
    .clint_icb_cmd_addr     (),
    .clint_icb_cmd_read     (),
    .clint_icb_cmd_wdata    (),
    .clint_icb_cmd_wmask    (),
    .clint_icb_rsp_valid    (clint_icb_rsp_valid),
    .clint_icb_rsp_ready    (),
    .clint_icb_rsp_err      (1'b0),
    .clint_icb_rsp_rdata    (clint_icb_rsp_rdata),
    .plic_icb_cmd_valid     (plic_icb_cmd_valid),
    .plic_icb_cmd_ready     (1'b1),
    .plic_icb_cmd_addr      (),
    .plic_icb_cmd_read      (),
    .plic_icb_cmd_wdata     (),
    .plic_icb_cmd_wmask     (),
    .plic_icb_rsp_valid     (plic_icb_rsp_valid),
    .plic_icb_rsp_ready     (),
    .plic_icb_rsp_err       (1'b0),
    .plic_icb_rsp_rdata     (32'b0),
    .fio_icb_cmd_valid      (fio_icb_cmd_valid),
    .fio_icb_cmd_ready      (1'b1),
    .fio_icb_cmd_addr       (),
    .fio_icb_cmd_read       (),
    .fio_icb_cmd_wdata      (),
    .fio_icb_cmd_wmask      (),
    .fio_icb_rsp_valid      (fio_icb_rsp_valid),
    .fio_icb_rsp_ready      (),
    .fio_icb_rsp_err        (1'b0),
    .fio_icb_rsp_rdata      (32'b0),
    .mem_icb_cmd_valid      (mem_icb_cmd_valid),
    .mem_icb_cmd_ready      (1'b1),
    .mem_icb_cmd_addr       (),
    .mem_icb_cmd_read       (),
    .mem_icb_cmd_wdata      (),
    .mem_icb_cmd_wmask      (),
    .mem_icb_rsp_valid      (mem_icb_rsp_valid),
    .mem_icb_rsp_ready      (),
    .mem_icb_rsp_err        (1'b0),
    .mem_icb_rsp_rdata      (32'b0),
    .test_mode              (1'b0),
    .clk                    (clk),
    .rst_n                  (rst_n)
  );

endmodule
