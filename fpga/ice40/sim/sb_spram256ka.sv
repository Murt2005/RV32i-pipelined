`ifndef _sb_spram256ka_sv
`define _sb_spram256ka_sv

// Simulation model of the iCE40 SB_SPRAM256KA block: 16384 x 16, per-nibble write mask

module SB_SPRAM256KA (
    input  logic [13:0] ADDRESS,
    input  logic [15:0] DATAIN,
    input  logic [3:0]  MASKWREN,
    input  logic        WREN,
    input  logic        CHIPSELECT,
    input  logic        CLOCK,
    input  logic        STANDBY,
    input  logic        SLEEP,
    input  logic        POWEROFF,
    output logic [15:0] DATAOUT
);

    logic [15:0] mem [0:16383];

    // Real SPRAM powers up undefined; zero it so simulation is repeatable
    initial begin
        for (int i = 0; i < 16384; i++)
            mem[i] = 16'h0000;
        DATAOUT = 16'h0000;
    end

    always @(posedge CLOCK) begin
        if (POWEROFF && !SLEEP && !STANDBY && CHIPSELECT) begin
            if (WREN) begin
                if (MASKWREN[0]) mem[ADDRESS][3:0]   <= DATAIN[3:0];
                if (MASKWREN[1]) mem[ADDRESS][7:4]   <= DATAIN[7:4];
                if (MASKWREN[2]) mem[ADDRESS][11:8]  <= DATAIN[11:8];
                if (MASKWREN[3]) mem[ADDRESS][15:12] <= DATAIN[15:12];
                // DATAOUT is not updated during a write
            end else begin
                DATAOUT <= mem[ADDRESS];
            end
        end
    end

endmodule

`endif
