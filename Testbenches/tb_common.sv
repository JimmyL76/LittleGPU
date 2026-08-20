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

    // log verbosity - when 0 only FAIL lines print (passes still counted)
    // set to 0 for fails-only logs on large randomized runs
    bit log_pass = 1'b1;
    
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
            if (log_pass) $display("[PASS] %s: Expected=0x%08h, Actual=0x%08h", test_name, expected, actual);
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
            if (log_pass) $display("[PASS] %s: Expected=0x%h (%s), Actual=0x%h", test_name, expected, description, actual);
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
            if (log_pass) $display("[PASS] %s: Expected=%0d, Actual=%0d", test_name, expected, actual);
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
    
    // Watchdog timeout task
    task automatic watchdog(
        input string module_name,
        input int timeout_time = 100000
    );
        #timeout_time;
        test_count++;
        fail_count++;
        $display("\n[FATAL] Watchdog timeout in %s: simulation stalled", module_name);
        report_summary();
        $fatal(1, "watchdog timeout");
    endtask
    
    // Reset test counters (useful for running multiple test suites)
    task automatic reset_counters();
        test_count = 0;
        pass_count = 0;
        fail_count = 0;
    endtask

    // generic named boolean check shared across testbenches
    // replaces one-off chk/check/record style tasks duplicated per harness
    // label identifies harness/config eg "P15_PROD"  name identifies the check
    task automatic check_true(input string label, input string name, input bit cond);
        test_count++;
        if (cond) begin
            pass_count++;
            if (log_pass) $display("[PASS] %s.%s", label, name);
        end else begin
            fail_count++;
            $display("[FAIL] %s.%s", label, name);
        end
    endtask

    // byte address mapping to channel and row with zero byte offset shared
    // across mem_controller harnesses  ch_lsb is clog2 of line bytes and
    // ch_addr_lsb adds clog2 of channel count on top
    function automatic logic [31:0] mc_addr_for(input int ch, input int row,
                                                 input int ch_lsb, input int ch_addr_lsb);
        return (row << ch_addr_lsb) | (ch << ch_lsb);
    endfunction

    // all-ones write-enable mask wide enough for any mem_controller line width
    // used in this project  caller assignment truncates down to its WE_WIDTH
    function automatic logic [127:0] mc_full_we();
        return {128{1'b1}};
    endfunction

    // which memory behavior mc_test_env puts behind the controller channels
    //   MEM_IDEAL  fixed one cycle latency, always ready
    //   MEM_STALL  random latency and random request backpressure
    //   MEM_DRIVEN test drives mem_ready and mem_resp_* itself, so it picks
    //              exactly when and in what order each channel completes
    typedef enum logic [1:0] {
        MEM_IDEAL  = 2'd0,
        MEM_STALL  = 2'd1,
        MEM_DRIVEN = 2'd2
    } mem_mode_t;

    // Instruction encoding helper
    function automatic logic [31:0] encode_instr(
        input string instr_type,
        input logic [4:0] rd = 0,
        input logic [4:0] rs1 = 0,
        input logic [4:0] rs2 = 0,
        input logic [31:0] imm = 0
    );
        logic [6:0] opcode;
        logic [2:0] funct3 = 0; 
        logic [6:0] funct7 = 0; 
        
        case (instr_type)
            "NOP": return 32'h00000013;
            "HALT": return 32'h00000000;
            
            // R-Type
            "ADD", "ADD_V", "ADD_S": begin
                opcode = (instr_type == "ADD_S") ? 7'h73 : 7'h33;
                funct3 = 3'b000; funct7 = 7'b0000000;
                return {funct7, rs2, rs1, funct3, rd, opcode};
            end
            "SUB", "SUB_V", "SUB_S": begin
                opcode = (instr_type == "SUB_S") ? 7'h73 : 7'h33;
                funct3 = 3'b000; funct7 = 7'b0100000;
                return {funct7, rs2, rs1, funct3, rd, opcode};
            end
            "SLL", "SLL_V", "SLL_S": begin
                opcode = (instr_type == "SLL_S") ? 7'h73 : 7'h33;
                funct3 = 3'b001; funct7 = 7'b0000000;
                return {funct7, rs2, rs1, funct3, rd, opcode};
            end
            "SLT", "SLT_V", "SLT_S": begin
                opcode = (instr_type == "SLT_S") ? 7'h73 : 7'h33;
                funct3 = 3'b010; funct7 = 7'b0000000;
                return {funct7, rs2, rs1, funct3, rd, opcode};
            end
            "SLTU", "SLTU_V", "SLTU_S": begin
                opcode = (instr_type == "SLTU_S") ? 7'h73 : 7'h33;
                funct3 = 3'b011; funct7 = 7'b0000000;
                return {funct7, rs2, rs1, funct3, rd, opcode};
            end
            "XOR", "XOR_V", "XOR_S": begin
                opcode = (instr_type == "XOR_S") ? 7'h73 : 7'h33;
                funct3 = 3'b100; funct7 = 7'b0000000;
                return {funct7, rs2, rs1, funct3, rd, opcode};
            end
            "SRL", "SRL_V", "SRL_S": begin
                opcode = (instr_type == "SRL_S") ? 7'h73 : 7'h33;
                funct3 = 3'b101; funct7 = 7'b0000000;
                return {funct7, rs2, rs1, funct3, rd, opcode};
            end
            "SRA", "SRA_V", "SRA_S": begin
                opcode = (instr_type == "SRA_S") ? 7'h73 : 7'h33;
                funct3 = 3'b101; funct7 = 7'b0100000;
                return {funct7, rs2, rs1, funct3, rd, opcode};
            end
            "OR", "OR_V", "OR_S": begin
                opcode = (instr_type == "OR_S") ? 7'h73 : 7'h33;
                funct3 = 3'b110; funct7 = 7'b0000000;
                return {funct7, rs2, rs1, funct3, rd, opcode};
            end
            "AND", "AND_V", "AND_S": begin
                opcode = (instr_type == "AND_S") ? 7'h73 : 7'h33;
                funct3 = 3'b111; funct7 = 7'b0000000;
                return {funct7, rs2, rs1, funct3, rd, opcode};
            end
            
            // I-Type
            "ADDI", "ADDI_V", "ADDI_S": begin
                opcode = (instr_type == "ADDI_S") ? 7'h53 : 7'h13;
                funct3 = 3'b000;
                return {imm[11:0], rs1, funct3, rd, opcode};
            end
            "SLTI", "SLTI_V", "SLTI_S": begin
                opcode = (instr_type == "SLTI_S") ? 7'h53 : 7'h13;
                funct3 = 3'b010;
                return {imm[11:0], rs1, funct3, rd, opcode};
            end
            "SLTIU", "SLTIU_V", "SLTIU_S": begin
                opcode = (instr_type == "SLTIU_S") ? 7'h53 : 7'h13;
                funct3 = 3'b011;
                return {imm[11:0], rs1, funct3, rd, opcode};
            end
            "XORI", "XORI_V", "XORI_S": begin
                opcode = (instr_type == "XORI_S") ? 7'h53 : 7'h13;
                funct3 = 3'b100;
                return {imm[11:0], rs1, funct3, rd, opcode};
            end
            "ORI", "ORI_V", "ORI_S": begin
                opcode = (instr_type == "ORI_S") ? 7'h53 : 7'h13;
                funct3 = 3'b110;
                return {imm[11:0], rs1, funct3, rd, opcode};
            end
            "ANDI", "ANDI_V", "ANDI_S": begin
                opcode = (instr_type == "ANDI_S") ? 7'h53 : 7'h13;
                funct3 = 3'b111;
                return {imm[11:0], rs1, funct3, rd, opcode};
            end
            "SLLI", "SLLI_V", "SLLI_S": begin
                opcode = (instr_type == "SLLI_S") ? 7'h53 : 7'h13;
                funct3 = 3'b001; funct7 = 7'b0000000;
                return {funct7, imm[4:0], rs1, funct3, rd, opcode};
            end
            "SRLI", "SRLI_V", "SRLI_S": begin
                opcode = (instr_type == "SRLI_S") ? 7'h53 : 7'h13;
                funct3 = 3'b101; funct7 = 7'b0000000;
                return {funct7, imm[4:0], rs1, funct3, rd, opcode};
            end
            "SRAI", "SRAI_V", "SRAI_S": begin
                opcode = (instr_type == "SRAI_S") ? 7'h53 : 7'h13;
                funct3 = 3'b101; funct7 = 7'b0100000;
                return {funct7, imm[4:0], rs1, funct3, rd, opcode};
            end
            
            // Load / Store
            "LW", "LW_V", "LW_S": begin
                opcode = (instr_type == "LW_S") ? 7'h43 : 7'h03;
                funct3 = 3'b010;
                return {imm[11:0], rs1, funct3, rd, opcode};
            end
            "LH", "LH_V", "LH_S": begin
                opcode = (instr_type == "LH_S") ? 7'h43 : 7'h03;
                funct3 = 3'b001;
                return {imm[11:0], rs1, funct3, rd, opcode};
            end
            "LHU", "LHU_V", "LHU_S": begin
                opcode = (instr_type == "LHU_S") ? 7'h43 : 7'h03;
                funct3 = 3'b101;
                return {imm[11:0], rs1, funct3, rd, opcode};
            end
            "LB", "LB_V", "LB_S": begin
                opcode = (instr_type == "LB_S") ? 7'h43 : 7'h03;
                funct3 = 3'b000;
                return {imm[11:0], rs1, funct3, rd, opcode};
            end
            "LBU", "LBU_V", "LBU_S": begin
                opcode = (instr_type == "LBU_S") ? 7'h43 : 7'h03;
                funct3 = 3'b100;
                return {imm[11:0], rs1, funct3, rd, opcode};
            end
            "SW", "SW_V", "SW_S": begin
                opcode = (instr_type == "SW_S") ? 7'h7B : 7'h23; // scalar store avoids 0x63 branch conflict
                funct3 = 3'b010;
                return {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
            end
            "SH", "SH_V", "SH_S": begin
                opcode = (instr_type == "SH_S") ? 7'h7B : 7'h23;
                funct3 = 3'b001;
                return {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
            end
            "SB", "SB_V", "SB_S": begin
                opcode = (instr_type == "SB_S") ? 7'h7B : 7'h23;
                funct3 = 3'b000;
                return {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
            end
            
            // Branch
            "BEQ", "BNE", "BLT", "BGE", "BLTU", "BGEU": begin
                opcode = 7'h63; // B-type (always scalar control flow)
                if (instr_type == "BEQ") funct3 = 3'b000;
                else if (instr_type == "BNE") funct3 = 3'b001;
                else if (instr_type == "BLT") funct3 = 3'b100;
                else if (instr_type == "BGE") funct3 = 3'b101;
                else if (instr_type == "BLTU") funct3 = 3'b110;
                else funct3 = 3'b111;
                return {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], opcode};
            end
            
            // Jump
            "JAL": begin
                opcode = 7'h6F;
                return {imm[20], imm[10:1], imm[11], imm[19:12], rd, opcode};
            end
            "JALR": begin
                opcode = 7'h67;
                funct3 = 3'b000;
                return {imm[11:0], rs1, funct3, rd, opcode};
            end
            
            // Upper Immediates
            "LUI", "LUI_V", "LUI_S": begin
                opcode = (instr_type == "LUI_S") ? 7'h77 : 7'h37;
                return {imm[31:12], rd, opcode};
            end
            "AUIPC", "AUIPC_V", "AUIPC_S": begin
                opcode = (instr_type == "AUIPC_S") ? 7'h57 : 7'h17;
                return {imm[31:12], rd, opcode};
            end
            
            // Custom instructions
            "SX_S": begin
                opcode = 7'h7E;
                funct3 = 3'b010; funct7 = 7'b0000000;
                return {funct7, rs2, rs1, funct3, rd, opcode};
            end
            "SX_I": begin
                opcode = 7'h7D;
                funct3 = 3'b010;
                return {imm[11:0], rs1, funct3, rd, opcode};
            end

            default: begin
                $display("ERROR: Unknown instr_type %s", instr_type);
                return 32'h0;
            end
        endcase
    endfunction

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
    parameter int MEM_SIZE   = 1024,
    parameter int TAG_WIDTH  = 1
)(
    input  logic                    clk,
    input  logic                    reset,
    // Memory interface
    input  logic                    valid,
    input  logic [ADDR_WIDTH-1:0]   addr,
    input  logic [DATA_WIDTH-1:0]   wdata,
    input  logic [(DATA_WIDTH/8)-1:0] we,  // Write enable (byte-level, sized to data width)
    input  logic [TAG_WIDTH-1:0]    tag = '0,
    output logic                    ready,
    output logic                    resp_valid,
    input  logic                    resp_ready,                // Receiver tells model it can accept response
    output logic [DATA_WIDTH-1:0]   rdata,
    output logic [TAG_WIDTH-1:0]    resp_tag
);
    
    // Memory array
    logic [DATA_WIDTH-1:0] mem [MEM_SIZE];
    
    // Pipeline registers for 1-cycle latency
    logic [ADDR_WIDTH-1:0] addr_reg;
    logic valid_reg;
    logic [(DATA_WIDTH/8)-1:0] we_reg;
    logic [DATA_WIDTH-1:0] wdata_reg;
    logic [TAG_WIDTH-1:0]  tag_reg;
    
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
            resp_tag <= 0;
            addr_reg <= 0;
            valid_reg <= 0;
            we_reg <= 0;
            wdata_reg <= 0;
            tag_reg <= 0;
        end else begin
            // Pipeline stage 1: capture request only when no response is parked
            //   (otherwise we'd overwrite wdata_reg/addr_reg mid-stall)
            if (!resp_valid || resp_ready) begin
                valid_reg <= valid;
                addr_reg <= addr;
                we_reg <= we;
                wdata_reg <= wdata;
                tag_reg <= tag;
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
                resp_tag <= tag_reg;
                resp_valid <= 1;
                if (DATA_WIDTH == 32) $display("IMEM: Fetched addr=%0d data=0x%0h", addr_reg, mem[addr_reg]);
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
// doesn't accept/return immediately. 
//////////////////////////////////////////////////////////////////////////////////

module memory_model_stall #(
    parameter int ADDR_WIDTH   = 32,
    parameter int DATA_WIDTH   = 32,
    parameter int MEM_SIZE     = 1024,
    parameter int MAX_LATENCY  = 5,    // Max response latency in cycles (>=1)
    parameter int TAG_WIDTH    = 1
)(
    input  logic                    clk,
    input  logic                    reset,
    input  logic                    valid,
    input  logic [ADDR_WIDTH-1:0]   addr,
    input  logic [DATA_WIDTH-1:0]   wdata,
    input  logic [(DATA_WIDTH/8)-1:0] we,
    input  logic [TAG_WIDTH-1:0]    tag,
    output logic                    ready,
    output logic                    resp_valid,
    input  logic                    resp_ready,
    output logic [DATA_WIDTH-1:0]   rdata,
    output logic [TAG_WIDTH-1:0]    resp_tag
);

    logic [DATA_WIDTH-1:0] mem [MEM_SIZE];

    // Request-side backpressure: ready is a registered, randomly-toggled signal
    logic ready_reg;
    logic busy;          // A request is being serviced
    assign ready = ready_reg && !busy && !(resp_valid && !resp_ready);

    // In-flight transaction bookkeeping
    logic [ADDR_WIDTH-1:0]    addr_lat;
    logic [(DATA_WIDTH/8)-1:0] we_lat;
    logic [DATA_WIDTH-1:0]    wdata_lat;
    logic [TAG_WIDTH-1:0]     tag_lat;
    int                       latency_cnt;   // Counts down to response

    initial begin
        for (int i = 0; i < MEM_SIZE; i++) mem[i] = 0;
    end

    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            ready_reg   <= 1'b1;
            resp_valid  <= 1'b0;
            rdata       <= '0;
            resp_tag    <= '0;
            addr_lat    <= '0;
            we_lat      <= '0;
            wdata_lat   <= '0;
            tag_lat     <= '0;
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
                tag_lat     <= tag;
                latency_cnt <= (($random & 32'h7FFFFFFF) % MAX_LATENCY) + 1;  // 1..MAX_LATENCY
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
                    resp_tag   <= tag_lat;
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

//////////////////////////////////////////////////////////////////////////////////
// Reusable mem_controller test environment
//
// Wraps mem_controller together with one behavioral memory model per channel.
// mem_mode picks what sits behind the channels: the ideal model, the stalling
// model, or the test itself (MEM_DRIVEN), which lets a test choose the exact
// completion order instead of whatever the models happen to produce.
//
// Tests only drive the user-side request/response interface, so none of them
// repeat the DUT instantiation or the per-channel memory-model generate block.
// The mem-side signals stay internal and are read hierarchically where a test
// needs to observe them (env.mem_valid), same as env.dut for controller state.
//////////////////////////////////////////////////////////////////////////////////
module mc_test_env #(
    parameter int DATA_WIDTH     = 32,
    parameter int ADDR_WIDTH     = 32,
    parameter int NUM_USERS      = 4,
    parameter int NUM_CHANNELS   = 4,
    parameter int MEM_LINE_BYTES = 4,
    parameter int MEM_DEPTH      = 256,
    parameter int RESP_BUF_DEPTH = 2,
    parameter int REQ_TAG_WIDTH  = common_pkg::REQ_TAG_WIDTH
)(
    input  logic                      clk,
    input  logic                      reset,
    // user-side request interface
    output logic [NUM_USERS-1:0]      req_ready,
    input  logic [NUM_USERS-1:0]      req_valid,
    input  logic [MEM_LINE_BYTES-1:0] req_we   [NUM_USERS],
    input  logic [ADDR_WIDTH-1:0]     req_addr [NUM_USERS],
    input  logic [DATA_WIDTH-1:0]     req_data [NUM_USERS],
    input  logic [REQ_TAG_WIDTH-1:0]  req_tag  [NUM_USERS],
    // user-side response interface
    output logic [NUM_USERS-1:0]      req_resp_valid,
    input  logic [NUM_USERS-1:0]      req_resp_ready,
    output logic [DATA_WIDTH-1:0]     req_resp_data [NUM_USERS],
    output logic [REQ_TAG_WIDTH-1:0]  req_resp_tag  [NUM_USERS],
    // selects which memory behavior sits behind the channels
    input  tb_common_pkg::mem_mode_t  mem_mode,
    // channel responses driven by the test, used only when mem_mode is MEM_DRIVEN
    input  logic [NUM_CHANNELS-1:0]   drv_mem_ready,
    input  logic [NUM_CHANNELS-1:0]   drv_mem_resp_valid,
    input  logic [DATA_WIDTH-1:0]     drv_mem_resp_data [NUM_CHANNELS]
);
    localparam int CH_ADDR_LSB   = $clog2(MEM_LINE_BYTES) + $clog2(NUM_CHANNELS);
    localparam int CH_ADDR_WIDTH = ADDR_WIDTH - CH_ADDR_LSB;

    // memory-side wiring between controller and per-channel models
    logic [NUM_CHANNELS-1:0]   mem_ready, mem_valid;
    logic [MEM_LINE_BYTES-1:0] mem_we   [NUM_CHANNELS];
    logic [CH_ADDR_WIDTH-1:0]  mem_addr [NUM_CHANNELS];
    logic [DATA_WIDTH-1:0]     mem_data [NUM_CHANNELS];
    logic [NUM_CHANNELS-1:0]   mem_resp_valid;
    logic [DATA_WIDTH-1:0]     mem_resp_data [NUM_CHANNELS];

    mem_controller #(
        .DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH), .NUM_USERS(NUM_USERS),
        .NUM_CHANNELS(NUM_CHANNELS), .MEM_LINE_BYTES(MEM_LINE_BYTES),
        .RESP_BUF_DEPTH(RESP_BUF_DEPTH), .REQ_TAG_WIDTH(REQ_TAG_WIDTH)
    ) dut (
        .clk(clk), .reset(reset),
        .req_ready(req_ready), .req_valid(req_valid), .req_we(req_we),
        .req_addr(req_addr), .req_data(req_data), .req_tag(req_tag),
        .req_resp_valid(req_resp_valid), .req_resp_ready(req_resp_ready),
        .req_resp_data(req_resp_data), .req_resp_tag(req_resp_tag),
        .mem_ready(mem_ready), .mem_valid(mem_valid), .mem_we(mem_we),
        .mem_addr(mem_addr), .mem_data(mem_data),
        .mem_resp_valid(mem_resp_valid), .mem_resp_ready(), .mem_resp_data(mem_resp_data)
    );

    // ideal and stalling models per channel, mem_mode selects which one the
    // controller sees, or hands the channel over to the test in MEM_DRIVEN
    logic [NUM_CHANNELS-1:0] ideal_ready, ideal_resp_valid, stall_ready, stall_resp_valid;
    logic [DATA_WIDTH-1:0]   ideal_rdata [NUM_CHANNELS], stall_rdata [NUM_CHANNELS];

    always_comb begin
        for (int ch = 0; ch < NUM_CHANNELS; ch++) begin
            case (mem_mode)
                tb_common_pkg::MEM_STALL: begin
                    mem_ready[ch]      = stall_ready[ch];
                    mem_resp_valid[ch] = stall_resp_valid[ch];
                    mem_resp_data[ch]  = stall_rdata[ch];
                end
                tb_common_pkg::MEM_DRIVEN: begin
                    mem_ready[ch]      = drv_mem_ready[ch];
                    mem_resp_valid[ch] = drv_mem_resp_valid[ch];
                    mem_resp_data[ch]  = drv_mem_resp_data[ch];
                end
                default: begin // MEM_IDEAL
                    mem_ready[ch]      = ideal_ready[ch];
                    mem_resp_valid[ch] = ideal_resp_valid[ch];
                    mem_resp_data[ch]  = ideal_rdata[ch];
                end
            endcase
        end
    end

    // each model only sees requests while it is the selected one, so an
    // unselected model never advances state or drifts out of sync
    generate
        for (genvar ch = 0; ch < NUM_CHANNELS; ch++) begin : gen_mem_ch
            memory_model #(
                .ADDR_WIDTH(CH_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .MEM_SIZE(MEM_DEPTH)
            ) ideal_mem (
                .clk(clk), .reset(reset),
                .valid(mem_valid[ch] & (mem_mode == tb_common_pkg::MEM_IDEAL)),
                .addr(mem_addr[ch]),
                .wdata(mem_data[ch]), .we(mem_we[ch]),
                .ready(ideal_ready[ch]), .resp_valid(ideal_resp_valid[ch]),
                .resp_ready(1'b1), .rdata(ideal_rdata[ch])
            );
            memory_model_stall #(
                .ADDR_WIDTH(CH_ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .MEM_SIZE(MEM_DEPTH),
                .MAX_LATENCY(5)
            ) stall_mem (
                .clk(clk), .reset(reset),
                .valid(mem_valid[ch] & (mem_mode == tb_common_pkg::MEM_STALL)),
                .addr(mem_addr[ch]),
                .wdata(mem_data[ch]), .we(mem_we[ch]),
                .ready(stall_ready[ch]), .resp_valid(stall_resp_valid[ch]),
                .resp_ready(1'b1), .rdata(stall_rdata[ch])
            );
        end
    endgenerate
endmodule

`endif
