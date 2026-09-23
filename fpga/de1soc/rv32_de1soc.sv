// DE1-SoC top: the shared top.sv plus the board's clocks, VGA, PS/2 keyboard and SDRAM
// stall stays tied low until the liveness bug on that path (see DOOM_PLAN.md) is fixed

`include "system.sv"
`include "memory_io.sv"

module rv32_de1soc (
    input  logic        CLOCK_50,
    input  logic [3:0]  KEY,          // active low
    input  logic [9:0]  SW,
    output logic [9:0]  LEDR,

    // VGA, via the ADV7123
    output logic        VGA_CLK,
    output logic [7:0]  VGA_R,
    output logic [7:0]  VGA_G,
    output logic [7:0]  VGA_B,
    output logic        VGA_HS,
    output logic        VGA_VS,
    output logic        VGA_BLANK_N,
    output logic        VGA_SYNC_N,

    // PS/2, receive only
    input  logic        PS2_CLK,
    input  logic        PS2_DAT,

    // SDRAM, IS42S16320D
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

    // Quartus PLL, declared as a black box so this file also elaborates in iverilog
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

    // DRAM_CLK comes straight from a phase-shifted PLL output, never through logic
    assign DRAM_CLK = clk_dram;

    // Held in reset until the PLL locks and for a while after, for the SDRAM's power-on wait
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

    // Turn set-2 scancodes into the {pressed, code} events the MMIO block expects
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

    assign VGA_CLK = clk_pix;

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

    // The shared top.sv, built with BOARD_TOP for the real SDRAM, framebuffer and palette
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

    // Status LEDs for bring-up
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
