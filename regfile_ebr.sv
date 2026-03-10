`ifndef __regfile_ebr_sv
`define __regfile_ebr_sv

// iCE40 EBR-backed 32x32 register file:
// - 2 read ports (registered outputs from EBR, 1-cycle latency)
// - 1 write port
// Implemented as 2 identical copies so each copy provides one read port.
// Each copy is split into low/high 16-bit halves -> 4x SB_RAM40_4K total.

module regfile_2r1w_ebr (
    input  logic        clk,

    input  logic [4:0]  raddr1,
    input  logic [4:0]  raddr2,
    output logic [31:0] rdata1,
    output logic [31:0] rdata2,

    input  logic        wen,
    input  logic [4:0]  waddr,
    input  logic [31:0] wdata
);

`ifdef SYNTHESIS

    // SB_RAM40_4K is 256x16 in READ_MODE=0/WRITE_MODE=0.
    // We only use addresses 0..31; upper bits are 0.
    logic [7:0] raddr1_ebr, raddr2_ebr, waddr_ebr;
    assign raddr1_ebr = {3'b000, raddr1};
    assign raddr2_ebr = {3'b000, raddr2};
    assign waddr_ebr  = {3'b000, waddr};

    logic we_eff;
    assign we_eff = wen && (waddr != 5'd0); // x0 is hard-wired to 0

    logic [15:0] a_lo_rdata, a_hi_rdata;
    logic [15:0] b_lo_rdata, b_hi_rdata;

    // Copy A (read port 1)
    SB_RAM40_4K ram_a_lo (
        .RDATA(a_lo_rdata),
        .RADDR(raddr1_ebr),
        .WADDR(waddr_ebr),
        .MASK(16'h0000),
        .WDATA(wdata[15:0]),
        .RCLKE(1'b1),
        .RCLK(clk),
        .RE(1'b1),
        .WCLKE(1'b1),
        .WCLK(clk),
        .WE(we_eff)
    );
    defparam ram_a_lo.READ_MODE = 0;
    defparam ram_a_lo.WRITE_MODE = 0;

    SB_RAM40_4K ram_a_hi (
        .RDATA(a_hi_rdata),
        .RADDR(raddr1_ebr),
        .WADDR(waddr_ebr),
        .MASK(16'h0000),
        .WDATA(wdata[31:16]),
        .RCLKE(1'b1),
        .RCLK(clk),
        .RE(1'b1),
        .WCLKE(1'b1),
        .WCLK(clk),
        .WE(we_eff)
    );
    defparam ram_a_hi.READ_MODE = 0;
    defparam ram_a_hi.WRITE_MODE = 0;

    // Copy B (read port 2)
    SB_RAM40_4K ram_b_lo (
        .RDATA(b_lo_rdata),
        .RADDR(raddr2_ebr),
        .WADDR(waddr_ebr),
        .MASK(16'h0000),
        .WDATA(wdata[15:0]),
        .RCLKE(1'b1),
        .RCLK(clk),
        .RE(1'b1),
        .WCLKE(1'b1),
        .WCLK(clk),
        .WE(we_eff)
    );
    defparam ram_b_lo.READ_MODE = 0;
    defparam ram_b_lo.WRITE_MODE = 0;

    SB_RAM40_4K ram_b_hi (
        .RDATA(b_hi_rdata),
        .RADDR(raddr2_ebr),
        .WADDR(waddr_ebr),
        .MASK(16'h0000),
        .WDATA(wdata[31:16]),
        .RCLKE(1'b1),
        .RCLK(clk),
        .RE(1'b1),
        .WCLKE(1'b1),
        .WCLK(clk),
        .WE(we_eff)
    );
    defparam ram_b_hi.READ_MODE = 0;
    defparam ram_b_hi.WRITE_MODE = 0;

    // x0 read-as-zero behavior
    always_comb begin
        rdata1 = (raddr1 == 5'd0) ? 32'd0 : {a_hi_rdata, a_lo_rdata};
        rdata2 = (raddr2 == 5'd0) ? 32'd0 : {b_hi_rdata, b_lo_rdata};
    end

`else

    // Simulation / non-synthesis model with the same 1-cycle read latency.
    logic [31:0] mem[0:31];
    logic [31:0] rdata1_q, rdata2_q;

    initial begin
        for (int i = 0; i < 32; i++)
            mem[i] = 32'd0;
        rdata1_q = 32'd0;
        rdata2_q = 32'd0;
    end

    always_ff @(posedge clk) begin
        if (wen && (waddr != 5'd0))
            mem[waddr] <= wdata;

        rdata1_q <= (raddr1 == 5'd0) ? 32'd0 : mem[raddr1];
        rdata2_q <= (raddr2 == 5'd0) ? 32'd0 : mem[raddr2];
    end

    always_comb begin
        rdata1 = rdata1_q;
        rdata2 = rdata2_q;
    end

`endif

endmodule

`endif

