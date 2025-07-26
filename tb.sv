//=====================================================
// TRANSACTION CLASS
// Describes the data structure for a single APB transfer
//=====================================================
class transaction;

  rand bit [31:0] paddr;     // Address (0 to 15)
  rand bit [7:0]  pwdata;    // Write data
  rand bit        psel;      // Select signal
  rand bit        penable;   // Enable signal
  randc bit       pwrite;    // Write/Read toggle (random cyclic)
       bit [7:0]  prdata;    // Read data received
       bit        pready;    // Ready response
       bit        pslverr;   // Error response

  // Constraint: paddr must be within 0-15
  constraint addr_c {
    paddr >= 0; paddr <= 15;
  }

  // Constraint: pwdata must be within valid range
  constraint data_c {
    pwdata >= 0; pwdata <= 255;
  }

  // Display method for debug
  function void display(input string tag);
    $display("[%0s] :  paddr:%0d  pwdata:%0d pwrite:%0b  prdata:%0d pslverr:%0b @ %0t",
             tag, paddr, pwdata, pwrite, prdata, pslverr, $time);
  endfunction

endclass

//=====================================================
// GENERATOR CLASS
// Generates randomized transactions and sends to driver
//=====================================================
class generator;

  transaction tr;
  mailbox #(transaction) mbx;
  int count = 0;                 // Number of transactions to generate

  event nextdrv;                // Event triggered after driver processes
  event nextsco;                // Event triggered after scoreboard checks
  event done;                   // Completion of all generations

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
    tr = new();
  endfunction

  task run();
    repeat(count) begin
      assert(tr.randomize()) else $error("Randomization failed");
      mbx.put(tr);
      tr.display("GEN");
      @(nextdrv);   // Wait for driver to complete
      @(nextsco);   // Wait for scoreboard to verify
    end
    ->done;         // Notify environment that generation is done
  endtask

endclass

//=====================================================
// DRIVER CLASS
// Drives transactions to the DUT through interface
//=====================================================
class driver;

  virtual abp_if vif;
  mailbox #(transaction) mbx;
  transaction datac;
  event nextdrv;

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
  endfunction

  // Reset sequence
  task reset();
    vif.presetn <= 1'b0;
    vif.psel    <= 1'b0;
    vif.penable <= 1'b0;
    vif.pwdata  <= 0;
    vif.paddr   <= 0;
    vif.pwrite  <= 1'b0;
    repeat(5) @(posedge vif.pclk);
    vif.presetn <= 1'b1;
    $display("[DRV] : RESET DONE");
    $display("----------------------------------------------------------------------------");
  endtask

  // Driver main loop
  task run();
    forever begin
      mbx.get(datac);          // Get transaction
      @(posedge vif.pclk);

      if (datac.pwrite == 1) begin // Write transaction
        vif.psel    <= 1'b1;
        vif.penable <= 1'b0;
        vif.pwdata  <= datac.pwdata;
        vif.paddr   <= datac.paddr;
        vif.pwrite  <= 1'b1;
        @(posedge vif.pclk);
        vif.penable <= 1'b1;
        @(posedge vif.pclk);
        vif.psel    <= 1'b0;
        vif.penable <= 1'b0;
        vif.pwrite  <= 1'b0;
        datac.display("DRV");
        ->nextdrv;
      end else begin // Read transaction
        vif.psel    <= 1'b1;
        vif.penable <= 1'b0;
        vif.pwdata  <= 0;
        vif.paddr   <= datac.paddr;
        vif.pwrite  <= 1'b0;
        @(posedge vif.pclk);
        vif.penable <= 1'b1;
        @(posedge vif.pclk);
        vif.psel    <= 1'b0;
        vif.penable <= 1'b0;
        vif.pwrite  <= 1'b0;
        datac.display("DRV");
        ->nextdrv;
      end
    end
  endtask

endclass

