`ifndef _rv32_top_sv
`define _rv32_top_sv

`include "base.sv"
`include "memory_io.sv"
`include "cpu.sv"
`include "uart.sv"
`include "memory_spram.sv"

// pico2-ice top level: power-on reset, UART program loader and the RV32I core

module rv32_top #(
    parameter int CLK_FREQ  = 12000000,     // must match the firmware's ice_fpga_init()
    parameter int BAUD_RATE = 1000000,
    parameter [31:0] RESET_PC = 32'h0001_0000,
    parameter [31:0] BUILD_ID = 32'h0000_0000  // hash of the RTL, set by the Makefile
) (
    input  logic clk,
    input  logic reset_n,
    input  logic rx_pin,
    output logic tx_pin,
    output logic led_r_n,
    output logic led_g_n,
    output logic led_b_n
);

    localparam int CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

    localparam [7:0] VERSION      = 8'h05;
    localparam [7:0] EOT          = 8'h04;
    localparam [31:0] MMIO_PUTCHAR = 32'h0002_FFF8;
    localparam [31:0] MMIO_HALT    = 32'h0002_FFFC;
    localparam [31:0] MMIO_CYCLES  = 32'h0002_FFF0;
    localparam [31:0] MMIO_TOHOST  = 32'h0002_FFC0;
    localparam [31:0] MMIO_RETIRED = 32'h0002_FFF4;

    // reset_n is only a pull-up on this board, so reset has to come from here
    logic [7:0] por_ctr  = 8'h00;
    logic       por_done = 1'b0;

    always_ff @(posedge clk) begin
        if (!por_done) begin
            por_ctr <= por_ctr + 8'd1;
            if (por_ctr == 8'hFF)
                por_done <= 1'b1;
        end
    end

    logic rst;
    assign rst = ~reset_n | ~por_done;

    logic [7:0] rx_data;
    logic       rx_valid, rx_err;
    logic [7:0] tx_data;
    logic       tx_valid, tx_busy;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst(rst), .rx(rx_pin),
        .data(rx_data), .valid(rx_valid), .frame_error(rx_err)
    );

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst(rst),
        .data(tx_data), .valid(tx_valid), .busy(tx_busy), .tx(tx_pin)
    );

    // Stall on the queue's registered count, not the live request, or the two form a loop
    localparam int TXQ_DEPTH = 16;
    localparam logic [4:0] TXQ_FULL_LVL  = 5'(TXQ_DEPTH);
    // One more store can still issue after the stall asserts
    localparam logic [4:0] TXQ_STALL_LVL = 5'(TXQ_DEPTH - 2);

    logic [7:0] txq [0:TXQ_DEPTH-1];
    logic [4:0] txq_count;
    logic [3:0] txq_rd, txq_wr;
    logic       txq_push;
    logic [7:0] txq_din;
    logic       txq_pop, txq_empty, txq_full;

    assign txq_empty = (txq_count == 5'd0);
    assign txq_full  = (txq_count == TXQ_FULL_LVL);

    assign tx_valid = ~txq_empty & ~tx_busy;
    assign tx_data  = txq[txq_rd];
    assign txq_pop  = tx_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            txq_count <= 5'd0;
            txq_rd    <= 4'd0;
            txq_wr    <= 4'd0;
        end else begin
            if (txq_push && !txq_full) begin
                txq[txq_wr] <= txq_din;
                txq_wr      <= txq_wr + 4'd1;
            end
            if (txq_pop)
                txq_rd <= txq_rd + 4'd1;

            case ({txq_push && !txq_full, txq_pop})
                2'b10:   txq_count <= txq_count + 5'd1;
                2'b01:   txq_count <= txq_count - 5'd1;
                default: txq_count <= txq_count;
            endcase
        end
    end

    logic cpu_run;
    logic cpu_halted;
    logic cpu_reset;
    logic cpu_stall;

    // Random stalls, set by 'T', to test the pipeline's stall handling on hardware
    logic [7:0]  stall_rate;
    logic [15:0] lfsr;

    // 'Z' clears memory and registers, so hardware starts from the same state as simulation
    logic        zeroing;

    assign cpu_reset = rst | ~cpu_run;

    memory_io_req cpu_inst_req, cpu_data_req;
    memory_io_rsp inst_rsp,     data_rsp, data_rsp_raw;
    logic         retired;

    // Performance counters, counted only while the core runs
    logic [31:0] perf_cycles, perf_retired;
    logic [31:0] perf_cycles_q, perf_retired_q;
    logic        perf_sel_cycles, perf_sel_retired;
    logic        perf_sel_cycles_q, perf_sel_retired_q;

    core the_core (
        .clk(clk),
        .reset(cpu_reset),
        .stall(cpu_stall),
        .clear_regs(zeroing),
        .reset_pc(RESET_PC),
        .inst_mem_req(cpu_inst_req),
        .inst_mem_rsp(inst_rsp),
        .data_mem_req(cpu_data_req),
        .data_mem_rsp(data_rsp),
        .retired(retired)
    );

    assign perf_sel_cycles  = cpu_data_req.valid & (cpu_data_req.addr == MMIO_CYCLES)
                            & is_any_byte(cpu_data_req.do_read);
    assign perf_sel_retired = cpu_data_req.valid & (cpu_data_req.addr == MMIO_RETIRED)
                            & is_any_byte(cpu_data_req.do_read);

    always_ff @(posedge clk) begin
        if (rst || !cpu_run) begin
            perf_cycles  <= 32'd0;
            perf_retired <= 32'd0;
        end else begin
            perf_cycles <= perf_cycles + 32'd1;
            if (retired) perf_retired <= perf_retired + 32'd1;
        end
        perf_sel_cycles_q  <= perf_sel_cycles;
        perf_sel_retired_q <= perf_sel_retired;
        perf_cycles_q      <= perf_cycles;
        perf_retired_q     <= perf_retired;
    end

    // One cycle late, to line up with the memory's response
    always_comb begin
        data_rsp = data_rsp_raw;
        if (perf_sel_cycles_q)       data_rsp.data = perf_cycles_q;
        else if (perf_sel_retired_q) data_rsp.data = perf_retired_q;
    end

    // Reseeded on every 'G', so a run is repeatable
    always_ff @(posedge clk) begin
        if (rst || !cpu_run)
            lfsr <= 16'hACE1;
        else
            lfsr <= lfsr[0] ? ((lfsr >> 1) ^ 16'hB400) : (lfsr >> 1);
    end

    logic stall_inject;
    // Even rate 255 leaves one value unstalled, so the core always makes progress
    assign stall_inject = (lfsr[7:0] < stall_rate);

    assign cpu_stall = (txq_count >= TXQ_STALL_LVL) | stall_inject;

    logic mmio_putchar, mmio_halt;

    assign mmio_putchar = cpu_run & cpu_data_req.valid
                        & (cpu_data_req.addr == MMIO_PUTCHAR)
                        & is_any_byte(cpu_data_req.do_write);

    assign mmio_halt    = cpu_run & cpu_data_req.valid
                        & ((cpu_data_req.addr == MMIO_HALT)
                        |  (cpu_data_req.addr == MMIO_TOHOST))
                        & is_any_byte(cpu_data_req.do_write);

    typedef enum logic [3:0] {
        S_IDLE   = 4'd0,
        S_ADDR   = 4'd1,
        S_LEN    = 4'd2,
        S_DATA   = 4'd3,
        S_RESP1  = 4'd4,
        S_RESP2  = 4'd5,
        S_ZERO   = 4'd6,
        S_RD_ACK = 4'd7,
        S_RD_REQ = 4'd8,
        S_RD_WAIT= 4'd9,
        S_RD_PUSH= 4'd10,
        S_TRATE  = 4'd11,
        S_BID_ACK= 4'd12,
        S_BID    = 4'd13
    } ldr_state_t;

    ldr_state_t   state;
    logic [31:0]  load_addr;
    logic [15:0]  load_len;
    logic [1:0]   byte_idx;
    logic [7:0]   resp0, resp1;
    logic         resp_two;
    logic         halt_pending;
    logic [7:0]   rx_err_count;
    logic [1:0]   bid_idx;
    logic [13:0]  zero_addr;

    logic         cmd_is_read;
    logic         rd_from_inst;
    logic [31:0]  rd_word;
    logic         rd_ready;

    memory_io_req ldr_req;
    logic         ldr_to_inst;
    logic         resp_ready;

    assign ldr_to_inst = (ldr_req.addr[19:16] == 4'h1);

    // Program output has priority; loader replies only happen while the core is stopped
    always_comb begin
        txq_push   = 1'b0;
        txq_din    = 8'h00;
        resp_ready = 1'b0;
        rd_ready   = 1'b0;

        if (mmio_putchar) begin
            txq_push = 1'b1;
            txq_din  = cpu_data_req.data[7:0];
        end else if (halt_pending && !txq_full) begin
            txq_push = 1'b1;
            txq_din  = EOT;
        end else if (!txq_full && (state == S_RESP1 || state == S_RESP2)) begin
            txq_push   = 1'b1;
            txq_din    = (state == S_RESP1) ? resp0 : resp1;
            resp_ready = 1'b1;
        end else if (!txq_full && state == S_BID_ACK) begin
            txq_push = 1'b1;
            txq_din  = 8'h62;                       // 'b'
            rd_ready = 1'b1;
        end else if (!txq_full && state == S_BID) begin
            txq_push = 1'b1;
            txq_din  = BUILD_ID[{bid_idx, 3'b000} +: 8];
            rd_ready = 1'b1;
        end else if (!txq_full && state == S_RD_ACK) begin
            txq_push = 1'b1;
            txq_din  = 8'h72;                       // 'r'
            rd_ready = 1'b1;
        end else if (!txq_full && state == S_RD_PUSH) begin
            txq_push = 1'b1;
            txq_din  = rd_word[{load_addr[1:0], 3'b000} +: 8];
            rd_ready = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state         <= S_IDLE;
            cpu_run       <= 1'b0;
            cpu_halted    <= 1'b0;
            halt_pending  <= 1'b0;
            load_addr     <= 32'd0;
            load_len      <= 16'd0;
            byte_idx      <= 2'd0;
            resp0         <= 8'd0;
            resp1         <= 8'd0;
            resp_two      <= 1'b0;
            rx_err_count  <= 8'd0;
            zeroing       <= 1'b0;
            zero_addr     <= 14'd0;
            cmd_is_read   <= 1'b0;
            rd_from_inst  <= 1'b0;
            rd_word       <= 32'd0;
            stall_rate    <= 8'd0;
            bid_idx       <= 2'd0;
            ldr_req       <= memory_io_no_req;
        end else begin
            ldr_req.valid <= 1'b0;

            if (rx_err)
                rx_err_count <= rx_err_count + 8'd1;

            if (mmio_halt) begin
                cpu_run      <= 1'b0;
                cpu_halted   <= 1'b1;
                halt_pending <= 1'b1;
            end else if (halt_pending && txq_push && txq_din == EOT) begin
                halt_pending <= 1'b0;
            end

            case (state)
                S_IDLE: begin
                    if (rx_valid) begin
                        case (rx_data)
                            8'h50: begin                 // 'P' ping
                                resp0 <= 8'h70; resp1 <= VERSION;
                                resp_two <= 1'b1; state <= S_RESP1;
                            end
                            8'h5A: begin                 // 'Z' zero memory
                                zeroing   <= 1'b1;
                                zero_addr <= 14'd0;
                                state     <= S_ZERO;
                            end
                            8'h57: begin                 // 'W' write
                                cmd_is_read <= 1'b0;
                                byte_idx <= 2'd0; state <= S_ADDR;
                            end
                            8'h52: begin                 // 'R' read
                                cmd_is_read <= 1'b1;
                                byte_idx <= 2'd0; state <= S_ADDR;
                            end
                            8'h54: begin                 // 'T' stall rate
                                state <= S_TRATE;
                            end
                            8'h42: begin                 // 'B' build id
                                bid_idx <= 2'd0;
                                state   <= S_BID_ACK;
                            end
                            8'h47: begin                 // 'G' go
                                cpu_run    <= 1'b1;
                                cpu_halted <= 1'b0;
                                resp0 <= 8'h67; resp_two <= 1'b0;
                                state <= S_RESP1;
                            end
                            8'h48: begin                 // 'H' halt
                                cpu_run <= 1'b0;
                                resp0 <= 8'h68; resp_two <= 1'b0;
                                state <= S_RESP1;
                            end
                            8'h53: begin                 // 'S' status
                                resp0 <= 8'h73;
                                resp1 <= {5'd0, |rx_err_count, cpu_halted, cpu_run};
                                resp_two <= 1'b1; state <= S_RESP1;
                            end
                            default: ;                   // 0x00 NOP and anything else
                        endcase
                    end
                end

                S_ADDR: begin
                    if (rx_valid) begin
                        case (byte_idx)
                            2'd0: load_addr[7:0]   <= rx_data;
                            2'd1: load_addr[15:8]  <= rx_data;
                            2'd2: load_addr[23:16] <= rx_data;
                            2'd3: load_addr[31:24] <= rx_data;
                        endcase
                        byte_idx <= byte_idx + 2'd1;
                        if (byte_idx == 2'd3) begin
                            byte_idx <= 2'd0;
                            state    <= S_LEN;
                        end
                    end
                end

                S_LEN: begin
                    if (rx_valid) begin
                        if (byte_idx == 2'd0) begin
                            load_len[7:0] <= rx_data;
                            byte_idx      <= 2'd1;
                        end else begin
                            load_len[15:8] <= rx_data;
                            byte_idx       <= 2'd0;
                            // Zero length: just ack
                            if ({rx_data, load_len[7:0]} == 16'd0) begin
                                resp0 <= cmd_is_read ? 8'h72 : 8'h77;
                                resp_two <= 1'b0;
                                state <= S_RESP1;
                            end else if (cmd_is_read) begin
                                state <= S_RD_ACK;
                            end else begin
                                state <= S_DATA;
                            end
                        end
                    end
                end

                S_DATA: begin
                    if (rx_valid) begin
                        ldr_req.valid    <= 1'b1;
                        ldr_req.addr     <= load_addr;
                        ldr_req.do_read  <= 4'b0000;
                        ldr_req.do_write <= 4'b0001 << load_addr[1:0];
                        ldr_req.data     <= {24'd0, rx_data} << {load_addr[1:0], 3'b000};
                        ldr_req.user_tag <= '0;

                        load_addr <= load_addr + 32'd1;
                        load_len  <= load_len - 16'd1;
                        if (load_len == 16'd1) begin
                            resp0 <= 8'h77; resp_two <= 1'b0;
                            state <= S_RESP1;
                        end
                    end
                end

                S_ZERO: begin
                    zero_addr <= zero_addr + 14'd1;
                    if (zero_addr == 14'h3FFF) begin
                        zeroing <= 1'b0;
                        resp0 <= 8'h7A; resp_two <= 1'b0;   // 'z'
                        state <= S_RESP1;
                    end
                end

                S_RD_ACK: begin
                    if (rd_ready)
                        state <= S_RD_REQ;
                end

                S_RD_REQ: begin
                    ldr_req.valid    <= 1'b1;
                    ldr_req.addr     <= load_addr;
                    ldr_req.do_read  <= 4'b1111;
                    ldr_req.do_write <= 4'b0000;
                    ldr_req.user_tag <= '0;
                    rd_from_inst     <= (load_addr[19:16] == 4'h1);
                    state            <= S_RD_WAIT;
                end

                S_RD_WAIT: begin
                    if (rd_from_inst ? inst_rsp.valid : data_rsp.valid) begin
                        rd_word <= rd_from_inst ? inst_rsp.data : data_rsp.data;
                        state   <= S_RD_PUSH;
                    end
                end

                S_RD_PUSH: begin
                    if (rd_ready) begin
                        load_addr <= load_addr + 32'd1;
                        load_len  <= load_len - 16'd1;
                        if (load_len == 16'd1) state <= S_IDLE;
                        else                   state <= S_RD_REQ;
                    end
                end

                S_BID_ACK: begin
                    if (rd_ready) state <= S_BID;
                end

                S_BID: begin
                    if (rd_ready) begin
                        bid_idx <= bid_idx + 2'd1;
                        if (bid_idx == 2'd3) state <= S_IDLE;
                    end
                end

                S_TRATE: begin
                    if (rx_valid) begin
                        stall_rate <= rx_data;
                        resp0 <= 8'h74; resp_two <= 1'b0;   // 't'
                        state <= S_RESP1;
                    end
                end

                S_RESP1: begin
                    if (resp_ready) begin
                        if (resp_two) state <= S_RESP2;
                        else          state <= S_IDLE;
                    end
                end

                S_RESP2: begin
                    if (resp_ready)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // The loader drives the memories while the core is stopped
    memory_io_req inst_req_mux, data_req_mux;

    memory_io_req zero_req;

    always_comb begin
        zero_req          = memory_io_no_req;
        zero_req.addr     = {16'd0, zero_addr, 2'b00};
        zero_req.data     = 32'd0;
        zero_req.do_write = 4'b1111;
        zero_req.valid    = zeroing;

        if (cpu_run) begin
            inst_req_mux = cpu_inst_req;
            data_req_mux = cpu_data_req;
        end else if (zeroing) begin
            inst_req_mux = zero_req;
            data_req_mux = zero_req;
        end else begin
            inst_req_mux = memory_io_no_req;
            data_req_mux = memory_io_no_req;
            if (ldr_to_inst)
                inst_req_mux = ldr_req;
            else
                data_req_mux = ldr_req;
        end
    end

    memory_spram #(.enable_rsp_addr(1)) code_mem (
        .clk(clk), .reset(rst), .req(inst_req_mux), .rsp(inst_rsp)
    );

    memory_spram #(.enable_rsp_addr(1)) data_mem (
        .clk(clk), .reset(rst), .req(data_req_mux), .rsp(data_rsp_raw)
    );

    // Blue blinks while the clock runs, green while the core runs, red once halted
    logic [22:0] heartbeat;
    always_ff @(posedge clk) begin
        if (rst)
            heartbeat <= '0;
        else
            heartbeat <= heartbeat + 23'd1;
    end

    assign led_b_n = ~heartbeat[22];
    assign led_g_n = ~cpu_run;
    assign led_r_n = ~cpu_halted;

endmodule

`endif
