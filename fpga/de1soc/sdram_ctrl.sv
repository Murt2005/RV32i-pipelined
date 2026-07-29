// SDRAM controller for the DE1-SoC's IS42S16320D: 64 MB, x16, 4 banks,
// 8192 rows, 1024 columns.
//
// Presents the project's `memory_io` contract, so from the caches' side this is
// interchangeable with memory.sv and memory_delay.sv: a request is accepted
// when rsp.ready is high, and exactly one rsp.valid follows with rsp.addr
// echoing. Everything below is about honouring that while an SDRAM does what an
// SDRAM does.
//
// Open page, one row at a time. The caches fill a 32-byte line as *eight
// separate word requests* at consecutive addresses (bus/icache.sv:127), not as
// a burst. Closing the row after each would pay activate + precharge eight
// times for one line -- roughly 80 cycles where 25 will do. So the open row is
// left open, and a request that hits it costs only a CAS. Sequential access,
// which is what a line fill and what Doom's renderer both produce, is the case
// this is tuned for.
//
// One row rather than one per bank. Four open rows would help a workload that
// interleaves streams -- and Doom's renderer is exactly that, a texture and a
// destination at unrelated addresses. It is deliberately not done yet: bank
// tracking multiplies the state and the timing checks by four, and this needs
// to be *correct* before it is clever. The measurement to justify it belongs on
// hardware, where a miss actually costs something.
//
// Burst length 2, so one SDRAM burst is exactly one 32-bit word. The alternative
// -- BL1 and two commands -- doubles the command count for no benefit, and
// longer bursts cannot be used when the client asks for one word at a time.
//
// Timing is in clock cycles at `clk_hz`, computed from the datasheet's
// nanoseconds so that changing the clock does not silently violate anything.

