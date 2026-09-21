`ifndef _base_
`define _base_

// Icarus has `bool` as a built-in keyword, so typedef'ing it there is an error.
// Every other tool (verilator, sv2v/yosys) needs the declaration -- without it
// the ISA package's function return types do not parse.
`ifndef __ICARUS__
typedef logic bool;
`endif

// Useful macros to make the code more readable
localparam true = 1'b1;
localparam false = 1'b0;
localparam one = 1'b1;
localparam zero = 1'b0;

`endif
