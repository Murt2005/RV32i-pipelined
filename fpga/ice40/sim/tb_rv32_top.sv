`timescale 1ns / 1ps

`include "sb_spram256ka.sv"
`include "rv32_top.sv"

// ---------------------------------------------------------------------------
// Board-level testbench: drives rv32_top through the same UART wire protocol
// the host tool uses, with the same RTL that gets synthesized (including a
// behavioural SPRAM model).
//
// The single most important thing this proves is that the design works with
// reset_n tied HIGH for all time. That is what the board actually does -- the
// reset pin is a plain pull-up, so it reads idle-high from the instant the
// FPGA configures. Every existing testbench pulses reset at t=0, which makes
// a missing power-on reset structurally invisible to them (gotcha G1).
// ---------------------------------------------------------------------------

module tb_rv32_top();

    // 6 MHz core. Baud is raised relative to the real build purely to keep the
    // simulation short; CLKS_PER_BIT is what actually matters and stays sane.
    localparam int CLK_FREQ     = 6000000;
    localparam int BAUD_RATE    = 750000;
    localparam int CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;   // 8

    localparam real CLK_PERIOD = 1000.0e3 / CLK_FREQ;     // ns
    localparam real BIT_TIME   = CLK_PERIOD * CLKS_PER_BIT;

    logic clk = 0;
    logic reset_n = 1'b1;      // deliberately never pulsed
    logic host_to_fpga = 1'b1; // idle high
    logic fpga_to_host;
    logic led_r_n, led_g_n, led_b_n;

    always #(CLK_PERIOD/2.0) clk = ~clk;

    rv32_top #(
        .CLK_FREQ(CLK_FREQ),
        .BAUD_RATE(BAUD_RATE)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .rx_pin(host_to_fpga),
        .tx_pin(fpga_to_host),
        .led_r_n(led_r_n),
        .led_g_n(led_g_n),
        .led_b_n(led_b_n)
    );

    // ---------------- host UART model ----------------
    task automatic send_byte(input logic [7:0] b);
        integer i;
        begin
            host_to_fpga = 1'b0;                 // start
            #(BIT_TIME);
            for (i = 0; i < 8; i = i + 1) begin
                host_to_fpga = b[i];             // LSB first
                #(BIT_TIME);
            end
            host_to_fpga = 1'b1;                 // stop
            #(BIT_TIME);
        end
    endtask

    task automatic recv_byte(output logic [7:0] b);
        integer i;
        begin
            @(negedge fpga_to_host);             // start bit
            #(BIT_TIME * 1.5);                   // centre of bit 0
            for (i = 0; i < 8; i = i + 1) begin
                b[i] = fpga_to_host;
                #(BIT_TIME);
            end
        end
    endtask

    task automatic expect_byte(input logic [7:0] want, input string what);
        logic [7:0] got;
        begin
            recv_byte(got);
            if (got !== want) begin
                $display("FATAL: %s: expected %02x got %02x", what, want, got);
                $fatal(1);
            end
        end
    endtask

    // ---------------- program image ----------------
    // Read the byte-lane hex files the normal build flow already produces.
    localparam int MEM_WORDS = 16384;
    // Separate 1-D arrays: iverilog cannot $readmemh into a slice of a 2-D array.
    reg [7:0] code0 [0:MEM_WORDS-1]; reg [7:0] code1 [0:MEM_WORDS-1];
    reg [7:0] code2 [0:MEM_WORDS-1]; reg [7:0] code3 [0:MEM_WORDS-1];
    reg [7:0] data0 [0:MEM_WORDS-1]; reg [7:0] data1 [0:MEM_WORDS-1];
    reg [7:0] data2 [0:MEM_WORDS-1]; reg [7:0] data3 [0:MEM_WORDS-1];

    function automatic [7:0] img_byte(input integer is_code, input integer idx);
        integer w, lane;
        begin
            w = idx / 4; lane = idx % 4;
            if (is_code) begin
                case (lane)
                    0: img_byte = code0[w]; 1: img_byte = code1[w];
                    2: img_byte = code2[w]; default: img_byte = code3[w];
                endcase
            end else begin
                case (lane)
                    0: img_byte = data0[w]; 1: img_byte = data1[w];
                    2: img_byte = data2[w]; default: img_byte = data3[w];
                endcase
            end
        end
    endfunction

    integer code_bytes, data_bytes;

    task automatic load_images;
        integer i, lane;
        begin
            for (i = 0; i < MEM_WORDS; i = i + 1) begin
                code0[i] = 8'h00; code1[i] = 8'h00;
                code2[i] = 8'h00; code3[i] = 8'h00;
                data0[i] = 8'h00; data1[i] = 8'h00;
                data2[i] = 8'h00; data3[i] = 8'h00;
            end
            $readmemh("code0.hex", code0);
            $readmemh("code1.hex", code1);
            $readmemh("code2.hex", code2);
            $readmemh("code3.hex", code3);
            $readmemh("data0.hex", data0);
            $readmemh("data1.hex", data1);
            $readmemh("data2.hex", data2);
            $readmemh("data3.hex", data3);

            // Only send up to the last non-zero byte; the images are 64 KiB of
            // mostly zeros and SPRAM already powers up cleared.
            code_bytes = 0;
            data_bytes = 0;
            for (i = 0; i < MEM_WORDS*4; i = i + 1) begin
                if (img_byte(1, i) !== 8'h00) code_bytes = i + 1;
                if (img_byte(0, i) !== 8'h00) data_bytes = i + 1;
            end
        end
    endtask

    task automatic write_region(input [31:0] base, input integer nbytes,
                                input integer is_code);
        integer i;
        logic [7:0] v;
        begin
            send_byte(8'h57);                    // 'W'
            send_byte(base[7:0]);
            send_byte(base[15:8]);
            send_byte(base[23:16]);
            send_byte(base[31:24]);
            send_byte(nbytes[7:0]);
            send_byte(nbytes[15:8]);
            for (i = 0; i < nbytes; i = i + 1) begin
                v = img_byte(is_code, i);
                send_byte(v);
            end
            expect_byte(8'h77, "write ack");     // 'w'
        end
    endtask

    // ---------------- main ----------------
    logic [7:0] b;
    integer     nout;
    string      out_line;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_rv32_top.vcd");
            $dumpvars(0, tb_rv32_top);
        end

        load_images();
        $display("--- image: %0d code bytes, %0d data bytes ---", code_bytes, data_bytes);

        // Let the internal power-on reset counter run out. Nothing external
        // ever asserts reset.
        #(CLK_PERIOD * 600);

        // Rung 1: does the command interface answer at all?
        send_byte(8'h00);                        // NOP, must be ignored
        send_byte(8'h50);                        // 'P'
        expect_byte(8'h70, "ping reply");
        expect_byte(8'h02, "version");
        $display("PING ok");

        send_byte(8'h5A);                        // 'Z' zero both memories
        expect_byte(8'h7A, "zero ack");
        $display("ZERO ok");

        write_region(32'h0001_0000, code_bytes, 1);
        write_region(32'h0002_0000, data_bytes, 0);
        $display("LOAD ok");

        send_byte(8'h47);                        // 'G'
        expect_byte(8'h67, "go reply");

        // Collect program output until the halt sentinel.
        nout = 0;
        out_line = "";
        forever begin
            recv_byte(b);
            if (b == 8'h04) begin
                if (out_line.len() != 0) $display("%s", out_line);
                $display("--- HALT after %0d bytes ---", nout);
                if (led_r_n !== 1'b0) $display("WARNING: halt LED not lit");
                $finish;
            end
            nout = nout + 1;
            if (b == 8'h0A) begin
                $display("%s", out_line);
                out_line = "";
            end else if (b != 8'h0D) begin
                out_line = {out_line, string'(b)};
            end
        end
    end

    // ---- debug instrumentation ----
    integer nputc = 0;
    always @(posedge clk) begin
        if ($test$plusargs("dbg")) begin
            if (dut.mmio_putchar) begin
                nputc = nputc + 1;
                $display("[%0t] PUTC #%0d '%c' stall=%b cnt=%0d",
                         $time, nputc, dut.cpu_data_req.data[7:0],
                         dut.cpu_stall, dut.txq_count);
            end
            if (dut.mmio_halt)
                $display("[%0t] HALT store, wbd=%08x",
                         $time, dut.the_core.executed_instruction.writeback_instruction.wbd);
        end
    end

    // Watchdog
    initial begin
        #(CLK_PERIOD * 4000000);
        $display("FATAL: timeout");
        $fatal(1);
    end

endmodule
