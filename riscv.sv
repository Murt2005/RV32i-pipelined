`ifndef riscv_common_pkg
`define riscv_common_pkg

`include "system.sv"

package riscv;
`ifdef __64bit__
`include "riscv64_common.sv"
`else
`include "riscv32_common.sv"
`endif
endpackage;

`endif
