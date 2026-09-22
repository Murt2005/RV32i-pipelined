`ifndef _divider_sv
`define _divider_sv

`include "system.sv"

// Iterative 32-bit divider for DIV / DIVU / REM / REMU.
module divider(
    input  logic        clk,
    input  logic        reset,

    input  logic        start,
    input  logic [31:0] dividend,
    input  logic [31:0] divisor,
    input  logic        is_signed,
    input  logic        want_rem,

    output logic        busy,
    output logic        done,
    input  logic        take,
    output logic [31:0] result
);

logic [31:0] quotient, remainder, divisor_mag;
logic [5:0]  iter;
logic        neg_quotient, neg_remainder, rem_out;
logic [31:0] early_result;
logic        early;

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
            early        <= 1'b1;
            early_result <= want_rem ? dividend : 32'hFFFF_FFFF;
            done         <= 1'b1;
        end else if (is_signed && dividend == 32'h8000_0000 && divisor == 32'hFFFF_FFFF) begin
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
            quotient  <= {quotient[30:0], fits};
            remainder <= fits ? subbed[31:0] : shifted[31:0];
            iter      <= iter - 6'd1;
        end
    end else if (done && take) begin
        done <= 1'b0;
    end
end

wire [31:0] q_signed = neg_quotient  ? (~quotient  + 32'd1) : quotient;
wire [31:0] r_signed = neg_remainder ? (~remainder + 32'd1) : remainder;

assign result = early     ? early_result
              : rem_out   ? r_signed
                          : q_signed;

endmodule

`endif
