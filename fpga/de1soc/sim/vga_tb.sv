// Checks the VGA timing against the 640x480@60 numbers, and checks that the
// pixel pipeline lines up with the sync it is supposed to accompany.
//
// The second half is the point. Timing counters are easy and rarely wrong; the
// two-cycle delay between reading a framebuffer address and driving the DAC is
// easy and frequently wrong, and its symptom on a real monitor -- a picture
// shifted two pixels with a colour fringe at one edge -- looks like a cable or
// a monitor problem rather than an RTL one.
//
//   iverilog -g2012 -o build/de1soc/vga_tb fpga/de1soc/sim/vga_tb.sv fpga/de1soc/vga.sv
//   ./build/de1soc/vga_tb

`timescale 1ns / 1ps

module vga_tb;

    logic clk = 0, reset = 1;
    always #20 clk = ~clk;          // 25 MHz

    logic [16:0] fb_addr;
    logic [7:0]  fb_index;
    logic [7:0]  pal_addr;
    logic [23:0] pal_rgb;
    logic [7:0]  r, g, b;
    logic        hs, vs, blank_n, sync_n, vsync_pulse;

    vga dut (
        .clk(clk), .reset(reset),
        .fb_addr(fb_addr), .fb_index(fb_index),
        .pal_addr(pal_addr), .pal_rgb(pal_rgb),
        .vga_r(r), .vga_g(g), .vga_b(b),
        .vga_hs(hs), .vga_vs(vs), .vga_blank_n(blank_n), .vga_sync_n(sync_n),
        .vsync_pulse(vsync_pulse)
    );

    // A framebuffer and palette that encode their own address, so a pixel that
    // arrives at the wrong time is identifiable rather than merely wrong.
    // Both model one cycle of read latency, which is what an M10K does.
    logic [16:0] fb_addr_q;
    logic [7:0]  pal_addr_q;
    always_ff @(posedge clk) fb_addr_q  <= fb_addr;
    always_ff @(posedge clk) pal_addr_q <= pal_addr;

    // 251 is prime, so the pattern does not alias with the 320-pixel stride.
    assign fb_index = fb_addr_q % 251;
    assign pal_rgb  = {pal_addr_q, ~pal_addr_q, pal_addr_q ^ 8'h5A};

    int errors = 0;

    task check(input [255:0] what, input int got, input int want);
        if (got !== want) begin
            $display("FAIL %-26s got %0d want %0d", what, got, want);
            errors = errors + 1;
        end else begin
            $display("  ok %-26s %0d", what, got);
        end
    endtask

    // ---- edge detection, no $past -----------------------------------------
    logic hs_q, vs_q;
    always_ff @(posedge clk) begin
        hs_q <= hs;
        vs_q <= vs;
    end
    wire hs_fall = hs_q & ~hs;
    wire vs_fall = vs_q & ~vs;
    wire vs_rise = ~vs_q & vs;

    // ---- the pipeline check, free-running ---------------------------------
    //
    // Whenever a visible pixel is on the DAC, its colour must be the palette
    // entry for the framebuffer address requested two cycles earlier.
    // Reconstructed here independently of the DUT's own pipeline registers, so
    // a delay that is self-consistently wrong still fails.
    logic [16:0] addr_d1, addr_d2;
    always_ff @(posedge clk) begin
        addr_d1 <= fb_addr;
        addr_d2 <= addr_d1;
    end

    logic [7:0] want_idx;
    int pix_checked = 0, pix_bad = 0;

    always_ff @(posedge clk) begin
        if (!reset && blank_n && !(r == 8'h00 && g == 8'h00 && b == 8'h00)) begin
            want_idx = addr_d2 % 251;
            pix_checked = pix_checked + 1;
            if (r !== want_idx || g !== ~want_idx || b !== (want_idx ^ 8'h5A)) begin
                if (pix_bad < 5)
                    $display("FAIL pixel: addr(t-2)=%0d want idx %02x got %02x%02x%02x",
                             addr_d2, want_idx, r, g, b);
                pix_bad  = pix_bad + 1;
                errors   = errors + 1;
            end
        end
    end

    // ---- measurements, as counters rather than procedural polling ---------
    //
    // Polling these from an initial block reads them one cycle late: the edge
    // wires are driven from NBA-updated registers, so a process sampling on the
    // same clock edge sees the previous value and every measurement comes back
    // one too large. Counting in the same clock domain that produces the edges
    // removes the race rather than compensating for it.
    int  h_count = 0, h_low_count = 0;
    int  line_len = 0, hs_low = 0;
    int  v_line_count = 0, v_low_count = 0;
    int  frame_lines = 0, vs_low = 0;
    int  img_lines_this = 0, img_lines = 0;
    logic line_had_image = 0;

    always_ff @(posedge clk) begin
        if (reset) begin
            h_count <= 0; h_low_count <= 0;
            v_line_count <= 0; v_low_count <= 0;
            img_lines_this <= 0; line_had_image <= 0;
        end else begin
            // --- horizontal ---
            if (hs_fall) begin
                line_len <= h_count + 1;
                hs_low   <= h_low_count + (hs ? 0 : 1);
                h_count     <= 0;
                h_low_count <= 0;
            end else begin
                h_count     <= h_count + 1;
                h_low_count <= h_low_count + (hs ? 0 : 1);
            end

            // --- vertical, counted in lines ---
            if (vs_fall) begin
                frame_lines <= v_line_count;
                vs_low      <= v_low_count;
                img_lines   <= img_lines_this;
                v_line_count   <= 0;
                v_low_count    <= 0;
                img_lines_this <= 0;
            end else if (hs_fall) begin
                v_line_count <= v_line_count + 1;
                if (!vs) v_low_count <= v_low_count + 1;
                if (line_had_image) img_lines_this <= img_lines_this + 1;
            end

            // --- did this line carry any non-black visible pixel? ---
            if (hs_fall)                              line_had_image <= 0;
            else if (blank_n && !(r == 0 && g == 0 && b == 0))
                                                      line_had_image <= 1;
        end
    end

    initial begin
        repeat (4) @(posedge clk);
        reset = 0;

        // Three full frames: one to settle, then the counters hold stable
        // values for a complete frame each time round.
        repeat (3) @(posedge vs_fall);
        @(posedge hs_fall);
        @(posedge clk);

        check("h total (clocks/line)", line_len,    800);
        check("h sync width",          hs_low,      96);
        check("v total (lines/frame)", frame_lines, 525);
        check("v sync width (lines)",  vs_low,      2);
        // 320x200 doubled is 400 lines of image, centred in 480.
        check("image lines",           img_lines,   400);

        $display("");
        $display("pixels checked %0d, mismatched %0d", pix_checked, pix_bad);
        if (pix_checked < 100000) begin
            $display("FAIL only %0d pixels checked; pattern is not reaching the DAC",
                     pix_checked);
            errors = errors + 1;
        end

        $display("%s (%0d errors)", errors ? "VGA FAILED" : "vga ok", errors);
        if (errors) $fatal(1);
        $finish;
    end

    initial begin
        #100_000_000;
        $display("FAIL timeout");
        $fatal(1);
    end

endmodule
