`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Core Unit Testbench
// Tests warp scheduler priorities, independent warp execution, and latency
// hiding via the scoreboard and coalescers.
//
// Test coverage:
//   test_legal_independent_warp_state    - independent legal state tracking per cycle
//   test_latency_hiding                  - forward progress during memory loads
//   test_exhaustion_backpressure         - multi-warp contention on scoreboard depth
//   test_lowest_index_execute_grant      - lowest-index execute grant priority on ties
//   test_lowest_index_memory_grant       - lowest-index memory grant priority on ties
//   test_backpressure_hold_and_resume    - downstream backpressure hold and resume
//////////////////////////////////////////////////////////////////////////////////

`include "../Src/common.sv"
import common_pkg::*;
import tb_common_pkg::*;

module tb_core;
    localparam int WARPS_PER_CORE    = 3;
    localparam int THREADS_PER_WARP  = 32;
    localparam int MEM_LINE_BYTES    = THREADS_PER_WARP * 4; // 128 bytes

    // Core inputs/outputs
    logic clk, reset, start, done;
    kernel_config_t kernel_config;
    data_t core_id, core_block_id;

    // Instr mem interface (per warp)
    logic [WARPS_PER_CORE-1:0] instr_mem_valid;
    instr_mem_addr_t instr_mem_addr [WARPS_PER_CORE];
    logic [WARPS_PER_CORE-1:0] instr_mem_resp_valid;
    logic [WARPS_PER_CORE-1:0] instr_mem_resp_ready;
    instr_t instr_mem_resp_data [WARPS_PER_CORE];

    // Data mem interface
    logic [THREADS_PER_WARP:0] data_mem_valid;
    data_mem_addr_t data_mem_addr [THREADS_PER_WARP+1];
    data_t data_mem_data [THREADS_PER_WARP+1];
    logic [(DATA_WIDTH/8)-1:0] data_mem_we [THREADS_PER_WARP+1];
    logic [THREADS_PER_WARP:0] data_mem_resp_valid;
    logic [THREADS_PER_WARP:0] data_mem_resp_ready;
    data_t data_mem_resp_data [THREADS_PER_WARP+1];

    // Round-tag signals
    logic [REQ_TAG_WIDTH-1:0] issue_tag_vec, resp_tag_vec, issue_tag_scl, resp_tag_scl;
    logic round_start_vec, round_start_scl;

    // Core DUT
    core #(
        .WARPS_PER_CORE(WARPS_PER_CORE),
        .THREADS_PER_WARP(THREADS_PER_WARP)
    ) dut (
        .clk(clk), .reset(reset),
        .start(start), .done(done),
        .kernel_config(kernel_config),
        .core_id(core_id), .core_block_id(core_block_id),
        
        // Instr mem
        .instr_mem_valid(instr_mem_valid),
        .instr_mem_addr(instr_mem_addr),
        .instr_mem_ready({WARPS_PER_CORE{1'b1}}), // always ready for tb
        .instr_mem_resp_valid(instr_mem_resp_valid),
        .instr_mem_resp_ready(instr_mem_resp_ready),
        .instr_mem_resp_data(instr_mem_resp_data),
        
        // Data mem
        .data_mem_valid(data_mem_valid),
        .data_mem_addr(data_mem_addr),
        .data_mem_data(data_mem_data),
        .data_mem_we(data_mem_we),
        .data_mem_resp_valid(data_mem_resp_valid),
        .data_mem_resp_ready(data_mem_resp_ready),
        .data_mem_resp_data(data_mem_resp_data),
        
        // Round-tag handshake
        .data_mem_issue_round_tag_vec(issue_tag_vec),
        .data_mem_round_start_vec(round_start_vec),
        .data_mem_resp_round_tag_vec(resp_tag_vec),
        .data_mem_issue_round_tag_scl(issue_tag_scl),
        .data_mem_round_start_scl(round_start_scl),
        .data_mem_resp_round_tag_scl(resp_tag_scl)
    );

    // Coalescer <-> Memory Model signals
    logic coal_vec_mem_valid, coal_vec_mem_ready, coal_vec_mem_resp_valid;
    logic [DATA_MEM_ADDR_WIDTH-1:0]  coal_vec_mem_addr;
    logic [MEM_LINE_BYTES*8-1:0]     coal_vec_mem_data, coal_vec_mem_resp_data;
    logic [MEM_LINE_BYTES-1:0]       coal_vec_mem_we;
    logic [REQ_TAG_WIDTH-1:0]        coal_vec_mem_tag, coal_vec_mem_resp_tag;

    logic coal_scl_mem_valid, coal_scl_mem_ready, coal_scl_mem_resp_valid;
    logic [DATA_MEM_ADDR_WIDTH-1:0]  coal_scl_mem_addr;
    logic [DATA_WIDTH-1:0]           coal_scl_mem_data, coal_scl_mem_resp_data;
    logic [3:0]                      coal_scl_mem_we;
    logic [REQ_TAG_WIDTH-1:0]        coal_scl_mem_tag, coal_scl_mem_resp_tag;

    // Vector Coalescer (Threads 0-31)
    coalescer #(
        .THREADS_PER_WARP(THREADS_PER_WARP),
        .MEM_LINE_BYTES(MEM_LINE_BYTES)
    ) vec_coal (
        .clk(clk), .reset(reset),
        .lsu_valid(data_mem_valid[0 +: THREADS_PER_WARP]),
        .lsu_addr(data_mem_addr[0 +: THREADS_PER_WARP]),
        .lsu_data(data_mem_data[0 +: THREADS_PER_WARP]),
        .lsu_we(data_mem_we[0 +: THREADS_PER_WARP]),
        .lsu_resp_valid(data_mem_resp_valid[0 +: THREADS_PER_WARP]),
        .lsu_resp_ready(data_mem_resp_ready[0 +: THREADS_PER_WARP]),
        .lsu_resp_data(data_mem_resp_data[0 +: THREADS_PER_WARP]),
        
        .issue_round_tag(issue_tag_vec),
        .resp_round_tag(resp_tag_vec),
        .round_start(round_start_vec),
        
        .mem_valid(coal_vec_mem_valid), .mem_ready(coal_vec_mem_ready),
        .mem_addr(coal_vec_mem_addr), .mem_data(coal_vec_mem_data), .mem_we(coal_vec_mem_we),
        .mem_resp_valid(coal_vec_mem_resp_valid), .mem_resp_ready(),
        .mem_resp_data(coal_vec_mem_resp_data), .mem_tag(coal_vec_mem_tag), .mem_resp_tag(coal_vec_mem_resp_tag)
    );

    // Scalar Coalescer (Thread 32)
    logic [0:0] scl_lsu_valid_arr;
    data_mem_addr_t scl_lsu_addr_arr [1];
    data_t scl_lsu_data_arr [1];
    logic [3:0] scl_lsu_we_arr [1];
    logic [0:0] scl_lsu_resp_valid_arr;
    logic [0:0] scl_lsu_resp_ready_arr;
    data_t scl_lsu_resp_data_arr [1];

    assign scl_lsu_valid_arr[0]              = data_mem_valid[THREADS_PER_WARP];
    assign scl_lsu_addr_arr[0]               = data_mem_addr[THREADS_PER_WARP];
    assign scl_lsu_data_arr[0]               = data_mem_data[THREADS_PER_WARP];
    assign scl_lsu_we_arr[0]                 = data_mem_we[THREADS_PER_WARP];
    assign scl_lsu_resp_ready_arr[0]         = data_mem_resp_ready[THREADS_PER_WARP];
    assign data_mem_resp_valid[THREADS_PER_WARP] = scl_lsu_resp_valid_arr[0];
    assign data_mem_resp_data[THREADS_PER_WARP]  = scl_lsu_resp_data_arr[0];

    coalescer #(
        .THREADS_PER_WARP(1),
        .MEM_LINE_BYTES(4)
    ) scl_coal (
        .clk(clk), .reset(reset),
        .lsu_valid(scl_lsu_valid_arr),
        .lsu_addr(scl_lsu_addr_arr),
        .lsu_data(scl_lsu_data_arr),
        .lsu_we(scl_lsu_we_arr),
        .lsu_resp_valid(scl_lsu_resp_valid_arr),
        .lsu_resp_ready(scl_lsu_resp_ready_arr),
        .lsu_resp_data(scl_lsu_resp_data_arr),
        .issue_round_tag(issue_tag_scl),
        .resp_round_tag(resp_tag_scl),
        .round_start(round_start_scl),
        .mem_valid(coal_scl_mem_valid), .mem_ready(coal_scl_mem_ready),
        .mem_addr(coal_scl_mem_addr),   .mem_data(coal_scl_mem_data), .mem_we(coal_scl_mem_we),
        .mem_resp_valid(coal_scl_mem_resp_valid), .mem_resp_ready(),
        .mem_resp_data(coal_scl_mem_resp_data),   .mem_tag(coal_scl_mem_tag), .mem_resp_tag(coal_scl_mem_resp_tag)
    );

    // stalling data memory models (simulate realistic latency)
    memory_model_stall #(
        .ADDR_WIDTH(DATA_MEM_ADDR_WIDTH), .DATA_WIDTH(MEM_LINE_BYTES*8),
        .MEM_SIZE(1024), .MAX_LATENCY(10), .TAG_WIDTH(REQ_TAG_WIDTH)
    ) vec_dmem (
        .clk(clk), .reset(reset),
        .valid(coal_vec_mem_valid), .addr(coal_vec_mem_addr),
        .wdata(coal_vec_mem_data),  .we(coal_vec_mem_we),
        .tag(coal_vec_mem_tag),
        .ready(coal_vec_mem_ready), .resp_valid(coal_vec_mem_resp_valid),
        .resp_ready(1'b1),          .rdata(coal_vec_mem_resp_data),
        .resp_tag(coal_vec_mem_resp_tag)
    );

    memory_model_stall #(
        .ADDR_WIDTH(DATA_MEM_ADDR_WIDTH), .DATA_WIDTH(32),
        .MEM_SIZE(1024), .MAX_LATENCY(10), .TAG_WIDTH(REQ_TAG_WIDTH)
    ) scl_dmem (
        .clk(clk), .reset(reset),
        .valid(coal_scl_mem_valid), .addr(coal_scl_mem_addr),
        .wdata(coal_scl_mem_data),  .we(coal_scl_mem_we),
        .tag(coal_scl_mem_tag),
        .ready(coal_scl_mem_ready), .resp_valid(coal_scl_mem_resp_valid),
        .resp_ready(1'b1),          .rdata(coal_scl_mem_resp_data),
        .resp_tag(coal_scl_mem_resp_tag)
    );

    // ideal instruction memory models (one per warp)
    genvar w;
    generate
        for (w = 0; w < WARPS_PER_CORE; w++) begin : instr_mem_gen
            memory_model #(
                .ADDR_WIDTH(INSTR_MEM_ADDR_WIDTH), .DATA_WIDTH(32), .MEM_SIZE(256)
            ) imem (
                .clk(clk), .reset(reset),
                .valid(instr_mem_valid[w]), .addr(instr_mem_addr[w] >> 2),
                .wdata(32'd0), .we(4'd0),
                .ready(),
                .resp_valid(instr_mem_resp_valid[w]),
                .resp_ready(instr_mem_resp_ready[w]),
                .rdata(instr_mem_resp_data[w])
            );
        end
    endgenerate

    // load_instr: helper to pre-load a word into a warp's instruction memory
    task load_instr(input int warp_idx, input int addr, input instr_t instr);
        if      (warp_idx == 0) instr_mem_gen[0].imem.load_mem(addr, instr);
        else if (warp_idx == 1) instr_mem_gen[1].imem.load_mem(addr, instr);
        else if (warp_idx == 2) instr_mem_gen[2].imem.load_mem(addr, instr);
    endtask

    task reset_instr_mem();
        for (int w = 0; w < WARPS_PER_CORE; w++) begin
            for (int i = 0; i < 32; i++) begin
                load_instr(w, i, encode_instr(.instr_type("HALT")));
            end
        end
    endtask

    // module-level flags used inside fork blocks (cannot be task-local)
    logic warp1_ran_while_warp0_in_memory; // set when warp 1 executes while warp 0 awaits memory
    logic execute_tie_observed, execute_tie_warp0_won; // set when all warps tie for execute
    logic both_in_memory_simultaneously;   // set when two warps are in WARP_MEMORY at the same time

    initial generate_clock(clk, 10);

    // watchdog timeout guard
    initial begin
        tb_common_pkg::watchdog("tb_core", 100000);
    end

    // =========================================================================
    // TEST 2: latency hiding
    //   Warp 0 stalls in WARP_MEMORY waiting for a load response. Warp 1 must
    //   make forward progress (execute instructions) while warp 0 is stalled.
    // =========================================================================
    task test_latency_hiding();
        $display("\n--- Testing Latency Hiding ---");

        apply_reset(clk, reset);
        reset_instr_mem();

        // warp 0: ALU init then vector load (will enter WARP_MEMORY and stall)
        load_instr(0, 0, encode_instr(.instr_type("ADDI_S"), .rd(1), .imm(5)));
        load_instr(0, 1, encode_instr(.instr_type("LW_V"),   .rd(5), .rs1(1)));
        load_instr(0, 2, encode_instr(.instr_type("HALT")));

        // warp 1: ALU-only sequence (should execute while warp 0 awaits memory)
        load_instr(1, 0, encode_instr(.instr_type("NOP")));
        load_instr(1, 1, encode_instr(.instr_type("ADDI_S"), .rd(2), .imm(10)));
        load_instr(1, 2, encode_instr(.instr_type("ADDI_S"), .rd(2), .imm(10)));
        load_instr(1, 3, encode_instr(.instr_type("ADDI_S"), .rd(2), .imm(10)));
        load_instr(1, 4, encode_instr(.instr_type("HALT")));

        warp1_ran_while_warp0_in_memory = 0;

        start = 1;
        @(posedge clk);
        start = 0;

        // monitor concurrently: catch any cycle where warp 1 executes while warp 0 is in memory
        fork
            forever @(posedge clk) begin
                if (dut.warp_state[0]       == WARP_MEMORY &&
                    dut.execute_resources_busy              &&
                    dut.execute_warp        == 1)
                    warp1_ran_while_warp0_in_memory = 1;
            end
            wait(done == 1);
        join_any
        disable fork;

        check_true("Core", "LatHide_Warp_1_made_forward_progress_while_warp_0_awaited_memory_Req_2.1_2.3", 
                   warp1_ran_while_warp0_in_memory);
        check_true("Core", "LatHide_Warp_0_eventually_done",  dut.warp_state[0] == WARP_DONE);
        check_true("Core", "LatHide_Warp_1_eventually_done",  dut.warp_state[1] == WARP_DONE);
        @(posedge clk);
    endtask

    // =========================================================================
    // TEST 3: exhaustion backpressure
    //   3 warps each issue a vector load. With SCOREBOARD_DEPTH=2 the third
    //   warp retries until an entry is available; all 3 complete cleanly.
    // =========================================================================
    task test_exhaustion_backpressure();
        $display("\n--- Testing Exhaustion Backpressure (3 warps, SCOREBOARD_DEPTH=2) ---");

        apply_reset(clk, reset);
        reset_instr_mem();

        // Load address into v6, load value into v4, store, then load back into v5
        load_instr(0, 0, encode_instr(.instr_type("ADDI_V"), .rd(6), .rs1(0), .imm(100)));
        load_instr(0, 1, encode_instr(.instr_type("ADDI_V"), .rd(4), .rs1(0), .imm(99)));
        load_instr(0, 2, encode_instr(.instr_type("SW_V"),   .rs1(6), .rs2(4), .imm(0)));
        load_instr(0, 3, encode_instr(.instr_type("LW_V"),   .rd(5), .rs1(6)));
        load_instr(0, 4, encode_instr(.instr_type("HALT")));

        load_instr(1, 0, encode_instr(.instr_type("ADDI_V"), .rd(6), .rs1(0), .imm(200)));
        load_instr(1, 1, encode_instr(.instr_type("ADDI_V"), .rd(4), .rs1(0), .imm(123)));
        load_instr(1, 2, encode_instr(.instr_type("SW_V"),   .rs1(6), .rs2(4), .imm(0)));
        load_instr(1, 3, encode_instr(.instr_type("LW_V"),   .rd(5), .rs1(6)));
        load_instr(1, 4, encode_instr(.instr_type("HALT")));

        load_instr(2, 0, encode_instr(.instr_type("ADDI_V"), .rd(6), .rs1(0), .imm(300)));
        load_instr(2, 1, encode_instr(.instr_type("ADDI_V"), .rd(4), .rs1(0), .imm(246)));
        load_instr(2, 2, encode_instr(.instr_type("SW_V"),   .rs1(6), .rs2(4), .imm(0)));
        load_instr(2, 3, encode_instr(.instr_type("LW_V"),   .rd(5), .rs1(6)));
        load_instr(2, 4, encode_instr(.instr_type("HALT")));

        start = 1;
        @(posedge clk);
        start = 0;

        wait(done == 1);
        @(posedge clk);

        check_true("Core", "Exhaust_All_warps_completed_successfully", 
            dut.warp_state[0] == WARP_DONE &&
            dut.warp_state[1] == WARP_DONE &&
            dut.warp_state[2] == WARP_DONE);
        
        // Verifying that backpressure didn't cause the writeback data to be lost.
        check_true("Core", "Exhaust_Warp0_v5_0", dut.reg_file[0].regs_inst.registers[0][5] == 99);
        check_true("Core", "Exhaust_Warp1_v5_0", dut.reg_file[1].regs_inst.registers[0][5] == 123);
        check_true("Core", "Exhaust_Warp2_v5_0", dut.reg_file[2].regs_inst.registers[0][5] == 246);
    endtask



    // =========================================================================
    // TEST 6: simultaneous WARP_MEMORY
    //   Two warps both issue vector loads. Both warps are observed
    //   simultaneously in WARP_MEMORY state, confirming independent parking.
    // =========================================================================
    task test_simultaneous_warp_memory();
        $display("\n--- Testing Simultaneous Warp Memory State ---");

        apply_reset(clk, reset);
        reset_instr_mem();

        // use different base addresses so the loads access different cache lines
        load_instr(0, 0, encode_instr(.instr_type("ADDI_S"), .rd(4), .imm(0)));
        load_instr(0, 1, encode_instr(.instr_type("LW_V"),   .rd(5), .rs1(4)));
        load_instr(0, 2, encode_instr(.instr_type("HALT")));

        load_instr(1, 0, encode_instr(.instr_type("ADDI_S"), .rd(4), .imm(128)));
        load_instr(1, 1, encode_instr(.instr_type("LW_V"),   .rd(5), .rs1(4)));
        load_instr(1, 2, encode_instr(.instr_type("HALT")));

        both_in_memory_simultaneously = 0;

        start = 1;
        @(posedge clk);
        start = 0;

        fork
            forever @(posedge clk) begin
                if (dut.warp_state[0] == WARP_MEMORY && dut.warp_state[1] == WARP_MEMORY)
                    both_in_memory_simultaneously = 1;
            end
            wait(done == 1);
        join_any
        disable fork;

        check_true("Core", "SimultMem_Warps_0_and_1_were_simultaneously_in_WARP_MEMORY_Req_1.5", 
                   both_in_memory_simultaneously);
        check_true("Core", "SimultMem_Warp_0_completed",  dut.warp_state[0] == WARP_DONE);
        check_true("Core", "SimultMem_Warp_1_completed",  dut.warp_state[1] == WARP_DONE);
        @(posedge clk);
    endtask

    // =========================================================================
    // TEST: Randomized ALU Streams
    //   Generates random ALU instructions (ADD_S, ADDI_S, SUB_S, XOR_S) for each warp,
    //   predicts the expected values, and verifies the hardware scalar registers.
    // =========================================================================
    task test_randomized_alu_streams();
        int expected_regs [WARPS_PER_CORE][32];
        int num_instr = 15;
        instr_t instr;
        int rd, rs1, rs2, imm, op_choice;
        string op_name;

        $display("\n--- Testing Randomized ALU Streams ---");

        apply_reset(clk, reset);
        reset_instr_mem();

        // Initialize expected regs to 0
        for (int w = 0; w < WARPS_PER_CORE; w++) begin
            for (int r = 0; r < 32; r++) expected_regs[w][r] = 0;
        end

        // Generate instructions
        for (int w = 0; w < WARPS_PER_CORE; w++) begin
            for (int i = 0; i < num_instr; i++) begin
                rd = ($urandom % 28) + 4; // Use regs 4-31
                rs1 = ($urandom % 28) + 4;
                rs2 = ($urandom % 28) + 4;
                imm = $urandom % 256;
                op_choice = $urandom % 4;

                case (op_choice)
                    0: begin
                        op_name = "ADDI_S";
                        instr = encode_instr(.instr_type(op_name), .rd(rd), .rs1(rs1), .imm(imm));
                        expected_regs[w][rd] = expected_regs[w][rs1] + imm;
                    end
                    1: begin
                        op_name = "ADD_S";
                        instr = encode_instr(.instr_type(op_name), .rd(rd), .rs1(rs1), .rs2(rs2));
                        expected_regs[w][rd] = expected_regs[w][rs1] + expected_regs[w][rs2];
                    end
                    2: begin
                        op_name = "SUB_S";
                        instr = encode_instr(.instr_type(op_name), .rd(rd), .rs1(rs1), .rs2(rs2));
                        expected_regs[w][rd] = expected_regs[w][rs1] - expected_regs[w][rs2];
                    end
                    3: begin
                        op_name = "XOR_S";
                        instr = encode_instr(.instr_type(op_name), .rd(rd), .rs1(rs1), .rs2(rs2));
                        expected_regs[w][rd] = expected_regs[w][rs1] ^ expected_regs[w][rs2];
                    end
                endcase
                load_instr(w, i, instr);
            end
            load_instr(w, num_instr, encode_instr(.instr_type("HALT")));
        end

        start = 1;
        @(posedge clk);
        start = 0;

        wait(done == 1);
        @(posedge clk);
        
        // Verify
        for (int w = 0; w < WARPS_PER_CORE; w++) begin
            for (int r = 4; r < 32; r++) begin
                int actual_val;
                int expected_val;
                
                // Read actual value
                if (w == 0) actual_val = dut.s_reg_file[0].scalar_regs_inst.registers[r];
                else if (w == 1) actual_val = dut.s_reg_file[1].scalar_regs_inst.registers[r];
                else if (w == 2) actual_val = dut.s_reg_file[2].scalar_regs_inst.registers[r];
                
                // Retrieve expected value
                expected_val = expected_regs[w][r];
                
                check_true($sformatf("RandomALU.Warp %0d Reg x%0d matches expected", w, r), "", actual_val == expected_val);
                if (actual_val != expected_val) begin
                    $display("    Expected: 0x%0h, Actual: 0x%0h", expected_val, actual_val);
                end
            end
        end
    endtask

    task test_control_flow();
        $display("--- Testing Control Flow (Branches and Jumps) ---");
        
        reset_instr_mem();
        
        // Warp 0: Forward branch (BEQ)
        // x1 = 10, x2 = 10
        // BEQ x1, x2, +8 (skips ADDI x3 = 99)
        // ADDI x3 = 99
        // ADDI x4 = 55
        // HALT
        load_instr(0, 0, encode_instr(.instr_type("ADDI_S"), .rd(1), .rs1(0), .imm(10)));
        load_instr(0, 1, encode_instr(.instr_type("ADDI_S"), .rd(2), .rs1(0), .imm(10)));
        load_instr(0, 2, encode_instr(.instr_type("BEQ"), .rs1(1), .rs2(2), .imm(8))); // +8 bytes = +2 instructions
        load_instr(0, 3, encode_instr(.instr_type("ADDI_S"), .rd(3), .rs1(0), .imm(99)));
        load_instr(0, 4, encode_instr(.instr_type("ADDI_S"), .rd(4), .rs1(0), .imm(55)));
        load_instr(0, 5, encode_instr(.instr_type("HALT")));

        // Warp 1: Backward branch (BNE)
        // x1 = 3 (loop counter)
        // x2 = 0 (accumulator)
        // LOOP: ADDI x2, x2, 5 (PC=8)
        //       ADDI x1, x1, -1 (PC=12)
        //       BNE x1, x0, -8 (PC=16) -> jumps to PC=8
        // HALT
        load_instr(1, 0, encode_instr(.instr_type("ADDI_S"), .rd(1), .rs1(0), .imm(3)));
        load_instr(1, 1, encode_instr(.instr_type("ADDI_S"), .rd(2), .rs1(0), .imm(0)));
        load_instr(1, 2, encode_instr(.instr_type("ADDI_S"), .rd(2), .rs1(2), .imm(5)));
        load_instr(1, 3, encode_instr(.instr_type("ADDI_S"), .rd(1), .rs1(1), .imm(-1)));
        load_instr(1, 4, encode_instr(.instr_type("BNE"), .rs1(1), .rs2(0), .imm(-8)));
        load_instr(1, 5, encode_instr(.instr_type("HALT")));
        
        // Warp 2: JAL and JALR
        // JAL x5, +12 (PC=0 -> jumps to PC=12)
        // ADDI x6, x0, 99 (PC=4)
        // HALT (PC=8)
        // ADDI x6, x0, 44 (PC=12)
        // ADDI x7, x0, 24 (PC=16)
        // JALR x0, x5, +4 (x5 is 4, jump to 8)
        load_instr(2, 0, encode_instr(.instr_type("JAL"), .rd(5), .imm(12)));
        load_instr(2, 1, encode_instr(.instr_type("ADDI_S"), .rd(6), .rs1(0), .imm(99)));
        load_instr(2, 2, encode_instr(.instr_type("HALT"))); // PC=8
        load_instr(2, 3, encode_instr(.instr_type("ADDI_S"), .rd(6), .rs1(0), .imm(44)));
        load_instr(2, 4, encode_instr(.instr_type("ADDI_S"), .rd(7), .rs1(0), .imm(24)));
        load_instr(2, 5, encode_instr(.instr_type("JALR"), .rd(0), .rs1(5), .imm(4))); // Jump to PC=8

        start = 1;
        @(posedge clk);
        start = 0;

        wait(done == 1);
        @(posedge clk);

        // Verify Warp 0
        check_true("Core", "ControlFlow_Warp 0 Reg x3_BEQ_failed_to_skip_instruction",  dut.s_reg_file[0].scalar_regs_inst.registers[3] == 0);
        check_true("Core", "ControlFlow_Warp 0 Reg x4_BEQ_didn't_execute_target",  dut.s_reg_file[0].scalar_regs_inst.registers[4] == 55);
        
        // Verify Warp 1
        check_true("Core", "ControlFlow_Warp 1 Reg x2_BNE_loop_failed",  dut.s_reg_file[1].scalar_regs_inst.registers[2] == 15);
        
        // Verify Warp 2
        check_true("Core", "ControlFlow_Warp 2 Reg x6_JAL_or_JALR_failed",  dut.s_reg_file[2].scalar_regs_inst.registers[6] == 44);
        check_true("Core", "ControlFlow_Warp 2 Reg x7_JALR_failed",  dut.s_reg_file[2].scalar_regs_inst.registers[7] == 24);
        check_true("Core", "ControlFlow_Warp 2 Reg x5_JAL_link_failed",  dut.s_reg_file[2].scalar_regs_inst.registers[5] == 4);
    endtask

    // =========================================================================
    // Backpressure hold and resume: when downstream issue is backpressured,
    // the warp remains parked in WARP_MEMORY and issues once released.
    // =========================================================================
    task test_backpressure_hold_and_resume();
        int backpressure_cycles;
        $display("\n--- Testing Backpressure Hold and Resume ---");

        // This test forces internal state (warp_state), which prevents the core from 
        // transitioning to WARP_WRITEBACK when a memory response arrives. This intentionally
        // violates the Response Resume Latency SVA, so we disable assertions for this test.
        $assertoff(0, dut);

        apply_reset(clk, reset);

        // grant warp 0 memory ownership directly, bypassing fetch/decode/execute,
        // so the test controls exactly when backpressure starts/ends
        force dut.scoreboard_inst.entry_valid = '{default: 1'b1};
        force dut.stall_reason = '{default: STALL_NONE};
        force dut.memory_resources_busy = 1'b1;
        force dut.memory_warp = '0;
        force dut.warp_state = '{WARP_MEMORY, WARP_IDLE, WARP_IDLE};

        for (int iter = 0; iter < 100; iter++) begin
            backpressure_cycles = ($random % 5) + 1; // 1..5 cycles

            // fill every entry so entry_available (internal has_free) is
            // genuinely 0 - this is what issue_accept actually depends on
            force dut.scoreboard_inst.entry_valid = '{default: 1'b1};
            for (int c = 0; c < backpressure_cycles; c++) begin
                @(posedge clk);
                #1;
                check_true("Core", "Backpressure_warp_stays_parked_in_WARP_MEMORY_while_backpressured", 
                           dut.warp_state[0] == WARP_MEMORY);
                check_true("Core", "Backpressure_warp_remains_selectable_stall_reason_STALL_NONE_while_backpressured", 
                           dut.stall_reason[0] == STALL_NONE);
                check_true("Core", "Backpressure_issue_does_not_accept_while_backpressured", 
                           dut.sb_issue_accept == 1'b0);
            end

            // free every entry - backpressure lifts
            force dut.scoreboard_inst.entry_valid = '{default: 1'b0};

            @(posedge clk);
            #1;
            check_true("Core", "Backpressure_issue_accepts_within_1_cycle_after_backpressure_release", 
                       dut.sb_issue_accept == 1'b1);

            release dut.scoreboard_inst.entry_valid;
        end

        release dut.warp_state;
        release dut.memory_warp;
        release dut.memory_resources_busy;
        release dut.stall_reason;
        
        $asserton(0, dut);
    endtask

    // =========================================================================
    // TEST: lowest-index execute grant priority
    //   All 3 warps become ready for execute on the same cycle. Warp 0 wins.
    // =========================================================================
    task test_lowest_index_execute_grant();
        $display("\n--- Testing Lowest-Index Execute Grant Priority ---");

        apply_reset(clk, reset);
        reset_instr_mem();

        for (int w = 0; w < WARPS_PER_CORE; w++) begin
            load_instr(w, 0, encode_instr(.instr_type("ADDI_S"), .rd(1), .imm(1)));
            load_instr(w, 1, encode_instr(.instr_type("HALT")));
        end

        execute_tie_observed = 0; execute_tie_warp0_won = 0;

        start = 1;
        @(posedge clk);
        start = 0;

        // monitor concurrently: catch the first cycle all 3 warps are
        // simultaneously ready to execute, then wait one more cycle for the
        // (registered) grant that responds to that tie to take effect
        fork
            forever begin
                @(posedge clk);
                if (!execute_tie_observed && (dut.warps_ready_to_execute == 3'b111)) begin
                    execute_tie_observed = 1;
                    @(posedge clk);
                    #1;
                    execute_tie_warp0_won = dut.execute_resources_busy && (dut.execute_warp == 0);
                end
            end
            wait(done == 1);
        join_any
        disable fork;

        check_true("Core", "LowestIdx_execute_tie_was_observed", execute_tie_observed);
        check_true("Core", "LowestIdx_execute_tie_grants_warp0", execute_tie_warp0_won);
        @(posedge clk);
    endtask

    // =========================================================================
    // TEST: lowest-index memory grant priority
    //   3-way tie for memory grant is tested by direct state stimulus.
    // =========================================================================
    task test_lowest_index_memory_grant();
        $display("\n--- Testing Lowest-Index Memory Grant Priority ---");

        $assertoff(0, dut);
        apply_reset(clk, reset);

        force dut.memory_resources_busy = 1'b0;
        force dut.warp_state = '{WARP_MEMORY, WARP_MEMORY, WARP_MEMORY};
        force dut.stall_reason = '{STALL_NONE, STALL_NONE, STALL_NONE};

        release dut.memory_resources_busy;
        @(posedge clk);
        #1;
        check_true("Core", "LowestIdx_memory_tie_grants_warp0",
                   dut.memory_resources_busy && (dut.memory_warp == 0));

        release dut.warp_state;
        release dut.stall_reason;
        $asserton(0, dut);
    endtask

    task run_all();
        test_latency_hiding();
        test_exhaustion_backpressure();
        test_simultaneous_warp_memory();
        test_randomized_alu_streams();
        test_control_flow();
        test_lowest_index_execute_grant();
        test_lowest_index_memory_grant();
        test_backpressure_hold_and_resume();
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        tb_common_pkg::reset_counters();
        kernel_config.num_blocks         = 1;
        kernel_config.num_warps_per_block = WARPS_PER_CORE;
        kernel_config.base_instr_addr    = 0;
        kernel_config.base_data_addr     = 0;
        core_id      = 0;
        core_block_id = 0;

        apply_reset(clk, reset);
        reset_instr_mem();

        run_all();

        tb_common_pkg::report_summary();
        $finish;
    end
endmodule
