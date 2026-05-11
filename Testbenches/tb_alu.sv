`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// ALU Testbench
// 
// Tests the Arithmetic Logic Unit module with comprehensive directed tests:
// - Arithmetic operations (ADD, SUB)
// - Logical operations (XOR, OR, AND)
// - Shift operations (SLL, SRL, SRA)
// - Comparison operations (SLT, SLTU)
// - Branch comparison logic
// - Mux selection (RS1Mux, RS2Mux)
// - State machine behavior
//////////////////////////////////////////////////////////////////////////////////

import common_pkg::*;
import tb_common_pkg::*;

module tb_alu;

    // Clock and reset
    logic clk;
    logic reset;
    
    // DUT inputs
    instr_mem_addr_t pc;
    data_t rs1, rs2, imm;
    logic [1:0] IsBR_J;
    logic Usign;
    logic RS1Mux;
    logic [1:0] BR;
    logic [3:0] ALUK;
    logic RS2Mux;
    
    // DUT outputs
    data_t alu_out;
    logic pc_jump;
    
    // Instantiate DUT
    alu dut (
        .pc(pc),
        .rs1(rs1),
        .rs2(rs2),
        .imm(imm),
        .IsBR_J(IsBR_J),
        .Usign(Usign),
        .RS1Mux(RS1Mux),
        .BR(BR),
        .ALUK(ALUK),
        .RS2Mux(RS2Mux),
        .alu_out(alu_out),
        .pc_jump(pc_jump)
    );
    
    // Clock generation (100MHz, 10ns period)
    initial begin
        generate_clock(clk, 10);
    end
    
    // Test stimulus and checking
    initial begin
        $display("========================================");
        $display("ALU Testbench Starting");
        $display("========================================");
        
        // Initialize signals
        pc = 0;
        rs1 = 0;
        rs2 = 0;
        imm = 0;
        IsBR_J = 0;
        Usign = 0;
        RS1Mux = 0;
        BR = 0;
        ALUK = 0;
        RS2Mux = 0;
        
        // Apply reset
        apply_reset(clk, reset, 2);
        
        // Run test groups
        test_arithmetic_operations();
        test_logical_operations();
        test_shift_operations();
        test_comparison_operations();
        test_branch_comparisons();
        test_mux_selection();
        test_edge_cases();
        
        // Report results
        report_summary();
        
        $display("========================================");
        $display("ALU Testbench Complete");
        $display("========================================");
        $finish;
    end
    
    //========================================
    // Test Task: Arithmetic Operations
    //========================================
    task test_arithmetic_operations();
        $display("\n--- Testing Arithmetic Operations ---");
        
        RS1Mux = 0;  // Use rs1
        RS2Mux = 0;  // Use rs2
        IsBR_J = 0;  // Not a branch
        
        // Test ADD (ALUK = 0)
        ALUK = 0;
        
        // ADD: Positive + Positive
        rs1 = 32'h00000005;
        rs2 = 32'h00000003;
        @(posedge clk); 
        compare_data("ADD_Positive", alu_out, 32'h00000008);
        
        // ADD: Negative + Negative
        rs1 = 32'hFFFFFFFE;  // -2
        rs2 = 32'hFFFFFFFD;  // -3
        @(posedge clk); 
        compare_data("ADD_Negative", alu_out, 32'hFFFFFFFB);  // -5
        
        // ADD: Positive + Negative
        rs1 = 32'h00000010;  // 16
        rs2 = 32'hFFFFFFF0;  // -16
        @(posedge clk); 
        compare_data("ADD_Mixed_Zero", alu_out, 32'h00000000);
        
        // ADD: Zero + Zero
        rs1 = 32'h00000000;
        rs2 = 32'h00000000;
        @(posedge clk); 
        compare_data("ADD_Zero", alu_out, 32'h00000000);
        
        // Test SUB (ALUK = 1)
        ALUK = 1;
        
        // SUB: Positive - Positive
        rs1 = 32'h00000010;  // 16
        rs2 = 32'h00000005;  // 5
        @(posedge clk); 
        compare_data("SUB_Positive", alu_out, 32'h0000000B);  // 11
        
        // SUB: Negative - Positive
        rs1 = 32'hFFFFFFF0;  // -16
        rs2 = 32'h00000005;  // 5
        @(posedge clk); 
        compare_data("SUB_Negative", alu_out, 32'hFFFFFFEB);  // -21
        
        // SUB: Same values (result = 0)
        rs1 = 32'h12345678;
        rs2 = 32'h12345678;
        @(posedge clk); 
        compare_data("SUB_Same_Zero", alu_out, 32'h00000000);
        
    endtask
    
    //========================================
    // Test Task: Logical Operations
    //========================================
    task test_logical_operations();
        $display("\n--- Testing Logical Operations ---");
        
        RS1Mux = 0;
        RS2Mux = 0;
        IsBR_J = 0;
        
        // Test XOR (ALUK = 2)
        ALUK = 2;
        rs1 = 32'hAAAAAAAA;
        rs2 = 32'h55555555;
        @(posedge clk); 
        compare_data("XOR_Alternating", alu_out, 32'hFFFFFFFF);
        
        rs1 = 32'hF0F0F0F0;
        rs2 = 32'h0F0F0F0F;
        @(posedge clk); 
        compare_data("XOR_Nibbles", alu_out, 32'hFFFFFFFF);
        
        rs1 = 32'h12345678;
        rs2 = 32'h00000000;
        @(posedge clk); 
        compare_data("XOR_With_Zero", alu_out, 32'h12345678);
        
        // Test OR (ALUK = 3)
        ALUK = 3;
        rs1 = 32'hAAAAAAAA;
        rs2 = 32'h55555555;
        @(posedge clk); 
        compare_data("OR_Alternating", alu_out, 32'hFFFFFFFF);
        
        rs1 = 32'h0000FFFF;
        rs2 = 32'hFFFF0000;
        @(posedge clk); 
        compare_data("OR_Halves", alu_out, 32'hFFFFFFFF);
        
        rs1 = 32'h00000000;
        rs2 = 32'h00000000;
        @(posedge clk); 
        compare_data("OR_Zeros", alu_out, 32'h00000000);
        
        // Test AND (ALUK = 4)
        ALUK = 4;
        rs1 = 32'hAAAAAAAA;
        rs2 = 32'h55555555;
        @(posedge clk); 
        compare_data("AND_Alternating", alu_out, 32'h00000000);
        
        rs1 = 32'hFFFFFFFF;
        rs2 = 32'h12345678;
        @(posedge clk); 
        compare_data("AND_With_Ones", alu_out, 32'h12345678);
        
        rs1 = 32'h0F0F0F0F;
        rs2 = 32'hF0F0F0F0;
        @(posedge clk); 
        compare_data("AND_Nibbles", alu_out, 32'h00000000);
        
    endtask
    
    //========================================
    // Test Task: Shift Operations
    //========================================
    task test_shift_operations();
        $display("\n--- Testing Shift Operations ---");
        
        RS1Mux = 0;
        RS2Mux = 0;
        IsBR_J = 0;
        
        // Test SLL - Shift Left Logical (ALUK = 5)
        ALUK = 5;
        rs1 = 32'h00000001;
        rs2 = 32'h00000000;  // Shift by 0
        @(posedge clk); 
        compare_data("SLL_Shift0", alu_out, 32'h00000001);
        
        rs1 = 32'h00000001;
        rs2 = 32'h00000004;  // Shift by 4
        @(posedge clk); 
        compare_data("SLL_Shift4", alu_out, 32'h00000010);
        
        rs1 = 32'h00000001;
        rs2 = 32'h0000001F;  // Shift by 31
        @(posedge clk); 
        compare_data("SLL_Shift31", alu_out, 32'h80000000);
        
        rs1 = 32'h12345678;
        rs2 = 32'h00000008;  // Shift by 8
        @(posedge clk); 
        compare_data("SLL_Shift8", alu_out, 32'h34567800);
        
        // Test SRL - Shift Right Logical (ALUK = 6)
        ALUK = 6;
        rs1 = 32'h80000000;
        rs2 = 32'h00000000;  // Shift by 0
        @(posedge clk); 
        compare_data("SRL_Shift0", alu_out, 32'h80000000);
        
        rs1 = 32'h80000000;
        rs2 = 32'h00000004;  // Shift by 4
        @(posedge clk); 
        compare_data("SRL_Shift4", alu_out, 32'h08000000);
        
        rs1 = 32'h80000000;
        rs2 = 32'h0000001F;  // Shift by 31
        @(posedge clk); 
        compare_data("SRL_Shift31", alu_out, 32'h00000001);
        
        rs1 = 32'h12345678;
        rs2 = 32'h00000008;  // Shift by 8
        @(posedge clk); 
        compare_data("SRL_Shift8", alu_out, 32'h00123456);
        
        // Test SRA - Shift Right Arithmetic (ALUK = 7)
        ALUK = 7;
        rs1 = 32'h80000000;  // Negative number
        rs2 = 32'h00000004;  // Shift by 4
        @(posedge clk); 
        compare_data("SRA_Negative_Shift4", alu_out, 32'hF8000000);
        
        rs1 = 32'h80000000;
        rs2 = 32'h0000001F;  // Shift by 31
        @(posedge clk); 
        compare_data("SRA_Negative_Shift31", alu_out, 32'hFFFFFFFF);
        
        rs1 = 32'h40000000;  // Positive number
        rs2 = 32'h00000004;  // Shift by 4
        @(posedge clk); 
        compare_data("SRA_Positive_Shift4", alu_out, 32'h04000000);
        
    endtask
    
    //========================================
    // Test Task: Comparison Operations
    //========================================
    task test_comparison_operations();
        $display("\n--- Testing Comparison Operations ---");
        
        RS1Mux = 0;
        RS2Mux = 0;
        IsBR_J = 0;
        
        // Test SLT - Set Less Than Signed (ALUK = 8, Usign = 0)
        ALUK = 8;
        Usign = 0;
        
        // Less than
        rs1 = 32'h00000005;
        rs2 = 32'h0000000A;
        @(posedge clk); 
        compare_data("SLT_LessThan", alu_out, 32'h00000001);
        
        // Greater than
        rs1 = 32'h0000000A;
        rs2 = 32'h00000005;
        @(posedge clk); 
        compare_data("SLT_GreaterThan", alu_out, 32'h00000000);
        
        // Equal
        rs1 = 32'h00000005;
        rs2 = 32'h00000005;
        @(posedge clk); 
        compare_data("SLT_Equal", alu_out, 32'h00000000);
        
        // Negative less than positive
        rs1 = 32'hFFFFFFFE;  // -2
        rs2 = 32'h00000001;  // 1
        @(posedge clk); 
        compare_data("SLT_Negative_LT_Positive", alu_out, 32'h00000001);
        
        // Negative greater than negative
        rs1 = 32'hFFFFFFFE;  // -2
        rs2 = 32'hFFFFFFF0;  // -16
        @(posedge clk); 
        compare_data("SLT_Negative_GT_Negative", alu_out, 32'h00000000);
        
        // Test SLTU - Set Less Than Unsigned (ALUK = 8, Usign = 1)
        Usign = 1;
        
        // Less than (unsigned)
        rs1 = 32'h00000005;
        rs2 = 32'h0000000A;
        @(posedge clk); 
        compare_data("SLTU_LessThan", alu_out, 32'h00000001);
        
        // Greater than (unsigned)
        rs1 = 32'h0000000A;
        rs2 = 32'h00000005;
        @(posedge clk); 
        compare_data("SLTU_GreaterThan", alu_out, 32'h00000000);
        
        // Unsigned: 0xFFFFFFFE > 0x00000001
        rs1 = 32'hFFFFFFFE;
        rs2 = 32'h00000001;
        @(posedge clk); 
        compare_data("SLTU_Large_GT_Small", alu_out, 32'h00000000);
        
    endtask
    
    //========================================
    // Test Task: Branch Comparison Logic
    //========================================
    task test_branch_comparisons();
        $display("\n--- Testing Branch Comparison Logic ---");
        
        RS1Mux = 0;
        RS2Mux = 0;
        ALUK = 0;  // ALU operation doesn't matter for branches
        IsBR_J = 1;  // Branch instruction
        
        // Test BEQ - Branch if Equal (BR = 0)
        BR = 0;
        rs1 = 32'h00000005;
        rs2 = 32'h00000005;
        @(posedge clk); 
        compare_bit_simple(1'b1, pc_jump, "BEQ_Equal");
        
        rs1 = 32'h00000005;
        rs2 = 32'h0000000A;
        @(posedge clk); 
        compare_bit_simple(1'b0, pc_jump, "BEQ_NotEqual");
        
        // Test BNE - Branch if Not Equal (BR = 1)
        BR = 1;
        rs1 = 32'h00000005;
        rs2 = 32'h0000000A;
        @(posedge clk); 
        compare_bit_simple(1'b1, pc_jump, "BNE_NotEqual");
        
        rs1 = 32'h00000005;
        rs2 = 32'h00000005;
        @(posedge clk); 
        compare_bit_simple(1'b0, pc_jump, "BNE_Equal");
        
        // Test BLT - Branch if Less Than Signed (BR = 2, Usign = 0)
        BR = 2;
        Usign = 0;
        rs1 = 32'h00000005;
        rs2 = 32'h0000000A;
        @(posedge clk); 
        compare_bit_simple(1'b1, pc_jump, "BLT_LessThan");
        
        rs1 = 32'h0000000A;
        rs2 = 32'h00000005;
        @(posedge clk); 
        compare_bit_simple(1'b0, pc_jump, "BLT_GreaterThan");
        
        rs1 = 32'hFFFFFFFE;  // -2
        rs2 = 32'h00000001;  // 1
        @(posedge clk); 
        compare_bit_simple(1'b1, pc_jump, "BLT_Negative_LT_Positive");
        
        // Test BLTU - Branch if Less Than Unsigned (BR = 2, Usign = 1)
        Usign = 1;
        rs1 = 32'h00000005;
        rs2 = 32'h0000000A;
        @(posedge clk); 
        compare_bit_simple(1'b1, pc_jump, "BLTU_LessThan");
        
        rs1 = 32'hFFFFFFFE;  // Large unsigned
        rs2 = 32'h00000001;  // Small unsigned
        @(posedge clk); 
        compare_bit_simple(1'b0, pc_jump, "BLTU_Large_GT_Small");
        
        // Test BGE - Branch if Greater or Equal Signed (BR = 3, Usign = 0)
        BR = 3;
        Usign = 0;
        rs1 = 32'h0000000A;
        rs2 = 32'h00000005;
        @(posedge clk); 
        compare_bit_simple(1'b1, pc_jump, "BGE_GreaterThan");
        
        rs1 = 32'h00000005;
        rs2 = 32'h00000005;
        @(posedge clk); 
        compare_bit_simple(1'b1, pc_jump, "BGE_Equal");
        
        rs1 = 32'h00000005;
        rs2 = 32'h0000000A;
        @(posedge clk); 
        compare_bit_simple(1'b0, pc_jump, "BGE_LessThan");
        
        // Test BGEU - Branch if Greater or Equal Unsigned (BR = 3, Usign = 1)
        Usign = 1;
        rs1 = 32'hFFFFFFFE;
        rs2 = 32'h00000001;
        @(posedge clk); 
        compare_bit_simple(1'b1, pc_jump, "BGEU_Large_GE_Small");
        
        // Test JAL - Unconditional Jump (IsBR_J = 2)
        IsBR_J = 2;
        rs1 = 32'h00000000;  // Doesn't matter
        rs2 = 32'h00000000;  // Doesn't matter
        @(posedge clk); 
        compare_bit_simple(1'b1, pc_jump, "JAL_Unconditional");
        
    endtask
    
    //========================================
    // Test Task: Mux Selection
    //========================================
    task test_mux_selection();
        $display("\n--- Testing Mux Selection ---");
        
        IsBR_J = 0;
        ALUK = 0;  // ADD operation
        
        // Test RS1Mux = 0 (use rs1)
        RS1Mux = 0;
        RS2Mux = 0;
        rs1 = 32'h00000010;
        rs2 = 32'h00000005;
        pc = 32'h00001000;
        @(posedge clk); 
        compare_data("RS1Mux_UseRS1", alu_out, 32'h00000015);
        
        // Test RS1Mux = 1 (use PC for PC-relative calculations)
        RS1Mux = 1;
        RS2Mux = 0;
        rs1 = 32'h00000010;  // Should be ignored
        rs2 = 32'h00000100;
        pc = 32'h00001000;
        @(posedge clk); 
        compare_data("RS1Mux_UsePC", alu_out, 32'h00001100);
        
        // Test RS2Mux = 0 (use rs2)
        RS1Mux = 0;
        RS2Mux = 0;
        rs1 = 32'h00000020;
        rs2 = 32'h00000008;
        imm = 32'h00000100;  // Should be ignored
        @(posedge clk); 
        compare_data("RS2Mux_UseRS2", alu_out, 32'h00000028);
        
        // Test RS2Mux = 1 (use immediate)
        RS1Mux = 0;
        RS2Mux = 1;
        rs1 = 32'h00000020;
        rs2 = 32'h00000008;  // Should be ignored
        imm = 32'h00000100;
        @(posedge clk); 
        compare_data("RS2Mux_UseImm", alu_out, 32'h00000120);
        
        // Test both muxes: PC + immediate (for AUIPC-like operation)
        RS1Mux = 1;
        RS2Mux = 1;
        rs1 = 32'h00000010;  // Should be ignored
        rs2 = 32'h00000008;  // Should be ignored
        pc = 32'h00001000;
        imm = 32'h00002000;
        @(posedge clk); 
        compare_data("Both_Mux_PC_Plus_Imm", alu_out, 32'h00003000);
        
    endtask
    
    //========================================
    // Test Task: Edge Cases
    //========================================
    task test_edge_cases();
        $display("\n--- Testing Edge Cases ---");
        
        RS1Mux = 0;
        RS2Mux = 0;
        IsBR_J = 0;
        
        // Test overflow in addition
        ALUK = 0;  // ADD
        rs1 = 32'h7FFFFFFF;  // Max positive signed
        rs2 = 32'h00000001;
        @(posedge clk); 
        compare_data("ADD_Overflow", alu_out, 32'h80000000);
        
        // Test underflow in subtraction
        ALUK = 1;  // SUB
        rs1 = 32'h80000000;  // Min negative signed
        rs2 = 32'h00000001;
        @(posedge clk); 
        compare_data("SUB_Underflow", alu_out, 32'h7FFFFFFF);
        
        // Test all ones
        ALUK = 0;  // ADD
        rs1 = 32'hFFFFFFFF;
        rs2 = 32'hFFFFFFFF;
        @(posedge clk); 
        compare_data("ADD_All_Ones", alu_out, 32'hFFFFFFFE);
        
        // Test LUI operation (ALUK = 9)
        ALUK = 9;
        RS2Mux = 1;  // Use immediate
        imm = 32'h12345000;
        @(posedge clk); 
        compare_data("LUI_Load_Upper_Immediate", alu_out, 32'h12345000);
        
    endtask
    
endmodule





