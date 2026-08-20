`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Fetcher Testbench
// 
// Tests the instruction fetcher module with comprehensive directed tests:
// - Basic fetch operations
// - State machine transitions (IDLE → FETCHING → DONE)
// - Memory interface handshaking (valid/ready protocol)
// - Reset behavior
// - Multiple consecutive fetch operations
// - Edge cases and timing
//////////////////////////////////////////////////////////////////////////////////

import common_pkg::*;
import tb_common_pkg::*;

module tb_fetcher;

    // Clock and reset
    logic clk;
    logic reset;
    
    // DUT inputs
    warp_state_t warp_state;
    instr_mem_addr_t pc;
    
    // Memory interface (from memory model)
    logic mem_resp_valid;
    instr_t mem_resp_data;
    
    // DUT outputs
    logic mem_valid;
    instr_mem_addr_t mem_addr;
    logic mem_resp_ready;  // fetcher drives high when fetching; mem model ignores it
    logic done;
    instr_t out_instr;
    
    // Internal state for verification (hierarchical reference)
    fetcher_state_t fetcher_state;
    assign fetcher_state = dut.s;
    
    // Memory model signals
    logic [3:0] mem_we;
    
    // Instantiate DUT
    fetcher dut (
        .clk(clk),
        .reset(reset),
        .warp_state(warp_state),
        .pc(pc),
        .mem_ready(1'b1), // always ready for tb
        .mem_valid(mem_valid),
        .mem_addr(mem_addr),
        .mem_resp_valid(mem_resp_valid),
        .mem_resp_ready(mem_resp_ready),
        .mem_resp_data(mem_resp_data),
        .done(done),
        .out_instr(out_instr)
    );
    
    // Instantiate instruction memory model
    memory_model #(
        .ADDR_WIDTH(32),
        .DATA_WIDTH(32),
        .MEM_SIZE(1024)
    ) instr_mem (
        .clk(clk),
        .reset(reset),
        .valid(mem_valid),
        .addr(mem_addr),
        .wdata(32'h0),  // No writes in fetcher
        .we(mem_we),
        .ready(),  // Always ready
        .resp_valid(mem_resp_valid),
        .resp_ready(mem_resp_ready),
        .rdata(mem_resp_data)
    );
    
    assign mem_we = 4'b0000;  // fetcher never writes
    
    // Clock generation (100MHz, 10ns period)
    initial begin
        generate_clock(clk, 10);
    end
    
    // Test stimulus and checking
    initial begin
        $display("========================================");
        $display("Fetcher Testbench Starting");
        $display("========================================");
        
        // Initialize signals
        warp_state = WARP_IDLE;
        pc = 0;
        
        // Apply reset
        apply_reset(clk, reset, 2);
        
        // Run test groups
        test_basic_fetch();
        test_state_machine();
        test_multiple_fetches();
        test_reset_behavior();
        test_edge_cases();
        
        // Report results
        report_summary();
        
        $display("========================================");
        $display("Fetcher Testbench Complete");
        $display("========================================");
        $finish;
    end
    
    //========================================
    // Test Task: Basic Fetch Operations
    //========================================
    task test_basic_fetch();
        $display("\n--- Testing Basic Fetch Operations ---");
        
        // Preload instruction memory with test instructions
        instr_mem.load_mem(0, 32'h12345678);
        instr_mem.load_mem(1, 32'hABCDEF00);
        instr_mem.load_mem(2, 32'hDEADBEEF);
        instr_mem.load_mem(3, 32'hCAFEBABE);
        
        // Test single instruction fetch from address 0
        warp_state = WARP_IDLE;
        pc = 32'h00000000;
        @(posedge clk); #1;
        compare_bit("Initial_State_IDLE", fetcher_state, FETCHER_IDLE, "idle");
        compare_bit_simple(1'b0, done, "Initial_Done_Low");
        compare_bit("Initial_MemValid_Low", mem_valid, 1'b0, "not valid");
        
        // Trigger fetch by setting warp_state to WARP_FETCH
        warp_state = WARP_FETCH;
        #1;
        compare_bit("Fetch_MemValid_High", mem_valid, 1'b1, "valid");
        @(posedge clk); #1;
        compare_bit("Fetch_State_FETCHING", fetcher_state, FETCHER_FETCHING, "fetching");
        compare_bit_simple(1'b0, done, "Fetch_Done_Low");
        compare_data("Fetch_MemAddr", mem_addr, 32'h00000000);
        
        // Wait for memory response (2-cycle pipeline in memory model)
        @(posedge clk); #1;  // Cycle 2: Memory pipeline stage 1 (captures request)
        compare_bit("Fetching_State_Still_FETCHING", fetcher_state, FETCHER_FETCHING, "fetching");
        
        @(posedge clk);  // Cycle 3: Memory pipeline stage 2 (mem_resp_valid high on edge, state transitions on edge)
        // Sample done immediately after clock edge, before #1 delay
        compare_bit_simple(1'b1, done, "Response_Done_High");
        compare_data("Response_OutInstr", out_instr, 32'h12345678);
        
        // Core sees done signal and moves to next stage
        warp_state = WARP_DECODE;
        
        #1;  // Now wait for NBA to complete
        compare_bit("Response_State_IDLE", fetcher_state, FETCHER_IDLE, "idle");
        compare_bit("Response_MemValid_Low", mem_valid, 1'b0, "not valid");
        
        @(posedge clk); #1;  // Cycle 4: State is IDLE, done is low
        compare_bit("Pulse_State_IDLE", fetcher_state, FETCHER_IDLE, "idle");
        compare_bit_simple(1'b0, done, "Pulse_Done_Low");
        compare_data("Pulse_OutInstr_Held", out_instr, 32'h12345678);
        
        // Instruction is held stable
        @(posedge clk); #1;
        compare_data("OutInstr_Held", out_instr, 32'h12345678);
        
        // Test fetch from different address
        warp_state = WARP_IDLE;
        pc = 32'h00000002;  // address 2
        @(posedge clk); #1;
        
        warp_state = WARP_FETCH;
        @(posedge clk); #1;  // Cycle 1: Enter FETCHING
        compare_data("Fetch2_MemAddr", mem_addr, 32'h00000002);
        
        @(posedge clk); #1;  // Cycle 2: Memory pipeline stage 1
        
        @(posedge clk);  // Cycle 3: Memory pipeline stage 2, done pulses
        compare_bit_simple(1'b1, done, "Fetch2_Done_High");
        compare_data("Fetch2_OutInstr", out_instr, 32'hDEADBEEF);
        
        // Core sees done and moves to next stage
        warp_state = WARP_DECODE;
        
    endtask
    
    //========================================
    // Test Task: State Machine Transitions
    //========================================
    task test_state_machine();
        $display("\n--- Testing State Machine Transitions ---");
        
        // Test IDLE → FETCHING transition
        warp_state = WARP_IDLE;
        pc = 32'h00000001;
        @(posedge clk); #1;
        compare_bit("SM_State_IDLE", fetcher_state, FETCHER_IDLE, "idle");
        compare_bit_simple(1'b0, done, "SM_IDLE_Done_Low");
        
        warp_state = WARP_FETCH;
        #1;
        compare_bit("SM_MemValid_Asserted", mem_valid, 1'b1, "valid");
        @(posedge clk); #1;  // Cycle 1: IDLE → FETCHING
        compare_bit("SM_State_FETCHING", fetcher_state, FETCHER_FETCHING, "fetching");
        compare_bit_simple(1'b0, done, "SM_FETCHING_Done_Low");
        
        // Test FETCHING → IDLE transition (when mem_resp_valid)
        @(posedge clk); #1;  // Cycle 2: Memory pipeline stage 1
        
        @(posedge clk);  // Cycle 3: Memory pipeline stage 2, done pulses, state transitions
        compare_bit_simple(1'b1, done, "SM_Done_Pulse_High");
        
        // Core sees done and moves to next stage
        warp_state = WARP_DECODE;
        
        #1;
        compare_bit("SM_State_IDLE_After_Fetch", fetcher_state, FETCHER_IDLE, "idle");
        compare_bit("SM_MemValid_Deasserted", mem_valid, 1'b0, "not valid");
        
        @(posedge clk); #1;  // Cycle 4: done is low
        compare_bit_simple(1'b0, done, "SM_Done_Pulse_Low");
        
        // Test that fetcher stays in IDLE if warp_state != WARP_FETCH
        warp_state = WARP_MEMORY;
        @(posedge clk); #1;
        compare_bit("SM_Stay_IDLE_Memory_State", fetcher_state, FETCHER_IDLE, "idle");
        compare_bit_simple(1'b0, done, "SM_Stay_IDLE_Memory");
        
        warp_state = WARP_WRITEBACK;
        @(posedge clk); #1;
        compare_bit("SM_Stay_IDLE_Writeback_State", fetcher_state, FETCHER_IDLE, "idle");
        compare_bit_simple(1'b0, done, "SM_Stay_IDLE_Writeback");
        
        // Test immediate re-fetch capability
        warp_state = WARP_FETCH;
        @(posedge clk); #1;  // Cycle 1: IDLE → FETCHING
        compare_bit("SM_Refetch_State_FETCHING", fetcher_state, FETCHER_FETCHING, "fetching");
        @(posedge clk); #1;  // Cycle 2: Memory pipeline stage 1
        
        @(posedge clk);  // Cycle 3: Memory pipeline stage 2, done pulses
        compare_bit_simple(1'b1, done, "SM_Refetch_Done");
        
        // Core sees done and moves to next stage
        warp_state = WARP_DECODE;
        
        #1;
        compare_bit("SM_Refetch_State_IDLE", fetcher_state, FETCHER_IDLE, "idle");
        
    endtask
    
    //========================================
    // Test Task: Multiple Consecutive Fetches
    //========================================
    task test_multiple_fetches();
        $display("\n--- Testing Multiple Consecutive Fetches ---");
        
        // Preload sequential instructions
        instr_mem.load_mem(10, 32'h11111111);
        instr_mem.load_mem(11, 32'h22222222);
        instr_mem.load_mem(12, 32'h33333333);
        instr_mem.load_mem(13, 32'h44444444);
        
        // Fetch sequence of instructions
        for (int i = 0; i < 4; i++) begin
            warp_state = WARP_IDLE;
            pc = 32'h0000000A + i;  // addresses 10, 11, 12, 13
            @(posedge clk); #1;
            
            warp_state = WARP_FETCH;
            @(posedge clk); #1;  // Cycle 1: IDLE → FETCHING
            @(posedge clk); #1;  // Cycle 2: Memory pipeline stage 1
            
            @(posedge clk);  // Cycle 3: Memory pipeline stage 2, done pulses
            
            // Check fetched instruction
            case (i)
                0: compare_data("Multi_Fetch0", out_instr, 32'h11111111);
                1: compare_data("Multi_Fetch1", out_instr, 32'h22222222);
                2: compare_data("Multi_Fetch2", out_instr, 32'h33333333);
                3: compare_data("Multi_Fetch3", out_instr, 32'h44444444);
            endcase
            
            compare_bit_simple(1'b1, done, $sformatf("Multi_Fetch%0d_Done", i));
            
            // Core sees done and moves to next stage
            warp_state = WARP_DECODE;
        end
        
        // Test back-to-back fetches
        warp_state = WARP_IDLE;
        pc = 32'h00000000;
        @(posedge clk); #1;
        
        warp_state = WARP_FETCH;
        @(posedge clk); #1;  // Cycle 1: IDLE → FETCHING
        @(posedge clk); #1;  // Cycle 2: Memory pipeline stage 1
        
        @(posedge clk);  // Cycle 3: Memory pipeline stage 2, done pulses
        compare_data("BackToBack_Fetch1", out_instr, 32'h12345678);
        compare_bit_simple(1'b1, done, "BackToBack_Done1");
        
        // Core sees done and moves to next stage
        warp_state = WARP_DECODE;
        
        #1;  // Wait for NBA - fetcher transitions to IDLE
        
        // Start next fetch on the next clock edge
        @(posedge clk); #1; // Cycle 4: Fetcher is now in IDLE
        pc = 32'h00000001;
        warp_state = WARP_FETCH;
        
        @(posedge clk); #1;  // Cycle 1: IDLE → FETCHING
        @(posedge clk); #1;  // Cycle 2: Memory response, done pulses
        compare_data("BackToBack_Fetch2", out_instr, 32'hABCDEF00);
        compare_bit_simple(1'b1, done, "BackToBack_Done2");
        
        // Core sees done and moves to next stage
        warp_state = WARP_DECODE;
        
    endtask
    
    //========================================
    // Test Task: Reset Behavior
    //========================================
    task test_reset_behavior();
        $display("\n--- Testing Reset Behavior ---");
        
        // Start a fetch operation
        warp_state = WARP_IDLE;
        pc = 32'h00000001;
        @(posedge clk); #1;
        
        warp_state = WARP_FETCH;
        #1;
        compare_bit("Reset_Before_MemValid", mem_valid, 1'b1, "valid");
        @(posedge clk); #1;  // Cycle 1: IDLE → FETCHING
        compare_bit("Reset_Before_State", fetcher_state, FETCHER_FETCHING, "fetching");
        
        // Assert reset during fetch
        reset = 0;
        @(posedge clk); #1;
        compare_bit("Reset_State_IDLE", fetcher_state, FETCHER_IDLE, "idle");
        compare_bit_simple(1'b0, done, "Reset_Done_Low");
        compare_data("Reset_OutInstr_Zero", out_instr, 32'h00000000);
        // Note: mem_valid and mem_addr are combinational and depend on current state and warp_state
        // After reset, state is IDLE, so mem_valid will be 0 only if warp_state != WARP_FETCH
        warp_state = WARP_IDLE;
        #1;  // Let combinational logic settle
        compare_bit("Reset_MemValid_Low", mem_valid, 1'b0, "not valid");
        compare_data("Reset_MemAddr_Zero", mem_addr, 32'h00000000);
        
        // Release reset
        reset = 1;
        @(posedge clk); #1;
        
        // Verify fetcher can operate normally after reset
        pc = 32'h00000002;
        warp_state = WARP_FETCH;
        @(posedge clk); #1;  // Cycle 1: IDLE → FETCHING
        compare_bit("AfterReset_State_FETCHING", fetcher_state, FETCHER_FETCHING, "fetching");
        compare_bit_simple(1'b0, done, "AfterReset_Done_Low_Fetching");
        compare_data("AfterReset_MemAddr", mem_addr, 32'h00000002);
        
        @(posedge clk); #1;  // Cycle 2: Memory pipeline stage 1
        
        @(posedge clk);  // Cycle 3: Memory pipeline stage 2, done pulses
        compare_bit_simple(1'b1, done, "AfterReset_Done_High");
        compare_data("AfterReset_OutInstr", out_instr, 32'hDEADBEEF);
        
        // Core sees done and moves to next stage
        warp_state = WARP_DECODE;
        
        #1;
        compare_bit("AfterReset_State_IDLE", fetcher_state, FETCHER_IDLE, "idle");
        
    endtask
    
    //========================================
    // Test Task: Edge Cases
    //========================================
    task test_edge_cases();
        $display("\n--- Testing Edge Cases ---");
        
        // Test fetch from address 0
        warp_state = WARP_IDLE;
        pc = 32'h00000000;
        @(posedge clk); #1;
        
        warp_state = WARP_FETCH;
        @(posedge clk); #1;  // Cycle 1: IDLE → FETCHING
        compare_data("Edge_Addr0_MemAddr", mem_addr, 32'h00000000);
        @(posedge clk); #1;  // Cycle 2: Memory pipeline stage 1
        
        @(posedge clk);  // Cycle 3: Memory pipeline stage 2, done pulses
        compare_bit_simple(1'b1, done, "Edge_Addr0_Done");
        compare_data("Edge_Addr0_OutInstr", out_instr, 32'h12345678);
        
        // Core sees done and moves to next stage
        warp_state = WARP_DECODE;
        
        // Test fetch from max address in memory
        instr_mem.load_mem(1023, 32'hFFFFFFFF);
        warp_state = WARP_IDLE;
        pc = 32'h000003FF;  // 1023
        @(posedge clk); #1;
        
        warp_state = WARP_FETCH;
        @(posedge clk); #1;  // Cycle 1: IDLE → FETCHING
        compare_data("Edge_MaxAddr_MemAddr", mem_addr, 32'h000003FF);
        @(posedge clk); #1;  // Cycle 2: Memory pipeline stage 1
        
        @(posedge clk);  // Cycle 3: Memory pipeline stage 2, done pulses
        compare_bit_simple(1'b1, done, "Edge_MaxAddr_Done");
        compare_data("Edge_MaxAddr_OutInstr", out_instr, 32'hFFFFFFFF);
        
        // Core sees done and moves to next stage
        warp_state = WARP_DECODE;
        
        // Test that out_instr is held stable after done pulse
        instr_mem.load_mem(5, 32'h55555555);
        warp_state = WARP_IDLE;
        pc = 32'h00000005;
        @(posedge clk); #1;
        
        warp_state = WARP_FETCH;
        @(posedge clk); #1;  // Cycle 1: IDLE → FETCHING
        @(posedge clk); #1;  // Cycle 2: Memory pipeline stage 1
        
        @(posedge clk);  // Cycle 3: Memory pipeline stage 2, done pulses
        compare_bit_simple(1'b1, done, "Edge_Stable_Done_Pulse");
        compare_data("Edge_Stable_OutInstr1", out_instr, 32'h55555555);
        
        // Core sees done and moves to next stage
        warp_state = WARP_DECODE;
        
        // Instruction held stable after done pulse
        #1;  // Wait for NBA
        @(posedge clk); #1;  // Cycle 4: State transitions to IDLE
        compare_bit_simple(1'b0, done, "Edge_Stable_Done_Low");
        compare_data("Edge_Stable_OutInstr2", out_instr, 32'h55555555);
        @(posedge clk); #1;
        compare_data("Edge_Stable_OutInstr3", out_instr, 32'h55555555);
        
        // Test that mem_valid is only asserted in FETCHING state
        warp_state = WARP_IDLE;
        @(posedge clk); #1;
        compare_bit("Edge_MemValid_IDLE", mem_valid, 1'b0, "not valid");
        
        warp_state = WARP_FETCH;
        #1;
        compare_bit("Edge_MemValid_FETCHING", mem_valid, 1'b1, "valid");
        @(posedge clk); #1;  // Cycle 1: IDLE → FETCHING
        
        @(posedge clk); #1;  // Cycle 2: Memory pipeline stage 1
        
        @(posedge clk);  // Cycle 3: Memory pipeline stage 2, done pulses
        
        // Core sees done and moves to next stage
        warp_state = WARP_DECODE;
        
        #1;  // Wait for NBA
        @(posedge clk); #1;  // Cycle 4: State transitions to IDLE
        compare_bit("Edge_MemValid_After_Done", mem_valid, 1'b0, "not valid");
        
    endtask
    
endmodule
