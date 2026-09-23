// 640x480@60 VGA scanout, with the 320x200 framebuffer doubled and letterboxed
// Framebuffer then palette reads take two cycles, so sync and blank are delayed to match

module vga #(
    // 640x480@60; 25.0 MHz instead of 25.175 is close enough for any monitor
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

    // Framebuffer and palette reads each take one cycle
    output logic [16:0] fb_addr,
    input  logic [7:0]  fb_index,

    output logic [7:0]  pal_addr,
    input  logic [23:0] pal_rgb,      // {R[7:0], G[7:0], B[7:0]}

    // To the ADV7123
    output logic [7:0]  vga_r,
    output logic [7:0]  vga_g,
    output logic [7:0]  vga_b,
    output logic        vga_hs,
    output logic        vga_vs,
    output logic        vga_blank_n,
    output logic        vga_sync_n,

    // One pulse per frame
    output logic        vsync_pulse
);

    localparam int H_TOTAL = h_visible + h_front + h_sync + h_back;   // 800
    localparam int V_TOTAL = v_visible + v_front + v_sync + v_back;   // 525

    // 320x200 doubled is 640x400, centred in 480 lines
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

    // Stage 0: framebuffer address for this pixel
    wire h_active = (hcnt < HW'(h_visible));
    wire v_active = (vcnt < VW'(v_visible));
    wire in_image = h_active
                  & (vcnt >= VW'(V_MARGIN))
                  & (vcnt <  VW'(V_MARGIN + V_IMAGE));

    wire [8:0] fb_x = hcnt[HW-1:1];                        // /2, 0..319
    wire [7:0] fb_y = 8'((vcnt - VW'(V_MARGIN)) >> 1);     // /2, 0..199

    // 320y = 256y + 64y, so no multiplier is needed
    wire [16:0] fb_off = {1'b0, fb_y, 8'b0} + {3'b0, fb_y, 6'b0};

    assign fb_addr = in_image ? (fb_off + {8'b0, fb_x}) : 17'd0;

    // Stage 1: pixel index to palette
    assign pal_addr = fb_index;

    // Sync is active low, delayed two cycles to line up with the pixel data
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

    // Black outside the letterboxed image
    assign vga_r = image_2 ? pal_rgb[23:16] : 8'h00;
    assign vga_g = image_2 ? pal_rgb[15:8]  : 8'h00;
    assign vga_b = image_2 ? pal_rgb[7:0]   : 8'h00;

    // One cycle at the start of vertical blanking
    logic vs_2_q;
    always_ff @(posedge clk) begin
        if (reset) vs_2_q <= 1'b1;
        else       vs_2_q <= vs_2;
    end
    assign vsync_pulse = vs_2_q & ~vs_2;   // falling edge of active-low vs

endmodule
