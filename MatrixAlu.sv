// Noah Pham - formula from chatgpt
// 4x4 matrix arithmetic unit that sits on the shared 256-bit bus.
// Supports the opcodes defined in params.vh and exposes a small set of
// memory mapped registers (status, source1, source2, result).

`timescale 1 ps / 1 ps

module MatrixAlu(
    input  logic        Clk,
    inout  logic [255:0] DataBus,
    input  logic [15:0] address,
    input  logic        nRead,
    input  logic        nWrite,
    input  logic        nReset
);

    `include "params.vh"

    logic [255:0] src_a;
    logic [255:0] src_b;
    logic [255:0] result_reg;
    logic         done;
    logic [7:0]   active_op;

    // Bus drive handling
    logic         drive_bus;
    logic [255:0] bus_value;
    
    assign DataBus = drive_bus ? bus_value : 256'bz;

    function automatic logic [15:0] word_at(input logic [255:0] data, input int idx);
        word_at = data[255 - (idx * 16) -: 16];
    endfunction

    function automatic logic [255:0] set_word(
        input logic [255:0] data,
        input int           idx,
        input logic [15:0]  value
    );
        logic [255:0] temp;
        temp = data;
        temp[255 - (idx * 16) -: 16] = value;
        set_word = temp;
    endfunction

    function automatic logic [255:0] scatter_matrix(input logic [15:0] words [0:15]);
        logic [255:0] pack;
        pack = '0;
        for (int i = 0; i < 16; i++) begin
            pack[255 - (i * 16) -: 16] = words[i];
        end
        scatter_matrix = pack;
    endfunction

    // Element-wise add/sub helper
    function automatic void element_op(
        input  logic [255:0] lhs,
        input  logic [255:0] rhs,
        input  bit           subtract,
        output logic [255:0] res
    );
        logic [15:0] temp [0:15];
        for (int i = 0; i < 16; i++) begin
            logic signed [16:0] a = {1'b0, word_at(lhs, i)};
            logic signed [16:0] b = {1'b0, word_at(rhs, i)};
            logic signed [16:0] calc = subtract ? (a - b) : (a + b);
            temp[i] = calc[15:0];
        end
        res = scatter_matrix(temp);
    endfunction

    function automatic void scale_matrix(
        input  logic [255:0] matrix_in,
        input  logic [15:0]  scalar,
        output logic [255:0] matrix_out
    );
        logic [15:0] temp [0:15];
        for (int i = 0; i < 16; i++) begin
            logic signed [31:0] mult = $signed({1'b0, word_at(matrix_in, i)}) * $signed({1'b0, scalar});
            temp[i] = mult[15:0];
        end
        matrix_out = scatter_matrix(temp);
    endfunction

    function automatic void transpose_matrix(
        input  logic [255:0] matrix_in,
        output logic [255:0] matrix_out
    );
        logic [15:0] temp [0:15];
        for (int row = 0; row < 4; row++) begin
            for (int col = 0; col < 4; col++) begin
                temp[row * 4 + col] = word_at(matrix_in, col * 4 + row);
            end
        end
        matrix_out = scatter_matrix(temp);
    endfunction

    function automatic void multiply_matrix(
        input  logic [255:0] lhs,
        input  logic [255:0] rhs,
        output logic [255:0] res
    );
        logic [15:0] temp [0:15];

        for (int row = 0; row < 4; row++) begin
            for (int col = 0; col < 4; col++) begin
                logic signed [31:0] acc = 32'sd0;
                for (int k = 0; k < 4; k++) begin
                    int a_index = row * 4 + k;
                    int b_index = k * 4 + col;
                    acc += $signed({1'b0, word_at(lhs, a_index)}) *
                           $signed({1'b0, word_at(rhs, b_index)});
                end
                temp[row * 4 + col] = acc[15:0];
            end
        end
        res = scatter_matrix(temp);
    endfunction

    function automatic logic [15:0] scalar_from_bus(input logic [255:0] data);
        scalar_from_bus = data[15:0];
    endfunction

    always_ff @(negedge Clk or negedge nReset) begin
        if (!nReset) begin
            src_a      <= '0;
            src_b      <= '0;
            result_reg <= '0;
            done       <= 1'b0;
            active_op  <= 8'h00;
        end else begin
            if (~nWrite && address[15:12] == AluEn) begin
                case (address[11:0])
                    ALU_Source1: begin
                        src_a <= DataBus;
                    end
                    ALU_Source2: begin
                        src_b <= DataBus;
                    end
                    AluStatusIn: begin
                        automatic logic [255:0] new_result;
                        new_result   = result_reg;
                        done         <= 1'b0;
                        active_op    <= DataBus[7:0];

                        unique case (DataBus[7:0])
                            MAdd: begin
                                element_op(src_a, src_b, 1'b0, new_result);
                            end
                            MSub: begin
                                element_op(src_a, src_b, 1'b1, new_result);
                            end
                            MTranspose: begin
                                transpose_matrix(src_a, new_result);
                            end
                            MScale,
                            MScaleImm: begin
                                logic [255:0] scaled;
                                scale_matrix(src_a, scalar_from_bus(src_b), scaled);
                                new_result   = scaled;
                            end
                            MMult1,
                            MMult2,
                            MMult3: begin
                                logic [255:0] mult_res;
                                multiply_matrix(src_a, src_b, mult_res);
                                new_result   = mult_res;
                            end
                            default: begin
                                // Unsupported opcode, leave result as-is
                            end
                        endcase
                        result_reg <= new_result;
                        done       <= 1'b1;
                    end
                    default: begin
                        // unused register slots
                    end
                endcase
            end
        end
    end

    always_comb begin
        drive_bus = 1'b0;
        bus_value = 256'b0;

        if ((address[15:12] == AluEn) && ~nRead) begin
            drive_bus = 1'b1;
            unique case (address[11:0])
                ALU_Source1: bus_value = src_a;
                ALU_Source2: bus_value = src_b;
                ALU_Result:  bus_value = result_reg;
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