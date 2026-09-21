`ifndef _divider_sv
`define _divider_sv

`include "system.sv"

// ---------------------------------------------------------------------------
// Iterative 32-bit divider for DIV / DIVU / REM / REMU.
//
// Restoring division, one bit per cycle, so 32 cycles plus a little. Divide is
// rare enough in the code this core runs that a fast divider would be area spent
// for nothing -- multiply is the operation worth making fast, and that is
// combinational in the ALU.
//
// Signed division is done on magnitudes with the signs reapplied at the end,
// because RISC-V truncates the quotient towards zero while a plain restoring
// algorithm on two's-complement values does not.
//
// The three results the spec defines rather than trapping are handled up front,
// in `start`, so the iteration never has to care about them:
//
//   divide by zero      quotient is all ones, remainder is the dividend
//   INT_MIN / -1        quotient is INT_MIN, remainder is zero
//
// Note both are *architectural results*, not errors: nothing here can raise an
// exception, which is why there is no error output.
// ---------------------------------------------------------------------------
module divider(
    input  logic        clk,
    input  logic        reset,

    // Pulse for one cycle to begin. Ignored while busy.
    input  logic        start,
    input  logic [31:0] dividend,
    input  logic [31:0] divisor,
    input  logic        is_signed,     // DIV/REM rather than DIVU/REMU
    input  logic        want_rem,      // REM/REMU rather than DIV/DIVU

    output logic        busy,          // iterating; nothing may be started
    output logic        done,          // result is valid and waiting to be taken
    input  logic        take,          // consumer has used the result; clears done
    output logic [31:0] result
);

logic [31:0] quotient, remainder, divisor_mag;
logic [5:0]  iter;
logic        neg_quotient, neg_remainder, rem_out;
logic [31:0] early_result;
logic        early;

// One trial subtraction per cycle: shift the next dividend bit into the
// remainder, subtract if it fits, and record the quotient bit.
//
// The shifted value needs 33 bits, not 32. The running remainder is only bounded
// by the divisor, which can be 0xFFFFFFFE, so shifting it left overflows 32 bits
// and dropping the top bit silently corrupts every division by a large divisor.
// Both branches below land back inside 32 bits: if the subtraction fits the
// result is less than the divisor, and if it does not the shifted value was
// already less than the divisor.
wire [32:0] shifted = {remainder, quotient[31]};
wire        fits    = (shifted >= {1'b0, divisor_mag});
wire [32:0] subbed  = shifted - {1'b0, divisor_mag};

wire dividend_neg = is_signed & dividend[31];
wire divisor_neg  = is_signed & divisor[31];

always_ff @(posedge clk) begin
    if (reset) begin
        busy <= 1'b0;
        done <= 1'b0;
    end else if (start && !busy && !done) begin
        rem_out       <= want_rem;
        neg_quotient  <= dividend_neg ^ divisor_neg;
        neg_remainder <= dividend_neg;

        if (divisor == 32'd0) begin
            // Defined, not a fault: -1 quotient, dividend as remainder.
            early        <= 1'b1;
            early_result <= want_rem ? dividend : 32'hFFFF_FFFF;
            done         <= 1'b1;
        end else if (is_signed && dividend == 32'h8000_0000 && divisor == 32'hFFFF_FFFF) begin
            // The one signed overflow. The quotient does not fit, and the spec
            // says to wrap rather than trap.
            early        <= 1'b1;
            early_result <= want_rem ? 32'd0 : 32'h8000_0000;
            done         <= 1'b1;
        end else begin
            early       <= 1'b0;
            quotient    <= dividend_neg ? (~dividend + 32'd1) : dividend;
            divisor_mag <= divisor_neg  ? (~divisor  + 32'd1) : divisor;
            remainder   <= 32'd0;
            iter        <= 6'd32;
            busy        <= 1'b1;
        end
    end else if (busy) begin
        if (iter == 6'd0) begin
            busy <= 1'b0;
            done <= 1'b1;
        end else begin
            // Shift the quotient left, filling in the bit just resolved.
            quotient  <= {quotient[30:0], fits};
            remainder <= fits ? subbed[31:0] : shifted[31:0];
            iter      <= iter - 6'd1;
        end
    end else if (done && take) begin
        done <= 1'b0;
    end
end

// Signs are reapplied on the way out rather than to the stored value, so the
// iteration only ever deals in magnitudes.
wire [31:0] q_signed = neg_quotient  ? (~quotient  + 32'd1) : quotient;
wire [31:0] r_signed = neg_remainder ? (~remainder + 32'd1) : remainder;

assign result = early     ? early_result
              : rem_out   ? r_signed
                          : q_signed;

endmodule

`endif
