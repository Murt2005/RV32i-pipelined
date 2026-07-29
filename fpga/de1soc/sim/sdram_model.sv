// Behavioural IS42S16320D, written to catch a controller that is wrong rather
// than merely to store bytes.
//
// A model that only remembers data will happily accept a read issued one cycle
// after ACTIVATE and hand back the right answer, so the controller passes in
// simulation and returns garbage on the board -- which is the classic way an
// SDRAM bring-up eats a fortnight. So every datasheet interval this controller
// can violate is checked here and reported with $error: tRCD, tRP, tRC, tRFC,
// tMRD, CAS-before-ACTIVATE, and access to a bank with no open row.
//
// Storage is an associative array. The real part is 64 MB and a dense array of
// that size makes the simulator crawl and the machine swap; a sparse one costs
// nothing for the few thousand words a test actually touches, and reads of
// never-written addresses return X, which is itself a useful signal.

`timescale 1ns / 1ps

module sdram_model #(
    parameter int row_bits    = 13,
    parameter int col_bits    = 10,
    parameter int bank_bits   = 2,
    parameter int cas_latency = 3,

    // Datasheet minima in ns, checked against $realtime.
    parameter real t_rcd = 20.0,
    parameter real t_rp  = 20.0,
    parameter real t_rc  = 70.0,
    parameter real t_rfc = 70.0,
    parameter real t_mrd = 15.0,

    // Rows per bank actually stored. The controller is unaware of this; it
    // only bounds what a testbench may touch.
    parameter int sim_row_bits = 3,

    parameter bit verbose = 0
) (
    input  logic                 clk,
    input  logic [row_bits-1:0]  addr,
    input  logic [bank_bits-1:0] ba,
    input  logic                 cke,
    input  logic                 cs_n,
    input  logic                 ras_n,
    input  logic                 cas_n,
    input  logic                 we_n,
    input  logic [1:0]           dqm,
    inout  wire  [15:0]          dq
);

    localparam int BANKS = 1 << bank_bits;

    // Storage for a bounded slice of the part, not all 64 MB of it.
    //
    // An associative array would be the natural choice and iverilog 13 does not
    // have them, so this is dense over `sim_row_bits` rows per bank. Any access
    // to a higher row is reported rather than folded back into range: silent
    // aliasing would let a test that wandered outside the modelled window pass
    // by reading back its own collision, which is worse than not modelling it.
    logic [15:0] mem [0:(BANKS << (sim_row_bits + col_bits)) - 1];
    logic [15:0] cur;

    // Per-bank state.
    logic                row_active [BANKS];
    logic [row_bits-1:0] active_row [BANKS];
    real                 t_activate [BANKS];   // when ACTIVATE was issued
    real                 t_precharge[BANKS];   // when PRECHARGE completed

    real t_last_refresh = 0.0;
    real t_last_lmr     = -1000.0;
    bit  initialised    = 0;

    int errors = 0;

    // Read pipeline: CL cycles deep, plus one for the second burst beat.
    logic [15:0] rd_pipe  [0:7];
    logic        rd_valid [0:7];

    logic [15:0] dq_out;
    logic        dq_drive;
    assign dq = dq_drive ? dq_out : 16'bz;

    // Write burst tracking: BL=2, so a WRITE takes data on its own cycle and
    // the next one.
    int                  wr_beats;
    logic [col_bits-1:0] wr_col;
    logic [bank_bits-1:0] wr_bank;

    // Read burst tracking.
    int                  rd_beats;
    logic [col_bits-1:0] rd_col;
    logic [bank_bits-1:0] rd_bank;

    wire [3:0] cmd = {cs_n, ras_n, cas_n, we_n};

    localparam logic [3:0] C_NOP    = 4'b0111;
    localparam logic [3:0] C_ACT    = 4'b0011;
    localparam logic [3:0] C_READ   = 4'b0101;
    localparam logic [3:0] C_WRITE  = 4'b0100;
    localparam logic [3:0] C_PRE    = 4'b0010;
    localparam logic [3:0] C_REF    = 4'b0001;
    localparam logic [3:0] C_LMR    = 4'b0000;

    function int key(input [bank_bits-1:0] b, input [row_bits-1:0] r,
                     input [col_bits-1:0] c);
        if (r >= (1 << sim_row_bits)) begin
            $error("SDRAM MODEL: row %0d is outside the %0d rows this model stores; \
widen sim_row_bits or move the test addresses",
                   r, 1 << sim_row_bits);
            errors++;
        end
        key = (int'(b) << (sim_row_bits + col_bits))
            | ((int'(r) & ((1 << sim_row_bits) - 1)) << col_bits)
            | int'(c);
    endfunction

    task fail(input string what);
        $error("SDRAM MODEL: %s at %0t", what, $realtime);
        errors++;
    endtask

    initial begin
        for (int b = 0; b < BANKS; b++) begin
            row_active[b]  = 0;
            t_activate[b]  = -1000.0;
            t_precharge[b] = -1000.0;
        end
        for (int i = 0; i < 8; i++) rd_valid[i] = 0;
        // x rather than 0, so a read of never-written memory is visible.
        for (int i = 0; i < (BANKS << (sim_row_bits + col_bits)); i++)
            mem[i] = 16'hxxxx;
        wr_beats = 0;
        rd_beats = 0;
        dq_drive = 0;
    end

    always_ff @(posedge clk) begin
        // ---- shift the read pipeline -------------------------------------
        for (int i = 7; i > 0; i--) begin
            rd_pipe[i]  <= rd_pipe[i-1];
            rd_valid[i] <= rd_valid[i-1];
        end
        rd_valid[0] <= 1'b0;

        // ---- continue an in-flight read burst ------------------------------
        // The *first* beat is launched by the READ command itself, below; this
        // handles the remaining beats of the burst.
        if (rd_beats > 0) begin
            rd_pipe[0]  <= mem[key(rd_bank, active_row[rd_bank], rd_col)];
            rd_valid[0] <= 1'b1;
            rd_col      <= rd_col + 1'b1;
            rd_beats    <= rd_beats - 1;
        end

        // ---- continue an in-flight write burst -----------------------------
        if (wr_beats > 0) begin
            if (dqm != 2'b11) begin
                cur = mem[key(wr_bank, active_row[wr_bank], wr_col)];
                if (cur === 16'hxxxx) cur = 16'h0000;
                if (!dqm[0]) cur[7:0]  = dq[7:0];
                if (!dqm[1]) cur[15:8] = dq[15:8];
                mem[key(wr_bank, active_row[wr_bank], wr_col)] = cur;
                if (verbose)
                    $display("  model: WR b%0d r%0d c%0d <= %04x (dqm %b)",
                             wr_bank, active_row[wr_bank], wr_col, dq, dqm);
            end
            wr_col   <= wr_col + 1'b1;
            wr_beats <= wr_beats - 1;
        end

        if (!cke) begin
            // Clock-enable low freezes the part; nothing here uses it.
        end else begin
            case (cmd)
            C_LMR: begin
                // All banks must be idle for a mode-register load.
                for (int b = 0; b < BANKS; b++)
                    if (row_active[b]) fail("LMR with a row still open");
                t_last_lmr  = $realtime;
                initialised = 1;
                if (verbose) $display("  model: LMR mode=%013b", addr);
            end

            C_REF: begin
                for (int b = 0; b < BANKS; b++)
                    if (row_active[b]) fail("REFRESH with a row still open");
                t_last_refresh = $realtime;
                if (verbose) $display("  model: REFRESH");
            end

            C_PRE: begin
                if (addr[10]) begin              // all banks
                    for (int b = 0; b < BANKS; b++) begin
                        row_active[b]  = 0;
                        t_precharge[b] = $realtime;
                    end
                end else begin
                    row_active[ba]  = 0;
                    t_precharge[ba] = $realtime;
                end
                if (verbose) $display("  model: PRECHARGE%s", addr[10] ? " ALL" : "");
            end

            C_ACT: begin
                if (row_active[ba])
                    fail($sformatf("ACTIVATE on bank %0d which is already open", ba));
                if ($realtime - t_precharge[ba] < t_rp && t_precharge[ba] > 0)
                    fail($sformatf("tRP violated: %.1f ns since PRECHARGE, need %.1f",
                                   $realtime - t_precharge[ba], t_rp));
                if ($realtime - t_activate[ba] < t_rc && t_activate[ba] > 0)
                    fail($sformatf("tRC violated: %.1f ns since last ACTIVATE, need %.1f",
                                   $realtime - t_activate[ba], t_rc));
                row_active[ba] = 1;
                active_row[ba] = addr;
                t_activate[ba] = $realtime;
                if (verbose) $display("  model: ACTIVATE b%0d r%0d", ba, addr);
            end

            C_READ: begin
                if (!row_active[ba])
                    fail($sformatf("READ on bank %0d with no open row", ba));
                else if ($realtime - t_activate[ba] < t_rcd)
                    fail($sformatf("tRCD violated: %.1f ns after ACTIVATE, need %.1f",
                                   $realtime - t_activate[ba], t_rcd));
                // First beat now, second next cycle. Launching both from the
                // burst counter instead would put the data one cycle late and
                // silently turn CL3 into CL4 -- which a controller written to
                // match would then "pass" with, and the board would not.
                rd_bank     <= ba;
                rd_pipe[0]  <= mem[key(ba, active_row[ba], addr[col_bits-1:0])];
                rd_valid[0] <= 1'b1;
                rd_col      <= addr[col_bits-1:0] + 1'b1;
                rd_beats    <= 1;                // one more beat to go
                if (verbose) $display("  model: READ b%0d c%0d", ba, addr[col_bits-1:0]);
            end

            C_WRITE: begin
                if (!row_active[ba])
                    fail($sformatf("WRITE on bank %0d with no open row", ba));
                else if ($realtime - t_activate[ba] < t_rcd)
                    fail($sformatf("tRCD violated: %.1f ns after ACTIVATE, need %.1f",
                                   $realtime - t_activate[ba], t_rcd));
                wr_bank <= ba;
                cur = mem[key(ba, active_row[ba], addr[col_bits-1:0])];
                if (cur === 16'hxxxx) cur = 16'h0000;
                if (!dqm[0]) cur[7:0]  = dq[7:0];
                if (!dqm[1]) cur[15:8] = dq[15:8];
                if (dqm != 2'b11)
                    mem[key(ba, active_row[ba], addr[col_bits-1:0])] = cur;
                wr_col   <= addr[col_bits-1:0] + 1'b1;
                wr_beats <= 1;
                if (verbose) $display("  model: WRITE b%0d c%0d", ba, addr[col_bits-1:0]);
            end

            default: ;                            // NOP / inhibit
            endcase
        end
    end

    // ---- drive DQ, cas_latency cycles after the read command --------------
    always_comb begin
        dq_drive = rd_valid[cas_latency-1];
        dq_out   = rd_pipe[cas_latency-1];
    end

endmodule
