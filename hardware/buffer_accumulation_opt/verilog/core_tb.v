// Created by prof. Mingu Kang @VVIP Lab in UCSD ECE department
// Please do not spread this code without permission 
`timescale 1ns/1ps

module core_tb;

// Parameters
parameter bw = 4;
parameter psum_bw = 16;
parameter len_kij = 9;
parameter len_onij = 16;
parameter col = 8;
parameter row = 8;
parameter len_nij = 36;
parameter ofifo_delay = 16;  // Delay from first execute instruction to first OFIFO read (optimized)

reg clk = 0;
reg reset = 1;

wire [34:0] inst_q;

reg [1:0]  inst_w_q = 0; 
reg [bw*row-1:0] D_xmem_q = 0;
reg CEN_xmem = 1;
reg WEN_xmem = 1;
reg [10:0] A_xmem = 0;
reg CEN_xmem_q = 1;
reg WEN_xmem_q = 1;
reg [10:0] A_xmem_q = 0;
reg CEN_pmem = 1;
reg WEN_pmem = 1;
reg [10:0] A_pmem = 0;
reg CEN_pmem_q = 1;
reg WEN_pmem_q = 1;
reg [10:0] A_pmem_q = 0;
reg ofifo_rd_q = 0;
reg l0_rd_q = 0;
reg l0_wr_q = 0;
reg execute_q = 0;
reg load_q = 0;
reg acc_q = 0;
reg acc = 0;

// Buffer accumulation control
reg first_kij = 0;
reg first_kij_q = 0;
reg relu_en = 0;
reg relu_en_q = 0;

reg [1:0]  inst_w; 
reg [bw*row-1:0] D_xmem;
reg [psum_bw*col-1:0] answer;


reg ofifo_rd;
reg l0_rd;
reg l0_wr;
reg execute;
reg load;
reg [8*30:1] stringvar;
reg [8*30:1] w_file_name;
wire ofifo_valid;
wire [col*psum_bw-1:0] sfp_out;

integer x_file, x_scan_file ; // file_handler
integer w_file, w_scan_file ; // file_handler
integer out_file, out_scan_file ; // file_handler
integer captured_data; 
integer t, i, kij;
integer error;

// === Added definitions ===
// 2D kij and onij mappings
integer ky, kx, oy, ox;
integer next_onij;

// SFU writeback signal
reg sfu_wb_q = 0;
reg sfu_wb;

// PMEM dump file writing
integer addr;                     
integer pmem_file;


// Map signals to instructions
assign inst_q[34] = relu_en_q; // Added for Part2
assign inst_q[33] = acc_q;
assign inst_q[32] = CEN_pmem_q;
assign inst_q[31] = WEN_pmem_q;
assign inst_q[30:20] = A_pmem_q;
assign inst_q[19]   = CEN_xmem_q;
assign inst_q[18]   = WEN_xmem_q;
assign inst_q[17:7] = A_xmem_q;
assign inst_q[6]   = ofifo_rd_q;
assign inst_q[5]  = first_kij_q; // Added for accumulation control
assign inst_q[4]   = sfu_wb_q;
assign inst_q[3]   = l0_rd_q;
assign inst_q[2]   = l0_wr_q;
assign inst_q[1]   = execute_q; 
assign inst_q[0]   = load_q; 


core  #(.bw(bw), .col(col), .row(row), .psum_bw(psum_bw), .len_onij(len_onij)) core_instance (
	.clk(clk), 
	.inst(inst_q),
	.ofifo_valid(ofifo_valid),
        .D_xmem(D_xmem_q), 
        .sfp_out(sfp_out), 
	.reset(reset)); 


initial begin 

  inst_w   = 0; 
  D_xmem   = 0;
  CEN_xmem = 1;
  WEN_xmem = 1;
  A_xmem   = 0;
  ofifo_rd = 0;
  sfu_wb   = 0;  // Added for sfu writeback
  l0_rd    = 0;
  l0_wr    = 0;
  execute  = 0;
  load     = 0;

  $dumpfile("core_tb.vcd");
  $dumpvars(0,core_tb);

  x_file = $fopen("sys_data/input.txt", "r");
  if (x_file == 0) $fatal(1, "CANT READ INPUT.TXT");
  // Following three lines are to remove the first three comment lines of the file
  x_scan_file = $fscanf(x_file,"%s", captured_data);
  x_scan_file = $fscanf(x_file,"%s", captured_data);
  x_scan_file = $fscanf(x_file,"%s", captured_data);

  //////// Reset /////////
  #0.5 clk = 1'b0;   
  reset = 1;
  #0.5 clk = 1'b1; 

  #0.5 clk = 1'b0;   
  reset = 0;
  #0.5 clk = 1'b1; 
  /////////////////////////

  /////// Activation data writing to memory ///////
  for (t=0; t<len_nij; t=t+1) begin  
    #0.5 clk = 1'b0;  
    
    // Read line (all ic for current pixel)
    x_scan_file = $fscanf(x_file,"%32b", D_xmem); 
    
    WEN_xmem = 0; CEN_xmem = 0; 
    if (t>0) A_xmem = A_xmem + 1;

    #0.5 clk = 1'b1;   
  end

  #0.5 clk = 1'b0;  WEN_xmem = 1;  CEN_xmem = 1; A_xmem = 0;
  #0.5 clk = 1'b1; 

  $fclose(x_file);
  /////////////////////////////////////////////////

  // One file with all weights
  w_file = $fopen("sys_data/weight.txt", "r");
  if (w_file == 0) $fatal(1, "CANT READ WEIGHT.TXT");
  w_scan_file = $fscanf(w_file,"%s", captured_data);
  w_scan_file = $fscanf(w_file,"%s", captured_data);
  w_scan_file = $fscanf(w_file,"%s", captured_data);


  for (kij=0; kij<len_kij; kij=kij+1) begin  // kij loop

    // Reset MAC array and FIFOs before new kernel
    #0.5 clk = 1'b0;   
    reset = 1;
    #0.5 clk = 1'b1; 

    #0.5 clk = 1'b0;   
    reset = 0;
    #0.5 clk = 1'b1; 

    // Get 2D location of current kij
    ky = kij / 3;
    kx = kij % 3;

    /////// Kernel data writing to memory ///////

    A_xmem = 1024; // Start writing weights at address 1024

    for (t=0; t<col; t=t+1) begin  
      #0.5 clk = 1'b0;  
      
      // Read line (all ic for current kernel position)
      w_scan_file = $fscanf(w_file,"%32b", D_xmem); 

      WEN_xmem = 0; CEN_xmem = 0; 
      if (t>0) A_xmem = A_xmem + 1; 

      #0.5 clk = 1'b1;  
    end

    #0.5 clk = 1'b0;  
    WEN_xmem = 1;  CEN_xmem = 1; A_xmem = 0;
    #0.5 clk = 1'b1; 
    /////////////////////////////////////


    /////// Pipelined kernel loading to L0 and PEs ///////
    // Prime XMEM read (xmem_q = XMEM[1024] for first L0 write)
    #0.5 clk = 1'b0;
    CEN_xmem = 0;
    WEN_xmem = 1;
    A_xmem = 1024;
    l0_wr = 0;
    l0_rd = 0;
    load = 0;
    #0.5 clk = 1'b1;

    // Overlap weight writes to L0 with weight loading to PEs
    for (t=0; t<col; t=t+1) begin

      #0.5 clk = 1'b0;
      CEN_xmem = 0; WEN_xmem = 1;

      // Account for XMEM read latency and clamp last weight address
      A_xmem = 1024 + ((t<col-1) ? t+1 : col-1);

      // Concurrent L0 writes and reads
      l0_wr = 1;
      l0_rd = 1;
      load = 1;

      #0.5 clk = 1'b1;
    end

    // End kernel loading
    #0.5 clk = 1'b0;
    CEN_xmem = 1;
    l0_wr = 0;
    l0_rd = 0;
    load = 0;
    #0.5 clk = 1'b1;
    /////////////////////////////////////

    /////// Pipelined activation loading, MAC execution, OFIFO read, buffer accumulation ///////

    // Prime XMEM read for first L0 write
    #0.5 clk = 1'b0;
    CEN_xmem = 0;
    WEN_xmem = 1;
    A_xmem = ky*6 + kx;
    l0_wr = 0;
    l0_rd = 0;
    execute = 0;
    ofifo_rd = 0;
    CEN_pmem = 1;
    WEN_pmem = 1;
    #0.5 clk = 1'b1;

    for (t=0; t<len_onij+ofifo_delay+1; t=t+1) begin

      #0.5 clk = 1'b0;

      // Activation loading and MAC execution
      if (t<len_onij) begin

        CEN_xmem = 0; WEN_xmem = 1;

        // Account for XMEM read latency
        next_onij = (t<len_onij-1) ? t+1 : len_onij-1;

        oy = next_onij / 4;
        ox = next_onij % 4;

        A_xmem = (oy+ky)*6 + (ox+kx);

        l0_wr = 1;
        l0_rd = 1;
        execute = 1;

      end else begin

        CEN_xmem = 1;
        l0_wr = 0;
        l0_rd = 0;
        execute = 0;

      end

      // Read OFIFO after accounting for MAC array propagation latency
      if (t>=ofifo_delay && t<ofifo_delay+len_onij)
        ofifo_rd = 1;
      else
        ofifo_rd = 0;

      // Buffer accumulation (account for 1 cycle OFIFO read latency)
      if (t>=ofifo_delay+1 && t<ofifo_delay+len_onij+1) begin

        // Select running sum for current output pixel
        A_pmem = t-ofifo_delay-1;

        // Initialize on first kij, accumulate on subsequent kij
        first_kij = (kij == 0);
        acc = 1;

      end else begin

        first_kij = 0;
        acc = 0;

      end

      // Disable intermediate PMEM writes
      CEN_pmem = 1;
      WEN_pmem = 1;

      #0.5 clk = 1'b1;
    end

    // End execution and accumulation
    #0.5 clk = 1'b0;
    CEN_xmem = 1;
    l0_wr = 0;
    l0_rd = 0;
    execute = 0;
    ofifo_rd = 0;
    acc = 0;
    first_kij = 0;
    CEN_pmem = 1;
    WEN_pmem = 1;
    #0.5 clk = 1'b1;

    /////////////////////////////////////
  end  // end of kij loop

  // Close weight file
  $fclose(w_file);

  ////////// ReLU and PMEM writeback /////////

  // Write accumulated output pixels to PMEM
  for (i=0; i<len_onij; i=i+1) begin

    #0.5 clk = 1'b0;

    // Select accumulated output pixel
    A_pmem = 1024+i;

    // Enable ReLU and disable accumulation
    relu_en = 1;
    acc = 0;
    first_kij = 0;

    // Write SFU output back to PMEM
    sfu_wb = 1;
    CEN_pmem = 0;
    WEN_pmem = 0;

    #0.5 clk = 1'b1;

  end

  // Allow final PMEM write to complete
  #0.5 clk = 1'b0;
  sfu_wb = 0;
  relu_en = 0;
  CEN_pmem = 1;
  WEN_pmem = 1;
  #0.5 clk = 1'b1;

  ///////////////////////////////////////////

  // ===== Dump PMEM contents to file for PMEM verification =====
  #0.1; // Wait for final PMEM write to complete
  pmem_file = $fopen("pmem_dump.txt", "w");
  for (addr=1024; addr<1024+len_onij; addr=addr+1) begin
    $fdisplay(pmem_file, "%032h", core_instance.pmem_inst.memory[addr]);
  end
  $fclose(pmem_file);

  ////////// Verify ReLU writeback in PMEM[1024..1039] //////////
  // Each SFU output was written back to PMEM at 1024+i. Read those addresses back
  // through the SRAM's read port and compare with psum.txt again, so the stored
  // values are checked too
  out_file = $fopen("sys_data/psum.txt", "r");
  if (out_file == 0) $fatal(1, "CANT READ PSUM.TXT");
  out_scan_file = $fscanf(out_file,"%s", captured_data);
  out_scan_file = $fscanf(out_file,"%s", captured_data);
  out_scan_file = $fscanf(out_file,"%s", captured_data);

  error = 0;

  $display("############ Verification of PMEM writeback #############");
  for (i=0; i<len_onij+1; i=i+1) begin
    #0.5 clk = 1'b0;

    if (i < len_onij) begin
      CEN_pmem = 0; WEN_pmem = 1; 
      A_pmem = 1024 + i;
    end else begin
      CEN_pmem = 1; WEN_pmem = 1;
    end

    #0.5 clk = 1'b1;
    #0.1;

    if (i > 0) begin
      out_scan_file = $fscanf(out_file,"%128b", answer);
      if (core_instance.pmem_q === answer)
        $display("%2d-th PMEM writeback matched! :D", i-1);
      else begin
        $display("%2d-th PMEM writeback ERROR!!", i-1);
        $display("pmem_q: %h", core_instance.pmem_q);
        $display("answer: %h", answer);
        error = error + 1;
      end
    end
  end

  if (error == 0) begin
  	$display("############ No error detected ##############"); 
  	$display("########### Project Completed !! ############"); 
  end
  else $display("####### RIP %0d errors #######", error);

  $fclose(out_file);
  //////////////////////////////////

  for (t=0; t<10; t=t+1) begin  
    #0.5 clk = 1'b0;  
    #0.5 clk = 1'b1;  
  end

  #10 $finish;

end

always @ (posedge clk) begin
   first_kij_q <= first_kij;
   relu_en_q   <= relu_en;
   inst_w_q   <= inst_w; 
   D_xmem_q   <= D_xmem;
   CEN_xmem_q <= CEN_xmem;
   WEN_xmem_q <= WEN_xmem;
   A_pmem_q   <= A_pmem;
   CEN_pmem_q <= CEN_pmem;
   WEN_pmem_q <= WEN_pmem;
   A_xmem_q   <= A_xmem;
   ofifo_rd_q <= ofifo_rd;
   acc_q      <= acc;
   sfu_wb_q   <= sfu_wb;
   l0_rd_q    <= l0_rd;
   l0_wr_q    <= l0_wr ;
   execute_q  <= execute;
   load_q     <= load;
   
end

endmodule