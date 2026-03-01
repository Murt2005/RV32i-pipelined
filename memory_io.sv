`ifndef _memory_io_
`define _memory_io_
`include "system.sv"

typedef struct packed {
    logic [`word_address_size-1:0]    addr;
    logic [31:0]    data;
    logic [3:0]     do_read;
    logic [3:0]     do_write;
    logic           valid;
    logic [2:0]     dummy;
    logic [`user_tag_size-1:0] user_tag;
}   memory_io_req32;

localparam memory_io_no_req32 = { {(`word_address_size){1'b0}}, 32'b0, 4'b0, 4'b0, 1'b0, 3'b000, {(`user_tag_size){1'b0}} };

typedef struct packed {
    logic [`word_address_size-1:0]    addr;
    logic [31:0]    data;
    logic           valid;
    logic           ready;
    logic [1:0]     dummy;
    logic [`user_tag_size - 1:0] user_tag;
}   memory_io_rsp32;

localparam memory_io_no_rsp32 = { {(`word_address_size){1'b0}}, 32'd0, 1'b0, 1'b1, 2'b00, {(`user_tag_size){1'b0}} };

`define whole_word32  4'b1111

function automatic logic is_whole_word32(logic [3:0] control);
    return control[0] & control[1] & control[2] & control[3];
endfunction

function automatic logic is_any_byte32(logic [3:0] control);
    return control[0] | control[1] | control[2] | control[3];
endfunction


typedef memory_io_req32     memory_io_req;
typedef memory_io_rsp32     memory_io_rsp;
localparam memory_io_no_req = memory_io_no_req32;
localparam memory_io_no_rsp = memory_io_no_rsp32;
function automatic logic is_any_byte(logic [3:0] control);
    return is_any_byte32(control);
endfunction
function automatic logic is_whole_word(logic [3:0] control);
    return is_whole_word32(control);
endfunction


`endif
