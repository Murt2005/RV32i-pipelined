`ifndef _dcache_sv
`define _dcache_sv

`include "system.sv"
`include "memory_io.sv"

// ---------------------------------------------------------------------------
// Data cache for the SDRAM region: direct mapped, write-through, no write
// allocate.
//
// Write-through rather than write-back on purpose, and it is not simply the
// easier option being dressed up. A write-back cache needs a dirty bit per line
// and an eviction path that writes a line out before reading the new one in --
// more state, and a second reason for a miss to take a long time. Write-through
// keeps a line clean by construction, so a miss is always a plain fill.
//
// The thing that usually argues for write-back is the store bandwidth, and here
// the hottest store stream by far is the framebuffer, which is a separate target
// that never comes through this cache at all. That removes most of the pressure
// before it starts. If profiling later says otherwise, adding a dirty bit is a
// change to this file.
//
// No write allocate: a store that misses is sent straight to memory and does not
// pull the line in. Writing a whole line to fill it, only to then overwrite part
// of it, costs a read the program never asked for. A store that hits does update
// the cached copy, so a read-after-write to the same line still hits.
//
// Ordering: a store is posted -- acknowledged as soon as it is accepted by the
// memory below, not when it lands -- but only one access is ever outstanding, so
// a later load cannot overtake an earlier store. That is what makes it safe to
// skip a write buffer entirely for now; a deeper buffer is only worth having
// once the core can issue more than one access at a time.
// ---------------------------------------------------------------------------
module dcache #(
    parameter int line_words = 8,          // 32-byte lines
    parameter int sets       = 512         // 512 * 32 = 16 KiB
) (
    input  logic clk,
    input  logic reset,

    input  memory_io_req  cpu_req,
    output memory_io_rsp  cpu_rsp,

    output memory_io_req  mem_req,
    input  memory_io_rsp  mem_rsp
);

localparam int WORD_W = $clog2(line_words);
localparam int IDX_W  = $clog2(sets);
localparam int OFF_LO = 2;
localparam int IDX_LO = OFF_LO + WORD_W;
localparam int TAG_LO = IDX_LO + IDX_W;
localparam int TAG_W  = `word_address_size - TAG_LO;

logic [31:0]      data_ram [0:sets*line_words-1];
logic [TAG_W-1:0] tag_ram  [0:sets-1];
logic             valid_ram[0:sets-1];

wire [`word_address_size-1:0] req_addr = cpu_req.addr;
wire [IDX_W-1:0]   req_idx  = req_addr[IDX_LO+IDX_W-1:IDX_LO];
wire [TAG_W-1:0]   req_tag  = req_addr[`word_address_size-1:TAG_LO];
wire [WORD_W-1:0]  req_word = req_addr[IDX_LO-1:OFF_LO];
wire               req_is_write = is_any_byte(cpu_req.do_write);

localparam logic [2:0] S_IDLE = 3'd0, S_LOOK = 3'd1, S_FILL = 3'd2,
                       S_DONE = 3'd3, S_WRITE = 3'd4;
logic [2:0] state;

logic [`word_address_size-1:0] pend_addr;
logic [IDX_W-1:0]   pend_idx;
logic [TAG_W-1:0]   pend_tag;
logic [WORD_W-1:0]  pend_word;
logic [31:0]        pend_data;
logic [3:0]         pend_wmask;
logic               pend_write;
logic [WORD_W:0]    fill_count;
logic [WORD_W-1:0]  fill_word;
logic               issued;

logic [31:0]      look_data;
logic [TAG_W-1:0] look_tag;
logic             look_valid;

wire hit = look_valid & (look_tag == pend_tag);

// Zeroed for the same reason memory.sv zeroes its arrays: an uninitialised RAM
// reads as X, and X does not stay put. rvfi_mem_rdata samples the data response
// unconditionally, so a single X word turns the commit record into "xxxxxxxx"
// and the cross-check dies parsing it rather than reporting a mismatch.
initial begin
    for (int k = 0; k < sets*line_words; k++) data_ram[k] = 32'd0;
    for (int k = 0; k < sets; k++) begin
        tag_ram[k]   = '0;
        valid_ram[k] = 1'b0;
    end
    look_data  = 32'd0;
    look_tag   = '0;
    look_valid = 1'b0;
end


