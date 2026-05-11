`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Common Testbench Infrastructure for LittleGPU Module Unit Tests
// 
// This file provides reusable utilities for all testbenches:
// - Test result tracking and reporting
// - Clock and reset generation tasks
// - Data comparison functions
// - Behavioral memory model for instruction/data memory
//////////////////////////////////////////////////////////////////////////////////

`ifndef TB_COMMON_SV
`define TB_COMMON_SV

package tb_common_pkg;
    
    // Test result tracking
    int test_count = 0;
    int pass_count = 0;
    int fail_count = 0;
    
    // Clock generation task with configurable period
    task automatic generate_clock(ref logic clk, input int period_ns = 10);
        clk = 0;
        forever #(period_ns/2) clk = ~clk;
    endtask
    
    // Reset generation task with configurable assertion time
    task automatic apply_reset(ref logic clk, ref logic reset, input int cycles = 2);
        reset = 0;
        repeat(cycles) @(posedge clk);
        reset = 1;
        @(posedge clk);
    endtask
    
    // Comparison task with error reporting for 32-bit data
    task automatic compare_data(
        input string test_name,
        input logic [31:0] actual,
        input logic [31:0] expected
    );
        test_count++;
        if (expected === actual) begin
            pass_count++;
            $display("[PASS] %s: Expected=0x%08h, Actual=0x%08h", test_name, expected, actual);
        end else begin
            fail_count++;
            $display("[FAIL] %s: Expected=0x%08h, Actual=0x%08h", test_name, expected, actual);
        end
    endtask
    
    // Comparison task for multi-bit signals with description
    task automatic compare_bit(
        input string test_name,
        input logic [31:0] actual,
        input logic [31:0] expected,
        input string description
    );
        test_count++;
        if (expected === actual) begin
            pass_count++;
            $display("[PASS] %s: Expected=0x%h (%s), Actual=0x%h", test_name, expected, description, actual);
        end else begin
            fail_count++;
            $display("[FAIL] %s: Expected=0x%h (%s), Actual=0x%h", test_name, expected, description, actual);
        end
    endtask
    
    // Simpler comparison task for single-bit signals (tb_alu)
    task automatic compare_bit_simple(
        input logic expected,
        input logic actual,
        input string test_name
    );
        test_count++;
        if (expected === actual) begin
            pass_count++;
            $display("[PASS] %s: Expected=%0d, Actual=%0d", test_name, expected, actual);
        end else begin
            fail_count++;
            $display("[FAIL] %s: Expected=%0d, Actual=%0d", test_name, expected, actual);
        end
    endtask
    
    // Test summary reporting
    task automatic report_summary();
        $display("========================================");
        $display("Test Summary:");
        $display("  Total Tests: %0d", test_count);
        $display("  Passed:      %0d", pass_count);
        $display("  Failed:      %0d", fail_count);
        if (fail_count == 0)
            $display("  Result:      ALL TESTS PASSED");
        else
            $display("  Result:      %0d TESTS FAILED", fail_count);
        $display("========================================");
    endtask
    
    // Reset test counters (useful for running multiple test suites)
    task automatic reset_counters();
        test_count = 0;
        pass_count = 0;
        fail_count = 0;
    endtask
    
endpackage

//////////////////////////////////////////////////////////////////////////////////
// Behavioral Memory Model
// 
// Provides a simple memory model for testbenches with:
// - Configurable address and data width
// - 1-cycle latency for reads and writes
// - Byte-level write enable support
// - Valid/ready handshaking protocol
// - Memory preloading capability
//////////////////////////////////////////////////////////////////////////////////

module memory_model #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter int MEM_SIZE = 1024  // Size in words
)(
    input logic clk,
    input logic reset,
    // Memory interface
    input logic valid,
    input logic [ADDR_WIDTH-1:0] addr,
    input logic [DATA_WIDTH-1:0] wdata,
    input logic [3:0] we,  // Write enable (byte-level)
    output logic ready,
    output logic resp_valid,
    output logic [DATA_WIDTH-1:0] rdata
);
    
    // Memory array
    logic [DATA_WIDTH-1:0] mem [MEM_SIZE];
    
    // Pipeline registers for 1-cycle latency
    logic [ADDR_WIDTH-1:0] addr_reg;
    logic valid_reg;
    logic [3:0] we_reg;
    logic [DATA_WIDTH-1:0] wdata_reg;
    
    // Initialize memory to zero
    initial begin
        for (int i = 0; i < MEM_SIZE; i++)
            mem[i] = 0;
    end
    
    // Memory access with 1-cycle latency
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            resp_valid <= 0;
            rdata <= 0;
            addr_reg <= 0;
            valid_reg <= 0;
            we_reg <= 0;
            wdata_reg <= 0;
        end else begin
            // Pipeline stage 1: Capture request
            valid_reg <= valid;
            addr_reg <= addr;
            we_reg <= we;
            wdata_reg <= wdata;
            
            // Pipeline stage 2: Process request
            if (valid_reg) begin
                if (|we_reg) begin  // Write operation
                    if (we_reg[0]) mem[addr_reg][7:0]   <= wdata_reg[7:0];
                    if (we_reg[1]) mem[addr_reg][15:8]  <= wdata_reg[15:8];
                    if (we_reg[2]) mem[addr_reg][23:16] <= wdata_reg[23:16];
                    if (we_reg[3]) mem[addr_reg][31:24] <= wdata_reg[31:24];
                end
                // Read operation (always return data, even for writes)
                rdata <= mem[addr_reg];
                resp_valid <= 1;
            end else begin
                resp_valid <= 0;
            end
        end
    end
    
    // Always ready for new requests
    assign ready = 1;
    
    // Task to preload memory (useful for instruction memory)
    task automatic load_mem(input int address, input logic [DATA_WIDTH-1:0] data);
        if (address < MEM_SIZE) begin
            mem[address] = data;
        end else begin
            $error("Memory load address %0d out of range (max %0d)", address, MEM_SIZE-1);
        end
    endtask
    
    // Task to read memory (useful for verification)
    function automatic logic [DATA_WIDTH-1:0] read_mem(input int address);
        if (address < MEM_SIZE) begin
            return mem[address];
        end else begin
            $error("Memory read address %0d out of range (max %0d)", address, MEM_SIZE-1);
            return 0;
        end
    endfunction
    
    // Task to display memory contents (useful for debugging)
    task automatic dump_mem(input int start_addr, input int end_addr);
        $display("Memory Dump [%0d:%0d]:", start_addr, end_addr);
        for (int i = start_addr; i <= end_addr && i < MEM_SIZE; i++) begin
            $display("  mem[%0d] = 0x%08h", i, mem[i]);
        end
    endtask
    
endmodule

`endif
