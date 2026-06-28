`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/19/2025 11:09:04 AM
// Design Name: 
// Module Name: fetcher
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

module fetcher (
    input logic clk, reset,
    input warp_state_t warp_state,
    input instr_mem_addr_t pc,
    // instr mem
    output logic mem_valid,
    output instr_mem_addr_t mem_addr,
    input logic mem_resp_valid,
    output logic mem_resp_ready,
    input instr_t mem_resp_data,
    // output back to core
    output logic done,
    output instr_t out_instr
    );
    
    fetcher_state_t s;
    instr_t out_instr_reg;  // registered instruction
    
    // combinational outputs
    always_comb begin
        // defaults
        mem_valid = 0;
        mem_addr = 0;
        mem_resp_ready = 0;
        done = 0;
        out_instr = out_instr_reg;  // default to reg value
        
        if (s == FETCHER_IDLE && warp_state == WARP_FETCH) begin
            mem_valid = 1;
            mem_addr = pc;
        end else if (s == FETCHER_FETCHING) begin
            mem_valid = 1;
            mem_addr = pc;  // hold address stable during fetch
            mem_resp_ready = 1; // ready to accept response while fetching
            if (mem_resp_valid) begin
                done = 1;  // done when memory responds
                out_instr = mem_resp_data;  // pass through fresh data
            end
        end
    end
    
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            s <= FETCHER_IDLE;
            out_instr_reg <= 0;
        end else begin
            case (s)
                FETCHER_IDLE: begin
                    if (warp_state == WARP_FETCH) begin
                        s <= FETCHER_FETCHING;
                    end
                end 
                FETCHER_FETCHING: begin
                    if (mem_resp_valid) begin
                        out_instr_reg <= mem_resp_data;  // reg for stability
                        s <= FETCHER_IDLE;
                    end
                end 
                default: $error("Invalid fetcher state");             
            endcase
        end
    end
    
endmodule
