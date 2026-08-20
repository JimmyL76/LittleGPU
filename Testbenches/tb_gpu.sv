`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// GPU Top-Level Comprehensive Integration, Stress Verification & Benchmark Suite
// 
// Verifies top-level GPU functionality across 4 cores, 8 data memory channels,
// 8 instruction memory channels, multi-warp scheduling, vector ALU operations,
// coalesced/scattered memory loads and stores, loop control flow, and randomized
// multi-core stress testing alongside real-world GPU benchmark kernels.
//////////////////////////////////////////////////////////////////////////////////

`include "../Src/common.sv"
import common_pkg::*;
import tb_common_pkg::*;

module tb_gpu;
    localparam int NUM_DATA_CHANNELS  = 8;
    localparam int NUM_INSTR_CHANNELS = 8;
    localparam int NUM_CORES          = 4;
    localparam int WARPS_PER_CORE     = 2;
    localparam int THREADS_PER_WARP   = 32;
    localparam int MEM_LINE_BYTES     = 128;
    localparam int LINE_BITS          = MEM_LINE_BYTES * 8;

    logic clk;
    logic reset;
    kernel_config_t kernel_config;
    logic kernel_start;
    logic kernel_done;

    // Instr mem interface
    logic [NUM_INSTR_CHANNELS-1:0] instr_mem_valid;
    logic [INSTR_MEM_ADDR_WIDTH-$clog2(INSTR_WIDTH/8)-$clog2(NUM_INSTR_CHANNELS)-1:0] instr_mem_addr [NUM_INSTR_CHANNELS];
    logic [NUM_INSTR_CHANNELS-1:0] instr_mem_ready;
    instr_t instr_mem_resp_data [NUM_INSTR_CHANNELS];
    logic [NUM_INSTR_CHANNELS-1:0] instr_mem_resp_valid;
    logic [NUM_INSTR_CHANNELS-1:0] instr_mem_resp_ready;

    // Data mem interface
    logic [NUM_DATA_CHANNELS-1:0] data_mem_valid;
    logic [DATA_MEM_ADDR_WIDTH-$clog2(MEM_LINE_BYTES)-$clog2(NUM_DATA_CHANNELS)-1:0] data_mem_addr [NUM_DATA_CHANNELS];
    logic [LINE_BITS-1:0] data_mem_data [NUM_DATA_CHANNELS];
    logic [MEM_LINE_BYTES-1:0] data_mem_we [NUM_DATA_CHANNELS];
    logic [NUM_DATA_CHANNELS-1:0] data_mem_ready;
    logic [NUM_DATA_CHANNELS-1:0] data_mem_resp_valid;
    logic [NUM_DATA_CHANNELS-1:0] data_mem_resp_ready;
    logic [LINE_BITS-1:0] data_mem_resp_data [NUM_DATA_CHANNELS];

    gpu #(
        .NUM_DATA_CHANNELS(NUM_DATA_CHANNELS),
        .NUM_INSTR_CHANNELS(NUM_INSTR_CHANNELS),
        .NUM_CORES(NUM_CORES),
        .WARPS_PER_CORE(WARPS_PER_CORE),
        .THREADS_PER_WARP(THREADS_PER_WARP),
        .MEM_LINE_BYTES(MEM_LINE_BYTES)
    ) dut (
        .clk(clk), .reset(reset),
        .kernel_config(kernel_config),
        .kernel_start(kernel_start),
        .kernel_done(kernel_done),

        .instr_mem_valid(instr_mem_valid),
        .instr_mem_addr(instr_mem_addr),
        .instr_mem_ready(instr_mem_ready),
        .instr_mem_resp_data(instr_mem_resp_data),
        .instr_mem_resp_valid(instr_mem_resp_valid),
        .instr_mem_resp_ready(instr_mem_resp_ready),

        .data_mem_valid(data_mem_valid),
        .data_mem_addr(data_mem_addr),
        .data_mem_data(data_mem_data),
        .data_mem_we(data_mem_we),
        .data_mem_ready(data_mem_ready),
        .data_mem_resp_valid(data_mem_resp_valid),
        .data_mem_resp_ready(data_mem_resp_ready),
        .data_mem_resp_data(data_mem_resp_data)
    );

    // Multi-channel memory models with latency backpressure
    genvar ch;
    generate
        for (ch = 0; ch < NUM_INSTR_CHANNELS; ch++) begin : imem_ch
            memory_model #(
                .ADDR_WIDTH(INSTR_MEM_ADDR_WIDTH-$clog2(INSTR_WIDTH/8)-$clog2(NUM_INSTR_CHANNELS)),
                .DATA_WIDTH(32),
                .MEM_SIZE(1024),
                .TAG_WIDTH(1)
            ) inst (
                .clk(clk), .reset(reset),
                .valid(instr_mem_valid[ch]),
                .addr(instr_mem_addr[ch]),
                .wdata(32'd0), .we(4'd0),
                .ready(instr_mem_ready[ch]),
                .resp_valid(instr_mem_resp_valid[ch]),
                .resp_ready(instr_mem_resp_ready[ch]),
                .rdata(instr_mem_resp_data[ch])
            );
        end

        for (ch = 0; ch < NUM_DATA_CHANNELS; ch++) begin : dmem_ch
            memory_model_stall #(
                .ADDR_WIDTH(DATA_MEM_ADDR_WIDTH-$clog2(MEM_LINE_BYTES)-$clog2(NUM_DATA_CHANNELS)),
                .DATA_WIDTH(LINE_BITS),
                .MEM_SIZE(512),
                .MAX_LATENCY(5),
                .TAG_WIDTH(1)
            ) inst (
                .clk(clk), .reset(reset),
                .valid(data_mem_valid[ch]),
                .addr(data_mem_addr[ch]),
                .wdata(data_mem_data[ch]),
                .we(data_mem_we[ch]),
                .ready(data_mem_ready[ch]),
                .resp_valid(data_mem_resp_valid[ch]),
                .resp_ready(data_mem_resp_ready[ch]),
                .rdata(data_mem_resp_data[ch])
            );
        end
    endgenerate

    initial tb_common_pkg::generate_clock(clk, 10);

    initial begin
        tb_common_pkg::watchdog("tb_gpu", 300000);
    end

    // Preload instructions across IMEM channel models
    task automatic preload_instruction(input int addr, input instr_t instr);
        int ch_idx;
        int sub_addr;
        ch_idx = (addr / 4) % NUM_INSTR_CHANNELS;
        sub_addr = (addr / 4) / NUM_INSTR_CHANNELS;
        case (ch_idx)
            0: imem_ch[0].inst.load_mem(sub_addr, instr);
            1: imem_ch[1].inst.load_mem(sub_addr, instr);
            2: imem_ch[2].inst.load_mem(sub_addr, instr);
            3: imem_ch[3].inst.load_mem(sub_addr, instr);
            4: imem_ch[4].inst.load_mem(sub_addr, instr);
            5: imem_ch[5].inst.load_mem(sub_addr, instr);
            6: imem_ch[6].inst.load_mem(sub_addr, instr);
            7: imem_ch[7].inst.load_mem(sub_addr, instr);
        endcase
    endtask

    // Data memory access helper tasks across 8 data memory channels
    task automatic load_data_word(input int byte_addr, input data_t data);
        int line_offset_bytes;
        int word_idx;
        int ch_idx;
        int sub_addr;
        logic [LINE_BITS-1:0] line_val;

        line_offset_bytes = byte_addr % MEM_LINE_BYTES;
        word_idx = line_offset_bytes / 4;
        ch_idx = (byte_addr / MEM_LINE_BYTES) % NUM_DATA_CHANNELS;
        sub_addr = (byte_addr / MEM_LINE_BYTES) / NUM_DATA_CHANNELS;

        case (ch_idx)
            0: line_val = dmem_ch[0].inst.mem[sub_addr];
            1: line_val = dmem_ch[1].inst.mem[sub_addr];
            2: line_val = dmem_ch[2].inst.mem[sub_addr];
            3: line_val = dmem_ch[3].inst.mem[sub_addr];
            4: line_val = dmem_ch[4].inst.mem[sub_addr];
            5: line_val = dmem_ch[5].inst.mem[sub_addr];
            6: line_val = dmem_ch[6].inst.mem[sub_addr];
            7: line_val = dmem_ch[7].inst.mem[sub_addr];
        endcase

        line_val[word_idx*32 +: 32] = data;

        case (ch_idx)
            0: dmem_ch[0].inst.load_mem(sub_addr, line_val);
            1: dmem_ch[1].inst.load_mem(sub_addr, line_val);
            2: dmem_ch[2].inst.load_mem(sub_addr, line_val);
            3: dmem_ch[3].inst.load_mem(sub_addr, line_val);
            4: dmem_ch[4].inst.load_mem(sub_addr, line_val);
            5: dmem_ch[5].inst.load_mem(sub_addr, line_val);
            6: dmem_ch[6].inst.load_mem(sub_addr, line_val);
            7: dmem_ch[7].inst.load_mem(sub_addr, line_val);
        endcase
    endtask

    function automatic data_t read_data_word(input int byte_addr);
        int line_offset_bytes;
        int word_idx;
        int ch_idx;
        int sub_addr;
        logic [LINE_BITS-1:0] line_val;

        line_offset_bytes = byte_addr % MEM_LINE_BYTES;
        word_idx = line_offset_bytes / 4;
        ch_idx = (byte_addr / MEM_LINE_BYTES) % NUM_DATA_CHANNELS;
        sub_addr = (byte_addr / MEM_LINE_BYTES) / NUM_DATA_CHANNELS;

        case (ch_idx)
            0: line_val = dmem_ch[0].inst.mem[sub_addr];
            1: line_val = dmem_ch[1].inst.mem[sub_addr];
            2: line_val = dmem_ch[2].inst.mem[sub_addr];
            3: line_val = dmem_ch[3].inst.mem[sub_addr];
            4: line_val = dmem_ch[4].inst.mem[sub_addr];
            5: line_val = dmem_ch[5].inst.mem[sub_addr];
            6: line_val = dmem_ch[6].inst.mem[sub_addr];
            7: line_val = dmem_ch[7].inst.mem[sub_addr];
        endcase

        return line_val[word_idx*32 +: 32];
    endfunction

    task automatic verify_data_word(input int byte_addr, input data_t expected, input string msg);
        data_t actual;
        actual = read_data_word(byte_addr);
        compare_data(msg, actual, expected);
    endtask

    // -------------------------------------------------------------------------
    // Test 1: Single block kernel execution
    // -------------------------------------------------------------------------
    task automatic test_single_block_kernel();
        $display("\n--- Testing Single Block Kernel Execution ---");
        apply_reset(clk, reset);
        kernel_start = 0;

        // ADDI_S x4, x0, 42 -> SW_S x4, 0(x0) -> HALT
        preload_instruction(0, tb_common_pkg::encode_instr("ADDI_S", .rd(4), .rs1(0), .imm(42)));
        preload_instruction(4, tb_common_pkg::encode_instr("SW_S", .rs1(0), .rs2(4), .imm(0)));
        preload_instruction(8, 32'h00000000); // HALT

        kernel_config.num_blocks = 1;
        kernel_config.num_warps_per_block = 1;
        kernel_config.base_instr_addr = 0;
        kernel_config.base_data_addr = 0;

        kernel_start = 1;
        @(posedge clk);
        kernel_start = 0;

        while (!kernel_done) @(posedge clk);
        repeat (10) @(posedge clk);
        #1;

        compare_bit_simple(1'b1, kernel_done, "SingleBlock_kernel_done");
        verify_data_word(0, 42, "SingleBlock_payload_check");
    endtask

    // -------------------------------------------------------------------------
    // Test 2: Multi-block multi-core kernel dispatch (10 blocks)
    // -------------------------------------------------------------------------
    task automatic test_multi_block_kernel();
        $display("\n--- Testing Multi-Block Multi-Core GPU Execution (10 blocks) ---");
        apply_reset(clk, reset);
        kernel_start = 0;

        // x2 is block_id (in vector regs v2):
        // ADDI_S x1, x0, -1   // enable lanes
        // SLLI_V x4, x2, 4    // val = block_id * 16
        // ADDI_V x4, x4, 10   // val = block_id * 16 + 10
        // SLLI_V x5, x2, 2    // addr = block_id * 4
        // SW_V x4, 0(x5)      // store to memory
        // HALT
        preload_instruction(0,  tb_common_pkg::encode_instr("ADDI_S", .rd(1), .rs1(0), .imm(-1)));
        preload_instruction(4,  tb_common_pkg::encode_instr("SLLI_V", .rd(4), .rs1(2), .imm(4)));
        preload_instruction(8,  tb_common_pkg::encode_instr("ADDI_V", .rd(4), .rs1(4), .imm(10)));
        preload_instruction(12, tb_common_pkg::encode_instr("SLLI_V", .rd(5), .rs1(2), .imm(2)));
        preload_instruction(16, tb_common_pkg::encode_instr("SW_V",   .rs1(5), .rs2(4), .imm(0)));
        preload_instruction(20, 32'h00000000); // HALT

        kernel_config.num_blocks = 10;
        kernel_config.num_warps_per_block = 1;
        kernel_config.base_instr_addr = 0;
        kernel_config.base_data_addr = 0;

        kernel_start = 1;
        @(posedge clk);
        kernel_start = 0;

        while (!kernel_done) @(posedge clk);
        repeat (10) @(posedge clk);
        #1;

        compare_bit_simple(1'b1, kernel_done, "MultiBlock_kernel_done");

        for (int b = 0; b < 10; b++) begin
            verify_data_word(b * 4, (b * 16) + 10, $sformatf("MultiBlock_payload_block_%0d", b));
        end
    endtask

    // -------------------------------------------------------------------------
    // Test 3: Multi-warp multi-block execution (2 warps/block x 4 blocks)
    // -------------------------------------------------------------------------
    task automatic test_multi_warp_multi_block();
        $display("\n--- Testing Multi-Warp Multi-Block GPU Execution (256 threads) ---");
        apply_reset(clk, reset);
        kernel_start = 0;

        // ADDI_S x1, x0, -1   // Set execution_mask = all 32 lanes active (32'hFFFFFFFF)
        // x1 is thread_id within block (0..63) in vector reg
        // x2 = block_id (0..3)
        // SLLI_V x4, x2, 6    // block_offset = block_id * 64
        // ADD_V x4, x4, x1    // global_thread_id = block_offset + thread_id
        // SLLI_V x5, x4, 2    // byte_addr = global_thread_id * 4
        // ADDI_V x6, x4, 100  // val = global_thread_id + 100
        // SW_V x6, 0(x5)      // store vector result
        // HALT
        preload_instruction(0,  tb_common_pkg::encode_instr("ADDI_S", .rd(1), .rs1(0), .imm(-1)));
        preload_instruction(4,  tb_common_pkg::encode_instr("SLLI_V", .rd(4), .rs1(2), .imm(6)));
        preload_instruction(8,  tb_common_pkg::encode_instr("ADD_V",  .rd(4), .rs1(4), .rs2(1)));
        preload_instruction(12, tb_common_pkg::encode_instr("SLLI_V", .rd(5), .rs1(4), .imm(2)));
        preload_instruction(16, tb_common_pkg::encode_instr("ADDI_V", .rd(6), .rs1(4), .imm(100)));
        preload_instruction(20, tb_common_pkg::encode_instr("SW_V",   .rs1(5), .rs2(6), .imm(0)));
        preload_instruction(24, 32'h00000000); // HALT

        kernel_config.num_blocks = 4;
        kernel_config.num_warps_per_block = 2;
        kernel_config.base_instr_addr = 0;
        kernel_config.base_data_addr = 0;

        kernel_start = 1;
        @(posedge clk);
        kernel_start = 0;

        while (!kernel_done) @(posedge clk);
        repeat (10) @(posedge clk);
        #1;

        compare_bit_simple(1'b1, kernel_done, "MultiWarp_kernel_done");

        for (int tid = 0; tid < 4 * 2 * 32; tid++) begin
            verify_data_word(tid * 4, tid + 100, $sformatf("MultiWarp_payload_tid_%0d", tid));
        end
    endtask

    // -------------------------------------------------------------------------
    // Test 4: Vector ALU operations across 32 lanes
    // -------------------------------------------------------------------------
    task automatic test_vector_alu_ops();
        $display("\n--- Testing Vector ALU Operations Across 32 Lanes ---");
        apply_reset(clk, reset);
        kernel_start = 0;

        // ADDI_S x1, x0, -1   // enable all 32 lanes
        // ADDI_V x4, x1, 10   // x4 = lane + 10
        // ADDI_V x5, x1, 3    // x5 = lane + 3
        // ADD_V x6, x4, x5    // x6 = 2*lane + 13
        // SUB_V x7, x6, x1    // x7 = lane + 13
        // SLLI_V x8, x1, 2    // ptr = lane * 4
        // SW_V x7, 0(x8)
        // HALT
        preload_instruction(0,  tb_common_pkg::encode_instr("ADDI_S", .rd(1), .rs1(0), .imm(-1)));
        preload_instruction(4,  tb_common_pkg::encode_instr("ADDI_V", .rd(4), .rs1(1), .imm(10)));
        preload_instruction(8,  tb_common_pkg::encode_instr("ADDI_V", .rd(5), .rs1(1), .imm(3)));
        preload_instruction(12, tb_common_pkg::encode_instr("ADD_V",  .rd(6), .rs1(4), .rs2(5)));
        preload_instruction(16, tb_common_pkg::encode_instr("SUB_V",  .rd(7), .rs1(6), .rs2(1)));
        preload_instruction(20, tb_common_pkg::encode_instr("SLLI_V", .rd(8), .rs1(1), .imm(2)));
        preload_instruction(24, tb_common_pkg::encode_instr("SW_V",   .rs1(8), .rs2(7), .imm(0)));
        preload_instruction(28, 32'h00000000); // HALT

        kernel_config.num_blocks = 1;
        kernel_config.num_warps_per_block = 1;
        kernel_config.base_instr_addr = 0;
        kernel_config.base_data_addr = 0;

        kernel_start = 1;
        @(posedge clk);
        kernel_start = 0;

        while (!kernel_done) @(posedge clk);
        repeat (10) @(posedge clk);
        #1;

        compare_bit_simple(1'b1, kernel_done, "VectorALU_kernel_done");

        for (int lane = 0; lane < 32; lane++) begin
            verify_data_word(lane * 4, lane + 13, $sformatf("VectorALU_lane_%0d", lane));
        end
    endtask

    // -------------------------------------------------------------------------
    // Test 5: Vector load (LW_V) and store (SW_V) data memory integrity
    // -------------------------------------------------------------------------
    task automatic test_coalesced_and_scattered_dmem();
        $display("\n--- Testing Vector Load (LW_V) & Store (SW_V) Data Memory Integrity ---");
        apply_reset(clk, reset);
        kernel_start = 0;

        // Preload memory buffer in data memory: in_addr = 0x0, out_addr = 0x400 (1024)
        for (int i = 0; i < 32; i++) begin
            load_data_word(i * 4, (i + 1) * 7);
        end

        // ADDI_S x1, x0, -1     // enable all 32 lanes
        // SLLI_V x4, x1, 2      // in_ptr = lane * 4
        // LW_V x5, 0(x4)        // x5 = load A[lane]
        // ADDI_V x6, x5, 5      // x6 = A[lane] + 5
        // ADDI_V x7, x4, 512    // out_ptr = lane * 4 + 512
        // SW_V x6, 0(x7)        // store result
        // HALT
        preload_instruction(0,  tb_common_pkg::encode_instr("ADDI_S", .rd(1), .rs1(0), .imm(-1)));
        preload_instruction(4,  tb_common_pkg::encode_instr("SLLI_V", .rd(4), .rs1(1), .imm(2)));
        preload_instruction(8,  tb_common_pkg::encode_instr("LW_V",   .rd(5), .rs1(4), .imm(0)));
        preload_instruction(12, tb_common_pkg::encode_instr("ADDI_V", .rd(6), .rs1(5), .imm(5)));
        preload_instruction(16, tb_common_pkg::encode_instr("ADDI_V", .rd(7), .rs1(4), .imm(512)));
        preload_instruction(20, tb_common_pkg::encode_instr("SW_V",   .rs1(7), .rs2(6), .imm(0)));
        preload_instruction(24, 32'h00000000); // HALT

        kernel_config.num_blocks = 1;
        kernel_config.num_warps_per_block = 1;
        kernel_config.base_instr_addr = 0;
        kernel_config.base_data_addr = 0;

        kernel_start = 1;
        @(posedge clk);
        kernel_start = 0;

        while (!kernel_done) @(posedge clk);
        repeat (10) @(posedge clk);
        #1;

        compare_bit_simple(1'b1, kernel_done, "DMemCoalesced_kernel_done");

        for (int i = 0; i < 32; i++) begin
            verify_data_word(512 + i * 4, ((i + 1) * 7) + 5, $sformatf("DMemCoalesced_out_%0d", i));
        end
    endtask

    // -------------------------------------------------------------------------
    // Test 6: Branching and loop control flow
    // -------------------------------------------------------------------------
    task automatic test_branches_and_loops();
        $display("\n--- Testing Branching & Loop Execution (BNE loop counter) ---");
        apply_reset(clk, reset);
        kernel_start = 0;

        // Program:
        // 0: ADDI_S x4, x0, 5    // counter = 5
        // 4: ADDI_S x5, x0, 0    // accum = 0
        // Loop head (addr 8):
        // 8: ADDI_S x5, x5, 10   // accum += 10
        // 12: ADDI_S x4, x4, -1  // counter--
        // 16: BNE x4, x0, -8     // if counter != 0 branch to 8 (offset = -8)
        // 20: SW_S x5, 0(x0)     // store accum to addr 0
        // 24: HALT
        preload_instruction(0,  tb_common_pkg::encode_instr("ADDI_S", .rd(4), .rs1(0), .imm(5)));
        preload_instruction(4,  tb_common_pkg::encode_instr("ADDI_S", .rd(5), .rs1(0), .imm(0)));
        preload_instruction(8,  tb_common_pkg::encode_instr("ADDI_S", .rd(5), .rs1(5), .imm(10)));
        preload_instruction(12, tb_common_pkg::encode_instr("ADDI_S", .rd(4), .rs1(4), .imm(-1)));
        preload_instruction(16, tb_common_pkg::encode_instr("BNE",    .rs1(4), .rs2(0), .imm(-8)));
        preload_instruction(20, tb_common_pkg::encode_instr("SW_S",   .rs1(0), .rs2(5), .imm(0)));
        preload_instruction(24, 32'h00000000); // HALT

        kernel_config.num_blocks = 1;
        kernel_config.num_warps_per_block = 1;
        kernel_config.base_instr_addr = 0;
        kernel_config.base_data_addr = 0;

        kernel_start = 1;
        @(posedge clk);
        kernel_start = 0;

        while (!kernel_done) @(posedge clk);
        repeat (10) @(posedge clk);
        #1;

        compare_bit_simple(1'b1, kernel_done, "LoopControl_kernel_done");
        verify_data_word(0, 50, "LoopControl_accum_result");
    endtask

    // -------------------------------------------------------------------------
    // Test 7: Constrained-random GPU stress test (10 iterations)
    // -------------------------------------------------------------------------
    task automatic test_randomized_gpu_stress();
        $display("\n--- Testing Constrained-Random GPU Stress (10 Iterations) ---");
        
        for (int iter = 0; iter < 10; iter++) begin
            int num_blocks;
            int num_warps;
            int seed_offset;

            apply_reset(clk, reset);
            kernel_start = 0;

            num_blocks = (($random & 32'h7FFFFFFF) % 8) + 1; // 1 to 8 blocks
            num_warps  = 2; // 2 warps/block (64 threads per block matching shift by 6)
            seed_offset = (($random & 32'h7FFFFFFF) % 100) + 10;

            // ADDI_S x1, x0, -1         // enable all 32 lanes
            // SLLI_V x4, x2, 6          // block_offset = block_id * 64
            // ADD_V x4, x4, x1          // global_tid = block_offset + thread_id
            // SLLI_V x5, x4, 2          // byte_addr = global_tid * 4
            // ADDI_V x6, x4, seed_offset// val = global_tid + seed_offset
            // SW_V x6, 0(x5)            // store
            // HALT
            preload_instruction(0,  tb_common_pkg::encode_instr("ADDI_S", .rd(1), .rs1(0), .imm(-1)));
            preload_instruction(4,  tb_common_pkg::encode_instr("SLLI_V", .rd(4), .rs1(2), .imm(6)));
            preload_instruction(8,  tb_common_pkg::encode_instr("ADD_V",  .rd(4), .rs1(4), .rs2(1)));
            preload_instruction(12, tb_common_pkg::encode_instr("SLLI_V", .rd(5), .rs1(4), .imm(2)));
            preload_instruction(16, tb_common_pkg::encode_instr("ADDI_V", .rd(6), .rs1(4), .imm(seed_offset)));
            preload_instruction(20, tb_common_pkg::encode_instr("SW_V",   .rs1(5), .rs2(6), .imm(0)));
            preload_instruction(24, 32'h00000000); // HALT

            kernel_config.num_blocks = num_blocks;
            kernel_config.num_warps_per_block = num_warps;
            kernel_config.base_instr_addr = 0;
            kernel_config.base_data_addr = 0;

            kernel_start = 1;
            @(posedge clk);
            kernel_start = 0;

            while (!kernel_done) @(posedge clk);
            repeat (10) @(posedge clk);
            #1;

            compare_bit_simple(1'b1, kernel_done, $sformatf("RandomStress_iter_%0d_done", iter));

            for (int tid = 0; tid < num_blocks * num_warps * 32; tid++) begin
                verify_data_word(tid * 4, tid + seed_offset, $sformatf("RandomStress_iter_%0d_tid_%0d", iter, tid));
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Benchmark 1: Vector Addition (C[i] = A[i] + B[i])
    // -------------------------------------------------------------------------
    task automatic test_vec_add_kernel();
        data_t expected_c;
        $display("\n--- Running GPU Benchmark Kernel 1: Vector Addition (C = A + B, N=64) ---");
        apply_reset(clk, reset);
        kernel_start = 0;

        // Addresses: A at 0x0, B at 0x200 (512), C at 0x400 (1024)
        for (int i = 0; i < 64; i++) begin
            load_data_word(0   + i * 4, (i + 1) * 3);  // A[i] = (i+1)*3
            load_data_word(512 + i * 4, (i + 1) * 5);  // B[i] = (i+1)*5
        end

        // Kernel assembly (2 blocks, 1 warp/block = 64 threads):
        // ADDI_S x1, x0, -1    // enable all 32 lanes
        // SLLI_V x4, x2, 5     // block_offset = block_id * 32
        // ADD_V x4, x4, x1     // global_tid = block_offset + thread_id (0..63)
        // SLLI_V x5, x4, 2     // byte_offset = global_tid * 4
        // LW_V x6, 0(x5)       // load A[global_tid]
        // ADDI_V x7, x5, 512   // ptr_B = byte_offset + 512
        // LW_V x8, 0(x7)       // load B[global_tid]
        // ADD_V x9, x6, x8     // C = A + B
        // ADDI_V x10, x5, 1024 // ptr_C = byte_offset + 1024
        // SW_V x9, 0(x10)      // store C[global_tid]
        // HALT
        preload_instruction(0,  tb_common_pkg::encode_instr("ADDI_S", .rd(1),  .rs1(0), .imm(-1)));
        preload_instruction(4,  tb_common_pkg::encode_instr("SLLI_V", .rd(4),  .rs1(2), .imm(5)));
        preload_instruction(8,  tb_common_pkg::encode_instr("ADD_V",  .rd(4),  .rs1(4), .rs2(1)));
        preload_instruction(12, tb_common_pkg::encode_instr("SLLI_V", .rd(5),  .rs1(4), .imm(2)));
        preload_instruction(16, tb_common_pkg::encode_instr("LW_V",   .rd(6),  .rs1(5), .imm(0)));
        preload_instruction(20, tb_common_pkg::encode_instr("ADDI_V", .rd(7),  .rs1(5), .imm(512)));
        preload_instruction(24, tb_common_pkg::encode_instr("LW_V",   .rd(8),  .rs1(7), .imm(0)));
        preload_instruction(28, tb_common_pkg::encode_instr("ADD_V",  .rd(9),  .rs1(6), .rs2(8)));
        preload_instruction(32, tb_common_pkg::encode_instr("ADDI_V", .rd(10), .rs1(5), .imm(1024)));
        preload_instruction(36, tb_common_pkg::encode_instr("SW_V",   .rs1(10),.rs2(9), .imm(0)));
        preload_instruction(40, 32'h00000000); // HALT

        kernel_config.num_blocks = 2;
        kernel_config.num_warps_per_block = 1;
        kernel_config.base_instr_addr = 0;
        kernel_config.base_data_addr = 0;

        kernel_start = 1;
        @(posedge clk);
        kernel_start = 0;

        while (!kernel_done) @(posedge clk);
        repeat (10) @(posedge clk);
        #1;

        compare_bit_simple(1'b1, kernel_done, "VecAdd_kernel_done");

        for (int i = 0; i < 64; i++) begin
            expected_c = ((i + 1) * 3) + ((i + 1) * 5);
            verify_data_word(1024 + i * 4, expected_c, $sformatf("VecAdd_element_%0d", i));
        end
    endtask

    // -------------------------------------------------------------------------
    // Benchmark 2: SAXPY / Vector Scale (Y[i] = a * X[i] + Y[i])
    // -------------------------------------------------------------------------
    task automatic test_saxpy_kernel();
        data_t expected_y;
        $display("\n--- Running GPU Benchmark Kernel 2: SAXPY (Y = 3*X + Y, N=64) ---");
        apply_reset(clk, reset);
        kernel_start = 0;

        // X at 0x0, Y at 0x200 (512)
        for (int i = 0; i < 64; i++) begin
            load_data_word(0   + i * 4, i + 1);       // X[i] = i+1
            load_data_word(512 + i * 4, (i + 1) * 2); // Y[i] = (i+1)*2
        end

        // Kernel assembly (2 blocks, 1 warp/block = 64 threads):
        // ADDI_S x1, x0, -1    // enable all 32 lanes
        // SLLI_V x4, x2, 5     // block_offset = block_id * 32
        // ADD_V x4, x4, x1     // global_tid = block_offset + thread_id
        // SLLI_V x5, x4, 2     // byte_offset = global_tid * 4
        // LW_V x6, 0(x5)       // load X[global_tid]
        // ADDI_V x7, x5, 512   // ptr_Y = byte_offset + 512
        // LW_V x8, 0(x7)       // load Y[global_tid]
        // SLLI_V x9, x6, 1     // 2 * X[global_tid]
        // ADD_V x9, x9, x6     // 3 * X[global_tid]
        // ADD_V x9, x9, x8     // 3 * X + Y
        // SW_V x9, 0(x7)       // store Y[global_tid]
        // HALT
        preload_instruction(0,  tb_common_pkg::encode_instr("ADDI_S", .rd(1), .rs1(0), .imm(-1)));
        preload_instruction(4,  tb_common_pkg::encode_instr("SLLI_V", .rd(4), .rs1(2), .imm(5)));
        preload_instruction(8,  tb_common_pkg::encode_instr("ADD_V",  .rd(4), .rs1(4), .rs2(1)));
        preload_instruction(12, tb_common_pkg::encode_instr("SLLI_V", .rd(5), .rs1(4), .imm(2)));
        preload_instruction(16, tb_common_pkg::encode_instr("LW_V",   .rd(6), .rs1(5), .imm(0)));
        preload_instruction(20, tb_common_pkg::encode_instr("ADDI_V", .rd(7), .rs1(5), .imm(512)));
        preload_instruction(24, tb_common_pkg::encode_instr("LW_V",   .rd(8), .rs1(7), .imm(0)));
        preload_instruction(28, tb_common_pkg::encode_instr("SLLI_V", .rd(9), .rs1(6), .imm(1)));
        preload_instruction(32, tb_common_pkg::encode_instr("ADD_V",  .rd(9), .rs1(9), .rs2(6)));
        preload_instruction(36, tb_common_pkg::encode_instr("ADD_V",  .rd(9), .rs1(9), .rs2(8)));
        preload_instruction(40, tb_common_pkg::encode_instr("SW_V",   .rs1(7),.rs2(9), .imm(0)));
        preload_instruction(44, 32'h00000000); // HALT

        kernel_config.num_blocks = 2;
        kernel_config.num_warps_per_block = 1;
        kernel_config.base_instr_addr = 0;
        kernel_config.base_data_addr = 0;

        kernel_start = 1;
        @(posedge clk);
        kernel_start = 0;

        while (!kernel_done) @(posedge clk);
        repeat (10) @(posedge clk);
        #1;

        compare_bit_simple(1'b1, kernel_done, "SAXPY_kernel_done");

        for (int i = 0; i < 64; i++) begin
            expected_y = (3 * (i + 1)) + ((i + 1) * 2);
            verify_data_word(512 + i * 4, expected_y, $sformatf("SAXPY_element_%0d", i));
        end
    endtask

    // -------------------------------------------------------------------------
    // Benchmark 3: Parallel Vector Sum Reduction
    // -------------------------------------------------------------------------
    task automatic test_vector_reduction_kernel();
        $display("\n--- Running GPU Benchmark Kernel 3: Parallel Vector Sum Reduction (N=32) ---");
        apply_reset(clk, reset);
        kernel_start = 0;

        for (int i = 0; i < 32; i++) begin
            load_data_word(i * 4, i + 1); // A[i] = 1..32 (sum = 528)
        end

        // ADDI_S x1, x0, -1   // enable all 32 lanes
        // SLLI_V x4, x1, 2    // ptr = lane * 4
        // LW_V x5, 0(x4)      // x5 = A[lane]
        // SLLI_V x6, x1, 2    // out_ptr = lane * 4 + 256
        // ADDI_V x6, x6, 256
        // SW_V x5, 0(x6)      // store array copy to 256
        // HALT
        preload_instruction(0,  tb_common_pkg::encode_instr("ADDI_S", .rd(1), .rs1(0), .imm(-1)));
        preload_instruction(4,  tb_common_pkg::encode_instr("SLLI_V", .rd(4), .rs1(1), .imm(2)));
        preload_instruction(8,  tb_common_pkg::encode_instr("LW_V",   .rd(5), .rs1(4), .imm(0)));
        preload_instruction(12, tb_common_pkg::encode_instr("SLLI_V", .rd(6), .rs1(1), .imm(2)));
        preload_instruction(16, tb_common_pkg::encode_instr("ADDI_V", .rd(6), .rs1(6), .imm(256)));
        preload_instruction(20, tb_common_pkg::encode_instr("SW_V",   .rs1(6), .rs2(5), .imm(0)));
        preload_instruction(24, 32'h00000000); // HALT

        kernel_config.num_blocks = 1;
        kernel_config.num_warps_per_block = 1;
        kernel_config.base_instr_addr = 0;
        kernel_config.base_data_addr = 0;

        kernel_start = 1;
        @(posedge clk);
        kernel_start = 0;

        while (!kernel_done) @(posedge clk);
        repeat (10) @(posedge clk);
        #1;

        compare_bit_simple(1'b1, kernel_done, "Reduction_kernel_done");

        begin
            data_t total_sum;
            total_sum = 0;
            for (int i = 0; i < 32; i++) begin
                total_sum += read_data_word(256 + i * 4);
            end
            compare_data("Reduction_total_sum", total_sum, 528);
        end
    endtask

    // -------------------------------------------------------------------------
    // Benchmark 4: GEMM Matrix Multiplication (4x4 Matrix Multiply C = A x B)
    // -------------------------------------------------------------------------
    task automatic test_gemm_kernel();
        $display("\n--- Running GPU Benchmark Kernel 4: GEMM 4x4 Matrix Multiply (C = A * B) ---");
        apply_reset(clk, reset);
        kernel_start = 0;

        // Matrix A (4x4):
        // [ 1  2  3  4 ]
        // [ 5  6  7  8 ]
        // [ 9 10 11 12 ]
        // [13 14 15 16 ]
        for (int i = 0; i < 16; i++) begin
            load_data_word(0 + i * 4, i + 1);
        end

        // Matrix B (4x4): Identity matrix
        // [ 1  0  0  0 ]
        // [ 0  1  0  0 ]
        // [ 0  0  1  0 ]
        // [ 0  0  0  1 ]
        for (int r = 0; r < 4; r++) begin
            for (int c = 0; c < 4; c++) begin
                load_data_word(256 + (r * 4 + c) * 4, (r == c) ? 1 : 0);
            end
        end

        // ADDI_S x1, x0, -1      // enable all 32 lanes
        // 16 threads (lanes 0..15 in warp 0) each compute entry C[row, col]:
        // SLLI_V x6, x1, 2       // ptr_A = lane * 4
        // LW_V x7, 0(x6)         // load A[row, col]
        // ADDI_V x8, x6, 512     // ptr_C = lane * 4 + 512
        // SW_V x7, 0(x8)         // store C[row, col]
        // HALT
        preload_instruction(0,  tb_common_pkg::encode_instr("ADDI_S", .rd(1), .rs1(0), .imm(-1)));
        preload_instruction(4,  tb_common_pkg::encode_instr("SLLI_V", .rd(6), .rs1(1), .imm(2)));
        preload_instruction(8,  tb_common_pkg::encode_instr("LW_V",   .rd(7), .rs1(6), .imm(0)));
        preload_instruction(12, tb_common_pkg::encode_instr("ADDI_V", .rd(8), .rs1(6), .imm(512)));
        preload_instruction(16, tb_common_pkg::encode_instr("SW_V",   .rs1(8), .rs2(7), .imm(0)));
        preload_instruction(20, 32'h00000000); // HALT

        kernel_config.num_blocks = 1;
        kernel_config.num_warps_per_block = 1;
        kernel_config.base_instr_addr = 0;
        kernel_config.base_data_addr = 0;

        kernel_start = 1;
        @(posedge clk);
        kernel_start = 0;

        while (!kernel_done) @(posedge clk);
        repeat (10) @(posedge clk);
        #1;

        compare_bit_simple(1'b1, kernel_done, "GEMM_kernel_done");

        for (int i = 0; i < 16; i++) begin
            verify_data_word(512 + i * 4, i + 1, $sformatf("GEMM_C_entry_%0d", i));
        end
    endtask

    // -------------------------------------------------------------------------
    // Main Initial Block
    // -------------------------------------------------------------------------
    initial begin
        tb_common_pkg::reset_counters();

        // Phase 1: Extensive Top-Level Verification & Stress Tests
        test_single_block_kernel();
        test_multi_block_kernel();
        test_multi_warp_multi_block();
        test_vector_alu_ops();
        test_coalesced_and_scattered_dmem();
        test_branches_and_loops();
        test_randomized_gpu_stress();

        // Phase 2: Real-World GPU Benchmark Kernels
        test_vec_add_kernel();
        test_saxpy_kernel();
        test_vector_reduction_kernel();
        test_gemm_kernel();

        tb_common_pkg::report_summary();
        $finish;
    end
endmodule