`include "memory_io.sv"

module sdram_ctrl #(
    parameter int clk_hz = 100_000_000,

    // IS42S16320D geometry.
    parameter int row_bits  = 13,
    parameter int col_bits  = 10,
    parameter int bank_bits = 2,

    // Datasheet, -7 grade. Rounded up to whole cycles.
    parameter int t_rcd_ns   = 20,     // activate -> read/write
    parameter int t_rp_ns    = 20,     // precharge -> activate
    parameter int t_rc_ns    = 70,     // activate -> activate, same bank
    parameter int t_rfc_ns   = 70,     // refresh cycle
    parameter int t_wr_ns    = 14,     // write recovery
    parameter int t_init_us  = 100,    // power-on quiet time
    parameter int cas_latency = 3,     // 2 or 3; 3 is safe at 100 MHz

    // 8192 rows in 64 ms.
    parameter int refresh_us_x100 = 781   // 7.81 us, in hundredths
) (
    input  logic clk,
    input  logic reset,

    // CPU side.
    input  memory_io_req  req,
    output memory_io_rsp  rsp,

    // SDRAM pins.
    output logic [row_bits-1:0]  dram_addr,
    output logic [bank_bits-1:0] dram_ba,
    output logic                 dram_cke,
    output logic                 dram_cs_n,
    output logic                 dram_ras_n,
    output logic                 dram_cas_n,
    output logic                 dram_we_n,
    output logic [1:0]           dram_dqm,
    inout  wire  [15:0]          dram_dq,

    // Bring-up visibility. `ready` here means initialisation has finished;
    // before that every request is refused rather than queued.
    output logic init_done
);

    // ---- timing, in cycles -------------------------------------------------
    localparam int NS_PER_CYCLE = 1_000_000_000 / clk_hz;
    `define CYC(ns) (((ns) + NS_PER_CYCLE - 1) / NS_PER_CYCLE)

    localparam int T_RCD  = `CYC(t_rcd_ns);
    localparam int T_RP   = `CYC(t_rp_ns);
    localparam int T_RC   = `CYC(t_rc_ns);
    localparam int T_RFC  = `CYC(t_rfc_ns);
    localparam int T_WR   = `CYC(t_wr_ns);
    localparam int T_INIT = (clk_hz / 1_000_000) * t_init_us;
    localparam int T_REF  = (clk_hz / 100_000_000) * refresh_us_x100;

    localparam int CW = 16;                      // wide enough for T_INIT
    localparam int RW = $clog2(T_REF + 1);

    // ---- command encoding, {cs,ras,cas,we} ---------------------------------
    localparam logic [3:0] CMD_NOP      = 4'b0111;
    localparam logic [3:0] CMD_ACTIVE   = 4'b0011;
    localparam logic [3:0] CMD_READ     = 4'b0101;
    localparam logic [3:0] CMD_WRITE    = 4'b0100;
    localparam logic [3:0] CMD_PRECHARGE= 4'b0010;
    localparam logic [3:0] CMD_REFRESH  = 4'b0001;
    localparam logic [3:0] CMD_LMR      = 4'b0000;
    localparam logic [3:0] CMD_INHIBIT  = 4'b1111;

    logic [3:0] cmd;
    assign {dram_cs_n, dram_ras_n, dram_cas_n, dram_we_n} = cmd;

    // Mode register: burst length 2, sequential, CAS latency, single-location
    // write (A9=1) so a write burst does not scribble past the word we mean.
    localparam logic [12:0] MODE_REG =
        {3'b000, 1'b1, 2'b00, cas_latency[2:0], 1'b0, 3'b001};

    // ---- address split -----------------------------------------------------
    // Column in the low bits so that consecutive words stay in one row: a row
    // holds 1024 x 16 bits = 2 KiB, which is 64 cache lines.
    //
    //   byte addr  [25:24] bank | [23:11] row | [10:1] col | [0] byte-in-word
    //
    // req.addr is a *word* address in this design's convention, so it is
    // shifted up by two to get bytes before being split.
    wire [25:0] byte_addr = {req.addr[23:0], 2'b00};
    wire [bank_bits-1:0] req_bank = byte_addr[25:24];
    wire [row_bits-1:0]  req_row  = byte_addr[23:11];
    wire [col_bits-1:0]  req_col  = byte_addr[10:1];

    // ---- state -------------------------------------------------------------
    typedef enum logic [3:0] {
        S_INIT_WAIT, S_INIT_PRE, S_INIT_REF1, S_INIT_REF2, S_INIT_LMR,
        S_IDLE, S_ACTIVATE, S_READ, S_READ_WAIT, S_WRITE, S_WRITE_WAIT,
        S_PRECHARGE, S_REFRESH
    } state_t;

    state_t state;
    logic [CW-1:0] timer;          // counts down; 0 means "may proceed"
    logic [RW-1:0] refresh_timer;
    logic          refresh_due;

    logic                 row_open;
    logic [row_bits-1:0]  open_row;
    logic [bank_bits-1:0] open_bank;

    // The captured request. Latched because req may not be held, and because
    // the response must echo the address it was made with.
    logic [`word_address_size-1:0] cap_addr;
    logic [31:0]                   cap_data;
    logic [3:0]                    cap_wr;
    logic                          cap_is_write;
    logic [bank_bits-1:0]          cap_bank;
    logic [row_bits-1:0]           cap_row;
    logic [col_bits-1:0]           cap_col;

    logic [15:0] rd_lo;
    logic [2:0]  cas_count;

    // ---- DQ tristate -------------------------------------------------------
    logic        dq_drive;
    logic [15:0] dq_out;
    assign dram_dq = dq_drive ? dq_out : 16'bz;

    assign dram_cke = 1'b1;
    assign init_done = (state != S_INIT_WAIT) && (state != S_INIT_PRE)
                    && (state != S_INIT_REF1) && (state != S_INIT_REF2)
                    && (state != S_INIT_LMR);

    // A request is accepted only when idle, initialised, out of any timing
    // wait, and with no refresh pending. Refusing rather than queueing keeps
    // this to one outstanding access, which the memory_io contract assumes.
    //
    // `timer == 0` is the part that is easy to leave out and fatal to omit. The
    // timer gates the whole state machine, so while it runs -- write recovery,
    // tRP, tRCD -- nothing is sampled. Advertising ready during that window
    // makes the controller drop a request it has already claimed: the client
    // sees ready, believes the access is under way, and waits for a response
    // that will never come. It deadlocked the second write in the testbench,
    // and on hardware it would present as the CPU hanging on a cache miss.
    wire can_accept = (state == S_IDLE) && init_done && !refresh_due
                   && (timer == 0);
    wire req_fire   = req.valid && can_accept
                   && (is_any_byte(req.do_read) || is_any_byte(req.do_write));

    logic        rsp_valid_r;
    logic [31:0] rsp_data_r;

    // One block, because `rsp` is one variable. Two always_comb blocks each
    // assigning part of it is multiple drivers on the whole struct, and the
    // result is not "the fields combine" -- it is undefined, and it showed up
    // as a controller that initialised and then never accepted a request.
    always_comb begin
        rsp       = memory_io_no_rsp;
        rsp.ready = can_accept;
        rsp.addr  = cap_addr;
        rsp.valid = rsp_valid_r;
        rsp.data  = rsp_data_r;
    end

    // ---- refresh accounting ------------------------------------------------
    // Counted independently of the state machine so that a long burst of
    // accesses cannot starve refresh: the flag latches and is only cleared by
    // an actual refresh command.
    always_ff @(posedge clk) begin
        if (reset) begin
            refresh_timer <= '0;
            refresh_due   <= 1'b0;
        end else if (refresh_timer == RW'(T_REF)) begin
            refresh_timer <= '0;
            refresh_due   <= 1'b1;
        end else begin
            refresh_timer <= refresh_timer + RW'(1);
            if (state == S_REFRESH) refresh_due <= 1'b0;
        end
    end

    // ---- main sequencer ----------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset) begin
            state       <= S_INIT_WAIT;
            timer       <= CW'(T_INIT);
            cmd         <= CMD_INHIBIT;
            dram_addr   <= '0;
            dram_ba     <= '0;
            dram_dqm    <= 2'b11;
            dq_drive    <= 1'b0;
            dq_out      <= '0;
            row_open    <= 1'b0;
            rsp_valid_r <= 1'b0;
            cas_count   <= '0;
        end else begin
            cmd         <= CMD_NOP;
            dram_dqm    <= 2'b00;
            dq_drive    <= 1'b0;
            rsp_valid_r <= 1'b0;

            if (timer != 0) begin
                timer <= timer - CW'(1);
            end else begin
                case (state)
                // ---- power-on sequence --------------------------------
                S_INIT_WAIT: begin
                    cmd       <= CMD_PRECHARGE;
                    dram_addr <= 13'h400;         // A10 = all banks
                    state     <= S_INIT_PRE;
                    timer     <= CW'(T_RP - 1);
                end
                S_INIT_PRE: begin
                    cmd   <= CMD_REFRESH;
                    state <= S_INIT_REF1;
                    timer <= CW'(T_RFC - 1);
                end
                S_INIT_REF1: begin
                    cmd   <= CMD_REFRESH;
                    state <= S_INIT_REF2;
                    timer <= CW'(T_RFC - 1);
                end
                S_INIT_REF2: begin
                    cmd       <= CMD_LMR;
                    dram_addr <= MODE_REG;
                    dram_ba   <= '0;
                    state     <= S_INIT_LMR;
                    timer     <= CW'(2);          // tMRD, 2 cycles
                end
                S_INIT_LMR: begin
                    state    <= S_IDLE;
                    row_open <= 1'b0;
                end

                // ---- normal operation ---------------------------------
                S_IDLE: begin
                    if (refresh_due) begin
                        // Precharge first if a row is open; the refresh
                        // itself requires all banks idle.
                        if (row_open) begin
                            cmd       <= CMD_PRECHARGE;
                            dram_addr <= 13'h400;
                            row_open  <= 1'b0;
                            timer     <= CW'(T_RP - 1);
                        end else begin
                            cmd   <= CMD_REFRESH;
                            state <= S_REFRESH;
                            timer <= CW'(T_RFC - 1);
                        end
                    end else if (req_fire) begin
                        cap_addr     <= req.addr;
                        cap_data     <= req.data;
                        cap_wr       <= req.do_write;
                        cap_is_write <= is_any_byte(req.do_write);
                        cap_bank     <= req_bank;
                        cap_row      <= req_row;
                        cap_col      <= req_col;

                        if (row_open && open_row == req_row
                                     && open_bank == req_bank) begin
                            // Row hit: straight to CAS. This is the case the
                            // whole open-page policy exists for.
                            if (is_any_byte(req.do_write)) state <= S_WRITE;
                            else                            state <= S_READ;
                        end else if (row_open) begin
                            cmd       <= CMD_PRECHARGE;
                            dram_addr <= 13'h400;
                            row_open  <= 1'b0;
                            state     <= S_PRECHARGE;
                            timer     <= CW'(T_RP - 1);
                        end else begin
                            state <= S_ACTIVATE;
                        end
                    end
                end

                S_PRECHARGE: state <= S_ACTIVATE;

                S_ACTIVATE: begin
                    cmd       <= CMD_ACTIVE;
                    dram_ba   <= cap_bank;
                    dram_addr <= cap_row;
                    open_row  <= cap_row;
                    open_bank <= cap_bank;
                    row_open  <= 1'b1;
                    if (cap_is_write) state <= S_WRITE;
                    else              state <= S_READ;
                    timer     <= CW'(T_RCD - 1);
                end

                S_READ: begin
                    cmd       <= CMD_READ;
                    dram_ba   <= cap_bank;
                    // A10 = 0: do not auto-precharge, the row stays open.
                    dram_addr <= {3'b000, cap_col};
                    cas_count <= 3'(cas_latency + 1);
                    state     <= S_READ_WAIT;
                end

                S_READ_WAIT: begin
                    // Burst of 2: the first halfword lands cas_latency cycles
                    // after the command, the second on the cycle after that.
                    if (cas_count != 0) begin
                        cas_count <= cas_count - 3'd1;
                        if (cas_count == 3'd1) rd_lo <= dram_dq;
                    end else begin
                        rsp_data_r  <= {dram_dq, rd_lo};
                        rsp_valid_r <= 1'b1;
                        state       <= S_IDLE;
                    end
                end

                S_WRITE: begin
                    cmd       <= CMD_WRITE;
                    dram_ba   <= cap_bank;
                    dram_addr <= {3'b000, cap_col};
                    dq_drive  <= 1'b1;
                    dq_out    <= cap_data[15:0];
                    dram_dqm  <= ~cap_wr[1:0];    // byte enables, active low
                    state     <= S_WRITE_WAIT;
                end

                S_WRITE_WAIT: begin
                    // Second halfword of the burst, on the very next cycle.
                    dq_drive    <= 1'b1;
                    dq_out      <= cap_data[31:16];
                    dram_dqm    <= ~cap_wr[3:2];
                    rsp_data_r  <= 32'd0;
                    rsp_valid_r <= 1'b1;          // writes answer immediately
                    state       <= S_IDLE;
                    timer       <= CW'(T_WR);     // write recovery
                end

                S_REFRESH: state <= S_IDLE;

                default: state <= S_IDLE;
                endcase
            end
        end
    end

`ifndef SYNTHESIS
    // The contract this module has to keep, checked where it is cheap to check.
    always_ff @(posedge clk) begin
        if (!reset) begin
            if (rsp_valid_r && !init_done)
                $error("sdram: response before initialisation finished");
            if (req.valid && rsp.ready && !init_done)
                $error("sdram: accepted a request before initialisation");
        end
    end
`endif

    `undef CYC
endmodule
