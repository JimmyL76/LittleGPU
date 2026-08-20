`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// LSU (Load-Store Unit) Testbench
//
// lsu is now a pure combinational address/write-data datapath: no clock, no
// state, no response handling. It computes mem_addr = rs1+imm and formats
// mem_data/mem_we for word/halfword/byte stores, gated by a single pre-folded
// thread_active input. There is no lsu_out/lsu_state_out/mem_resp_* anymore -
// the memory_scoreboard now owns response formatting and writeback.
//
// Tests: address calculation, word/halfword/byte write-enable + data merge,
// thread_active gating (both mem_valid and value stability when gated low).
//////////////////////////////////////////////////////////////////////////////////

import common_pkg::*;
import tb_common_pkg::*;

module tb_lsu;

    // DUT inputs
    logic thread_active;
    data_t rs1, rs2, imm;
    logic [1:0] DataSize;
    logic DMemR_W;

    // DUT outputs
    logic mem_valid;
    data_mem_addr_t mem_addr;
    data_t mem_data;
    logic [3:0] mem_we;

    lsu dut (
        .thread_active(thread_active),
        .rs1(rs1), .rs2(rs2), .imm(imm),
        .DataSize(DataSize),
        .DMemR_W(DMemR_W),
        .mem_valid(mem_valid),
        .mem_addr(mem_addr),
        .mem_data(mem_data),
        .mem_we(mem_we)
    );

    initial begin
        $display("========================================");
        $display("LSU Testbench Starting");
        $display("========================================");

        thread_active = 1'b1; // default enabled in tests
        rs1 = 0; rs2 = 0; imm = 0;
        DataSize = 0; DMemR_W = 0;
        #1;

        test_address_calculation();
        test_word_operations();
        test_halfword_operations();
        test_byte_operations();
        test_thread_active_gating();

        report_summary();

        $display("========================================");
        $display("LSU Testbench Complete");
        $display("========================================");
        $finish;
    end

    //========================================
    // Address = rs1 + imm, combinational, no clock needed
    //========================================
    task test_address_calculation();
        $display("\n--- Testing Address Calculation ---");

        rs1 = 32'h00000100; imm = 32'h00000010; // positive offset
        rs2 = 32'hAAAAAAAA; DataSize = 2'b00; DMemR_W = 1'b1;
        #1;
        compare_data("Addr_Calc_Positive_Offset", mem_addr, 32'h00000110);

        rs1 = 32'h00000100; imm = 32'hFFFFFFF0; // negative offset, sign-extended
        #1;
        compare_data("Addr_Calc_Negative_Offset", mem_addr, 32'h000000F0);

        rs1 = 32'h00000200; imm = 32'h00000000;
        #1;
        compare_data("Addr_Calc_Zero_Offset", mem_addr, 32'h00000200);
    endtask

    //========================================
    // Word store/load request formatting
    //========================================
    task test_word_operations();
        $display("\n--- Testing Word-sized Requests ---");

        rs1 = 32'h00000010; imm = 0; rs2 = 32'hDEADBEEF;
        DataSize = 2'b00; DMemR_W = 1'b1; // store
        #1;
        compare_bit_simple(1'b1, mem_valid, "Word_Store_MemValid");
        compare_data("Word_Store_MemAddr", mem_addr, 32'h00000010);
        compare_data("Word_Store_MemData", mem_data, 32'hDEADBEEF);
        compare_data("Word_Store_WriteEnable", mem_we, 4'b1111);

        DMemR_W = 1'b0; // load - no write enable
        #1;
        compare_bit_simple(1'b1, mem_valid, "Word_Load_MemValid");
        compare_data("Word_Load_MemAddr", mem_addr, 32'h00000010);
        compare_data("Word_Load_WriteEnable", mem_we, 4'b0000);
    endtask

    //========================================
    // Halfword store write-enable + data replication by alignment
    //========================================
    task test_halfword_operations();
        $display("\n--- Testing Halfword-sized Requests ---");

        rs1 = 32'h00000020; imm = 0; rs2 = 32'h0000ABCD;
        DataSize = 2'b01; DMemR_W = 1'b1;
        #1;
        compare_data("Halfword_Store_Offset0_MemAddr", mem_addr, 32'h00000020);
        compare_data("Halfword_Store_Offset0_MemData", mem_data, 32'hABCDABCD);
        compare_data("Halfword_Store_Offset0_WE", mem_we, 4'b0011);

        rs1 = 32'h00000022; rs2 = 32'h00001234; // offset 2
        #1;
        compare_data("Halfword_Store_Offset2_MemAddr", mem_addr, 32'h00000022);
        compare_data("Halfword_Store_Offset2_WE", mem_we, 4'b1100);
    endtask

    //========================================
    // Byte store write-enable by alignment
    //========================================
    task test_byte_operations();
        $display("\n--- Testing Byte-sized Requests ---");

        for (int offset = 0; offset < 4; offset++) begin
            rs1 = 32'h00000030 + offset; imm = 0;
            rs2 = 32'h000000A0 + offset;
            DataSize = 2'b10; DMemR_W = 1'b1;
            #1;
            case (offset)
                0: compare_data("Byte_Store_Offset0_WE", mem_we, 4'b0001);
                1: compare_data("Byte_Store_Offset1_WE", mem_we, 4'b0010);
                2: compare_data("Byte_Store_Offset2_WE", mem_we, 4'b0100);
                3: compare_data("Byte_Store_Offset3_WE", mem_we, 4'b1000);
            endcase
        end
    endtask

    //========================================
    // thread_active gates mem_valid; deasserted thread presents nothing
    //========================================
    task test_thread_active_gating();
        $display("\n--- Testing thread_active Gating ---");

        rs1 = 32'h00000040; imm = 0; rs2 = 32'hCAFEBABE;
        DataSize = 2'b00; DMemR_W = 1'b1;
        thread_active = 1'b1;
        #1;
        compare_bit_simple(1'b1, mem_valid, "Active_MemValid_High");

        thread_active = 1'b0;
        #1;
        compare_bit_simple(1'b0, mem_valid, "Inactive_MemValid_Low");
        compare_data("Inactive_MemAddr_Zero", mem_addr, 32'h00000000);
        compare_data("Inactive_MemWE_Zero", mem_we, 4'b0000);

        thread_active = 1'b1;
    endtask

endmodule
