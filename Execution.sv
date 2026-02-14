// Noah Pham - Chatgpt help debugging
// Bus master / control engine for the Simplistic Processing Engine project.
// Fetches instructions from InstructionMemory, decodes them, and
// orchestrates memory transactions plus Matrix/Integer ALU operations.

`timescale 1 ps / 1 ps

module Execution(
    input  logic        Clk,
    inout  logic [255:0] DataBus,
    output logic [15:0] address,
    output logic        nRead,
    output logic        nWrite,
    input  logic        nReset
);

  `include "params.vh"

    typedef enum logic [5:0] {
        ST_RESET,
        ST_FETCH,
        ST_FETCH_WAIT,
        ST_DECODE,
        ST_MEM_READ_REQ,
        ST_MEM_READ_WAIT,
        ST_POST_READ,
        ST_MATRIX_SRC1_WRITE,
        ST_MATRIX_SRC1_WAIT,
        ST_MATRIX_SRC2_WRITE,
        ST_MATRIX_SRC2_WAIT,
        ST_MATRIX_CMD_WRITE,
        ST_MATRIX_CMD_WAIT,
        ST_MATRIX_STATUS_READ,
        ST_MATRIX_STATUS_WAIT,
        ST_MATRIX_RESULT_READ,
        ST_MATRIX_RESULT_WAIT,
        ST_INT_SRC1_WRITE,
        ST_INT_SRC1_WAIT,
        ST_INT_SRC2_WRITE,
        ST_INT_SRC2_WAIT,
        ST_INT_CMD_WRITE,
        ST_INT_CMD_WAIT,
        ST_INT_STATUS_READ,
        ST_INT_STATUS_WAIT,
        ST_INT_RESULT_READ,
        ST_INT_RESULT_WAIT,
        ST_BRANCH_EVAL,
        ST_RESULT_STORE,
        ST_WRITEBACK_REQ,
        ST_WRITEBACK_WAIT,
        ST_COMPLETE,
        ST_HALT
    } state_t;

    typedef enum logic [1:0] {
        OP_NONE,
        OP_MATRIX,
        OP_INTEGER,
        OP_BRANCH
    } op_kind_t;

    typedef enum logic [2:0] {
        READ_NONE,
        READ_MATRIX_A,
        READ_MATRIX_B,
        READ_SCALAR_A,
        READ_SCALAR_B
    } read_target_t;

    logic [255:0] InternalReg [0:15];

    // Program control
    state_t state, state_next;
    logic [11:0] pc;
    logic [11:0] pc_next;
    logic [31:0] instr_reg;

    // Decoded fields
    logic [7:0] current_opcode;
    logic [7:0] current_dest;
    logic [7:0] current_srcA;
    logic [7:0] current_srcB;
    op_kind_t   current_op_kind;

    // Operand qualification
    logic dest_is_register;
    logic srcA_is_register;
    logic srcB_is_register;
    logic srcB_is_immediate;
    logic uses_src2;
    logic matrix_src2_is_scalar;
    logic matrix_needs_src2;

    logic [3:0] dest_reg_index;
    logic [3:0] srcA_reg_index;
    logic [3:0] srcB_reg_index;

    logic [11:0] dest_mem_addr;
    logic [11:0] srcA_mem_addr;
    logic [11:0] srcB_mem_addr;

    logic signed [11:0] branch_offset_value;

    // Operand storage
    logic [255:0] matrix_src_a;
    logic [255:0] matrix_src_b;
    logic [255:0] matrix_result;
    logic [15:0]  scalar_src_a;
    logic [15:0]  scalar_src_b;
    logic [15:0]  scalar_result;

    logic src1_ready;
    logic src2_ready;

    // Pending read control
    read_target_t pending_read_target;
    logic [11:0]  pending_read_addr;
    read_target_t pending_read_target_next;
    logic [11:0]  pending_read_addr_next;
    logic         load_new_read;
    logic         clear_pending_read;

    // Writeback staging
    logic [255:0] pending_write_data;
    logic [11:0]  pending_write_addr;

    // ALU opcode shadow
    logic [7:0] pending_matrix_opcode;
    logic [7:0] pending_int_opcode;

    // Temporary variables for procedural blocks
    logic matrix_op;
    logic int_op;
    logic branch_op;
    op_kind_t next_kind;
    logic need_src1;
    logic need_src2_flag;
    logic take_branch;
    state_t exec_entry;
    logic [15:0] val;

    // Bus drive control
    logic        drive_bus;
    logic [255:0] bus_value;

    assign DataBus = drive_bus ? bus_value : 256'bz;

    function automatic logic is_register_code(input logic [7:0] code);
        return (code[7:4] == 4'h1);
    endfunction

    function automatic logic is_matrix_opcode(input logic [7:0] op);
        case (op)
            MMult1, MMult2, MMult3,
            MAdd, MSub, MTranspose,
            MScale, MScaleImm: return 1'b1;
            default:            return 1'b0;
        endcase
    endfunction

    function automatic logic needs_matrix_src2(input logic [7:0] op);
        case (op)
            MTranspose:                      return 1'b0;
            default:                         return 1'b1;
        endcase
    endfunction

    function automatic logic is_integer_opcode(input logic [7:0] op);
        case (op)
            Iadd, Isub, Imult, Idiv: return 1'b1;
            default:                 return 1'b0;
        endcase
    endfunction

    function automatic logic is_branch_opcode(input logic [7:0] op);
        case (op)
            BNE, BEQ, BLT, BGT: return 1'b1;
            default:            return 1'b0;
        endcase
    endfunction

    localparam int MAIN_LOCAL_ADDR_BITS = 12;
    localparam int MAIN_ALIGN_BITS      = 7;  // lower 7 bits absent on bus
    localparam int MAIN_INDEX_WIDTH     = MAIN_LOCAL_ADDR_BITS - MAIN_ALIGN_BITS;

    function automatic logic [11:0] to_mem_addr(input logic [7:0] idx);
        logic [11:0] offset;
        offset            = 12'd0;
        offset[11:MAIN_ALIGN_BITS] = idx[MAIN_INDEX_WIDTH-1:0];
        return offset;
    endfunction

    function automatic logic signed [11:0] decode_branch_offset(input logic [7:0] raw);
        // Sign-extend 8-bit signed value to 12 bits
        return $signed({{4{raw[7]}}, raw});
    endfunction

    function automatic logic [11:0] alu_local_addr(input int idx);
        return idx[11:0];
    endfunction

    function automatic logic [255:0] scalar_to_bus(input logic [15:0] value);
        return {240'b0, value};
    endfunction

    always_ff @(posedge Clk or negedge nReset) begin
        if (!nReset) begin
            state                  <= ST_RESET;
            pc                     <= 12'd0;
            pc_next                <= 12'd0;
            instr_reg              <= 32'd0;
            current_opcode         <= 8'h00;
            current_dest           <= 8'h00;
            current_srcA           <= 8'h00;
            current_srcB           <= 8'h00;
            current_op_kind        <= OP_NONE;
            dest_is_register       <= 1'b0;
            srcA_is_register       <= 1'b0;
            srcB_is_register       <= 1'b0;
            srcB_is_immediate      <= 1'b0;
            uses_src2              <= 1'b0;
            matrix_src2_is_scalar  <= 1'b0;
            matrix_needs_src2      <= 1'b0;
            dest_reg_index         <= 4'd0;
            srcA_reg_index         <= 4'd0;
            srcB_reg_index         <= 4'd0;
            dest_mem_addr          <= 12'd0;
            srcA_mem_addr          <= 12'd0;
            srcB_mem_addr          <= 12'd0;
            branch_offset_value    <= 12'sd0;
            matrix_src_a           <= 256'd0;
            matrix_src_b           <= 256'd0;
            matrix_result          <= 256'd0;
            scalar_src_a           <= 16'd0;
            scalar_src_b           <= 16'd0;
            scalar_result          <= 16'd0;
            src1_ready             <= 1'b0;
            src2_ready             <= 1'b0;
            pending_read_target    <= READ_NONE;
            pending_read_addr      <= 12'd0;
            pending_write_data     <= 256'd0;
            pending_write_addr     <= 12'd0;
            pending_matrix_opcode  <= 8'h00;
            pending_int_opcode     <= 8'h00;
            for (int k = 0; k < 16; k++) begin
                InternalReg[k] <= 256'd0;
            end
        end else begin
            state <= state_next;

            if (state == ST_RESET) begin
                pc      <= 12'd0;
                pc_next <= 12'd0;
            end

            if (state == ST_FETCH_WAIT) begin
                instr_reg <= DataBus[31:0];
            end

            if (state == ST_COMPLETE) begin
                pc <= pc_next;
            end

            if (load_new_read) begin
                pending_read_target <= pending_read_target_next;
                pending_read_addr   <= pending_read_addr_next;
            end else if (clear_pending_read) begin
                pending_read_target <= READ_NONE;
            end

                case (state)
                ST_DECODE: begin
                    logic [7:0] opcode_dec;
                    logic matrix_src2_scalar_flag;
                    logic matrix_needs_src2_flag_local;
                    logic srcA_reg_flag;
                    logic srcB_reg_flag;
                    logic srcB_imm_flag;
                    logic dest_reg_flag;
                    logic need_src2_calc;

                    opcode_dec = instr_reg[31:24];
                    current_opcode  <= instr_reg[31:24];
                    current_dest    <= instr_reg[23:16];
                    current_srcA    <= instr_reg[15:8];
                    current_srcB    <= instr_reg[7:0];
                    dest_reg_index  <= instr_reg[19:16];
                    srcA_reg_index  <= instr_reg[11:8];
                    srcB_reg_index  <= instr_reg[3:0];
                    dest_mem_addr   <= to_mem_addr(instr_reg[23:16]);
                    srcA_mem_addr   <= to_mem_addr(instr_reg[15:8]);
                    srcB_mem_addr   <= to_mem_addr(instr_reg[7:0]);
                    pc_next         <= pc + 12'd1;

                    matrix_op  = is_matrix_opcode(opcode_dec);
                    int_op     = is_integer_opcode(opcode_dec);
                    branch_op  = is_branch_opcode(opcode_dec);
                    if (matrix_op) begin
                        next_kind             = OP_MATRIX;
                        pending_matrix_opcode <= opcode_dec;
                    end else if (int_op) begin
                        next_kind          = OP_INTEGER;
                        pending_int_opcode <= opcode_dec;
                    end else if (branch_op) begin
                        next_kind = OP_BRANCH;
                    end else begin
                        next_kind = OP_NONE;
                    end
                    current_op_kind <= next_kind;

                    matrix_src2_scalar_flag      = (opcode_dec == MScale) || (opcode_dec == MScaleImm);
                    matrix_needs_src2_flag_local = needs_matrix_src2(opcode_dec);
                    matrix_src2_is_scalar        <= matrix_src2_scalar_flag;
                    matrix_needs_src2            <= matrix_needs_src2_flag_local;

                    dest_reg_flag = is_register_code(instr_reg[23:16]);
                    dest_is_register <= (next_kind != OP_BRANCH) && dest_reg_flag;

                    srcA_reg_flag = is_register_code(instr_reg[15:8]);
                    srcB_reg_flag = is_register_code(instr_reg[7:0]);
                    srcB_imm_flag = (opcode_dec == MScaleImm);

                    srcA_is_register <= srcA_reg_flag;
                    srcB_is_register <= srcB_reg_flag;
                    srcB_is_immediate <= srcB_imm_flag;

                    need_src1 = (matrix_op | int_op | branch_op);

                    if (next_kind == OP_MATRIX)
                        need_src2_calc = matrix_needs_src2_flag_local;
                    else if (next_kind == OP_INTEGER || next_kind == OP_BRANCH)
                        need_src2_calc = 1'b1;
                    else
                        need_src2_calc = 1'b0;

                    need_src2_flag <= need_src2_calc;
                    uses_src2      <= need_src2_calc;

                    src1_ready <= (need_src1 && !srcA_reg_flag) ? 1'b0 : 1'b1;

                    if (!need_src2_calc)
                        src2_ready <= 1'b1;
                    else if (srcB_reg_flag || srcB_imm_flag)
                        src2_ready <= 1'b1;
                    else
                        src2_ready <= 1'b0;

                    branch_offset_value <= branch_op ? decode_branch_offset(instr_reg[23:16])
                                                     : 12'sd0;

                    if (next_kind == OP_MATRIX) begin
                        if (srcA_reg_flag) begin
                            matrix_src_a <= InternalReg[srcA_reg_index];
                        end
                        if (matrix_needs_src2_flag_local) begin
                            if (matrix_src2_scalar_flag) begin
                                if (srcB_reg_flag) begin
                                    val = InternalReg[srcB_reg_index][15:0];
                                    scalar_src_b <= val;
                                    matrix_src_b <= scalar_to_bus(val);
                                end else if (srcB_imm_flag) begin
                                    val = {8'h00, instr_reg[7:0]};
                                    scalar_src_b <= val;
                                    matrix_src_b <= scalar_to_bus(val);
                                end
                            end else if (srcB_reg_flag) begin
                                matrix_src_b <= InternalReg[srcB_reg_index];
                            end
                        end
                    end else if (next_kind == OP_INTEGER || next_kind == OP_BRANCH) begin
                        if (srcA_reg_flag) begin
                            scalar_src_a <= InternalReg[srcA_reg_index][15:0];
                        end
                        if (need_src2_calc && srcB_reg_flag) begin
                            scalar_src_b <= InternalReg[srcB_reg_index][15:0];
                        end
                    end
                end

                ST_MEM_READ_WAIT: begin
                    case (pending_read_target)
                        READ_MATRIX_A: begin
                            matrix_src_a <= DataBus;
                            src1_ready   <= 1'b1;
                        end
                        READ_MATRIX_B: begin
                            matrix_src_b <= DataBus;
                            src2_ready   <= 1'b1;
                        end
                        READ_SCALAR_A: begin
                            scalar_src_a <= DataBus[15:0];
                            src1_ready   <= 1'b1;
                        end
                        READ_SCALAR_B: begin
                            scalar_src_b <= DataBus[15:0];
                            src2_ready   <= 1'b1;
                            if (current_op_kind == OP_MATRIX && matrix_src2_is_scalar) begin
                                matrix_src_b <= scalar_to_bus(DataBus[15:0]);
                            end
                        end
                        default: ;
                    endcase
                end

                ST_MATRIX_RESULT_WAIT: begin
                    matrix_result <= DataBus;
                end

                ST_INT_RESULT_WAIT: begin
                    scalar_result <= DataBus[15:0];
                end

                ST_BRANCH_EVAL: begin
                    take_branch = 1'b0;
                    case (current_opcode)
                        BEQ: take_branch = (scalar_src_a == scalar_src_b);
                        BNE: take_branch = (scalar_src_a != scalar_src_b);
                        BLT: take_branch = ($signed(scalar_src_a) < $signed(scalar_src_b));
                        BGT: take_branch = ($signed(scalar_src_a) > $signed(scalar_src_b));
                        default: take_branch = 1'b0;
                    endcase
                    if (take_branch) begin
                        pc_next <= pc + branch_offset_value;
                    end
                end

                ST_RESULT_STORE: begin
                    if (dest_is_register) begin
                        case (current_op_kind)
                            OP_MATRIX:  InternalReg[dest_reg_index] <= matrix_result;
                            OP_INTEGER: InternalReg[dest_reg_index] <= scalar_to_bus(scalar_result);
                            default: ;
                        endcase
                    end else begin
                        case (current_op_kind)
                            OP_MATRIX: begin
                                pending_write_data <= matrix_result;
                                pending_write_addr <= dest_mem_addr;
                            end
                            OP_INTEGER: begin
                                pending_write_data <= scalar_to_bus(scalar_result);
                                pending_write_addr <= dest_mem_addr;
                            end
                            default: ;
                        endcase
                    end
                end
            endcase
        end
    end

    always_comb begin
        logic [31:0] instr_word;
        logic [7:0]  opcode_now;
        logic [7:0]  dest_now;
        logic [7:0]  srcA_now;
        logic [7:0]  srcB_now;
        logic        matrix_op_now;
        logic        int_op_now;
        logic        branch_op_now;
        op_kind_t    op_kind_now;
        logic        matrix_src2_scalar_now;
        logic        matrix_needs_src2_now;
        logic        srcA_is_reg_now;
        logic        srcB_is_reg_now;
        logic        srcB_is_imm_now;
        logic        need_src1_now;
        logic        need_src2_now;
        logic        decode_src1_ready_now;
        logic        decode_src2_ready_now;
        logic [11:0] dest_addr_now;
        logic [11:0] srcA_addr_now;
        logic [11:0] srcB_addr_now;
        op_kind_t    op_kind_effective;

        instr_word = instr_reg;
        opcode_now = instr_word[31:24];
        dest_now   = instr_word[23:16];
        srcA_now   = instr_word[15:8];
        srcB_now   = instr_word[7:0];

        matrix_op_now  = is_matrix_opcode(opcode_now);
        int_op_now     = is_integer_opcode(opcode_now);
        branch_op_now  = is_branch_opcode(opcode_now);

        if (matrix_op_now)          op_kind_now = OP_MATRIX;
        else if (int_op_now)        op_kind_now = OP_INTEGER;
        else if (branch_op_now)     op_kind_now = OP_BRANCH;
        else                        op_kind_now = OP_NONE;

        matrix_src2_scalar_now = (opcode_now == MScale) || (opcode_now == MScaleImm);
        matrix_needs_src2_now  = needs_matrix_src2(opcode_now);

        srcA_is_reg_now = is_register_code(srcA_now);
        srcB_is_reg_now = is_register_code(srcB_now);
        srcB_is_imm_now = (opcode_now == MScaleImm);

        need_src1_now = matrix_op_now || int_op_now || branch_op_now;
        if (op_kind_now == OP_MATRIX) begin
            need_src2_now = matrix_needs_src2_now;
        end else if (op_kind_now == OP_INTEGER || op_kind_now == OP_BRANCH) begin
            need_src2_now = 1'b1;
        end else begin
            need_src2_now = 1'b0;
        end

        decode_src1_ready_now = (!need_src1_now) ? 1'b1 :
                                (srcA_is_reg_now ? 1'b1 : 1'b0);

        decode_src2_ready_now = (!need_src2_now) ? 1'b1 :
                                ((srcB_is_reg_now || srcB_is_imm_now) ? 1'b1 : 1'b0);

        dest_addr_now = to_mem_addr(dest_now);
        srcA_addr_now = to_mem_addr(srcA_now);
        srcB_addr_now = to_mem_addr(srcB_now);

        // Defaults
        state_next               = state;
        nRead                    = 1'b1;
        nWrite                   = 1'b1;
        address                  = 16'h0000;
        drive_bus                = 1'b0;
        bus_value                = 256'd0;
        load_new_read            = 1'b0;
        clear_pending_read       = 1'b0;
        pending_read_target_next = pending_read_target;
        pending_read_addr_next   = pending_read_addr;

        op_kind_effective = (state == ST_DECODE) ? op_kind_now : current_op_kind;

        case (op_kind_effective)
            OP_MATRIX:  exec_entry = ST_MATRIX_SRC1_WRITE;
            OP_INTEGER: exec_entry = ST_INT_SRC1_WRITE;
            OP_BRANCH:  exec_entry = ST_BRANCH_EVAL;
            default:    exec_entry = ST_COMPLETE;
        endcase

        case (state)
            ST_RESET: begin
                state_next = ST_FETCH;
            end
            ST_FETCH: begin
                address   = {InstrMemEn, pc};
                nRead     = 1'b0;
                state_next = ST_FETCH_WAIT;
            end
            ST_FETCH_WAIT: begin
                address   = {InstrMemEn, pc};
                nRead     = 1'b0;
                state_next = ST_DECODE;
            end
            ST_DECODE: begin
                if (opcode_now == 8'hFF) begin
                    state_next = ST_HALT;
                end else if (op_kind_now == OP_NONE) begin
                    state_next = ST_COMPLETE;
                end else if (!decode_src1_ready_now) begin
                    load_new_read            = 1'b1;
                    pending_read_addr_next   = srcA_addr_now;
                    pending_read_target_next = (op_kind_now == OP_MATRIX) ? READ_MATRIX_A
                                                                          : READ_SCALAR_A;
                    state_next = ST_MEM_READ_REQ;
                end else if (!decode_src2_ready_now) begin
                    load_new_read            = 1'b1;
                    pending_read_addr_next   = srcB_addr_now;
                    if (op_kind_now == OP_MATRIX && !matrix_src2_scalar_now) begin
                        pending_read_target_next = READ_MATRIX_B;
                    end else begin
                        pending_read_target_next = READ_SCALAR_B;
                    end
                    state_next = ST_MEM_READ_REQ;
                end else begin
                    state_next = ST_POST_READ;
                end
            end
            ST_MEM_READ_REQ: begin
                address   = {MainMemEn, pending_read_addr};
                nRead     = 1'b0;
                state_next = ST_MEM_READ_WAIT;
            end
            ST_MEM_READ_WAIT: begin
                address   = {MainMemEn, pending_read_addr};
                nRead     = 1'b0;
                clear_pending_read = 1'b1;
                state_next = ST_POST_READ;
            end
            ST_POST_READ: begin
                if (!src1_ready) begin
                    load_new_read            = 1'b1;
                    pending_read_addr_next   = srcA_mem_addr;
                    pending_read_target_next = (current_op_kind == OP_MATRIX) ? READ_MATRIX_A
                                                                               : READ_SCALAR_A;
                    state_next = ST_MEM_READ_REQ;
                end else if (!src2_ready) begin
                    load_new_read            = 1'b1;
                    pending_read_addr_next   = srcB_mem_addr;
                    if (current_op_kind == OP_MATRIX && !matrix_src2_is_scalar) begin
                        pending_read_target_next = READ_MATRIX_B;
                    end else begin
                        pending_read_target_next = READ_SCALAR_B;
                    end
                    state_next = ST_MEM_READ_REQ;
                end else begin
                    state_next = exec_entry;
                end
            end
            ST_MATRIX_SRC1_WRITE: begin
                address   = {AluEn, alu_local_addr(ALU_Source1)};
                bus_value = matrix_src_a;
                drive_bus = 1'b1;
                nWrite    = 1'b0;
                state_next = ST_MATRIX_SRC1_WAIT;
            end
            ST_MATRIX_SRC1_WAIT: begin
                state_next = (matrix_needs_src2) ? ST_MATRIX_SRC2_WRITE
                                                 : ST_MATRIX_CMD_WRITE;
            end
            ST_MATRIX_SRC2_WRITE: begin
                address   = {AluEn, alu_local_addr(ALU_Source2)};
                bus_value = matrix_src_b;
                drive_bus = 1'b1;
                nWrite    = 1'b0;
                state_next = ST_MATRIX_SRC2_WAIT;
            end
            ST_MATRIX_SRC2_WAIT: begin
                state_next = ST_MATRIX_CMD_WRITE;
            end
            ST_MATRIX_CMD_WRITE: begin
                address         = {AluEn, alu_local_addr(AluStatusIn)};
                bus_value[7:0]  = pending_matrix_opcode;
                drive_bus       = 1'b1;
                nWrite          = 1'b0;
                state_next      = ST_MATRIX_CMD_WAIT;
            end
            ST_MATRIX_CMD_WAIT: begin
                state_next = ST_MATRIX_STATUS_READ;
            end
            ST_MATRIX_STATUS_READ: begin
                address   = {AluEn, alu_local_addr(AluStatusOut)};
                nRead     = 1'b0;
                state_next = ST_MATRIX_STATUS_WAIT;
            end
            ST_MATRIX_STATUS_WAIT: begin
                address   = {AluEn, alu_local_addr(AluStatusOut)};
                nRead     = 1'b0;
                if (DataBus[0]) state_next = ST_MATRIX_RESULT_READ;
                else            state_next = ST_MATRIX_STATUS_WAIT;
            end
            ST_MATRIX_RESULT_READ: begin
                address   = {AluEn, alu_local_addr(ALU_Result)};
                nRead     = 1'b0;
                state_next = ST_MATRIX_RESULT_WAIT;
            end
            ST_MATRIX_RESULT_WAIT: begin
                address   = {AluEn, alu_local_addr(ALU_Result)};
                nRead     = 1'b0;
                state_next = ST_RESULT_STORE;
            end
            ST_INT_SRC1_WRITE: begin
                address   = {IntAlu, alu_local_addr(ALU_Source1)};
                bus_value = scalar_to_bus(scalar_src_a);
                drive_bus = 1'b1;
                nWrite    = 1'b0;
                state_next = ST_INT_SRC1_WAIT;
            end
            ST_INT_SRC1_WAIT: begin
                state_next = ST_INT_SRC2_WRITE;
            end
            ST_INT_SRC2_WRITE: begin
                address   = {IntAlu, alu_local_addr(ALU_Source2)};
                bus_value = scalar_to_bus(scalar_src_b);
                drive_bus = 1'b1;
                nWrite    = 1'b0;
                state_next = ST_INT_SRC2_WAIT;
            end
            ST_INT_SRC2_WAIT: begin
                state_next = ST_INT_CMD_WRITE;
            end
            ST_INT_CMD_WRITE: begin
                address         = {IntAlu, alu_local_addr(AluStatusIn)};
                bus_value[7:0]  = pending_int_opcode;
                drive_bus       = 1'b1;
                nWrite          = 1'b0;
                state_next      = ST_INT_CMD_WAIT;
            end
            ST_INT_CMD_WAIT: begin
                state_next = ST_INT_STATUS_READ;
            end
            ST_INT_STATUS_READ: begin
                address   = {IntAlu, alu_local_addr(AluStatusOut)};
                nRead     = 1'b0;
                state_next = ST_INT_STATUS_WAIT;
            end
            ST_INT_STATUS_WAIT: begin
                address   = {IntAlu, alu_local_addr(AluStatusOut)};
                nRead     = 1'b0;
                if (DataBus[0]) state_next = ST_INT_RESULT_READ;
                else            state_next = ST_INT_STATUS_WAIT;
            end
            ST_INT_RESULT_READ: begin
                address   = {IntAlu, alu_local_addr(ALU_Result)};
                nRead     = 1'b0;
                state_next = ST_INT_RESULT_WAIT;
            end
            ST_INT_RESULT_WAIT: begin
                address   = {IntAlu, alu_local_addr(ALU_Result)};
                nRead     = 1'b0;
                state_next = ST_RESULT_STORE;
            end
            ST_BRANCH_EVAL: begin
                state_next = ST_COMPLETE;
            end
            ST_RESULT_STORE: begin
                if (dest_is_register)
                    state_next = ST_COMPLETE;
                else
                    state_next = ST_WRITEBACK_REQ;
            end
            ST_WRITEBACK_REQ: begin
                address   = {MainMemEn, pending_write_addr};
                bus_value = pending_write_data;
                drive_bus = 1'b1;
                nWrite    = 1'b0;
                state_next = ST_WRITEBACK_WAIT;
            end
            ST_WRITEBACK_WAIT: begin
                address   = {MainMemEn, pending_write_addr};
                bus_value = pending_write_data;
                drive_bus = 1'b1;
                nWrite    = 1'b0;
                state_next = ST_COMPLETE;
            end
            ST_COMPLETE: begin
                state_next = ST_FETCH;
            end
            ST_HALT: begin
                address   = 16'h0000;
                nRead     = 1'b1;
                nWrite    = 1'b1;
                state_next = ST_HALT;
            end
            default: begin
                state_next = ST_RESET;
            end
        endcase
    end

endmodule