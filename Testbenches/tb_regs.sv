`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Vector Register File Testbench
// 
// Tests the regs module with comprehensive directed tests:
// - Reset and initialization behavior
// - Register read operations (rs1, rs2)
// - Register write operations with execution mask filtering
// - Special registers (x0=zero, x1=thread_id, x2=block_id, x3=block_size)
// - Data source multiplexing (alu_out, lsu_out, next_pc)
// - Warp enable control
// - Scalar signal filtering
//////////////////////////////////////////////////////////////////////////////////

import common_pkg::*;
import tb_common_pkg::*;

module tb_regs;

    // Parameters
    localparam int THREADS_PER_WARP = 32;
    localparam int REGS_PER_THREAD = 32;
    
    // Clock and reset
    logic clk;
    logic reset;
    
    // DUT inputs
    warp_state_t warp_state;
    logic warp_enable;
    logic [THREADS_PER_WARP-1:0] execution_mask;
    data_t warp_id, block_id, block_size;
    logic [1:0] Scalar;
    logic LdReg;
    logic [1:0] IsBR_J;
    logic DMemEN;
    logic [4:0] RS1Addr, RS2Addr, RDAddr;
    data_t alu_out [THREADS_PER_WARP];
    data_t lsu_out [THREADS_PER_WARP];
    data_t next_pc [THREADS_PER_WARP];
    
    // DUT outputs
    data_t rs1 [THREADS_PER_WARP];
    data_t rs2 [THREADS_PER_WARP];
    
    // Instantiate DUT
    regs #(
        .THREADS_PER_WARP(THREADS_PER_WARP),
        .REGS_PER_THREAD(REGS_PER_THREAD)
    ) dut (
        .clk(clk),
        .reset(reset),
        .warp_state(warp_state),
        .warp_enable(warp_enable),
        .execution_mask(execution_mask),
        .warp_id(warp_id),
        .block_id(block_id),
        .block_size(block_size),
        .Scalar(Scalar),
        .LdReg(LdReg),
        .IsBR_J(IsBR_J),
        .DMemEN(DMemEN),
        .RS1Addr(RS1Addr),
        .RS2Addr(RS2Addr),
        .RDAddr(RDAddr),
        .rs1(rs1),
        .rs2(rs2),
        .alu_out(alu_out),
        .lsu_out(lsu_out),
        .next_pc(next_pc)
    );
    
    // Clock generation (100MHz, 10ns period)
    initial begin
        generate_clock(clk, 10);
    end
    
    // Test stimulus and checking
    initial begin
        $display("========================================");
        $display("Vector Register File Testbench Starting");
        $display("========================================");
        
        // Initialize signals
        warp_state = WARP_IDLE;
        warp_enable = 0;
        execution_mask = '1;  // all threads enabled by default
        warp_id = 0;
        block_id = 0;
        block_size = 0;
        Scalar = 0;
        LdReg = 0;
        IsBR_J = 0;
        DMemEN = 0;
        RS1Addr = 0;
        RS2Addr = 0;
        RDAddr = 0;
        
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            alu_out[t] = 0;
            lsu_out[t] = 0;
            next_pc[t] = 0;
        end
        
        // Apply reset
        apply_reset(clk, reset, 2);
        
        // Run test groups
        test_reset_and_init();
        test_register_reads();
        test_register_writes();
        test_special_registers();
        test_execution_mask();
        test_data_source_mux();
        test_warp_enable_control();
        
        // Report results
        report_summary();
        
        $display("========================================");
        $display("Vector Register File Testbench Complete");
        $display("========================================");
        $finish;
    end
    
    //========================================
    // Test Task: Reset and Initialization
    //========================================
    task test_reset_and_init();
        $display("\n--- Testing Reset and Initialization ---");
        
        // Verify all registers are zero after reset
        warp_enable = 1;
        warp_state = WARP_DECODE;
        Scalar = 0;  // vector mode
        RS1Addr = 5;
        RS2Addr = 10;
        
        @(posedge clk); #1;
        
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            compare_data($sformatf("Reset_Thread%0d_RS1", t), rs1[t], 32'h0);
            compare_data($sformatf("Reset_Thread%0d_RS2", t), rs2[t], 32'h0);
        end
        
        warp_state = WARP_IDLE;
        @(posedge clk); #1;
        
    endtask
    
    //========================================
    // Test Task: Register Read Operations
    //========================================
    task test_register_reads();
        $display("\n--- Testing Register Read Operations ---");
        
        // Write some test values first
        warp_enable = 1;
        warp_state = WARP_WRITEBACK;
        Scalar = 0;
        LdReg = 1;
        RDAddr = 5;
        execution_mask = '1;
        
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            alu_out[t] = 32'hA000_0000 + t;
        end
        
        @(posedge clk); #1;
        
        // Now read back
        warp_state = WARP_DECODE;
        RS1Addr = 5;
        RS2Addr = 5;
        
        @(posedge clk); #1;
        
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            compare_data($sformatf("Read_Thread%0d_RS1", t), rs1[t], 32'hA000_0000 + t);
            compare_data($sformatf("Read_Thread%0d_RS2", t), rs2[t], 32'hA000_0000 + t);
        end
        
        warp_state = WARP_IDLE;
        @(posedge clk); #1;
        
    endtask
    
    //========================================
    // Test Task: Register Write Operations
    //========================================
    task test_register_writes();
        $display("\n--- Testing Register Write Operations ---");
        
        // Test write to register 8
        warp_enable = 1;
        warp_state = WARP_WRITEBACK;
        Scalar = 0;
        LdReg = 1;
        IsBR_J = 0;
        DMemEN = 0;
        RDAddr = 8;
        execution_mask = '1;
        
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            alu_out[t] = 32'hB000_0000 + t;
        end
        
        @(posedge clk); #1;
        
        // Read back
        warp_state = WARP_DECODE;
        RS1Addr = 8;
        
        @(posedge clk); #1;
        
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            compare_data($sformatf("Write_Thread%0d_Reg8", t), rs1[t], 32'hB000_0000 + t);
        end
        
        warp_state = WARP_IDLE;
        @(posedge clk); #1;
        
    endtask
    
    //========================================
    // Test Task: Special Registers
    //========================================
    task test_special_registers();
        $display("\n--- Testing Special Registers ---");
        
        // Set warp/block identifiers
        warp_enable = 1;
        warp_id = 2;
        block_id = 5;
        block_size = 128;
        
        @(posedge clk); #1;
        
        // Read special registers
        warp_state = WARP_DECODE;
        Scalar = 0;
        RS1Addr = 0;  // ZERO_REG
        RS2Addr = 1;  // THREAD_ID_REG
        
        @(posedge clk); #1;
        
        // Check x0 is always zero
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            compare_data($sformatf("SpecialReg_Thread%0d_X0", t), rs1[t], 32'h0);
        end
        
        // Check x1 contains thread_id (warp_id * THREADS_PER_WARP + t)
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            compare_data($sformatf("SpecialReg_Thread%0d_X1_ThreadID", t), rs2[t], 2 * THREADS_PER_WARP + t);
        end
        
        // Read x2 and x3
        RS1Addr = 2;  // BLOCK_ID_REG
        RS2Addr = 3;  // BLOCK_SIZE_REG
        
        @(posedge clk); #1;
        
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            compare_data($sformatf("SpecialReg_Thread%0d_X2_BlockID", t), rs1[t], 5);
            compare_data($sformatf("SpecialReg_Thread%0d_X3_BlockSize", t), rs2[t], 128);
        end
        
        warp_state = WARP_IDLE;
        @(posedge clk); #1;
        
    endtask
    
    //========================================
    // Test Task: Execution Mask Filtering
    //========================================
    task test_execution_mask();
        $display("\n--- Testing Execution Mask Filtering ---");
        
        // Write with partial execution mask (only odd threads)
        warp_enable = 1;
        warp_state = WARP_WRITEBACK;
        Scalar = 0;
        LdReg = 1;
        RDAddr = 12;
        execution_mask = 32'hAAAA_AAAA;  // 10101010... pattern (bit 0=0, bit 1=1, bit 2=0, bit 3=1, ...)
        
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            alu_out[t] = 32'hC000_0000 + t;
        end
        
        @(posedge clk); #1;
        
        // Read back
        warp_state = WARP_DECODE;
        execution_mask = '1;  // enable all for read
        RS1Addr = 12;
        
        @(posedge clk); #1;
        
        // Only odd threads should have been updated (0xAAAA_AAAA has odd bits set)
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            if (t[0] == 1) begin  // odd thread (bit is set in mask)
                compare_data($sformatf("ExecMask_Thread%0d_Updated", t), rs1[t], 32'hC000_0000 + t);
            end else begin  // even thread (bit is clear in mask)
                compare_data($sformatf("ExecMask_Thread%0d_NotUpdated", t), rs1[t], 32'h0);
            end
        end
        
        warp_state = WARP_IDLE;
        @(posedge clk); #1;
        
    endtask
    
    //========================================
    // Test Task: Data Source Multiplexing
    //========================================
    task test_data_source_mux();
        $display("\n--- Testing Data Source Multiplexing ---");
        
        // Test ALU source (default)
        warp_enable = 1;
        warp_state = WARP_WRITEBACK;
        Scalar = 0;
        LdReg = 1;
        IsBR_J = 0;
        DMemEN = 0;
        RDAddr = 15;
        execution_mask = '1;
        
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            alu_out[t] = 32'hD000_0000 + t;
            lsu_out[t] = 32'hE000_0000 + t;
            next_pc[t] = 32'hF000_0000 + t;
        end
        
        @(posedge clk); #1;
        
        warp_state = WARP_DECODE;
        RS1Addr = 15;
        
        @(posedge clk); #1;
        
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            compare_data($sformatf("DataMux_Thread%0d_ALU", t), rs1[t], 32'hD000_0000 + t);
        end
        
        // Test LSU source
        warp_state = WARP_WRITEBACK;
        DMemEN = 1;
        RDAddr = 16;
        
        @(posedge clk); #1;
        
        warp_state = WARP_DECODE;
        RS1Addr = 16;
        
        @(posedge clk); #1;
        
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            compare_data($sformatf("DataMux_Thread%0d_LSU", t), rs1[t], 32'hE000_0000 + t);
        end
        
        // Test next_pc source (IsBR_J=2)
        warp_state = WARP_WRITEBACK;
        IsBR_J = 2;
        DMemEN = 0;
        RDAddr = 17;
        
        @(posedge clk); #1;
        
        warp_state = WARP_DECODE;
        RS1Addr = 17;
        
        @(posedge clk); #1;
        
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            compare_data($sformatf("DataMux_Thread%0d_NextPC", t), rs1[t], 32'hF000_0000 + t);
        end
        
        warp_state = WARP_IDLE;
        @(posedge clk); #1;
        
    endtask
    
    //========================================
    // Test Task: Warp Enable Control
    //========================================
    task test_warp_enable_control();
        $display("\n--- Testing Warp Enable Control ---");
        
        // Try to write with warp_enable=0
        warp_enable = 0;
        warp_state = WARP_WRITEBACK;
        Scalar = 0;
        IsBR_J = 0;
        DMemEN = 0;
        LdReg = 1;
        RDAddr = 20;
        execution_mask = '1;
        
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            alu_out[t] = 32'h9999_9999;
        end
        
        @(posedge clk); #1;
        
        // Try to read with warp_enable=1 (cannot read if 0)
        warp_enable = 1;
        warp_state = WARP_DECODE;
        RS1Addr = 20;
        
        @(posedge clk); #1;
        
        // Should still be zero (not written)
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            compare_data($sformatf("WarpDisable_Thread%0d_NoWrite", t), rs1[t], 32'h0);
        end
        
        // Now write
        warp_state = WARP_WRITEBACK;
        
        @(posedge clk); #1;
        
        warp_state = WARP_DECODE;
        
        @(posedge clk); #1;
        
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            compare_data($sformatf("WarpEnable_Thread%0d_Write", t), rs1[t], 32'h9999_9999);
        end
        
        warp_state = WARP_IDLE;
        @(posedge clk); #1;
        
    endtask
    
endmodule

