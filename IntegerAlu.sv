// Noah Pham - formula from chatgpt
// 16-bit integer ALU that shares the global 256-bit bus. Supports the
// integer opcodes defined in params.vh (add, sub, mul, div).

`timescale 1 ps / 1 ps

module IntegerAlu(
    input  logic        Clk,
    inout  logic [255:0] DataBus,
    input  logic [15:0] address,
    input  logic        nRead,
    input  logic        nWrite,
    input  logic        nReset
);
    
    `include "params.vh"

    logic [15:0] src_a;
    logic [15:0] src_b;
    logic [15:0] result_reg;
    logic        done;
    logic [7:0]  active_op;

    // Temporary variables for procedural blocks
    logic [15:0] next_result;
    logic [16:0] sum;
    logic signed [16:0] diff;
    logic [31:0] product;

    logic        drive_bus;
    logic [255:0] bus_value;

    assign DataBus = drive_bus ? bus_value : 256'bz;

    always_ff @(negedge Clk or negedge nReset) begin
        if (!nReset) begin
            src_a      <= 16'd0;
            src_b      <= 16'd0;
            result_reg <= 16'd0;
            done       <= 1'b0;
            active_op  <= 8'h00;
        end else begin
            if (~nWrite && address[15:12] == IntAlu) begin
                case (address[11:0])
                    ALU_Source1: begin
                        src_a <= DataBus[15:0];
                    end
                    ALU_Source2: begin
                        src_b <= DataBus[15:0];
                    end
                    AluStatusIn: begin
                        next_result = result_reg;
                        done        <= 1'b0;
                        active_op   <= DataBus[7:0];

                        unique case (DataBus[7:0])
                            Iadd: begin
                                sum = {1'b0, src_a} + {1'b0, src_b};
                                next_result   = sum[15:0];
                            end
                            Isub: begin
                                diff = $signed({1'b0, src_a}) - $signed({1'b0, src_b});
                                next_result   = diff[15:0];
                            end
                            Imult: begin
                                product = src_a * src_b;
                                next_result   = product[15:0];
                            end
                            Idiv: begin
                                if (src_b == 16'd0) begin
                                    next_result = 16'd0;
                                end else begin
                                    next_result = src_a / src_b;
                                end
                            end
                            default: begin
                                // unsupported opcode -> no change
                            end
                        endcase
                        result_reg <= next_result;
                        done       <= 1'b1;
                    end
                    default: begin
                        // no other writable registers
                    end
                endcase
            end
        end
    end

    always_comb begin
        drive_bus = 1'b0;
        bus_value = 256'b0;

        if ((address[15:12] == IntAlu) && ~nRead) begin
            drive_bus = 1'b1;
            unique case (address[11:0])
                ALU_Source1: bus_value = {240'b0, src_a};
                ALU_Source2: bus_value = {240'b0, src_b};
                ALU_Result:  bus_value = {240'b0, result_reg};
                AluStatusOut: begin
                    bus_value[0]   = done;
                    bus_value[1]   = 1'b0;
                    bus_value[9:2] = active_op;
                end
                default: bus_value = 256'b0;
            endcase
        end
    end

endmodule