import "DPI-C" function void psram_read(int addr, output int data);
import "DPI-C" function void psram_write(int addr, int data, int wcount);
module psram(
  input sck,
  input ce_n,
  inout [3:0] dio
);

  assign dio =  (count < 5'd21)  ? 4'bz :
                (state == READ_RET && count == 5'd21) ? data_reg[7:4] :
                (state == READ_RET && count == 5'd22) ? data_reg[3:0] :
                (state == READ_RET && count == 5'd23) ? data_reg[15:12] :
                (state == READ_RET && count == 5'd24) ? data_reg[11:8] :
                (state == READ_RET && count == 5'd25) ? data_reg[23:20] :
                (state == READ_RET && count == 5'd26) ? data_reg[19:16] :
                (state == READ_RET && count == 5'd27) ? data_reg[31:28] :
                (state == READ_RET && count == 5'd28) ? data_reg[27:24] : 4'bz;

  localparam  IDLE = 4'b0000,
              CMD = 4'b0001,
              READ_ADDR = 4'b0010,
              READ_EXEC = 4'b0011,
              READ_RET  = 4'b0100,
              WRITE_ADDR= 4'b0101,
              WRITE_DATA= 4'b0110;

  reg [3:0] state, next_state;

  always @(posedge sck or posedge ce_n) begin
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
  reg [31:0] wdata_reg;
  reg [3:0] wcount;

  always @(*) begin
    if(!ce_n && state == READ_EXEC) begin
      psram_read({8'd0,addr_reg}, data);
    end else if (ce_n && (wcount > 4'd0)) begin
      psram_write({8'd0,addr_reg}, wdata_reg, {28'd0, wcount>>1});
      data = 32'd0;
    end else begin
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

      WRITE_ADDR: begin
        if(count == 5'd14) begin
          next_state = WRITE_DATA;
        end
      end

      READ_EXEC: begin
        if(count == 5'd20) begin
          next_state = READ_RET;
        end
      end

      default: begin
        next_state = state;
      end
    endcase
  end

  always @(posedge sck or posedge ce_n) begin
    if(ce_n) begin
      cmd_reg <= 8'd0;
      count <= 5'd0;
    end else begin
      case(state)
        IDLE: begin 
          cmd_reg <= {cmd_reg[6:0], dio[0]};
          count <= 5'd1;
          wdata_reg <= 32'd0;
          wcount <= 4'd0;
          addr_reg <= 24'd0;
          data_reg <= 32'd0;
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

        WRITE_ADDR: begin
          if(count < 5'd14) begin
            addr_reg <= {addr_reg[19:0], dio[3:0]};
          end else if(count == 5'd14) begin
            wdata_reg <= {wdata_reg[27:0], dio[3:0]};
            wcount <= wcount + 4'd1;
          end
          count <= count + 5'd1;
        end
        
        READ_EXEC: begin
          count <= count + 5'd1;
          if(count == 5'd20) begin
            data_reg <= data;
          end
        end

        WRITE_DATA: begin
          if(count < 5'd22) begin
            wdata_reg <= {wdata_reg[27:0], dio[3:0]};
            wcount <= wcount + 4'd1;
          end
          count <= count + 5'd1;
        end

        READ_RET: begin
          count <= count + 5'd1;
        end

        default: begin
          count <= 5'd0;
          cmd_reg <= 8'd0;
        end
      endcase
    end
  end
endmodule
