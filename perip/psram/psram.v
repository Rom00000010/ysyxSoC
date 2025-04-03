import "DPI-C" function void psram_read(int addr, output int data);
module psram(
  input sck,
  input ce_n,
  inout [3:0] dio
);

  assign dio =  (count < 5'd21)  ? 4'bz :
                (count == 5'd21) ? data_reg[31:28] :
                (count == 5'd22) ? data_reg[27:24] :
                (count == 5'd23) ? data_reg[23:20] :
                (count == 5'd24) ? data_reg[19:16] :
                (count == 5'd25) ? data_reg[15:12] :
                (count == 5'd26) ? data_reg[11:8] :
                (count == 5'd27) ? data_reg[7:4] :
                (count == 5'd28) ? data_reg[3:0] : 4'bz;

  localparam  IDLE = 4'b0000,
              CMD = 4'b0001,
              READ_ADDR = 4'b0010,
              READ_EXEC = 4'b0011,
              READ_RET  = 4'b0100,
              WRITE_ADDR= 4'b0101,
              WRITE_DATA= 4'b0110,
              WRITE_RET = 4'b0111;

  reg [3:0] state, next_state;

  always @(posedge sck) begin
    if(ce_n) begin
      state <= IDLE;
    end else begin
      state <= next_state;
    end
  end

  reg [4:0] count;
  reg [7:0] cmd_reg;
  reg [23:0] addr_reg;
  reg [31:0] data_reg;
  reg [31:0] data;

  always @(*) begin
    if(!ce_n && state == READ_EXEC) begin
      psram_read({8'd0,addr_reg}, data);
    end
    else begin
      data = 32'd0;
    end
  end

  always @(*) begin 
    next_state = state;
    case(state)
      IDLE: begin
          next_state = CMD;
      end

      CMD: begin 
        if(count == 5'd8 && cmd_reg == 8'hEB) begin
          next_state = READ_ADDR;
        end else if(count == 5'd8 && cmd_reg == 8'h38) begin
          next_state = WRITE_ADDR;
        end
      end

      READ_ADDR: begin
        if(count == 5'd14) begin
          next_state = READ_EXEC;
        end
      end

      READ_EXEC: begin
        if(count == 5'd20) begin
          next_state = READ_RET;
        end
      end

      READ_RET: begin
        if(count == 5'd28) begin
          next_state = IDLE;
        end
      end

      default: begin
        next_state = IDLE;
      end
    endcase
  end

  always @(posedge sck) begin
    if(ce_n) begin
      count <= 5'd0;
      cmd_reg <= 8'd0;
      addr_reg <= 24'd0;
      data_reg <= 32'd0;
    end else begin
      case(state)
        IDLE: begin 
          cmd_reg <= {cmd_reg[6:0], dio[0]};
          count <= count + 5'd1;
        end

        CMD: begin
          if(count < 5'd8) begin  
            cmd_reg <= {cmd_reg[6:0], dio[0]};
          end else if(count == 5'd8) begin
            addr_reg <= {addr_reg[19:0], dio[3:0]};
          end
          count <= count + 5'd1;
        end

        READ_ADDR: begin
          if(count < 5'd14) begin
            addr_reg <= {addr_reg[19:0], dio[3:0]};
          end 
          count <= count + 5'd1;
        end

        READ_EXEC: begin
          count <= count + 5'd1;
          if(count == 5'd20) begin
            data_reg <= data;
          end
        end

        READ_RET: begin
          count <= count + 5'd1;
          if(count == 5'd28) begin
            count <= 5'd0;
            cmd_reg <= 8'd0;
            addr_reg <= 24'd0;
            data_reg <= 32'd0;
          end
        end

        default: begin
          count <= 5'd0;
          cmd_reg <= 8'd0;
        end
      endcase
    end
  end
endmodule
