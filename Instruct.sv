// Mark W. welker
// Instruction memory.
// holds the instructions that the processor will execute.
//
// the address lines are generic and each module must handle their own decode.
// The address bus is large enough that each module can contain a local address decode. This will save on multiple enables.
// bit 11-0 are for addressing inside each unit.
// nWrite = 0 means databus is being written into the part on the falling edge of write
// nRead = 0 means it is expected to drive the databus while this signal is low and the address is correct until the nRead goes high independent of address bus.

`timescale 1 ps / 1 ps

module InstructionMemory(Clk,DataBus, address, nRead,nReset);
// NOTE the lack of datain and write. This is because this is a ROM model

`include "params.vh"

input logic nRead, nReset, Clk;
input logic [15:0] address;

inout logic [255:0] DataBus; // shared 256-bit system bus

logic [31:0] InstructMemory[15]; // physical storage
logic        ItsMe;
logic [255:0] InstToOutput;

always_ff @(negedge Clk or negedge nReset)
begin
  if (!nReset) begin
    InstToOutput <= '0;
    ItsMe        <= 1'b0;
  end
  else begin
    if(address[15:12] == InstrMemEn) begin
      ItsMe <= 1'b1;
      if(~nRead) begin
        InstToOutput <= {224'b0, InstructMemory[address[11:0]]};
      end
    end
    else begin
      ItsMe <= 1'b0;
    end
  end
end

always @(negedge nReset)
begin
  InstructMemory[0]  = Instruct1;
  InstructMemory[1]  = Instruct2;
  InstructMemory[2]  = Instruct3;
  InstructMemory[3]  = Instruct4;
  InstructMemory[4]  = Instruct5;
  InstructMemory[5]  = Instruct6;
  InstructMemory[6]  = Instruct7;
  InstructMemory[7]  = Instruct8;
  InstructMemory[8]  = Instruct9;
  InstructMemory[9]  = Instruct10;
  InstructMemory[10] = Instruct11;
  InstructMemory[11] = Instruct12;
  InstructMemory[12] = Instruct13;
end

assign DataBus = (ItsMe && ~nRead) ? InstToOutput : 256'bz;

endmodule