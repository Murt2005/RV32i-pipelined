// The SDRAM controller against the behavioural part, before either goes near
// the CPU. The plan calls this out as the classic time sink, and the reason is
// that debugging a memory controller through a stalling pipeline means every
// symptom arrives second-hand.
//
// Three things are checked, in increasing order of how easy they are to get
// wrong:
//
//   data      write then read back, at addresses chosen to exercise row hits,
//             row misses and bank changes
//   protocol  exactly one response per accepted request, with rsp.addr echoing
//             -- the memory_io contract the caches rely on
//   timing    delegated to the model, which $errors on any datasheet violation
//
//   iverilog -g2012 -o build/de1soc/sdram_tb fpga/de1soc/sim/sdram_tb.sv \
//       fpga/de1soc/sim/sdram_model.sv fpga/de1soc/sdram_ctrl.sv
//   ./build/de1soc/sdram_tb

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

    // A short power-on wait; the sequence is identical, and 100 us of simulated
    // quiet time at 100 MHz is 10000 idle cycles of nothing happening.
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

    // ---- protocol monitor, running the whole time -------------------------
    // One response per accepted request, and the address must come back.
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

    // ---- request helpers ---------------------------------------------------
    //
    // Stimulus changes on the negedge and is sampled on the posedge. Driving it
    // straight after @(posedge clk) instead is a race: the DUT reads `req` in
    // the same active region the task writes it, Verilog does not order those,
    // and the symptom is a write whose do_write has already been cleared by the
    // time the controller looks -- which presents as writes that complete and
    // store nothing.
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

        // ---- initialisation completes -------------------------------------
        while (!init_done) @(posedge clk);
        $display("  ok init_done asserted");

        // ---- sequential words: the row-hit path a cache line fill takes ----
        for (i = 0; i < 16; i++)
            do_write(24'h000100 + i, 32'hA5A50000 + i);
        for (i = 0; i < 16; i++)
            expect_word(24'h000100 + i, 32'hA5A50000 + i);
        $display("  ok 16 sequential words survive a write/read round trip");

        // ---- byte enables --------------------------------------------------
        do_write(24'h000200, 32'hFFFFFFFF);
        issue(24'h000200, 32'h000000AA, 4'b0001, 4'b0000);   // lane 0 only
        expect_word(24'h000200, 32'hFFFFFFAA);
        $display("  ok byte enables write one lane only");

        // ---- a different row, forcing precharge + activate ------------------
        do_write(24'h000800, 32'hDEADBEEF);
        expect_word(24'h000100, 32'hA5A50000);     // old row still intact
        expect_word(24'h000800, 32'hDEADBEEF);
        $display("  ok row change preserves both rows");

        // ---- a different bank -----------------------------------------------
        do_write(24'h400000, 32'hCAFEBABE);
        expect_word(24'h400000, 32'hCAFEBABE);
        expect_word(24'h000800, 32'hDEADBEEF);
        $display("  ok bank change preserves both banks");

        // ---- open-page actually pays: a row hit must be cheaper than a miss --
        // Open the row, then time a hit in it against a read in another row.
        expect_word(24'h000100, 32'hA5A50000);       // opens the row
        t0 = $time;  expect_word(24'h000101, 32'hA5A50001);  cycles_hit  = ($time - t0)/10;
        // The far read is to memory that was written earlier, so it is a real
        // check as well as a timing measurement.
        t0 = $time;  expect_word(24'h000800, 32'hDEADBEEF);  cycles_miss = ($time - t0)/10;
        $display("  .. row hit %0d cycles, row miss %0d cycles", cycles_hit, cycles_miss);
        if (cycles_hit >= cycles_miss) begin
            $display("FAIL open-page policy is not helping: hit %0d >= miss %0d",
                     cycles_hit, cycles_miss);
            errors++;
        end else begin
            $display("  ok row hits are cheaper than row misses");
        end

        // ---- survive a refresh ---------------------------------------------
        // T_REF is 781 cycles, so idling well past it forces at least one.
        repeat (2000) @(posedge clk);
        expect_word(24'h000100, 32'hA5A50000);
        expect_word(24'h400000, 32'hCAFEBABE);
        $display("  ok data survives refresh cycles");

        // ---- the model's own timing verdict ---------------------------------
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
