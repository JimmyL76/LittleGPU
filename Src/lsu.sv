`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/19/2025 02:11:29 PM
// Design Name: 
// Module Name: lsu
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//   fire-and-forget address/write-data datapath, no response handling
//   computes addr and formats store data/write-enable, issues for exactly one
//   cycle while thread_active && warp_state==WARP_MEMORY && entry_available,
//   then relies on the memory_scoreboard to catch the eventual response and
//   drive writeback directly, so this module carries no state of its own
//////////////////////////////////////////////////////////////////////////////////

import common_pkg::*;

// for simplicity, LSU is implemented per thread instead of per warp/thread group
module lsu #(
    parameter int MEM_LINE_BYTES = 4
    )(
    // single pre-computed gate for this thread: execution mask bit AND
    // warp_state==WARP_MEMORY AND scoreboard entry_available, folded together
    // once in core.sv (same pattern as the current memory_thread_active) and
    // broadcast, rather than each of THREADS_PER_WARP lanes recomputing the
    // identical warp-wide comparison in parallel
    input logic thread_active,
    // data + control signals
    input data_t rs1, rs2, imm,
    input logic [1:0] DataSize,
    input logic DMemR_W,
    // data mem, request side only so no response ports
    output logic mem_valid,
    output data_mem_addr_t mem_addr,
    output data_t mem_data,
    output logic [MEM_LINE_BYTES-1:0] mem_we
    );
    
    // addr is always rs1 + imm
    data_t addr;
    assign addr = rs1 + imm;
    
    // store data + WE logic
    // the following section only works for byte-addressable with 32-bit channels (4 bytes)
    // TBD: logic when MEM_LINE_BYTES is a larger multitude of 4
    data_t store_result;
    logic [MEM_LINE_BYTES-1:0] WE_result;
    
    always_comb begin
        // default assignments
        store_result = 32'bx;
        WE_result = 4'bx;
        
        case(DataSize) // 1 - halfword, 0 - word, 2 - byte
            0: begin
                store_result = rs2;
                WE_result = 4'b1111;
            end
            1: begin
                store_result = {2{rs2[15:0]}};
                case(addr[1:0]) // assume no unaligned accesses
                    0: WE_result = 4'b0011;
                    2: WE_result = 4'b1100;
                    default: WE_result = 4'bx;
                endcase
            end
            2: begin
                store_result = {4{rs2[7:0]}};
                case(addr[1:0])
                    0: WE_result = 4'b0001;
                    1: WE_result = 4'b0010;
                    2: WE_result = 4'b0100;
                    3: WE_result = 4'b1000;
                endcase
            end
            default: begin
                store_result = 32'bx;
                WE_result = 4'bx;
            end
        endcase
        if(!DMemR_W) WE_result = 4'b0000; // if not store, WE is always 0
    end
    
    // combinational request - single-cycle pulse, no state to hold it up
    always_comb begin
        mem_valid = 1'b0;
        mem_addr = '0;
        mem_data = '0;
        mem_we = '0;
        if (thread_active) begin
            mem_valid = 1'b1;
            mem_addr = addr;
            mem_data = store_result;
            mem_we = WE_result;
        end
    end
        
endmodule
