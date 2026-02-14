# HDL-Final-Project
# Simplistic Processing Engine (SPE)

## Overview

The Simplistic Processing Engine (SPE) is a structured, state-driven execution unit designed to support matrix operations, scalar arithmetic, and branch instructions. The architecture follows a deterministic fetch–decode–execute–writeback pipeline, with explicit state transitions and controlled memory/ALU interactions.

This document describes the complete control flow, state machine behavior, and data movement within the Execution Unit.

---

# 1. Initialization and Instruction Fetch

## Reset State

**State:** `ST_RESET`

* Clears:

  * Program Counter (PC)
  * Internal registers
  * Pending read/write flags
* Transitions to: `ST_FETCH`

---

## Instruction Fetch

**State:** `ST_FETCH`

* Drives Instruction Memory using:

  * `InstrMemEn`
  * `PC`
* Asserts `nRead = 0`
* Transitions to: `ST_FETCH_WAIT`

---

## Fetch Wait

**State:** `ST_FETCH_WAIT`

* Holds read request for one full cycle
* Latches fetched instruction into `instr_reg`

**Next State:**

* `ST_DECODE` (normal opcode)
* `ST_HALT` (if opcode = `0xFF`)

---

# 2. Decode and Operand Acquisition

## Decode

**State:** `ST_DECODE`

Responsibilities:

* Extract opcode
* Identify register IDs
* Detect immediate flags
* Classify instruction:

  * Matrix
  * Integer
  * Branch
* Determine operand addresses
* Check operand readiness

**Next State:**

* `ST_MEM_READ_REQ` (if operands missing)
* `ST_POST_READ` (if operands ready)

---

## Memory Read Request

**State:** `ST_MEM_READ_REQ`

* Issues read to MainMemory using `pending_read_addr`
* Sets `pending_read_target`
* Transitions to: `ST_MEM_READ_WAIT`

---

## Memory Read Wait

**State:** `ST_MEM_READ_WAIT`

* Holds read enable for one cycle
* Captures `DataBus` into operand slot
* Clears pending flags
* Transitions to: `ST_POST_READ`

---

## Post-Read Operand Check

**State:** `ST_POST_READ`

* Re-evaluates operand readiness

**Next State:**

* `ST_MEM_READ_REQ` (if more reads required)
* Execution entry state:

  * `ST_MATRIX_SRC1_WRITE`
  * `ST_INT_SRC1_WRITE`
  * `ST_BRANCH_EVAL`

Operand readiness is dynamically evaluated, enabling flexible instruction sequencing.

---

# 3. Matrix ALU Operation Sequence

Matrix operations use a dedicated Matrix ALU interface.

| State                   | Purpose                                 |
| ----------------------- | --------------------------------------- |
| `ST_MATRIX_SRC1_WRITE`  | Write matrix operand A                  |
| `ST_MATRIX_SRC2_WRITE`  | Write operand B (skipped for unary ops) |
| `ST_MATRIX_CMD_WRITE`   | Launch operation via `AluStatusIn`      |
| `ST_MATRIX_STATUS_READ` | Poll `AluStatusOut` for completion      |
| `ST_MATRIX_RESULT_READ` | Read result into `matrix_result`        |
| `ST_RESULT_STORE`       | Stage result for writeback              |

All memory-bound results pass through the unified writeback pipeline to maintain clean bus arbitration.

---

# 4. Integer ALU Operation Sequence

Scalar operations follow a similar structure.

| State                | Purpose                    |
| -------------------- | -------------------------- |
| `ST_INT_SRC1_WRITE`  | Write scalar operand A     |
| `ST_INT_SRC2_WRITE`  | Write scalar operand B     |
| `ST_INT_CMD_WRITE`   | Launch Integer ALU         |
| `ST_INT_STATUS_READ` | Poll for completion        |
| `ST_INT_RESULT_READ` | Capture result             |
| `ST_RESULT_STORE`    | Stage result for writeback |

Scalar results are zero-extended prior to writeback.

---

# 5. Branch Evaluation

## Branch Execution

**State:** `ST_BRANCH_EVAL`

* Evaluate branch condition
* If TRUE:

  * `pc_next = pc + branch_offset`
* If FALSE:

  * Continue sequential execution

Branches do not use the ALU.

---

# 6. Writeback and Completion

## Writeback Request

**State:** `ST_WRITEBACK_REQ`

* Drives `pending_write_addr`
* Asserts `nWrite = 0`
* Places staged data on `DataBus`
* Transitions to: `ST_WRITEBACK_WAIT`

---

## Writeback Wait

**State:** `ST_WRITEBACK_WAIT`

* Holds bus signals one extra cycle
* Ensures memory samples on negative clock edge
* Transitions to: `ST_COMPLETE`

---

## Instruction Complete

**State:** `ST_COMPLETE`

* Updates `pc <= pc_next`
* Returns to `ST_FETCH`

---

# 7. Halt State

If opcode = `0xFF`:

| State     | Purpose                              |
| --------- | ------------------------------------ |
| `ST_HALT` | Persistent halt with no bus activity |

---

# 8. End-to-End Dataflow Summary

For every non-halt instruction:

1. **Fetch** – Retrieve 32-bit instruction from Instruction Memory
2. **Decode** – Identify instruction type and operands
3. **Operand Acquisition** – Fetch missing operands from MainMemory
4. **ALU Launch** – Execute Matrix or Integer operation
5. **Result Retrieval** – Poll and capture output
6. **Writeback** – Update register or memory
7. **PC Update** – Advance to next instruction

---

# Architectural Characteristics

* Deterministic state-driven execution
* Explicit memory arbitration
* Unified writeback pipeline
* Dedicated Matrix and Integer ALU interfaces
* Dynamic operand readiness evaluation
* Clean separation between control logic and datapath
