`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// LSU (Load-Store Unit) Testbench
// 
// Tests the LSU module with comprehensive directed tests:
// - Word, halfword, and byte-sized loads and stores
// - Sign extension and zero extension for loads
// - Write enable generation based on alignment
// - State machine transitions (IDLE → REQUESTING → DONE)
// - Address calculation (rs1 + imm)
// - Memory interface handshaking
//////////////////////////////////////////////////////////////////////////////////

import common_pkg::*;
import tb_common_pkg::*;

module tb_lsu;

    // Clock and reset
    logic clk;
    logic reset;
    
    // DUT inputs
    warp_state_t warp_state;
    logic thread_active;
    data_t rs1, rs2, imm;
    logic [1:0] DataSize;
    logic DMemR_W;
    logic Usign;
    
    // Memory interface (from memory model)
    logic mem_resp_valid;
    data_t mem_resp_data;
    
    // DUT outputs
    logic mem_valid;
    data_mem_addr_t mem_addr;
    data_t mem_data;
    logic [3:0] mem_we;
    logic mem_resp_ready;  // lsu drives high when waiting; mem model ignores it
    lsu_state_t lsu_state_out;
    data_t lsu_out;
    
    // Instantiate DUT
    lsu dut (
        .clk(clk),
        .reset(reset),
        .warp_state(warp_state),
        .thread_active(thread_active),
        .rs1(rs1),
        .rs2(rs2),
        .imm(imm),
        .DataSize(DataSize),
        .DMemR_W(DMemR_W),
        .Usign(Usign),
        .mem_valid(mem_valid),
        .mem_addr(mem_addr),
        .mem_data(mem_data),
        .mem_we(mem_we),
        .mem_resp_valid(mem_resp_valid),
        .mem_resp_ready(mem_resp_ready),
        .mem_resp_data(mem_resp_data),
        .lsu_state_out(lsu_state_out),
        .lsu_out(lsu_out)
    );
    
    // Instantiate data memory model
    memory_model #(
        .ADDR_WIDTH(32),
        .DATA_WIDTH(32),
        .MEM_SIZE(1024)
    ) data_mem (
        .clk(clk),
        .reset(reset),
        .valid(mem_valid),
        .addr(mem_addr),
        .wdata(mem_data),
        .we(mem_we),
        .ready(),  // Always ready
        .resp_valid(mem_resp_valid),
        .resp_ready(mem_resp_ready),
        .rdata(mem_resp_data)
    );
    
    // Clock generation (100MHz, 10ns period)
    initial begin
        generate_clock(clk, 10);
    end
    
    // Test stimulus and checking
    initial begin
        $display("========================================");
        $display("LSU Testbench Starting");
        $display("========================================");
        
        // Initialize signals
        warp_state = WARP_IDLE;
        thread_active = 1'b1;  // Enable thread for all tests
        rs1 = 0;
        rs2 = 0;
        imm = 0;
        DataSize = 0;
        DMemR_W = 0;
        Usign = 0;
        
        // Apply reset
        apply_reset(clk, reset, 2);
        
        // Run test groups
        test_word_operations();
        test_halfword_operations();
        test_byte_operations();
        test_sign_extension();
        test_state_machine();
        test_address_calculation();
        
        // Report results
        report_summary();
        
        $display("========================================");
        $display("LSU Testbench Complete");
        $display("========================================");
        $finish;
    end
    
    //========================================
    // Test Task: Word-sized Load/Store Operations
    //========================================
    task test_word_operations();
        $display("\n--- Testing Word-sized Load/Store Operations ---");
        
        // Test word store (32-bit) to aligned address
        warp_state = WARP_IDLE;
        rs1 = 32'h00000010;  // base address
        rs2 = 32'hDEADBEEF;  // data to store
        imm = 32'h00000000;  // offset
        DataSize = 2'b00;    // word
        DMemR_W = 1'b1;      // store
        Usign = 1'b0;
        
        @(posedge clk); #1;
        compare_bit("Word_Store_Initial_State", lsu_state_out, LSU_IDLE, "idle");
        
        // Trigger store operation
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        compare_bit("Word_Store_Requesting_State", lsu_state_out, LSU_REQUESTING, "requesting");
        compare_bit_simple(1'b1, mem_valid, "Word_Store_MemValid");
        compare_data("Word_Store_MemAddr", mem_addr, 32'h00000010);
        compare_data("Word_Store_MemData", mem_data, 32'hDEADBEEF);
        compare_data("Word_Store_WriteEnable", mem_we, 4'b1111);
        
        // Wait for memory response (1-cycle memory latency + 1 cycle for LSU state transition)
        @(posedge clk); #1;  // LSU transitions to REQUESTING, memory captures
        @(posedge clk); #1;  // Memory responds, LSU transitions to DONE
        compare_bit("Word_Store_Done_State", lsu_state_out, LSU_DONE, "done");
        compare_bit_simple(1'b0, mem_valid, "Word_Store_MemValid_Low");
        
        // Transition back to IDLE
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        compare_bit("Word_Store_Idle_State", lsu_state_out, LSU_IDLE, "idle");
        
        // Test word load (32-bit) from same address
        warp_state = WARP_IDLE;
        rs1 = 32'h00000010;
        imm = 32'h00000000;
        DataSize = 2'b00;    // word
        DMemR_W = 1'b0;      // load
        Usign = 1'b0;
        
        @(posedge clk); #1;
        
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        compare_bit("Word_Load_Requesting_State", lsu_state_out, LSU_REQUESTING, "requesting");
        compare_bit_simple(1'b1, mem_valid, "Word_Load_MemValid");
        compare_data("Word_Load_MemAddr", mem_addr, 32'h00000010);
        compare_data("Word_Load_WriteEnable", mem_we, 4'b0000);  // no write on load
        
        @(posedge clk); #1;  // LSU transitions to REQUESTING, memory captures
        @(posedge clk); #1;  // Memory responds, LSU transitions to DONE
        compare_bit("Word_Load_Done_State", lsu_state_out, LSU_DONE, "done");
        compare_data("Word_Load_Data", lsu_out, 32'hDEADBEEF);
        
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        
    endtask
    
    //========================================
    // Test Task: Halfword-sized Load/Store Operations
    //========================================
    task test_halfword_operations();
        $display("\n--- Testing Halfword-sized Load/Store Operations ---");
        
        // Test halfword store to offset 0
        warp_state = WARP_IDLE;
        rs1 = 32'h00000020;
        rs2 = 32'h0000ABCD;  // halfword data
        imm = 32'h00000000;
        DataSize = 2'b01;    // halfword
        DMemR_W = 1'b1;      // store
        Usign = 1'b1;        // unsigned
        
        @(posedge clk); #1;
        
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        compare_data("Halfword_Store_Offset0_MemAddr", mem_addr, 32'h00000020);
        compare_data("Halfword_Store_Offset0_MemData", mem_data, 32'hABCDABCD);  // replicated
        compare_data("Halfword_Store_Offset0_WE", mem_we, 4'b0011);
        
        @(posedge clk); #1;
        @(posedge clk); #1;
        
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        
        // Test halfword store to offset 2
        warp_state = WARP_IDLE;
        rs1 = 32'h00000022;  // offset 2
        rs2 = 32'h00001234;
        imm = 32'h00000000;
        DataSize = 2'b01;
        DMemR_W = 1'b1;
        Usign = 1'b1;
        
        @(posedge clk); #1;
        
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        compare_data("Halfword_Store_Offset2_MemAddr", mem_addr, 32'h00000022);
        compare_data("Halfword_Store_Offset2_WE", mem_we, 4'b1100);
        
        @(posedge clk); #1;
        @(posedge clk); #1;
        
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        
        // Test halfword load from offset 0 (unsigned)
        warp_state = WARP_IDLE;
        rs1 = 32'h00000020;
        imm = 32'h00000000;
        DataSize = 2'b01;
        DMemR_W = 1'b0;      // load
        Usign = 1'b1;        // unsigned (zero-extend)
        
        @(posedge clk); #1;
        
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        compare_data("Halfword_Load_Offset0_Unsigned", lsu_out, 32'h0000ABCD);
        
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        
        // Test halfword load from offset 2 (unsigned)
        warp_state = WARP_IDLE;
        rs1 = 32'h00000022;
        imm = 32'h00000000;
        DataSize = 2'b01;
        DMemR_W = 1'b0;
        Usign = 1'b1;
        
        @(posedge clk); #1;
        
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        compare_data("Halfword_Load_Offset2_Unsigned", lsu_out, 32'h00001234);
        
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        
    endtask
    
    //========================================
    // Test Task: Byte-sized Load/Store Operations
    //========================================
    task test_byte_operations();
        $display("\n--- Testing Byte-sized Load/Store Operations ---");
        
        // Store test bytes at different offsets
        for (int offset = 0; offset < 4; offset++) begin
            warp_state = WARP_IDLE;
            rs1 = 32'h00000030 + offset;
            rs2 = 32'h000000A0 + offset;  // A0, A1, A2, A3
            imm = 32'h00000000;
            DataSize = 2'b10;    // byte
            DMemR_W = 1'b1;      // store
            Usign = 1'b1;
            
            @(posedge clk); #1;
            
            warp_state = WARP_MEMORY;
            @(posedge clk); #1;
            
            // Check write enable based on offset
            case (offset)
                0: compare_data("Byte_Store_Offset0_WE", mem_we, 4'b0001);
                1: compare_data("Byte_Store_Offset1_WE", mem_we, 4'b0010);
                2: compare_data("Byte_Store_Offset2_WE", mem_we, 4'b0100);
                3: compare_data("Byte_Store_Offset3_WE", mem_we, 4'b1000);
            endcase
            
            @(posedge clk); #1;
            @(posedge clk); #1;
            
            warp_state = WARP_WRITEBACK;
            @(posedge clk); #1;
        end
        
        // Load test bytes from different offsets (unsigned)
        for (int offset = 0; offset < 4; offset++) begin
            warp_state = WARP_IDLE;
            rs1 = 32'h00000030 + offset;
            imm = 32'h00000000;
            DataSize = 2'b10;
            DMemR_W = 1'b0;      // load
            Usign = 1'b1;        // unsigned
            
            @(posedge clk); #1;
            
            warp_state = WARP_MEMORY;
            @(posedge clk); #1;
            @(posedge clk); #1;
            @(posedge clk); #1;
            
            // Check loaded data
            case (offset)
                0: compare_data("Byte_Load_Offset0_Unsigned", lsu_out, 32'h000000A0);
                1: compare_data("Byte_Load_Offset1_Unsigned", lsu_out, 32'h000000A1);
                2: compare_data("Byte_Load_Offset2_Unsigned", lsu_out, 32'h000000A2);
                3: compare_data("Byte_Load_Offset3_Unsigned", lsu_out, 32'h000000A3);
            endcase
            
            warp_state = WARP_WRITEBACK;
            @(posedge clk); #1;
        end
        
    endtask
    
    //========================================
    // Test Task: Sign Extension Tests
    //========================================
    task test_sign_extension();
        $display("\n--- Testing Sign Extension ---");
        
        // Store negative halfword (sign bit set)
        warp_state = WARP_IDLE;
        rs1 = 32'h00000040;
        rs2 = 32'h0000FF80;  // negative halfword (-128 in 16-bit)
        imm = 32'h00000000;
        DataSize = 2'b01;    // halfword
        DMemR_W = 1'b1;      // store
        Usign = 1'b0;
        
        @(posedge clk); #1;
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        
        // Load with sign extension
        warp_state = WARP_IDLE;
        rs1 = 32'h00000040;
        imm = 32'h00000000;
        DataSize = 2'b01;
        DMemR_W = 1'b0;      // load
        Usign = 1'b0;        // signed (sign-extend)
        
        @(posedge clk); #1;
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        compare_data("Halfword_Load_SignExtend", lsu_out, 32'hFFFFFF80);
        
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        
        // Load same data with zero extension
        warp_state = WARP_IDLE;
        rs1 = 32'h00000040;
        imm = 32'h00000000;
        DataSize = 2'b01;
        DMemR_W = 1'b0;
        Usign = 1'b1;        // unsigned (zero-extend)
        
        @(posedge clk); #1;
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        compare_data("Halfword_Load_ZeroExtend", lsu_out, 32'h0000FF80);
        
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        
        // Store negative byte
        warp_state = WARP_IDLE;
        rs1 = 32'h00000050;
        rs2 = 32'h000000F0;  // negative byte (-16 in 8-bit)
        imm = 32'h00000000;
        DataSize = 2'b10;    // byte
        DMemR_W = 1'b1;
        Usign = 1'b0;
        
        @(posedge clk); #1;
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        
        // Load byte with sign extension
        warp_state = WARP_IDLE;
        rs1 = 32'h00000050;
        imm = 32'h00000000;
        DataSize = 2'b10;
        DMemR_W = 1'b0;
        Usign = 1'b0;        // signed
        
        @(posedge clk); #1;
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        compare_data("Byte_Load_SignExtend", lsu_out, 32'hFFFFFFF0);
        
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        
        // Load byte with zero extension
        warp_state = WARP_IDLE;
        rs1 = 32'h00000050;
        imm = 32'h00000000;
        DataSize = 2'b10;
        DMemR_W = 1'b0;
        Usign = 1'b1;        // unsigned
        
        @(posedge clk); #1;
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        @(posedge clk); #1;
        @(posedge clk); #1;
        compare_data("Byte_Load_ZeroExtend", lsu_out, 32'h000000F0);
        
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        
    endtask
    
    //========================================
    // Test Task: State Machine Transitions
    //========================================
    task test_state_machine();
        $display("\n--- Testing State Machine Transitions ---");
        
        // Test IDLE → REQUESTING transition
        warp_state = WARP_IDLE;
        rs1 = 32'h00000060;
        rs2 = 32'h12345678;
        imm = 32'h00000000;
        DataSize = 2'b00;
        DMemR_W = 1'b1;
        Usign = 1'b0;
        
        @(posedge clk); #1;
        compare_bit("SM_Initial_State_IDLE", lsu_state_out, LSU_IDLE, "idle");
        
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        compare_bit("SM_State_REQUESTING", lsu_state_out, LSU_REQUESTING, "requesting");
        compare_bit_simple(1'b1, mem_valid, "SM_MemValid_High");
        
        // Test REQUESTING → DONE transition
        @(posedge clk); #1;  // Memory pipeline stage 1
        compare_bit("SM_State_Still_REQUESTING", lsu_state_out, LSU_REQUESTING, "requesting");
        
        @(posedge clk);  // Memory pipeline stage 2, mem_resp_valid goes high
        #1;
        compare_bit("SM_State_DONE", lsu_state_out, LSU_DONE, "done");
        compare_bit_simple(1'b0, mem_valid, "SM_MemValid_Low");
        
        // Test DONE → IDLE transition
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        compare_bit("SM_State_IDLE_After_Wait", lsu_state_out, LSU_IDLE, "idle");
        
        // Test that LSU stays in IDLE if warp_state != WARP_MEMORY
        warp_state = WARP_FETCH;
        @(posedge clk); #1;
        compare_bit("SM_Stay_IDLE_Fetch", lsu_state_out, LSU_IDLE, "idle");
        
        warp_state = WARP_EXECUTE;
        @(posedge clk); #1;
        compare_bit("SM_Stay_IDLE_Execute", lsu_state_out, LSU_IDLE, "idle");
        
    endtask
    
    //========================================
    // Test Task: Address Calculation
    //========================================
    task test_address_calculation();
        $display("\n--- Testing Address Calculation ---");
        
        // Test address = rs1 + imm (positive offset)
        warp_state = WARP_IDLE;
        rs1 = 32'h00000100;
        rs2 = 32'hAAAAAAAA;
        imm = 32'h00000010;  // offset +16
        DataSize = 2'b00;
        DMemR_W = 1'b1;
        Usign = 1'b0;
        
        @(posedge clk); #1;
        
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        compare_data("Addr_Calc_Positive_Offset", mem_addr, 32'h00000110);
        
        @(posedge clk); #1;
        @(posedge clk); #1;
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        
        // Test address = rs1 + imm (negative offset)
        warp_state = WARP_IDLE;
        rs1 = 32'h00000100;
        rs2 = 32'hBBBBBBBB;
        imm = 32'hFFFFFFF0;  // offset -16 (sign-extended)
        DataSize = 2'b00;
        DMemR_W = 1'b1;
        Usign = 1'b0;
        
        @(posedge clk); #1;
        
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        compare_data("Addr_Calc_Negative_Offset", mem_addr, 32'h000000F0);
        
        @(posedge clk); #1;
        @(posedge clk); #1;
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        
        // Test address = rs1 + 0
        warp_state = WARP_IDLE;
        rs1 = 32'h00000200;
        rs2 = 32'hCCCCCCCC;
        imm = 32'h00000000;
        DataSize = 2'b00;
        DMemR_W = 1'b1;
        Usign = 1'b0;
        
        @(posedge clk); #1;
        
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        compare_data("Addr_Calc_Zero_Offset", mem_addr, 32'h00000200);
        
        @(posedge clk); #1;
        @(posedge clk); #1;
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        
    endtask
    
endmodule

