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
    input logic [(DATA_WIDTH/8)-1:0] we,  // Write enable (byte-level, sized to data width)
    output logic ready,
    output logic resp_valid,
    input logic resp_ready,                // Receiver tells model it can accept response
    output logic [DATA_WIDTH-1:0] rdata
);
    
    // Memory array
    logic [DATA_WIDTH-1:0] mem [MEM_SIZE];
    
    // Pipeline registers for 1-cycle latency
    logic [ADDR_WIDTH-1:0] addr_reg;
    logic valid_reg;
    logic [(DATA_WIDTH/8)-1:0] we_reg;
    logic [DATA_WIDTH-1:0] wdata_reg;
    
    // Initialize memory to zero
    initial begin
        for (int i = 0; i < MEM_SIZE; i++)
            mem[i] = 0;
    end
    
    // Memory access with 1-cycle latency
    // Once resp_valid is asserted it must hold (along with rdata) until the
    // receiver completes the handshake (resp_valid && resp_ready). This is
    // proper valid/ready semantics; if the receiver isn't ready, the response
    // stays parked on the bus
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            resp_valid <= 0;
            rdata <= 0;
            addr_reg <= 0;
            valid_reg <= 0;
            we_reg <= 0;
            wdata_reg <= 0;
        end else begin
            // Pipeline stage 1: capture request only when no response is parked
            //   (otherwise we'd overwrite wdata_reg/addr_reg mid-stall)
            if (!resp_valid || resp_ready) begin
                valid_reg <= valid;
                addr_reg <= addr;
                we_reg <= we;
                wdata_reg <= wdata;
            end
            
            // Pipeline stage 2: produce response or hold it
            if (resp_valid && !resp_ready) begin
                // Held: receiver hasn't accepted yet, keep resp_valid + rdata stable
            end else if (valid_reg) begin
                if (|we_reg) begin
                    for (int b = 0; b < (DATA_WIDTH/8); b++) begin
                        if (we_reg[b]) mem[addr_reg][b*8 +: 8] <= wdata_reg[b*8 +: 8];
                    end
                end
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

//////////////////////////////////////////////////////////////////////////////////
// Stalling Behavioral Memory Model
//
// Same storage/handshake as memory_model, but adds non-ideal timing to stress
// the controller's request/response paths:
//   - Random request backpressure: deasserts `ready` for a random # of cycles
//   - Random response latency: 1..MAX_LATENCY cycles before resp_valid
//   - Honors resp_ready: holds resp_valid + rdata until the handshake completes
//
// Use this in place of memory_model to verify the DUT tolerates a memory that
// doesn't accept/return immediately. SEED makes each instance's pattern distinct
// yet reproducible.
//////////////////////////////////////////////////////////////////////////////////

module memory_model_stall #(
    parameter int ADDR_WIDTH   = 32,
    parameter int DATA_WIDTH   = 32,
    parameter int MEM_SIZE     = 1024,
    parameter int MAX_LATENCY  = 5,    // Max response latency in cycles (>=1)
    parameter int SEED         = 1     // Per-instance RNG seed
)(
    input  logic                    clk,
    input  logic                    reset,
    input  logic                    valid,
    input  logic [ADDR_WIDTH-1:0]   addr,
    input  logic [DATA_WIDTH-1:0]   wdata,
    input  logic [(DATA_WIDTH/8)-1:0] we,
    output logic                    ready,
    output logic                    resp_valid,
    input  logic                    resp_ready,
    output logic [DATA_WIDTH-1:0]   rdata
);

    logic [DATA_WIDTH-1:0] mem [MEM_SIZE];

    // Request-side backpressure: ready is a registered, randomly-toggled signal
    logic ready_reg;
    assign ready = ready_reg;

    // In-flight transaction bookkeeping
    logic [ADDR_WIDTH-1:0]    addr_lat;
    logic [(DATA_WIDTH/8)-1:0] we_lat;
    logic [DATA_WIDTH-1:0]    wdata_lat;
    int                       latency_cnt;   // Counts down to response
    logic                     busy;          // A request is being serviced

    initial begin
        for (int i = 0; i < MEM_SIZE; i++) mem[i] = 0;
    end

    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            ready_reg   <= 1'b1;
            resp_valid  <= 1'b0;
            rdata       <= '0;
            addr_lat    <= '0;
            we_lat      <= '0;
            wdata_lat   <= '0;
            latency_cnt <= 0;
            busy        <= 1'b0;
        end else begin
            // Response handshake: clear resp_valid only once the receiver accepts
            if (resp_valid && resp_ready) begin
                resp_valid <= 1'b0;
            end

            // Randomly toggle request-side readiness when idle (not mid-request)
            if (!busy && !resp_valid) begin
                ready_reg <= (($random & 3) != 0);  // ~75% ready
            end else begin
                ready_reg <= 1'b1;
            end

            // Accept a new request when valid && ready && not already busy
            if (valid && ready_reg && !busy && !(resp_valid && !resp_ready)) begin
                addr_lat    <= addr;
                we_lat      <= we;
                wdata_lat   <= wdata;
                latency_cnt <= ($random % MAX_LATENCY) + 1;  // 1..MAX_LATENCY
                busy        <= 1'b1;
            end else if (busy) begin
                // Count down latency, then perform the access and assert response
                if (latency_cnt > 1) begin
                    latency_cnt <= latency_cnt - 1;
                end else begin
                    if (|we_lat) begin
                        for (int b = 0; b < (DATA_WIDTH/8); b++) begin
                            if (we_lat[b]) mem[addr_lat][b*8 +: 8] <= wdata_lat[b*8 +: 8];
                        end
                    end
                    rdata      <= mem[addr_lat];
                    resp_valid <= 1'b1;
                    busy       <= 1'b0;
                end
            end
        end
    end

    task automatic load_mem(input int address, input logic [DATA_WIDTH-1:0] data);
        if (address < MEM_SIZE) mem[address] = data;
        else $error("Memory load address %0d out of range (max %0d)", address, MEM_SIZE-1);
    endtask

endmodule

`endif
