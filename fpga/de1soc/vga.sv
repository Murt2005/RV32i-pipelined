// VGA scanout for the DE1-SoC's ADV7123 video DAC.
//
// 640x480@60 timing, with Doom's 320x200 framebuffer pixel-doubled to 640x400
// and letterboxed into the middle. 640x480 rather than a mode that fits 320x200
// exactly because every monitor made in the last thirty years syncs to it
// without argument, and bring-up should not also be a display-compatibility
// exercise.
//
// The framebuffer is read on its second port at the pixel clock while the CPU
// writes the first at 50 MHz. M10K blocks support independent clocks per port
// natively, so this is a dual-port memory rather than a clock-domain crossing:
// there is no handshake here and none is needed. Reading a location the CPU is
// writing in the same cycle yields old or new data, never a corrupt byte, and
// the visible consequence is a pixel that is one frame stale.
//
// Two pipeline stages sit between deciding to read a pixel and driving it:
//
//   cycle 0   fb_addr driven from the counters
//   cycle 1   fb_index arrives; drives pal_addr
//   cycle 2   pal_rgb arrives; drives the DAC
//
// so hs, vs and blank are delayed by the same two cycles. Getting that wrong
// does not produce a broken picture -- it produces a picture shifted two pixels
// left with a two-pixel colour fringe at the edges, which is exactly the kind
// of thing that gets blamed on the monitor for a week.

module vga #(
    // 640x480@60. The nominal pixel clock is 25.175 MHz; 25.0 MHz is 0.7% slow
    // and every monitor tolerates it. The DE1-SoC's PLL can make 25.175 exactly
    // if some display ever objects.
    parameter int h_visible = 640,
    parameter int h_front   = 16,
    parameter int h_sync    = 96,
    parameter int h_back    = 48,

    parameter int v_visible = 480,
    parameter int v_front   = 10,
    parameter int v_sync    = 2,
    parameter int v_back    = 33,

    parameter int fb_w = 320,
    parameter int fb_h = 200
) (
    input  logic        clk,          // pixel clock, 25 MHz
    input  logic        reset,

    // Framebuffer port B. One cycle of read latency.
    output logic [16:0] fb_addr,
    input  logic [7:0]  fb_index,

    // Palette lookup. One cycle of read latency.
    output logic [7:0]  pal_addr,
    input  logic [23:0] pal_rgb,      // {R[7:0], G[7:0], B[7:0]}

    // To the ADV7123.
    output logic [7:0]  vga_r,
    output logic [7:0]  vga_g,
    output logic [7:0]  vga_b,
    output logic        vga_hs,
    output logic        vga_vs,
    output logic        vga_blank_n,
    output logic        vga_sync_n,

    // For the CPU side: one pulse per frame, in the pixel domain.
    output logic        vsync_pulse
);

    localparam int H_TOTAL = h_visible + h_front + h_sync + h_back;   // 800
    localparam int V_TOTAL = v_visible + v_front + v_sync + v_back;   // 525

    // 320x200 doubled is 640x400, centred in 480 lines.
    localparam int V_IMAGE  = fb_h * 2;                 // 400
    localparam int V_MARGIN = (v_visible - V_IMAGE) / 2; // 40

    localparam int HW = $clog2(H_TOTAL);
    localparam int VW = $clog2(V_TOTAL);

    logic [HW-1:0] hcnt;
    logic [VW-1:0] vcnt;

    always_ff @(posedge clk) begin
        if (reset) begin
            hcnt <= '0;
            vcnt <= '0;
        end else if (hcnt == HW'(H_TOTAL - 1)) begin
            hcnt <= '0;
            vcnt <= (vcnt == VW'(V_TOTAL - 1)) ? '0 : vcnt + VW'(1);
        end else begin
            hcnt <= hcnt + HW'(1);
        end
    end

    // ---- stage 0: where in the framebuffer this pixel comes from ----------
    wire h_active = (hcnt < HW'(h_visible));
    wire v_active = (vcnt < VW'(v_visible));
    wire in_image = h_active
                  & (vcnt >= VW'(V_MARGIN))
                  & (vcnt <  VW'(V_MARGIN + V_IMAGE));

    wire [8:0] fb_x = hcnt[HW-1:1];                        // /2, 0..319
    wire [7:0] fb_y = 8'((vcnt - VW'(V_MARGIN)) >> 1);     // /2, 0..199

    // 320 is not a power of two, so this is a real multiply. Written as
    // shift-and-add rather than `*` because the DE1-SoC has DSP blocks but
    // there is no reason to spend one on a constant: 320y = 256y + 64y.
    wire [16:0] fb_off = {1'b0, fb_y, 8'b0} + {3'b0, fb_y, 6'b0};

    assign fb_addr = in_image ? (fb_off + {8'b0, fb_x}) : 17'd0;

    // ---- stage 1: index -> palette ---------------------------------------
    assign pal_addr = fb_index;

    // ---- sync and blank, delayed to match the two read stages ------------
    // Active low, and the polarity is not negotiable: 640x480@60 specifies
    // negative sync on both. Getting it backwards gives a rolling picture.
    wire hs_0 = ~((hcnt >= HW'(h_visible + h_front)) &
                  (hcnt <  HW'(h_visible + h_front + h_sync)));
    wire vs_0 = ~((vcnt >= VW'(v_visible + v_front)) &
                  (vcnt <  VW'(v_visible + v_front + v_sync)));
    wire blank_0 = h_active & v_active;
    wire image_0 = in_image;

    logic hs_1, vs_1, blank_1, image_1;
    logic hs_2, vs_2, blank_2, image_2;

    always_ff @(posedge clk) begin
        if (reset) begin
            {hs_1, vs_1, blank_1, image_1} <= 4'b1100;
            {hs_2, vs_2, blank_2, image_2} <= 4'b1100;
        end else begin
            hs_1 <= hs_0;  vs_1 <= vs_0;  blank_1 <= blank_0;  image_1 <= image_0;
            hs_2 <= hs_1;  vs_2 <= vs_1;  blank_2 <= blank_1;  image_2 <= image_1;
        end
    end

    assign vga_hs      = hs_2;
    assign vga_vs      = vs_2;
    assign vga_blank_n = blank_2;
    assign vga_sync_n  = 1'b0;         // sync-on-green unused; tie low per DE1-SoC

    // Black outside the letterboxed image, so the margins are not whatever the
    // palette happens to hold at index 0.
    assign vga_r = image_2 ? pal_rgb[23:16] : 8'h00;
    assign vga_g = image_2 ? pal_rgb[15:8]  : 8'h00;
    assign vga_b = image_2 ? pal_rgb[7:0]   : 8'h00;

    // One cycle at the start of vertical blanking. The CPU side uses this to
    // pace itself to the display if it ever runs fast enough to want to.
    logic vs_2_q;
    always_ff @(posedge clk) begin
        if (reset) vs_2_q <= 1'b1;
        else       vs_2_q <= vs_2;
    end
    assign vsync_pulse = vs_2_q & ~vs_2;   // falling edge of active-low vs

endmodule
