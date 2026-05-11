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
// 
//////////////////////////////////////////////////////////////////////////////////

import common_pkg::*;

// for simplicity, LSU is implemented per thread instead of per warp/thread group
module lsu #(
    parameter int CACHE_LINE_BYTE_SIZE = 4
    )(
    input logic clk, reset,
    input warp_state_t warp_state,
    input logic thread_active,  // execution mask for this thread
    // data + control signals
    input data_t rs1, rs2, imm,
    input logic [1:0] DataSize,
    input logic DMemR_W,
    input logic Usign,
    // data mem
    output logic mem_valid,
    output data_mem_addr_t mem_addr,
    output data_t mem_data,
    output logic [CACHE_LINE_BYTE_SIZE-1:0] mem_we,
    input logic mem_resp_ready,
    input data_t mem_resp_data,
    // output back to core
    output lsu_state_t lsu_state_out,
    output data_t lsu_out
    );
    
    // addr is always rs1 + imm
    data_t addr;
    assign addr = rs1 + imm;
    
    // load & store + WE logic
    // the following section only works for byte-addressable with 32-bit channels (4 bytes)
    // TBD: logic when CACHE_LINE_BYTE_SIZE is a larger multitude of 4
    data_t load_result, store_result;
    logic [CACHE_LINE_BYTE_SIZE-1:0] WE_result;
    logic [15:0] halfword_data;
    logic [7:0] byte_data;
    logic halfword_sign, byte_sign;
    
    always_comb begin
        // default assignments
        store_result = 32'bx;
        load_result = 32'bx;
        WE_result = 4'bx;
        halfword_data = 16'bx;
        byte_data = 8'bx;
        halfword_sign = 1'b0;
        byte_sign = 1'b0;
        
        case(DataSize) // 1 - halfword, 0 - word, 2 - byte
            0: begin 
                store_result = rs2; 
                load_result = mem_resp_data; 
                WE_result = 4'b1111;
            end
            1: begin
                store_result = {2{rs2[15:0]}};
                case(addr[1:0]) // assume no unaligned accesses
                    0: begin
                        halfword_data = mem_resp_data[15:0];
                        WE_result = 4'b0011;
                    end
                    2: begin
                        halfword_data = mem_resp_data[31:16];
                        WE_result = 4'b1100;
                    end
                    default: begin 
                        halfword_data = 16'bx; 
                        WE_result = 4'bx; 
                    end
                endcase
                halfword_sign = Usign ? 1'b0 : halfword_data[15];
                load_result = {{16{halfword_sign}}, halfword_data};
            end
            2: begin
                store_result = {4{rs2[7:0]}};
                case(addr[1:0]) 
                    0: begin 
                        byte_data = mem_resp_data[7:0]; 
                        WE_result = 4'b0001; 
                    end
                    1: begin 
                        byte_data = mem_resp_data[15:8]; 
                        WE_result = 4'b0010; 
                    end
                    2: begin 
                        byte_data = mem_resp_data[23:16]; 
                        WE_result = 4'b0100; 
                    end
                    3: begin 
                        byte_data = mem_resp_data[31:24]; 
                        WE_result = 4'b1000; 
                    end
                endcase
                byte_sign = Usign ? 1'b0 : byte_data[7];
                load_result = {{24{byte_sign}}, byte_data};
            end 
            default: begin 
                store_result = 32'bx; 
                load_result = 32'bx; 
                WE_result = 4'bx; 
            end
        endcase
        if(!DMemR_W) WE_result = 4'b0000; // if not store, WE is always 0
    end
    
    data_t next_lsu_out, next_mem_data; assign next_lsu_out = load_result; assign next_mem_data = store_result; 
    logic [CACHE_LINE_BYTE_SIZE-1:0] next_mem_we; assign next_mem_we = WE_result;
        
    lsu_state_t s;
    data_t lsu_out_reg;  // registered output for stability
    
    // combinational outputs for mem interface and done signal
    always_comb begin
        // defaults
        mem_valid = 0;
        mem_addr = 0;
        mem_data = 0;
        mem_we = 0;
        lsu_out = lsu_out_reg;  // default to reg value
        
        // only initiate memory requests if thread is active
        if (thread_active && s == LSU_IDLE && warp_state == WARP_MEMORY) begin
            mem_valid = 1;
            mem_addr = addr;
            mem_data = next_mem_data;
            mem_we = next_mem_we;
        end else if (thread_active && s == LSU_REQUESTING) begin
            mem_valid = 1;
            mem_addr = addr;  // hold address stable during request
            mem_data = next_mem_data;  // hold data stable
            mem_we = next_mem_we;  // hold write enable stable
            if (mem_resp_ready) begin
                lsu_out = next_lsu_out;  // pass through fresh data
            end
        end
    end
    
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            s <= LSU_IDLE;
            lsu_out_reg <= 0;
        end else begin
            // inactive threads skip memory operations entirely
            if (!thread_active) begin
                s <= LSU_IDLE;  // stay idle
            end else begin
                case (s)
                    LSU_IDLE: begin
                        if (warp_state == WARP_MEMORY) begin
                            s <= LSU_REQUESTING;
                        end
                    end
                    LSU_REQUESTING: begin
                        if (mem_resp_ready) begin
                            lsu_out_reg <= next_lsu_out;  // reg for stability
                            s <= LSU_DONE;
                        end
                    end
                    LSU_DONE: begin
                        if (warp_state == WARP_WRITEBACK) begin
                            s <= LSU_IDLE;
                        end
                    end
                    default: $error("Invalid LSU state");
                endcase
            end
        end
    end
    
    assign lsu_state_out = s;
        
endmodule