//=====================================================
// MONITOR CLASS
// Observes bus signals and reconstructs transactions
//=====================================================
class monitor;

  virtual abp_if vif;
  mailbox #(transaction) mbx;
  transaction tr;

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
  endfunction

  task run();
    tr = new();
    forever begin
      @(posedge vif.pclk);
      if (vif.pready) begin
        tr.pwdata  = vif.pwdata;
        tr.paddr   = vif.paddr;
        tr.pwrite  = vif.pwrite;
        tr.prdata  = vif.prdata;
        tr.pslverr = vif.pslverr;
        @(posedge vif.pclk); // Capture after valid output
        tr.display("MON");
        mbx.put(tr);
      end
    end
  endtask

endclass

//=====================================================
// SCOREBOARD CLASS
// Validates DUT behavior against expected behavior
//=====================================================
class scoreboard;

  mailbox #(transaction) mbx;
  transaction tr;
  event nextsco;

  bit [7:0] pwdata[16] = '{default:0}; // Reference memory
  bit [7:0] rdata;
  int err = 0;                         // Error counter

  function new(mailbox #(transaction) mbx);
    this.mbx = mbx;
  endfunction

  task run();
    forever begin
      mbx.get(tr);
      tr.display("SCO");

      if (tr.pwrite && !tr.pslverr) begin  // Valid write
        pwdata[tr.paddr] = tr.pwdata;
        $display("[SCO] : DATA STORED DATA : %0d ADDR: %0d", tr.pwdata, tr.paddr);
      end else if (!tr.pwrite && !tr.pslverr) begin // Valid read
        rdata = pwdata[tr.paddr];
        if (tr.prdata == rdata)
          $display("[SCO] : Data Matched");
        else begin
          err++;
          $display("[SCO] : Data Mismatched");
        end
      end else if (tr.pslverr) begin
        $display("[SCO] : SLV ERROR DETECTED");
      end

      $display("---------------------------------------------------------------------------------------------------");
      ->nextsco;
    end
  endtask

endclass

//=====================================================
// ENVIRONMENT CLASS
// Connects and runs all components together
//=====================================================
class environment;

  generator  gen;
  driver     drv;
  monitor    mon;
  scoreboard sco;

  event nextgd;    // gen → drv
  event nextgs;    // gen → sco

  mailbox #(transaction) gdmbx; // generator → driver
  mailbox #(transaction) msmbx; // monitor → scoreboard

  virtual abp_if vif;

  function new(virtual abp_if vif);
    gdmbx = new();
    gen   = new(gdmbx);
    drv   = new(gdmbx);

    msmbx = new();
    mon   = new(msmbx);
    sco   = new(msmbx);

    this.vif    = vif;
    drv.vif     = this.vif;
    mon.vif     = this.vif;

    gen.nextsco = nextgs;
    sco.nextsco = nextgs;

    gen.nextdrv = nextgd;
    drv.nextdrv = nextgd;
  endfunction

  // Reset
  task pre_test();
    drv.reset();
  endtask

  // Parallel execution of all components
  task test();
    fork
      gen.run();
      drv.run();
      mon.run();
      sco.run();
    join_any
  endtask

  // Final report
  task post_test();
    wait(gen.done.triggered);
    $display("----Total number of Mismatch : %0d------", sco.err);
    $finish();
  endtask

  // Run the entire environment
  task run();
    pre_test();
    test();
    post_test();
  endtask

endclass

//=====================================================
// TOP MODULE: Testbench
//=====================================================
module tb;

  abp_if vif(); // Interface instance

  // DUT instantiation
  apb_s dut (
    vif.pclk,
    vif.presetn,
    vif.paddr,
    vif.psel,
    vif.penable,
    vif.pwdata,
    vif.pwrite,
    vif.prdata,
    vif.pready,
    vif.pslverr
  );

  // Clock generation
  initial begin
    vif.pclk <= 0;
  end
  always #10 vif.pclk <= ~vif.pclk;

  environment env;

  // Testbench main execution
  initial begin
    env = new(vif);
    env.gen.count = 20;  // Number of transactions
    env.run();
  end

  // Dump VCD for waveform viewing
  initial begin
    $dumpfile("dump.vcd");
    $dumpvars;
  end

endmodule
