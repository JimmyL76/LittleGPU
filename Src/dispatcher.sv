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
    input logic [NUM_CORES-1:0] core_done,
    output logic [NUM_CORES-1:0] cores_in_use, // status mask for debug: 1 = core executing a block
    output logic [NUM_CORES-1:0] core_start,
    output data_t core_block_id [NUM_CORES], // each core gets its own block id
    // kernel execution
    output logic finished
    );
      
    data_t blocks_dispatched;
    // a finished block/core is when core_done[i] == 1 && cores_in_use[i] == 1
    data_t blocks_finished, next_blocks_finished;
    logic [NUM_CORES-1:0] cores_just_finished;
    always_comb begin
        next_blocks_finished = blocks_finished;
        cores_just_finished = '0;
        for (int i = 0; i < NUM_CORES; i++)
            if (core_done[i] && cores_in_use[i] && !core_start[i]) begin 
                cores_just_finished[i] = 1; // set bit
                next_blocks_finished++; // +1 to blocks finished
            end
    end
    
    // since we process one kernel at a time, blocks_dispatched will never go above num_blocks
    data_t blocks_left;
    assign blocks_left = kernel_config.num_blocks - blocks_dispatched;
    // since we assign blocks in ascending order, the block_id_used is just based on blocks_dispatched
    // this means we assume for simplicity there is no block priority
    data_t block_id_used [4];
    always_comb begin
        for (int i = 0; i < 4; i++)
            block_id_used[i] = blocks_dispatched + i;
    end
    
    // first calculate how many blocks to send out, this system will dispatch up to 4 blocks per cycle
    // to calculate the nth core that is free, use bits and bit masking
    // (~i) & (i + 1) gives the lowest cleared bit ; i = 0101, ~i = 1010, ~i+1 = 1011, i+1 = 0110
    // uses [NUM_CORES-1:0] instead of data_t since # of cores could be not 32
    logic [NUM_CORES-1:0] nth_free_core [4];
    logic [$clog2(NUM_CORES)-1:0] core_id_used [4];
    logic [NUM_CORES-1:0] current_occupied_cores;
    assign current_occupied_cores = (cores_in_use | core_start) & ~cores_just_finished;

    logic [NUM_CORES-1:0] free_pool [4];
    always_comb begin
        free_pool[0] = ~current_occupied_cores;
        nth_free_core[0] = free_pool[0] & (~free_pool[0] + 1'b1);
        for (int i = 1; i < 4; i++) begin
            free_pool[i] = free_pool[i-1] & ~nth_free_core[i-1];
            nth_free_core[i] = free_pool[i] & (~free_pool[i] + 1'b1);
        end
    end
    
    // convert nth_free_cores to core_id 
    genvar j;
    generate 
        for (j = 0; j < 4; j++) begin : onehot_to_binary_func
            utility #(NUM_CORES) util_inst(nth_free_core[j], core_id_used[j]);
        end
    endgenerate
    
    data_t next_blocks_dispatched;
    data_t next_core_block_id [NUM_CORES];
    logic [NUM_CORES-1:0] newly_dispatched_cores;
    always_comb begin
        next_blocks_dispatched = blocks_dispatched; 
        next_core_block_id = core_block_id;
        newly_dispatched_cores = '0;
        for (int i = 0; i < 4; i++) begin
            if ((blocks_left > i) && (|nth_free_core[i])) begin
                next_core_block_id[core_id_used[i]] = block_id_used[i];
                newly_dispatched_cores |= nth_free_core[i];
                next_blocks_dispatched++;
            end 
        end
    end
    
    logic running;
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin 
            finished <= 0;
            running <= 0;
            blocks_dispatched <= 0;
            blocks_finished <= 0;
            cores_in_use <= 0;
            core_start <= '0;
            for (int i = 0; i < NUM_CORES; i++)
                core_block_id[i] <= 0;
        end else if ((start || running) && !finished) begin
            running <= 1;
            cores_in_use <= (cores_in_use & ~cores_just_finished) | newly_dispatched_cores;
            blocks_dispatched <= next_blocks_dispatched;
            core_block_id <= next_core_block_id;
            blocks_finished <= next_blocks_finished;
            core_start <= '0;
            for (int i = 0; i < 4; i++) begin
                if ((blocks_left > i) && (|nth_free_core[i])) begin
                    core_start[core_id_used[i]] <= 1;
                    $display("Dispatcher: Dispatching block %d to core %d", block_id_used[i], core_id_used[i]);
                end
            end
            if (next_blocks_finished == kernel_config.num_blocks) begin
                $display("Dispatcher: Finished execution");
                finished <= 1;
                running <= 0;
            end
        end
    end
    
endmodule
