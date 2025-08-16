`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/03/2025 09:31:10 AM
// Design Name: 
// Module Name: core
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

module core #(
        parameter int NUM_CORES
    )(
        input logic clk, reset,
        // core info
        input logic start, 
        output logic done,
        input kernel_config_t kernel_config,
        input data_t core_block_id, 
        // kernel execution
        output logic [NUM_CORES-1:0] core_done // NOTE: to skip 1 cycle idle delay, core_done should come 1 cycle before core finishes
    );
    
    
endmodule
