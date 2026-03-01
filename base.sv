`ifndef _base_
`define _base_

`ifdef verilator
typedef logic bool;
`endif
// Useful macros to make the code more readable
localparam true = 1'b1;
localparam false = 1'b0;
localparam one = 1'b1;
localparam zero = 1'b0;

`endif
