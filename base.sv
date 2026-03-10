`ifndef _base_
`define _base_

// Icarus Verilog (used for simulation) does not accept `logic` as a builtin
// type in the same way as Yosys/other SV tools. Provide a simple typedef that
// is compatible with both flows by switching on a define we pass from the
// Makefile when invoking iverilog.
`ifdef IVERILOG
// Icarus has spotty support for `typedef` in some configurations.
// Use a macro alias instead so `bool` can still be used as a "type token".
`define bool bit
`else
typedef logic bool;
`endif
// Useful macros to make the code more readable
localparam true = 1'b1;
localparam false = 1'b0;
localparam one = 1'b1;
localparam zero = 1'b0;

`endif
