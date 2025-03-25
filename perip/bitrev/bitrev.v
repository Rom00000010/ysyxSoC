module bitrev (
  input  wire sck,   
  input  wire ss, 
  input  wire mosi,
  output wire miso 
);
  wire reset = ss;

  reg [7:0] shift_reg; 
  reg [3:0] bit_count; 

  assign miso = ss ? 1'b1 : 
                (bit_count < 8) ? 1'b1 : 
                shift_reg[0];

  always @(posedge sck or posedge reset) begin
    if (reset) begin
      bit_count <= 4'd0;
      shift_reg <= 8'd0;
    end else begin
      if (bit_count < 8) begin
        shift_reg <= {shift_reg[6:0], mosi};
      end else begin
        shift_reg <= {1'b0, shift_reg[7:1]};
      end

      if (bit_count < 15)
        bit_count <= bit_count + 1'b1;
    end
  end

endmodule
