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

module fetcher(
    input logic clk, reset,
    input warp_state_t warp_state,
    input instr_mem_addr_t pc,
    // instr mem
    output logic mem_valid,
    output instr_mem_addr_t mem_addr,
    input logic mem_resp_ready,
    input instr_t mem_resp_data,
    // output back to core
    output fetcher_state_t out_fetcher_state,
    output instr_t out_instr
    );
    
    fetcher_state_t s;
    
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            s <= FETCHER_IDLE;
            mem_valid <= 0;
            mem_addr <= 0;
            out_instr <= 0;
        end else begin
            case (s)
                FETCHER_IDLE: begin
                    if (warp_state == WARP_FETCH) begin
                        mem_valid <= 1;
                        mem_addr <= pc;
                        s <= FETCHER_FETCHING;
                    end
                end 
                FETCHER_FETCHING: begin
                    if (mem_resp_ready) begin
                        mem_valid <= 0;
                        out_instr <= mem_resp_data;
                        s <= FETCHER_DONE;
                    end
                end 
                FETCHER_DONE: begin // extra state to wait for warp (like a done signal)
                    if (warp_state == WARP_DECODE) begin
                        s <= FETCHER_IDLE;
                    end
                end
                default: $error("Invalid fetcher state");             
            endcase
        end
    end
    
    assign out_fetcher_state = s;
    
endmodule
