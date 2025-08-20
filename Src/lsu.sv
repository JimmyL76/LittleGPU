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
module lsu(
    input logic clk, reset,
    input warp_state_t warp_state,
    // from core
    input logic core_we,
    input data_t rs1, rs2, imm,
    // data mem
    output logic mem_valid,
    output data_mem_addr_t mem_addr,
    output data_t mem_data,
    output logic mem_we,
    input logic mem_resp_ready,
    input data_t mem_resp_data,
    // output back to core
    output lsu_state_t lsu_state_out,
    output data_t lsu_out
    );
    
    // addr is always rs1 + imm
    data_t addr;
    assign addr = rs1 + imm;
    
    // load + store logic
    // MEMORY LOGIC
    // load & store + WE logic
    logic [31:0] next_load_result;
    logic [3:0] next_WE_result;
    always_comb begin
        case(DataSize) 
            0: begin 
                store_result = memory.rs2; 
                load_result = D_Mem_Bus; WE_result = 4'b1111;
            end
            1: begin
                store_result = {2{memory.rs2[15:0]}};
                if(memory.contr.Usign) 
                    case(memory.alu[1:0]) // assume no unaligned
                        0: begin
                        load_result = D_Mem_Bus[15:0];
                        WE_result = 4'b0011;
                        end
                        2: begin
                        load_result = D_Mem_Bus[31:16];
                        WE_result = 4'b1100;
                        end
                        default: begin load_result = 32'bx; WE_result = 4'bx; end
                    endcase
                else 
                    case(memory.alu[1:0]) 
                        0: begin
                        load_result = {{16{D_Mem_Bus[15]}}, D_Mem_Bus[15:0]};
                        WE_result = 4'b0011;
                        end
                        2: begin 
                        load_result = {{16{D_Mem_Bus[31]}}, D_Mem_Bus[31:16]};
                        WE_result = 4'b1100;
                        end
                        default: begin load_result = 32'bx; WE_result = 4'bx; end
                    endcase
            end
            2: begin
                store_result = {4{memory.rs2[7:0]}};
                if(memory.contr.Usign) 
                    case(memory.alu[1:0]) 
                        0: begin load_result = D_Mem_Bus[7:0]; WE_result = 4'b0001; end
                        1: begin load_result = D_Mem_Bus[15:8]; WE_result = 4'b0010; end
                        2: begin load_result = D_Mem_Bus[23:16]; WE_result = 4'b0100; end
                        3: begin load_result = D_Mem_Bus[31:24]; WE_result = 4'b1000; end
                    endcase
                else 
                    case(memory.alu[1:0]) 
                        0: begin load_result = {{24{D_Mem_Bus[7]}}, D_Mem_Bus[7:0]}; WE_result = 4'b0001; end
                        1: begin load_result = {{24{D_Mem_Bus[15]}}, D_Mem_Bus[15:8]}; WE_result = 4'b0010; end
                        2: begin load_result = {{24{D_Mem_Bus[23]}}, D_Mem_Bus[23:16]}; WE_result = 4'b0100; end
                        3: begin load_result = {{24{D_Mem_Bus[31]}}, D_Mem_Bus[31:24]}; WE_result = 4'b1000; end
                    endcase
            end 
            default: begin store_result = 32'bx; load_result = 32'bx; WE_result = 4'bx; end
        endcase
        if(!memory.contr.DMemR_W) WE_result = 4'b0000; // if not store, WE is always 0
    end
    
    lsu_state_t s;
    
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            s <= LSU_IDLE;
            mem_valid <= 0;
            mem_addr <= 0;
            mem_data <= 0;
            lsu_out <= 0;
            mem_we <= 0;
        end else begin
            case (s)
                LSU_IDLE: begin
                    if (warp_state == WARP_REQUEST) begin
                        mem_valid <= 1;
                        mem_addr <= addr;
                        mem_data <= rs2;
                        mem_we <= core_we;
                        s <= LSU_REQUESTING;
                    end
                end
                LSU_REQUESTING: begin
                    if (mem_resp_ready) begin
                        mem_valid <= 0;
                        lsu_out <= mem_resp_data;
                        s <= LSU_DONE;
                    end
                end
                LSU_DONE: begin
                    if (warp_state == WARP_WAIT) begin
                        s <= LSU_IDLE;
                    end
                end
                default: $error("Invalid LSU state");
            endcase
        end
    end
    
    assign lsu_state_out = s;
        
endmodule
