// Mark W. Welker
// project
// Spring 2023
//
//

`timescale 1 ps / 1 ps

module MainMemory(Clk,Dataout, address, nRead,nWrite, nReset);

`include "params.vh"

input logic nRead,nWrite, nReset, Clk;
input logic [15:0] address;

inout logic [255:0] Dataout; // to the CPU 

  logic [255:0]MainMemory[14]; // this is the physical memory
  logic ItsMe; // the address bus is talkig to this module. used to enable tristate buffers.
  logic [255:0] MemToOutput; // this is a temporary data register to be set to go to the output. 
  localparam int MEM_ADDR_MSB = 11;
  localparam int MEM_ADDR_LSB = 7; // 256-bit alignment removes lower 7 bits
  logic [MEM_ADDR_MSB-MEM_ADDR_LSB:0] mem_index;
  assign mem_index = address[MEM_ADDR_MSB:MEM_ADDR_LSB];

always_ff @(negedge Clk or negedge nReset)
begin
	if (~nReset) begin
	MainMemory[0] <= 256'h0009_000c_0008_000d_0008_0003_000f_0009_000B_0013_0010_0007_000c_0005_000e_0006;
	MainMemory[1] <= 256'h0007_0005_0007_0009_000c_0003_000e_0002_0010_0009_000f_0008_000c_0007_0004_0006;
	MainMemory[2] <= 256'h0;
	MainMemory[3] <= 256'h0;
	MainMemory[4] <= 256'h0;
	MainMemory[5] <= 256'h0;
	MainMemory[6] <= 256'h0;
	MainMemory[7] <= 256'h0;
	MainMemory[8] <= 256'h0;
	MainMemory[9] <= 256'h0;
	MainMemory[10] <= 256'h4;
	MainMemory[11] <= 256'he;
	MainMemory[12] <= 256'h0;
	MainMemory[13] <= 256'h0;
	
	
      MemToOutput <= 0;
      ItsMe <= 0;
	end

  else begin
    if(address[15:12] == MainMemEn) // talking to MainMemory
		begin
			if (~nRead)begin
			  ItsMe <= 1; // Only Drive Bus on read
				MemToOutput <= MainMemory[mem_index]; // data will remain on dataout until it is changed.
			end else begin
			  ItsMe <= 0; // don't drive bus when not reading
			end
			if(~nWrite && mem_index < 14)begin
		    MainMemory[mem_index] <= Dataout;
			end
		end
    else begin
      ItsMe <= 0;
    end
  end
end 	

assign Dataout = ItsMe ? MemToOutput : 256'bz;
endmodule