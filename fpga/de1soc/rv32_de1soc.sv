// DE1-SoC board top: the RV32 machine with real video, a real keyboard and a
// real SDRAM behind it.
//
// The bus, caches, on-chip memories and MMIO all live in the shared top.sv and
// are not repeated here -- this file is only the things that exist because
// there is a board. Doing it the other way, with a board-specific copy of the
// bus, means two versions that drift and a Doom that works in one of them.
//
// ---------------------------------------------------------------------------
// Clocking: 50 MHz for everything except scanout, which is 25 MHz.
//
// The plan called for the SDRAM at 100 MHz with a 2:1 clock-enable crossing.
// This runs it at 50 MHz, in the CPU's own domain, on purpose: it removes the
// crossing entirely for bring-up, and a controller that is *correct* at half
// the bandwidth is worth more right now than one that is fast and suspect. The
// timing parameters are computed from clk_hz, so raising it later is a
// parameter change plus a re-run of sdram_tb, not a rewrite.
//
// Scanout genuinely is a separate domain, and needs no synchroniser: the
// framebuffer is a true dual-port M10K with independent clocks per port, so the
// CPU writes port A at 50 MHz while the video side reads port B at 25 MHz. The
// worst case is a pixel one frame stale, never a corrupt one.
//
// ---------------------------------------------------------------------------
// The core's `stall` input is tied low here, and that is a decision rather than
// an omission.
//
// On the iCE40 board `stall` carries UART transmit backpressure. Formal found a
// counterexample on that path (liveness_ch0, see DOOM_PLAN.md): one stalled
// cycle with a JAL in fetch leaves the instruction latched and never retiring --
// a core that is busy rather than hung, which no watchdog catches. That bug is
// not fixed yet. This board loads over JTAG rather than a UART and has no need
// to backpressure the pipeline, so the path is left unexercised instead of
// carried onto hardware. If anything ever wants to drive `stall` here, the
// liveness failure has to be closed first.

`include "system.sv"
`include "memory_io.sv"

