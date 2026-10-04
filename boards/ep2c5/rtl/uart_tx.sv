// uart_tx.sv - minimal 8N1 UART transmitter with a valid/ready byte interface.
// Plain shift register: start bit, 8 data bits LSB first, stop bit.
module uart_tx #(
  parameter int CLK_DIV = 434            // clock cycles per bit (50 MHz / 115200)
) (
  input  logic       clk,
  input  logic       rst,
  input  logic       in_valid,
  input  logic [7:0] in_data,
  output logic       in_ready,
  output logic       tx
);
  localparam int DW = (CLK_DIV > 2) ? $clog2(CLK_DIV) : 1;
  localparam logic [DW-1:0] DIV_LAST = CLK_DIV - 1;
  logic [DW-1:0] div;
  logic [3:0]    nbits;                  // bit periods left: 10 = start ... 1 = stop, 0 = idle
  logic [8:0]    sh;                     // {stop, data[7:0]}; sh[0] goes out next

  assign in_ready = (nbits == 4'd0);

  always_ff @(posedge clk) begin
    if (rst) begin
      tx <= 1'b1; nbits <= '0; div <= '0; sh <= '1;
    end else if (nbits == 4'd0) begin
      if (in_valid) begin tx <= 1'b0; sh <= {1'b1, in_data}; nbits <= 4'd10; div <= '0; end
    end else if (div == DIV_LAST) begin
      div <= '0; nbits <= nbits - 4'd1;
      if (nbits != 4'd1) begin tx <= sh[0]; sh <= {1'b1, sh[8:1]}; end   // next data / stop bit
      else tx <= 1'b1;                                                  // back to idle
    end else div <= div + 1'b1;
  end
endmodule
