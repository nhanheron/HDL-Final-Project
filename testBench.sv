// Mark W Welker
// Generic Test bench It drives only clock and reset.

`timescale 1 ps / 1 ps

module TestMatrix  (Clk,nReset);

	output logic Clk,nReset; // we are driving these signals from here. 

	initial begin
		Clk = 0;
		nReset = 1;
	#5 nReset = 0;
	#5 nReset = 1;
	
	end
	
	always  #5 Clk = ~Clk;

	
	endmodule