module rv32_de1soc (
    input  logic        CLOCK_50,
    input  logic [3:0]  KEY,          // active low
    input  logic [9:0]  SW,
    output logic [9:0]  LEDR,

    // VGA, via the ADV7123.
    output logic        VGA_CLK,
    output logic [7:0]  VGA_R,
    output logic [7:0]  VGA_G,
    output logic [7:0]  VGA_B,
    output logic        VGA_HS,
    output logic        VGA_VS,
    output logic        VGA_BLANK_N,
    output logic        VGA_SYNC_N,

    // PS/2. Receive only; these are bidirectional on the board but nothing
    // here sends to the keyboard.
    input  logic        PS2_CLK,
    input  logic        PS2_DAT,

    // SDRAM, IS42S16320D.
    output logic [12:0] DRAM_ADDR,
    output logic [1:0]  DRAM_BA,
    output logic        DRAM_CAS_N,
    output logic        DRAM_CKE,
    output logic        DRAM_CLK,
    output logic        DRAM_CS_N,
    inout  wire  [15:0] DRAM_DQ,
    output logic        DRAM_LDQM,
    output logic        DRAM_UDQM,
    output logic        DRAM_RAS_N,
    output logic        DRAM_WE_N
);

    // ---- clocks ----------------------------------------------------------
    // A Quartus PLL instance goes here. Declared as a black box so that this
    // file elaborates in iverilog for the board-level testbench; the generated
    // altera_pll is dropped in at synthesis and matches this port list.
    logic clk_sys;      // 50 MHz, CPU + SDRAM
    logic clk_pix;      // 25 MHz, scanout
    logic clk_dram;     // 50 MHz, phase-shifted -3ns for the DRAM_CLK pin
    logic pll_locked;

    de1soc_pll pll (
        .refclk   (CLOCK_50),
        .rst      (~KEY[0]),
        .outclk_0 (clk_sys),
        .outclk_1 (clk_pix),
        .outclk_2 (clk_dram),
        .locked   (pll_locked)
    );

    // The DRAM clock is driven from a phase-shifted PLL output rather than from
    // clk_sys through logic: the part samples our outputs on its own clock
    // edge, so it needs to arrive early enough to meet setup at the device
    // after board delay. Routing a clock through the fabric instead is the
    // classic reason an SDRAM works in simulation and not on the bench.
    assign DRAM_CLK = clk_dram;

    // Reset until the PLL locks, plus KEY[0] as a manual reset. Held for a
    // while after lock so the SDRAM's own power-on quiet time is honoured from
    // a defined start rather than from whenever configuration happened.
    logic [15:0] reset_cnt;
    logic        reset;
    always_ff @(posedge clk_sys) begin
        if (!pll_locked || !KEY[0]) begin
            reset_cnt <= '0;
            reset     <= 1'b1;
        end else if (reset_cnt != 16'hFFFF) begin
            reset_cnt <= reset_cnt + 16'd1;
            reset     <= 1'b1;
        end else begin
            reset     <= 1'b0;
        end
    end

    // ---- PS/2 ------------------------------------------------------------
    logic       ps2_valid;
    logic [7:0] ps2_code;
    logic       ps2_err_parity, ps2_err_framing, ps2_err_timeout;

    ps2_keyboard #(.clk_hz(50_000_000)) kbd (
        .clk(clk_sys), .reset(reset),
        .ps2_clk(PS2_CLK), .ps2_dat(PS2_DAT),
        .code_valid(ps2_valid), .code(ps2_code),
        .err_parity(ps2_err_parity), .err_framing(ps2_err_framing),
        .err_timeout(ps2_err_timeout)
    );

    // Scancode set 2 to the key events top.sv's MMIO block already accepts.
    // 0xF0 prefixes a release and 0xE0 an extended code; both are consumed here
    // so the CPU sees the same {pressed, code} pairs the simulation harness
    // injects, and the software side does not change between the two.
    logic       key_strobe;
    logic [8:0] key_event;
    logic       next_is_break, next_is_ext;

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            key_strobe    <= 1'b0;
            next_is_break <= 1'b0;
            next_is_ext   <= 1'b0;
        end else begin
            key_strobe <= 1'b0;
            if (ps2_valid) begin
                if (ps2_code == 8'hF0) begin
                    next_is_break <= 1'b1;
                end else if (ps2_code == 8'hE0) begin
                    next_is_ext <= 1'b1;
                end else begin
                    key_event     <= {~next_is_break, ps2_code};
                    key_strobe    <= 1'b1;
                    next_is_break <= 1'b0;
                    next_is_ext   <= 1'b0;
                end
            end
        end
    end

    // ---- video -----------------------------------------------------------
    logic [16:0] fb_addr;
    logic [7:0]  fb_index;
    logic [7:0]  pal_addr;
    logic [23:0] pal_rgb;
    logic        vsync_pulse;

    vga scanout (
        .clk(clk_pix), .reset(reset),
        .fb_addr(fb_addr), .fb_index(fb_index),
        .pal_addr(pal_addr), .pal_rgb(pal_rgb),
        .vga_r(VGA_R), .vga_g(VGA_G), .vga_b(VGA_B),
        .vga_hs(VGA_HS), .vga_vs(VGA_VS),
        .vga_blank_n(VGA_BLANK_N), .vga_sync_n(VGA_SYNC_N),
        .vsync_pulse(vsync_pulse)
    );

    // The ADV7123 latches on the rising edge of its own clock input, so it gets
    // the pixel clock directly.
    assign VGA_CLK = clk_pix;

    // ---- SDRAM -----------------------------------------------------------
    memory_io_req sdram_req;
    memory_io_rsp sdram_rsp;
    logic         sdram_init_done;
    logic [1:0]   dram_dqm;

    assign {DRAM_UDQM, DRAM_LDQM} = dram_dqm;

    sdram_ctrl #(.clk_hz(50_000_000), .cas_latency(3)) dram (
        .clk(clk_sys), .reset(reset),
        .req(sdram_req), .rsp(sdram_rsp),
        .dram_addr(DRAM_ADDR), .dram_ba(DRAM_BA), .dram_cke(DRAM_CKE),
        .dram_cs_n(DRAM_CS_N), .dram_ras_n(DRAM_RAS_N), .dram_cas_n(DRAM_CAS_N),
        .dram_we_n(DRAM_WE_N), .dram_dqm(dram_dqm), .dram_dq(DRAM_DQ),
        .init_done(sdram_init_done)
    );

    // ---- the machine -----------------------------------------------------
    //
    // The same top.sv every simulation and every test in the project runs
    // through, compiled with BOARD_TOP so that the SDRAM comes from the
    // controller above, the framebuffer gains its scanout port, and the palette
    // is readable by the DAC side. The simulation build is textually unchanged
    // by that define; `make cycle-check` reports identical counts across all
    // 103 tests.
    //
    // stall_rate and mem_delay are the simulation injectors and are tied off:
    // the first is the path the liveness counterexample lives on (see the file
    // header), the second models a memory that is now real.
    logic halt, frame_done;

    top #(
        .sdram_bytes(32'h0400_0000)          // the real 64 MiB
    ) machine (
        .clk(clk_sys),
        .reset(reset),
        .stall_rate(8'd0),
        .mem_delay(8'd0),
        .halt(halt),
        .frame_done(frame_done),
        .key_strobe(key_strobe),
        .key_event(key_event),

        .sdram_req_o(sdram_req),
        .sdram_rsp_i(sdram_rsp),

        .fb_rd_clk(clk_pix),
        .fb_rd_addr(fb_addr),
        .fb_rd_data(fb_index),

        .pal_rd_addr(pal_addr),
        .pal_rd_data(pal_rgb)
    );

    // ---- bring-up visibility ---------------------------------------------
    // LEDs before a console, because these are the only thing that works when
    // nothing else does.
    assign LEDR[0] = pll_locked;
    assign LEDR[1] = ~reset;
    assign LEDR[2] = sdram_init_done;
    assign LEDR[3] = halt;
    assign LEDR[4] = frame_done;
    assign LEDR[5] = ps2_valid;
    assign LEDR[6] = ps2_err_parity | ps2_err_framing | ps2_err_timeout;
    assign LEDR[7] = vsync_pulse;
    assign LEDR[9:8] = SW[9:8];

endmodule
