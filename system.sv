`ifndef _system_
`define _system_

`define word_size 32
`define word_address_size 32

`define word_size_bytes (`word_size/8)
`define word_address_size_bytes (`word_address_size/8)

`define user_tag_size 16

typedef logic [31:0] word;
`endif
