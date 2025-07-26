module apb_s (
    input        pclk,       // APB clock
    input        presetn,    // Active-low reset
    input [31:0] paddr,      // Address from master
    input        psel,       // Select signal from master
    input        penable,    // Enable signal to distinguish Setup/Access phase
    input  [7:0] pwdata,     // Write data from master
    input        pwrite,     // Write enable

    output reg  [7:0] prdata,   // Read data to master
    output reg        pready,   // Ready signal to indicate operation complete
    output            pslverr   // Slave error output
);

  // FSM state definitions
  localparam [1:0] idle = 0, write = 1, read = 2;

  // Internal 16-byte memory (8-bit wide x 16 locations)
  reg [7:0] mem[16];

  // Current and next state registers
  reg [1:0] state, nstate;

  // Error detection signals
  bit addr_err, addv_err, data_err;

  //===========================================================
  // Sequential logic for state transition
  //===========================================================
  always @(posedge pclk, negedge presetn) begin
    if (!presetn)
      state <= idle;       // Reset state
    else
      state <= nstate;     // Move to next state
  end

  //===========================================================
  // Combinational logic for FSM next-state and output control
  //===========================================================
  always @(*) begin
    case (state)
      idle: begin
        prdata = 8'h00;     // Default read data
        pready = 1'b0;      // Not ready yet

        // Transition to write or read based on psel and pwrite
        if (psel && pwrite)
          nstate = write;
        else if (psel && !pwrite)
          nstate = read;
        else
          nstate = idle;
      end

      write: begin
        if (psel && penable) begin  // Access phase
          if (!addr_err && !addv_err && !data_err) begin
            pready = 1'b1;
            mem[paddr] = pwdata;    // Perform memory write
            nstate = idle;
          end else begin
            pready = 1'b1;          // Still signal ready (error was signaled separately)
            nstate = idle;
          end
        end
      end

      read: begin
        if (psel && penable) begin  // Access phase
          if (!addr_err && !addv_err && !data_err) begin
            pready = 1'b1;
            prdata = mem[paddr];    // Read from memory
            nstate = idle;
          end else begin
            pready = 1'b1;
            prdata = 8'h00;         // Return default value on error
            nstate = idle;
          end
        end
      end

      default: begin
        nstate = idle;
        prdata = 8'h00;
        pready = 1'b0;
      end
    endcase
  end

  //===========================================================
  // Address validity check: paddr must be ≥ 0
  //===========================================================
  reg av_t = 0;
  always @(*) begin
    if (paddr >= 0)
      av_t = 1'b0;      // Valid
    else
      av_t = 1'b1;      // Invalid address
  end

  //===========================================================
  // Data validity check: pwdata must be ≥ 0
  //===========================================================
  reg dv_t = 0;
  always @(*) begin
    if (pwdata >= 0)
      dv_t = 1'b0;      // Valid
    else
      dv_t = 1'b1;      // Invalid data
  end

  //===========================================================
  // Error Detection Logic
  //===========================================================

  // Address out-of-range (should be 0–15)
  assign addr_err = ((nstate == write || nstate == read) && (paddr > 15)) ? 1'b1 : 1'b0;

  // Invalid address value (negative — though `paddr` is unsigned so this is redundant)
  assign addv_err = (nstate == write || nstate == read) ? av_t : 1'b0;

  // Invalid data value (negative — again, redundant for unsigned `pwdata`)
  assign data_err = (nstate == write || nstate == read) ? dv_t : 1'b0;

  // Combine all error flags for slave error output
  assign pslverr = (psel && penable) ? (addv_err || addr_err || data_err) : 1'b0;

endmodule
