`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/27/2025 08:50:15 PM
// Design Name: 
// Module Name: dispatcher
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

`include "common.sv"
import common_pkg::*; // import classes and functions

module dispatcher #(
        parameter int NUM_CORES
    )(
        input logic clk, reset, start,
        input kernel_config_t kernel_config,
        // core states
        input logic [NUM_CORES-1:0] core_done, // NOTE: to skip 1 cycle idle delay, core_done should come 1 cycle before core finishes
        output logic [NUM_CORES-1:0] cores_in_use, 
        output data_t [NUM_CORES-1:0] core_block_id, // each core gets its own block id
        // kernel execution
        output logic finished
    );
      
    data_t blocks_dispatched;
    // a finished block/core is when core_done[i] == 1 && cores_in_use[i] == 1
    data_t blocks_finished, next_blocks_finished;
    logic [NUM_CORES-1:0] cores_just_finished;
    always_comb begin
        next_blocks_finished = blocks_finished;
        for (int i = 0; i < NUM_CORES; i++)
            if (core_done[i] && cores_in_use[i]) begin 
                cores_just_finished[i] = 1; // set bit
                next_blocks_finished++; // +1 to blocks finished
            end
    end
    
    // since we process one kernel at a time, blocks_dispatched will never go above num_blocks
    data_t blocks_left;
    assign blocks_left = kernel_config.num_blocks - blocks_dispatched;
    // since we assign blocks in ascending order, the block_id_used is just based on blocks_dispatched
    // this means we assume for simplicity there is no block priority
    data_t [0:3] block_id_used;
    always_comb begin
        for (int i = 0; i < 4; i++)
            block_id_used[i] = blocks_dispatched + i;
    end
    
    // first calculate how many blocks to send out, this system will dispatch up to 4 blocks per cycle
    // to calculate the nth core that is free, use bits and bit masking
    // (~i) & (i + 1) gives the lowest cleared bit ; i = 0101, ~i = 1010, ~i+1 = 1011, i+1 = 0110
    // uses [NUM_CORES-1:0] instead of data_t since # of cores could be not 32
    logic [NUM_CORES-1:0][0:3] nth_free_core;
    logic [$clog2(NUM_CORES)-1:0][0:3] core_id_used;
    always_comb begin
        nth_free_core[0] = ~cores_in_use & (cores_in_use + 1);
        for (int i = 0; i < 4; i++)
            nth_free_core[i] = nth_free_core[i-1] & (~nth_free_core[i-1] + 1);
    end
            
    // convert nth_free_cores to core_id 
    genvar j;
    generate 
        for (j = 0; j < 4; j++) begin : onehot_to_binary_func
            utility #(NUM_CORES) util_inst(nth_free_core[j], core_id_used[j]);
        end  
    endgenerate
    
    logic [NUM_CORES-1:0] next_cores_in_use, next_blocks_dispatched;
    data_t [NUM_CORES-1:0] next_core_block_id;
    always_comb begin
        next_blocks_dispatched = blocks_dispatched; next_cores_in_use = cores_in_use;
        next_core_block_id = core_block_id;
        for (int i = 0; i < 4; i++) begin
            if (blocks_left > i) begin
                next_core_block_id[core_id_used[i]] = block_id_used[i];
                $display("Dispatcher: Dispatching block %d to core %d", block_id_used[i], core_id_used[i]);
            end 
        end
        case (blocks_left)
            0: begin // do nothing on zero
            end
            1: begin
                next_cores_in_use |= nth_free_core[0];
                next_blocks_dispatched = blocks_dispatched + 1;
            end
            2: begin
                next_cores_in_use |= (nth_free_core[0] | nth_free_core[1]);
                next_blocks_dispatched = blocks_dispatched + 2;       
            end
            3: begin
                next_cores_in_use |= (nth_free_core[0] | nth_free_core[1] | nth_free_core[2]);
                next_blocks_dispatched = blocks_dispatched + 3;       
            end
            default: begin // 4 or more
                next_cores_in_use |= (nth_free_core[0] | nth_free_core[1] | nth_free_core[2] | nth_free_core[3]);
                next_blocks_dispatched = blocks_dispatched + 4;       
            end
        endcase
    end
    
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin 
            finished <= 0;
            blocks_dispatched <= 0;
            blocks_finished <= 0;
            cores_in_use <= 0;
            for (int i = 0; i < NUM_CORES; i++)
                core_block_id[i] <= 0;
        end else if (start && (!finished)) begin                
            // dispatch blocks to free cores if available
            cores_in_use <= next_cores_in_use & (~cores_just_finished); // cores that just finished are set to 0
            blocks_dispatched <= next_blocks_dispatched;
            core_block_id <= next_core_block_id;            
        
            // check if finished
            blocks_finished <= next_blocks_finished;
            if (next_blocks_finished == kernel_config.num_blocks) begin
                $display("Dispatcher: Finished execution");
                finished <= 1;
            end
            
        end
    
    end
    
endmodule
