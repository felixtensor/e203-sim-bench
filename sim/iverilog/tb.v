// Icarus testbench for rtl/e203_sim.v. Clock/ICB timing and the scratch
// signature match sim/main.cpp; see docs/results.md.
// Inputs: +PROGRAM=file +BOOT=decimal +SCRATCH=decimal +LATENCY=n +STALL=n
// Optional: +MAXCYCLES=n +VCD=file. Exit: 0 success, 1 CPU failure, 2 harness error.
`timescale 1ns/10ps

module tb_e203_bench;

  localparam integer ITCM_WORDS = 8192;   // 64 KiB / 8-byte words
  localparam integer DTCM_WORDS = 16384;  // 64 KiB / 4-byte words
  localparam integer EXT_BYTES  = 65536;  // 64 KiB external memory

  localparam [31:0] ITCM_BASE = 32'h8000_0000;
  localparam [31:0] DTCM_BASE = 32'h9000_0000;
  localparam [31:0] EXT_BASE  = 32'h2000_0000;
  localparam [31:0] MAILBOX   = 32'h2000_2000;
  localparam [31:0] ITCM_SCRATCH = 32'h8000_1000;
  localparam [31:0] EXT_SCRATCH  = 32'h2000_1000;

  // ---------------------------------------------------------------- DUT I/O
  reg         clk = 1'b0;
  always #5 clk = ~clk;             // 10 ns period: cycle n clk=0 window is
                                    // [10n, 10n+5), rising edge at 10n+5
  reg         rst_n = 1'b0;
  reg  [31:0] boot_addr = ITCM_BASE;
  wire [31:0] pc;
  wire        cmd_valid;
  reg         cmd_ready;
  wire [31:0] cmd_addr;
  wire        cmd_read;
  wire [31:0] cmd_wdata;
  wire [3:0]  cmd_wmask;
  reg         rsp_valid;
  wire        rsp_ready;
  reg  [31:0] rsp_rdata;
  reg         rsp_err;

  e203_sim dut (
    .clk       (clk),
    .rst_n     (rst_n),
    .boot_addr (boot_addr),
    .pc        (pc),
    .cmd_valid (cmd_valid),
    .cmd_ready (cmd_ready),
    .cmd_addr  (cmd_addr),
    .cmd_read  (cmd_read),
    .cmd_wdata (cmd_wdata),
    .cmd_wmask (cmd_wmask),
    .rsp_valid (rsp_valid),
    .rsp_ready (rsp_ready),
    .rsp_err   (rsp_err),
    .rsp_rdata (rsp_rdata)
  );

  // Staged SRAM simulation models (same hierarchy the upstream E203 tb uses).
  `define ITCM_MEM dut.cpu.u_e203_srams.u_e203_itcm_ram.u_e203_itcm_gnrl_ram.u_sirv_sim_ram.mem_r
  `define DTCM_MEM dut.cpu.u_e203_srams.u_e203_dtcm_ram.u_e203_dtcm_gnrl_ram.u_sirv_sim_ram.mem_r

  // ------------------------------------------------------------- harness RAM
  reg [7:0] ext_mem  [0:EXT_BYTES-1];  // external memory image, byte addressed
  reg [7:0] prog_mem [0:EXT_BYTES-1];  // flat program image staging area

  // --------------------------------------------------------- protocol state
  integer    n;               // cycle counter (cycle 0 = first clk=0 window)
  integer    pending;         // one outstanding external command
  integer    response_at;     // first cycle at which rsp_valid is asserted
  reg [31:0] response_data;   // held rsp_rdata until the response is accepted
  integer    reads, writes;   // accepted external read/write command counts

  // -------------------------------------------------------------- plusargs
  reg  [1023:0] program_file;
  reg  [1023:0] vcd_file;
  reg  [31:0]   boot_arg;
  reg  [31:0]   scratch_arg;
  reg  [31:0]   latency_arg;
  reg  [31:0]   stall_arg;
  reg  [31:0]   maxcycles_arg;
  integer       fd, c, i, program_size;
  integer       maxcycles;

  // ------------------------------------------ sampled (pre-rising-edge) I/O
  reg        s_cmd_valid, s_cmd_ready, s_cmd_read, s_rsp_valid, s_rsp_ready;
  reg [31:0] s_cmd_addr, s_cmd_wdata;
  reg [3:0]  s_cmd_wmask;

  // ------------------------------------------------------ expected signature
  reg [7:0] expected_sig [0:11];

  // ================================================================ helpers
  // Drive the harness-controlled DUT inputs for the current cycle n. This is
  // called while clk==0 and mirrors the shared native driver's pre-edge assignments.
  task apply_inputs;
    begin
      rst_n     = (n >= 16);
      cmd_ready = (n >= 16) && (pending == 0) &&
                  ((stall_arg == 32'd0) || ((n % stall_arg) != 0));
      rsp_valid = (pending != 0) && (n >= response_at);
      rsp_rdata = response_data;
      rsp_err   = 1'b0;
    end
  endtask

  // Sample the handshakes / payloads before the rising edge. Exactly like the
  // reference driver, the accepted command/response is decided from these
  // sampled values, never from post-edge outputs.
  task snapshot;
    begin
      s_cmd_valid = cmd_valid;
      s_cmd_ready = cmd_ready;
      s_cmd_addr  = cmd_addr;
      s_cmd_read  = cmd_read;
      s_cmd_wdata = cmd_wdata;
      s_cmd_wmask = cmd_wmask;
      s_rsp_valid = rsp_valid;
      s_rsp_ready = rsp_ready;
    end
  endtask

  // Post-rising-edge bookkeeping; identical to the shared native driver after model.clk(1).
  task bookkeeping;
    integer   bi;
    reg [31:0] aligned, aaddr;
    reg [7:0]  actual;
    reg        sig_ok;
    begin
      if (s_rsp_valid && s_rsp_ready)
        pending = 0;

      if (s_cmd_valid && s_cmd_ready) begin
        if (pending != 0) begin
          $display("ERROR: more than one outstanding ICB command at cycle %0d", n);
          $finish_and_return(2);
        end
        if ((s_cmd_addr < EXT_BASE) || (s_cmd_addr >= (EXT_BASE + 32'h0001_0000))) begin
          $display("ERROR: unexpected external address 0x%08x at cycle %0d", s_cmd_addr, n);
          $finish_and_return(2);
        end
        pending       = 1;
        response_at   = n + latency_arg;
        response_data = 32'h0;
        aligned       = s_cmd_addr & 32'hffff_fffc;
        if (s_cmd_read) begin
          reads = reads + 1;
          response_data = { ext_mem[aligned - EXT_BASE + 3],
                            ext_mem[aligned - EXT_BASE + 2],
                            ext_mem[aligned - EXT_BASE + 1],
                            ext_mem[aligned - EXT_BASE + 0] };
        end else begin
          writes = writes + 1;
          if (s_cmd_wmask[0]) ext_mem[aligned - EXT_BASE + 0] = s_cmd_wdata[7:0];
          if (s_cmd_wmask[1]) ext_mem[aligned - EXT_BASE + 1] = s_cmd_wdata[15:8];
          if (s_cmd_wmask[2]) ext_mem[aligned - EXT_BASE + 2] = s_cmd_wdata[23:16];
          if (s_cmd_wmask[3]) ext_mem[aligned - EXT_BASE + 3] = s_cmd_wdata[31:24];
        end

        // Mailbox write decides PASS/FAIL, after the write has been applied.
        if (!s_cmd_read && (s_cmd_addr == MAILBOX)) begin
          if (s_cmd_wmask !== 4'hf) begin
            $display("ERROR: malformed mailbox write mask=0x%x at cycle %0d",
                     s_cmd_wmask, n);
            $finish_and_return(2);
          end
          if (s_cmd_wdata == 32'h0000_0002) begin
            $display("FAIL cpu_self_check cycles=%0d", n);
            $finish_and_return(1);
          end else if (s_cmd_wdata == 32'h0000_0001) begin
            sig_ok = 1;
            for (bi = 0; bi < 12; bi = bi + 1) begin
              aaddr = scratch_arg + bi;
              if (scratch_arg == DTCM_BASE) begin
                actual = `DTCM_MEM[(aaddr - DTCM_BASE) >> 2] >> (8 * (aaddr[1:0]));
              end else if (scratch_arg == ITCM_SCRATCH) begin
                actual = `ITCM_MEM[(aaddr - ITCM_BASE) >> 3] >> (8 * (aaddr[2:0]));
              end else begin
                actual = ext_mem[aaddr - EXT_BASE];
              end
              if (actual !== expected_sig[bi])
                sig_ok = 0;
            end
            if (!sig_ok) begin
              $display("ERROR: memory signature mismatch at scratch 0x%08x (cycle %0d)",
                       scratch_arg, n);
              $finish_and_return(2);
            end
            $display("PASS cycles=%0d external_reads=%0d external_writes=%0d",
                     n, reads, writes);
            $finish_and_return(0);
          end else begin
            $display("ERROR: malformed mailbox write data=0x%08x at cycle %0d",
                     s_cmd_wdata, n);
            $finish_and_return(2);
          end
        end
      end
    end
  endtask

  // ======================================================== init + main loop
  initial begin
    // ---- plusargs ------------------------------------------------------
    program_file = 1024'b0;
    if (!$value$plusargs("PROGRAM=%s", program_file)) begin
      $display("ERROR: missing +PROGRAM=<flat-binary>");
      $display("usage: vvp TB +PROGRAM=<bin> +BOOT=<dec> +SCRATCH=<dec> +LATENCY=<dec> +STALL=<dec> [+MAXCYCLES=<dec>] [+VCD=<file>]");
      $finish_and_return(2);
    end
    boot_arg = ITCM_BASE;
    if (!$value$plusargs("BOOT=%d", boot_arg)) begin
      $display("ERROR: missing +BOOT=<decimal address>");
      $finish_and_return(2);
    end
    scratch_arg = DTCM_BASE;
    if (!$value$plusargs("SCRATCH=%d", scratch_arg)) begin
      $display("ERROR: missing +SCRATCH=<decimal address>");
      $finish_and_return(2);
    end
    latency_arg = 32'd1;
    if (!$value$plusargs("LATENCY=%d", latency_arg)) begin
      $display("ERROR: missing +LATENCY=<decimal cycles>");
      $finish_and_return(2);
    end
    stall_arg = 32'd0;
    if (!$value$plusargs("STALL=%d", stall_arg)) begin
      $display("ERROR: missing +STALL=<decimal period>");
      $finish_and_return(2);
    end
    maxcycles_arg = 32'd20000;
    if (!$value$plusargs("MAXCYCLES=%d", maxcycles_arg))
      maxcycles_arg = 32'd20000;
    maxcycles = maxcycles_arg;

    // ---- argument validation (same supported values as the native driver) ------
    if ((boot_arg != ITCM_BASE) && (boot_arg != EXT_BASE)) begin
      $display("ERROR: unsupported boot address 0x%08x", boot_arg);
      $finish_and_return(2);
    end
    if ((scratch_arg != DTCM_BASE) && (scratch_arg != EXT_SCRATCH) &&
        (scratch_arg != ITCM_SCRATCH)) begin
      $display("ERROR: unsupported scratch address 0x%08x", scratch_arg);
      $finish_and_return(2);
    end
    if (latency_arg == 32'd0) begin
      $display("ERROR: response latency must be at least one cycle");
      $finish_and_return(2);
    end
    if (maxcycles <= 0) begin
      $display("ERROR: MAXCYCLES must be positive");
      $finish_and_return(2);
    end
    boot_addr = boot_arg;

    if ($test$plusargs("VERBOSE"))
      $display("IVERILOG-TB program=%0s boot=0x%08x scratch=0x%08x latency=%0d stall=%0d maxcycles=%0d",
               program_file, boot_arg, scratch_arg, latency_arg, stall_arg, maxcycles_arg);

    // ---- zero all memories (arcilator's model state starts zeroed) ------
    for (i = 0; i < ITCM_WORDS; i = i + 1)
      `ITCM_MEM[i] = 64'h0;
    for (i = 0; i < DTCM_WORDS; i = i + 1)
      `DTCM_MEM[i] = 32'h0;
    for (i = 0; i < EXT_BYTES; i = i + 1) begin
      ext_mem[i]  = 8'h0;
      prog_mem[i] = 8'h0;
    end

    // ---- read the flat program image ------------------------------------
    fd = $fopen(program_file, "rb");
    if (fd == 0) begin
      $display("ERROR: cannot open program file %0s", program_file);
      $finish_and_return(2);
    end
    program_size = 0;
    c = $fgetc(fd);
    while (c >= 0) begin
      if (program_size >= EXT_BYTES) begin
        $display("ERROR: program is larger than 64 KiB");
        $finish_and_return(2);
      end
      prog_mem[program_size] = c[7:0];
      program_size = program_size + 1;
      c = $fgetc(fd);
    end
    $fclose(fd);
    if (program_size == 0) begin
      $display("ERROR: empty program file");
      $finish_and_return(2);
    end

    // ---- place the image (ITCM: 64-bit LE words; external: bytes) -------
    if (boot_arg == ITCM_BASE) begin
      for (i = 0; i < ((program_size + 7) / 8); i = i + 1)
        `ITCM_MEM[i] = { prog_mem[i*8+7], prog_mem[i*8+6], prog_mem[i*8+5],
                         prog_mem[i*8+4], prog_mem[i*8+3], prog_mem[i*8+2],
                         prog_mem[i*8+1], prog_mem[i*8+0] };
    end else begin
      for (i = 0; i < program_size; i = i + 1)
        ext_mem[i] = prog_mem[i];
    end

    // ---- expected 12-byte scratch signature -----------------------------
    expected_sig[0]  = 8'h37;  expected_sig[1]  = 8'h00;
    expected_sig[2]  = 8'h00;  expected_sig[3]  = 8'h00;
    expected_sig[4]  = 8'h80;  expected_sig[5]  = 8'h00;
    expected_sig[6]  = 8'h2e;  expected_sig[7]  = 8'hfb;
    expected_sig[8]  = 8'ha5;  expected_sig[9]  = 8'h00;
    expected_sig[10] = 8'h00;  expected_sig[11] = 8'h00;

    // ---- optional VCD (never used during timing runs) -------------------
    vcd_file = 1024'b0;
    if ($value$plusargs("VCD=%s", vcd_file)) begin
      $dumpfile(vcd_file);
      $dumpvars(0, tb_e203_bench);
    end

    // ---- cycle 0: drive inputs, settle, sample, then first rising edge --
    n             = 0;
    pending       = 0;
    response_at   = 0;
    response_data = 32'h0;
    reads         = 0;
    writes        = 0;

    apply_inputs();
    #1;                 // let combinational outputs settle in the clk=0 window
    snapshot();
    @(posedge clk);      // end of cycle 0
    bookkeeping();

    forever begin
      n = n + 1;
      if (n >= maxcycles) begin
        $display("TIMEOUT cycles=%0d pc=0x%08x", n, pc);
        $finish_and_return(1);
      end
      @(negedge clk);    // start of cycle n (clk returns to 0)
      apply_inputs();
      #1;
      snapshot();
      @(posedge clk);    // end of cycle n
      bookkeeping();
    end
  end

endmodule
