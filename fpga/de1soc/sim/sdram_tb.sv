// SDRAM controller against the behavioural part: data, one response per request, and timing

`timescale 1ns / 1ps

`include "system.sv"
`include "memory_io.sv"

module sdram_tb;

    logic clk = 0, reset = 1;
    always #5 clk = ~clk;                     // 100 MHz

    memory_io_req req;
    memory_io_rsp rsp;

    logic [12:0] dram_addr;
    logic [1:0]  dram_ba;
    logic        dram_cke, dram_cs_n, dram_ras_n, dram_cas_n, dram_we_n;
    logic [1:0]  dram_dqm;
    wire  [15:0] dram_dq;
    logic        init_done;

    // Short power-on wait to keep the simulation fast
    sdram_ctrl #(.clk_hz(100_000_000), .t_init_us(1), .cas_latency(3)) dut (
        .clk(clk), .reset(reset), .req(req), .rsp(rsp),
        .dram_addr(dram_addr), .dram_ba(dram_ba), .dram_cke(dram_cke),
        .dram_cs_n(dram_cs_n), .dram_ras_n(dram_ras_n), .dram_cas_n(dram_cas_n),
        .dram_we_n(dram_we_n), .dram_dqm(dram_dqm), .dram_dq(dram_dq),
        .init_done(init_done)
    );

    sdram_model #(.cas_latency(3)) mem (
        .clk(clk), .addr(dram_addr), .ba(dram_ba), .cke(dram_cke),
        .cs_n(dram_cs_n), .ras_n(dram_ras_n), .cas_n(dram_cas_n),
        .we_n(dram_we_n), .dqm(dram_dqm), .dq(dram_dq)
    );

    int errors = 0;

    // Protocol monitor: one response per accepted request, with the address echoed
    int outstanding = 0;
    logic [`word_address_size-1:0] expect_addr;

    always_ff @(posedge clk) begin
        if (!reset) begin
            if (req.valid && rsp.ready) begin
                if (outstanding != 0) begin
                    $display("FAIL accepted a request with one already outstanding");
                    errors++;
                end
                outstanding <= 1;
                expect_addr <= req.addr;
            end
            if (rsp.valid) begin
                if (outstanding == 0) begin
                    $display("FAIL response with no request outstanding");
                    errors++;
                end
                if (rsp.addr !== expect_addr) begin
                    $display("FAIL rsp.addr %08x, expected %08x", rsp.addr, expect_addr);
                    errors++;
                end
                outstanding <= 0;
            end
        end
    end

    // Stimulus changes on the negedge, so it never races the DUT on the posedge
    task automatic drive_idle;
        req.valid    = 1'b0;
        req.do_read  = 4'b0000;
        req.do_write = 4'b0000;
    endtask

    task automatic issue(input [23:0] word_addr, input [31:0] data,
                         input [3:0] wr, input [3:0] rd);
        @(negedge clk);
        req.addr     = word_addr;
        req.data     = data;
        req.do_write = wr;
        req.do_read  = rd;
        req.valid    = 1'b1;
        forever begin
            @(posedge clk);
            if (rsp.ready) break;      // the same value the DUT just used
        end
        @(negedge clk);
        drive_idle();
        while (!rsp.valid) @(posedge clk);
    endtask

    task automatic do_write(input [23:0] word_addr, input [31:0] data);
        issue(word_addr, data, 4'b1111, 4'b0000);
    endtask

    task automatic do_read(input [23:0] word_addr, output [31:0] data);
        issue(word_addr, 32'd0, 4'b0000, 4'b1111);
        data = rsp.data;
    endtask

    task automatic expect_word(input [23:0] a, input [31:0] want);
        logic [31:0] got;
        do_read(a, got);
        if (got !== want) begin
            $display("FAIL read %06x got %08x want %08x", a, got, want);
            errors++;
        end
    endtask

    int i;
    logic [31:0] v;
    int t0, cycles_hit, cycles_miss;

    initial begin
        req = memory_io_no_req;
        drive_idle();
        repeat (5) @(posedge clk);
        reset = 0;

        // Initialisation completes
        while (!init_done) @(posedge clk);
        $display("  ok init_done asserted");

        // Sequential words: the row-hit path a cache line fill takes
        for (i = 0; i < 16; i++)
            do_write(24'h000100 + i, 32'hA5A50000 + i);
        for (i = 0; i < 16; i++)
            expect_word(24'h000100 + i, 32'hA5A50000 + i);
        $display("  ok 16 sequential words survive a write/read round trip");

        // Byte enables
        do_write(24'h000200, 32'hFFFFFFFF);
        issue(24'h000200, 32'h000000AA, 4'b0001, 4'b0000);   // lane 0 only
        expect_word(24'h000200, 32'hFFFFFFAA);
        $display("  ok byte enables write one lane only");

        // A different row, forcing precharge and activate
        do_write(24'h000800, 32'hDEADBEEF);
        expect_word(24'h000100, 32'hA5A50000);     // old row still intact
        expect_word(24'h000800, 32'hDEADBEEF);
        $display("  ok row change preserves both rows");

        // A different bank
        do_write(24'h400000, 32'hCAFEBABE);
        expect_word(24'h400000, 32'hCAFEBABE);
        expect_word(24'h000800, 32'hDEADBEEF);
        $display("  ok bank change preserves both banks");

        // A row hit must be cheaper than a miss
        expect_word(24'h000100, 32'hA5A50000);       // opens the row
        t0 = $time;  expect_word(24'h000101, 32'hA5A50001);  cycles_hit  = ($time - t0)/10;
        // The far read hits earlier data, so it's a real check as well as a timing one
        t0 = $time;  expect_word(24'h000800, 32'hDEADBEEF);  cycles_miss = ($time - t0)/10;
        $display("  .. row hit %0d cycles, row miss %0d cycles", cycles_hit, cycles_miss);
        if (cycles_hit >= cycles_miss) begin
            $display("FAIL open-page policy is not helping: hit %0d >= miss %0d",
                     cycles_hit, cycles_miss);
            errors++;
        end else begin
            $display("  ok row hits are cheaper than row misses");
        end

        // Survive a refresh: idling past T_REF (781 cycles) forces one
        repeat (2000) @(posedge clk);
        expect_word(24'h000100, 32'hA5A50000);
        expect_word(24'h400000, 32'hCAFEBABE);
        $display("  ok data survives refresh cycles");

        // The model's own timing verdict
        if (mem.errors != 0) begin
            $display("FAIL model reported %0d timing violations", mem.errors);
            errors = errors + mem.errors;
        end else begin
            $display("  ok no datasheet timing violations");
        end

        $display("");
        $display("%s (%0d errors)", errors ? "SDRAM FAILED" : "sdram ok", errors);
        if (errors) $fatal(1);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FAIL timeout -- controller is stuck");
        $fatal(1);
    end

endmodule
