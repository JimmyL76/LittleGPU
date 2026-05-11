`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Scalar Register File Testbench
// 
// Tests the scalar_regs module with comprehensive directed tests:
// - Reset and initialization behavior
// - Scalar register read operations (rs1, rs2)
// - Scalar register write operations
// - Special registers (s0=zero, s1=execution_mask)
// - Data source multiplexing (alu_out, lsu_out, next_pc, v_to_s_value)
// - Execution mask output verification
// - Warp enable control
// - Scalar signal filtering
//////////////////////////////////////////////////////////////////////////////////

import common_pkg::*;
import tb_common_pkg::*;

module tb_scalar_regs;

    // Parameters
    localparam int SCALAR_REGS_PER_WARP = 32;
    
    // Clock and reset
    logic clk;
    logic reset;
    
    // DUT inputs
    warp_state_t warp_state;
    logic warp_enable;
    logic [1:0] Scalar;
    logic LdReg;
    logic [1:0] IsBR_J;
    logic DMemEN;
    logic [4:0] RS1Addr, RS2Addr, RDAddr;
    data_t alu_out, lsu_out, next_pc, v_to_s_value;
    
    // DUT outputs
    data_t execution_mask;
    data_t rs1, rs2;
    
    // Instantiate DUT
    scalar_regs #(
        .SCALAR_REGS_PER_WARP(SCALAR_REGS_PER_WARP)
    ) dut (
        .clk(clk),
        .reset(reset),
        .warp_state(warp_state),
        .warp_enable(warp_enable),
        .execution_mask(execution_mask),
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
        .next_pc(next_pc),
        .v_to_s_value(v_to_s_value)
    );
    
    // Clock generation (100MHz, 10ns period)
    initial begin
        generate_clock(clk, 10);
    end
    
    // Waveform dumping
    initial begin
        $dumpfile("tb_scalar_regs.vcd");
        $dumpvars(0, tb_scalar_regs);
    end
    
    // Test stimulus and checking
    initial begin
        $display("========================================");
        $display("Scalar Register File Testbench Starting");
        $display("========================================");
        
        // Initialize signals
        warp_state = WARP_IDLE;
        warp_enable = 0;
        Scalar = 0;
        LdReg = 0;
        IsBR_J = 0;
        DMemEN = 0;
        RS1Addr = 0;
        RS2Addr = 0;
        RDAddr = 0;
        alu_out = 0;
        lsu_out = 0;
        next_pc = 0;
        v_to_s_value = 0;
        
        // Apply reset
        apply_reset(clk, reset, 2);
        
        // Run test groups
        test_reset_and_init();
        test_scalar_register_reads();
        test_scalar_register_writes();
        test_special_registers();
        test_execution_mask_register();
        test_data_source_mux();
        test_warp_enable_control();
        test_scalar_filtering();
        
        // Report results
        report_summary();
        
        $display("========================================");
        $display("Scalar Register File Testbench Complete");
        $display("========================================");
        $finish;
    end
    
    //========================================
    // Test Task: Reset and Initialization
    //========================================
    task test_reset_and_init();
        $display("\n--- Testing Reset and Initialization ---");
        
        // Verify s0 is zero and s1 is initialized to 1 after reset
        warp_enable = 1;
        warp_state = WARP_DECODE;
        Scalar = 1;  // scalar mode
        RS1Addr = 0;  // s0 (ZERO_REG)
        RS2Addr = 1;  // s1 (EXEC_MASK_REG)
        
        @(posedge clk); #1;
        
        compare_data("Reset_S0_Zero", rs1, 32'h0000_0000);
        compare_data("Reset_S1_InitOne", rs2, 32'h0000_0001);
        compare_data("Reset_ExecMask_InitOne", execution_mask, 32'h0000_0001);
        
        // Verify other registers are zero
        RS1Addr = 5;
        RS2Addr = 10;
        
        @(posedge clk); #1;
        
        compare_data("Reset_S5_Zero", rs1, 32'h0);
        compare_data("Reset_S10_Zero", rs2, 32'h0);
        
        warp_state = WARP_IDLE;
        @(posedge clk); #1;
        
    endtask
    
    //========================================
    // Test Task: Scalar Register Read Operations
    //========================================
    task test_scalar_register_reads();
        $display("\n--- Testing Scalar Register Read Operations ---");
        
        // Write some test values first
        warp_enable = 1;
        warp_state = WARP_WRITEBACK;
        Scalar = 1;  // scalar mode
        LdReg = 1;
        IsBR_J = 0;
        DMemEN = 0;
        RDAddr = 5;
        alu_out = 32'hA5A5_A5A5;
        
        @(posedge clk); #1;
        
        // Write another value
        RDAddr = 7;
        alu_out = 32'h5A5A_5A5A;
        
        @(posedge clk); #1;
        
        // Now read back with Scalar=1
        warp_state = WARP_DECODE;
        Scalar = 1;
        RS1Addr = 5;
        RS2Addr = 7;
        
        @(posedge clk); #1;
        
        compare_data("ScalarRead_S5", rs1, 32'hA5A5_A5A5);
        compare_data("ScalarRead_S7", rs2, 32'h5A5A_5A5A);
        
        warp_state = WARP_IDLE;
        @(posedge clk); #1;
        
    endtask
    
    //========================================
    // Test Task: Scalar Register Write Operations
    //========================================
    task test_scalar_register_writes();
        $display("\n--- Testing Scalar Register Write Operations ---");
        
        // Test write to register s8 with Scalar=1
        warp_enable = 1;
        warp_state = WARP_WRITEBACK;
        Scalar = 1;
        LdReg = 1;
        IsBR_J = 0;
        DMemEN = 0;
        RDAddr = 8;
        alu_out = 32'hBEEF_CAFE;
        
        @(posedge clk); #1;
        
        // Read back
        warp_state = WARP_DECODE;
        Scalar = 1;
        RS1Addr = 8;
        
        @(posedge clk); #1;
        
        compare_data("ScalarWrite_S8", rs1, 32'hBEEF_CAFE);
        
        // Test write with Scalar=2 (vector-to-scalar)
        warp_state = WARP_WRITEBACK;
        Scalar = 2;
        LdReg = 1;
        RDAddr = 9;
        v_to_s_value = 32'hDEAD_BEEF;
        
        @(posedge clk); #1;
        
        // Read back
        warp_state = WARP_DECODE;
        Scalar = 1;
        RS1Addr = 9;
        
        @(posedge clk); #1;
        
        compare_data("ScalarWrite_S9_VtoS", rs1, 32'hDEAD_BEEF);
        
        warp_state = WARP_IDLE;
        @(posedge clk); #1;
        
    endtask
    
    //========================================
    // Test Task: Special Registers
    //========================================
    task test_special_registers();
        $display("\n--- Testing Special Registers ---");
        
        // Test s0 (ZERO_REG) - should always read zero
        warp_enable = 1;
        warp_state = WARP_DECODE;
        Scalar = 1;
        RS1Addr = 0;
        
        @(posedge clk); #1;
        
        compare_data("SpecialReg_S0_Zero", rs1, 32'h0);
        
        // Try to write to s0 (should not change)
        warp_state = WARP_WRITEBACK;
        Scalar = 1;
        LdReg = 1;
        RDAddr = 0;
        alu_out = 32'hFFFF_FFFF;
        
        @(posedge clk); #1;
        
        // Read back s0 - should still be zero
        warp_state = WARP_DECODE;
        RS1Addr = 0;
        
        @(posedge clk); #1;
        
        compare_data("SpecialReg_S0_CannotWrite", rs1, 32'h0);
        
        warp_state = WARP_IDLE;
        @(posedge clk); #1;
        
    endtask
    
    //========================================
    // Test Task: Execution Mask Register (s1)
    //========================================
    task test_execution_mask_register();
        $display("\n--- Testing Execution Mask Register (s1) ---");
        
        // Write various patterns to s1
        warp_enable = 1;
        warp_state = WARP_WRITEBACK;
        Scalar = 1;
        LdReg = 1;
        RDAddr = 1;  // s1 (EXEC_MASK_REG)
        alu_out = 32'hAAAA_AAAA;  // 10101010... pattern
        
        @(posedge clk); #1;
        
        // Verify execution_mask output reflects s1
        compare_data("ExecMask_Pattern1", execution_mask, 32'hAAAA_AAAA);
        
        // Write another pattern
        alu_out = 32'h5555_5555;  // 01010101... pattern
        
        @(posedge clk); #1;
        
        compare_data("ExecMask_Pattern2", execution_mask, 32'h5555_5555);
        
        // Write all zeros
        alu_out = 32'h0000_0000;
        
        @(posedge clk); #1;
        
        compare_data("ExecMask_AllZeros", execution_mask, 32'h0000_0000);
        
        // Write all ones
        alu_out = 32'hFFFF_FFFF;
        
        @(posedge clk); #1;
        
        compare_data("ExecMask_AllOnes", execution_mask, 32'hFFFF_FFFF);
        
        // Write specific pattern (first 16 threads active)
        alu_out = 32'h0000_FFFF;
        
        @(posedge clk); #1;
        
        compare_data("ExecMask_First16", execution_mask, 32'h0000_FFFF);
        
        // Read s1 to verify it matches execution_mask
        warp_state = WARP_DECODE;
        Scalar = 1;
        RS1Addr = 1;
        
        @(posedge clk); #1;
        
        compare_data("ExecMask_S1_Matches", rs1, 32'h0000_FFFF);
        
        warp_state = WARP_IDLE;
        @(posedge clk); #1;
        
    endtask
    
    //========================================
    // Test Task: Data Source Multiplexing
    //========================================
    task test_data_source_mux();
        $display("\n--- Testing Data Source Multiplexing ---");
        
        // Test ALU source (default: DMemEN=0, IsBR_J!=2, Scalar!=2)
        warp_enable = 1;
        warp_state = WARP_WRITEBACK;
        Scalar = 1;
        LdReg = 1;
        IsBR_J = 0;
        DMemEN = 0;
        RDAddr = 10;
        alu_out = 32'h1111_1111;
        lsu_out = 32'h2222_2222;
        next_pc = 32'h3333_3333;
        v_to_s_value = 32'h4444_4444;
        
        @(posedge clk); #1;
        
        warp_state = WARP_DECODE;
        RS1Addr = 10;
        
        @(posedge clk); #1;
        
        compare_data("DataMux_ALU", rs1, 32'h1111_1111);
        
        // Test LSU source (DMemEN=1)
        warp_state = WARP_WRITEBACK;
        DMemEN = 1;
        RDAddr = 11;
        
        @(posedge clk); #1;
        
        warp_state = WARP_DECODE;
        RS1Addr = 11;
        
        @(posedge clk); #1;
        
        compare_data("DataMux_LSU", rs1, 32'h2222_2222);
        
        // Test next_pc source (IsBR_J=2)
        warp_state = WARP_WRITEBACK;
        IsBR_J = 2;
        DMemEN = 0;
        RDAddr = 12;
        
        @(posedge clk); #1;
        
        warp_state = WARP_DECODE;
        RS1Addr = 12;
        
        @(posedge clk); #1;
        
        compare_data("DataMux_NextPC", rs1, 32'h3333_3333);
        
        // Test v_to_s_value source (Scalar=2)
        warp_state = WARP_WRITEBACK;
        Scalar = 2;
        IsBR_J = 0;
        DMemEN = 0;
        RDAddr = 13;
        
        @(posedge clk); #1;
        
        warp_state = WARP_DECODE;
        Scalar = 1;
        RS1Addr = 13;
        
        @(posedge clk); #1;
        
        compare_data("DataMux_VtoS", rs1, 32'h4444_4444);
        
        // Test priority: IsBR_J=2 takes precedence over DMemEN
        warp_state = WARP_WRITEBACK;
        Scalar = 1;
        IsBR_J = 2;
        DMemEN = 1;
        RDAddr = 14;
        
        @(posedge clk); #1;
        
        warp_state = WARP_DECODE;
        RS1Addr = 14;
        
        @(posedge clk); #1;
        
        compare_data("DataMux_Priority_NextPC", rs1, 32'h3333_3333);
        
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
        Scalar = 1;
        LdReg = 1;
        IsBR_J = 0;
        DMemEN = 0;
        RDAddr = 20;
        alu_out = 32'h9999_9999;
        
        @(posedge clk); #1;
        
        // Try to read with warp_enable=1
        warp_enable = 1;
        warp_state = WARP_DECODE;
        RS1Addr = 20;
        
        @(posedge clk); #1;
        
        // Should still be zero (not written)
        compare_data("WarpDisable_NoWrite", rs1, 32'h0);
        
        // Now write
        warp_state = WARP_WRITEBACK;
        
        @(posedge clk); #1;
        
        warp_state = WARP_DECODE;
        
        @(posedge clk); #1;
        
        compare_data("WarpEnable_Write", rs1, 32'h9999_9999);
        
        warp_state = WARP_IDLE;
        @(posedge clk); #1;
        
    endtask
    
    //========================================
    // Test Task: Scalar Signal Filtering
    //========================================
    task test_scalar_filtering();
        $display("\n--- Testing Scalar Signal Filtering ---");
        
        // Write a value to s15
        warp_enable = 1;
        warp_state = WARP_WRITEBACK;
        Scalar = 1;
        LdReg = 1;
        RDAddr = 15;
        alu_out = 32'h7777_7777;
        
        @(posedge clk); #1;
        
        // Try to read with Scalar=0 (vector mode) - should not read
        warp_state = WARP_DECODE;
        Scalar = 0;
        RS1Addr = 15;
        
        @(posedge clk); #1;
        
        // rs1 should not be updated (will retain previous value or be undefined)
        // We'll just verify that reading with Scalar=1 works
        Scalar = 1;
        
        @(posedge clk); #1;
        
        compare_data("ScalarFilter_Read", rs1, 32'h7777_7777);
        
        // Try to write with Scalar=0 (should not write)
        warp_state = WARP_WRITEBACK;
        Scalar = 0;
        LdReg = 1;
        RDAddr = 16;
        alu_out = 32'h8888_8888;
        
        @(posedge clk); #1;
        
        // Read back - should be zero (not written)
        warp_state = WARP_DECODE;
        Scalar = 1;
        RS1Addr = 16;
        
        @(posedge clk); #1;
        
        compare_data("ScalarFilter_NoWrite", rs1, 32'h0);
        
        warp_state = WARP_IDLE;
        @(posedge clk); #1;
        
    endtask
    
endmodule