// Byte-wise merge of a store into a cached word, so a partial write updates the
// copy here as well as memory. Without it the cache would serve the pre-store
// value for the untouched lanes on the next read.
function automatic logic [31:0] merge(logic [31:0] old_w, logic [31:0] new_w,
                                      logic [3:0] mask);
    merge = {mask[3] ? new_w[31:24] : old_w[31:24],
             mask[2] ? new_w[23:16] : old_w[23:16],
             mask[1] ? new_w[15:8]  : old_w[15:8],
             mask[0] ? new_w[7:0]   : old_w[7:0]};
endfunction

// ready is built only from registers, never from the request -- see the note in
// bus/decoder.sv. Accepting during a read hit keeps back-to-back loads at one
// per cycle.
wire can_accept = (state == S_IDLE) | ((state == S_LOOK) & hit & ~pend_write);
wire take       = cpu_req.valid & can_accept
                & (is_any_byte(cpu_req.do_read) | is_any_byte(cpu_req.do_write));

assign cpu_rsp.ready    = can_accept;
assign cpu_rsp.addr     = pend_addr;
assign cpu_rsp.user_tag = '0;
assign cpu_rsp.dummy    = '0;
assign cpu_rsp.valid    = ((state == S_LOOK) & hit & ~pend_write) | (state == S_DONE);
assign cpu_rsp.data     = (state == S_DONE) ? data_ram[{pend_idx, pend_word}]
                                            : look_data;

always_comb begin
    mem_req = memory_io_no_req;
    if (state == S_WRITE) begin
        // Write-through: the store goes to memory whether or not it hit.
        mem_req.addr     = pend_addr;
        mem_req.data     = pend_data;
        mem_req.do_write = pend_wmask;
        mem_req.valid    = ~issued & mem_rsp.ready;
    end else if (state == S_FILL) begin
        mem_req.addr    = {pend_addr[`word_address_size-1:IDX_LO], fill_word, 2'b00};
        mem_req.do_read = 4'b1111;
        mem_req.valid   = ~issued & mem_rsp.ready;
    end
end

integer i;
always_ff @(posedge clk) begin
    if (reset) begin
        state  <= S_IDLE;
        issued <= 1'b0;
        for (i = 0; i < sets; i = i + 1)
            valid_ram[i] <= 1'b0;
    end else begin
        case (state)
            S_IDLE, S_LOOK: begin
                if (take) begin
                    pend_addr  <= req_addr;
                    pend_idx   <= req_idx;
                    pend_tag   <= req_tag;
                    pend_word  <= req_word;
                    pend_data  <= cpu_req.data;
                    pend_wmask <= cpu_req.do_write;
                    pend_write <= req_is_write;
                    look_data  <= data_ram[{req_idx, req_word}];
                    look_tag   <= tag_ram[req_idx];
                    look_valid <= valid_ram[req_idx];
                    state      <= S_LOOK;
                end else if (state == S_LOOK) begin
                    if (pend_write) begin
                        // A store updates the cached copy only if the line is
                        // already here; no write allocate.
                        if (hit)
                            data_ram[{pend_idx, pend_word}] <=
                                merge(look_data, pend_data, pend_wmask);
                        issued <= 1'b0;
                        state  <= S_WRITE;
                    end else if (hit)
                        state <= S_IDLE;
                    else begin
                        fill_word           <= '0;
                        fill_count          <= '0;
                        issued              <= 1'b0;
                        valid_ram[pend_idx] <= 1'b0;
                        state               <= S_FILL;
                    end
                end
            end

            S_WRITE: begin
                if (mem_req.valid)
                    issued <= 1'b1;
                if (mem_rsp.valid) begin
                    issued <= 1'b0;
                    state  <= S_DONE;
                end
            end

            S_FILL: begin
                if (mem_req.valid)
                    issued <= 1'b1;
                if (mem_rsp.valid) begin
                    data_ram[{pend_idx, fill_word}] <= mem_rsp.data;
                    issued <= 1'b0;
                    if (fill_count == line_words - 1) begin
                        tag_ram[pend_idx]   <= pend_tag;
                        valid_ram[pend_idx] <= 1'b1;
                        state               <= S_DONE;
                    end else begin
                        fill_word  <= fill_word + 1'b1;
                        fill_count <= fill_count + 1'b1;
                    end
                end
            end

            S_DONE: state <= S_IDLE;

            default: state <= S_IDLE;
        endcase
    end
end

`ifndef SYNTHESIS
always @(posedge clk)
    if (!reset && cpu_req.valid && !can_accept)
        $error("%m: request presented while not ready (addr %08x)", cpu_req.addr);
`endif

endmodule

`endif
