// jpeg_rom.sv - on-chip ROM holding a JPEG file (initialised from a $readmemh hex file,
// which Quartus turns into M4K initialisation data).  Streams the bytes out with a
// valid/ready handshake; `restart` rewinds to byte 0.
module jpeg_rom #(
  parameter int    ADDR_BITS = 10,                 // ROM size = 2**ADDR_BITS bytes
  parameter int    LENGTH    = 719,                // number of valid bytes
  parameter        HEX_FILE  = "jpeg_rom.hex"
) (
  input  logic       clk,
  input  logic       rst,
  input  logic       restart,
  output logic       out_valid,
  output logic [7:0] out_data,
  input  logic       out_ready,
  output logic       done                          // all bytes delivered
);
  logic [7:0] rom [0:(1<<ADDR_BITS)-1];
  initial $readmemh(HEX_FILE, rom);

  logic [ADDR_BITS:0] addr;                        // next byte to fetch
  logic               have;                        // out_data holds rom[addr-1]
  logic               advance;

  assign out_valid = have;
  assign done      = ~have && (addr == LENGTH[ADDR_BITS:0]);
  assign advance   = !have || out_ready;           // output register free (or being consumed)

  // synchronous ROM read with clock enable and no reset: inferred into an M4K block
  always_ff @(posedge clk) begin
    if (advance) out_data <= rom[addr[ADDR_BITS-1:0]];
  end

  always_ff @(posedge clk) begin
    if (rst || restart) begin
      addr <= '0; have <= 1'b0;
    end else if (advance) begin
      if (addr < LENGTH[ADDR_BITS:0]) begin
        addr <= addr + 1'b1;
        have <= 1'b1;
      end else have <= 1'b0;
    end
  end
endmodule
