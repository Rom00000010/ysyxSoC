// define this macro to enable fast behavior simulation
// for flash by skipping SPI transfers
//`define FAST_FLASH

module spi_top_apb #(
        parameter flash_addr_start = 32'h30000000,
        parameter flash_addr_end   = 32'h3fffffff,
        parameter spi_ss_num       = 8
    ) (
        input         clock,
        input         reset,
        input  [31:0] in_paddr,
        input         in_psel,
        input         in_penable,
        input  [2:0]  in_pprot,
        input         in_pwrite,
        input  [31:0] in_pwdata,
        input  [3:0]  in_pstrb,
        output        in_pready,
        output [31:0] in_prdata,
        output        in_pslverr,

        output                  spi_sck,
        output [spi_ss_num-1:0] spi_ss,
        output                  spi_mosi,
        input                   spi_miso,
        output                  spi_irq_out
    );

`ifdef FAST_FLASH

    wire [31:0] data;
    parameter invalid_cmd = 8'h0;
    flash_cmd flash_cmd_i(
                  .clock(clock),
                  .valid(in_psel && !in_penable),
                  .cmd(in_pwrite ? invalid_cmd : 8'h03),
                  .addr({8'b0, in_paddr[23:2], 2'b0}),
                  .data(data)
              );
    assign spi_sck    = 1'b0;
    assign spi_ss     = 8'b0;
    assign spi_mosi   = 1'b1;
    assign spi_irq_out= 1'b0;
    assign in_pslverr = 1'b0;
    assign in_pready  = in_penable && in_psel && !in_pwrite;
    assign in_prdata  = data[31:0];

`else

    // Mode detection signals
    wire is_xip_access = (in_paddr >= flash_addr_start) && (in_paddr <= flash_addr_end);
    wire is_spi_access = in_psel && !is_xip_access;

    // XIP FSM state definitions
    localparam [3:0] XIP_IDLE  = 4'd0,
               XIP_SETUP_DIV   = 4'd1,
               XIP_SETUP_SS    = 4'd2,
               XIP_SETUP_CMD   = 4'd3,
               XIP_SETUP_DUMMY = 4'd4,
               XIP_CONF_CTRL   = 4'd5,
               XIP_START       = 4'd6,
               XIP_WAIT        = 4'd7,
               XIP_READ_DATA   = 4'd8,
               XIP_RETURN      = 4'd9;

    reg [31:0] ctrl_config;     // Store control register configuration
    always @* begin
        ctrl_config = 32'h0;
        ctrl_config[13] = 1'b1;            // ASS = 1 (Auto slave select)
        ctrl_config[12] = 1'b0;            // IE = 0 (no interrupt)
        ctrl_config[11] = 1'b0;            // LSB = 0 (MSB first)
        ctrl_config[10] = 1'b1;            // Tx_NEG = 1 (output on falling edge)
        ctrl_config[9] = 1'b0;             // Rx_NEG = 0 (sample on rising edge)
        ctrl_config[6:0] = 7'd64;          // CHAR_LEN = 64 bits
    end
    
    // State registers
    reg [31:0] xip_flash_addr;
    always @(posedge clock or posedge reset) begin
        if (reset)
            xip_flash_addr <= 32'h0;
        else if (is_xip_access && in_psel && !in_penable && !in_pwrite)
            xip_flash_addr <= in_paddr - flash_addr_start;
    end

    reg [3:0] xip_state, xip_next_state;
    always @(posedge clock or posedge reset) begin
        if (reset)
            xip_state <= XIP_IDLE;
        else
            xip_state <= xip_next_state;
    end

    // XIP FSM next-state logic (combinational)
    always @* begin
        xip_next_state = xip_state;

        case (xip_state)
            XIP_IDLE: begin
                if (is_xip_access && in_psel && !in_penable) begin
                    if (in_pwrite)
                        xip_next_state = XIP_IDLE;
                    else
                        xip_next_state = XIP_SETUP_DIV;
                end
            end

            XIP_SETUP_DIV: begin
                if(spi_pready)
                    xip_next_state = XIP_SETUP_SS;
            end

            XIP_SETUP_SS: begin
                if(spi_pready)
                    xip_next_state = XIP_SETUP_CMD;
            end

            XIP_SETUP_CMD: begin
                if(spi_pready)
                    xip_next_state = XIP_SETUP_DUMMY;
            end

            XIP_SETUP_DUMMY: begin
                if(spi_pready)
                    xip_next_state = XIP_CONF_CTRL;
            end

            XIP_CONF_CTRL: begin
                if(spi_pready)
                    xip_next_state = XIP_START;
            end

            XIP_START: begin
                if(spi_pready)
                    xip_next_state = XIP_WAIT;
            end

            XIP_WAIT: begin
                if (!spi_busy)
                    xip_next_state = XIP_READ_DATA;
            end

            XIP_READ_DATA: begin
                if(spi_pready)
                    xip_next_state = XIP_RETURN;
            end

            XIP_RETURN: begin
                if(in_psel && in_penable)
                xip_next_state = XIP_IDLE;
            end

            default: begin  end
        endcase
    end

    // XIP FSM output logic (combinational)
    always @* begin
        xip_reg_addr = 5'h0;
        xip_reg_wdata = 32'h0;
        xip_reg_write = 1'b0;
        xip_reg_select = 1'b0;
        xip_reg_enable = 1'b0;
        xip_pready = 1'b0;
        xip_pslverr = 1'b0;
        xip_prdata = 32'h0;

        case (xip_state)

            XIP_IDLE: begin
                // Unsupport write
                if(is_xip_access && in_psel && in_pwrite)
                begin
                    xip_pready = 1'b1;
                    xip_pslverr = 1'b1;
                end
            end

            XIP_SETUP_DIV: begin
                // Set SPI clock divider to slowest speed (as per manual.md)
                xip_reg_addr = 5'h14;
                xip_reg_wdata = 32'h0000;
                xip_reg_write = 1'b1;
                xip_reg_select = 1'b1;
                xip_reg_enable = 1'b1;
            end

            XIP_SETUP_SS: begin
                // Select slave 0 (flash chip)
                xip_reg_addr = 5'h18;  // SS register
                xip_reg_wdata = 32'h0001;  // select slave 0
                xip_reg_write = 1'b1;
                xip_reg_select = 1'b1;
                xip_reg_enable = 1'b1;
            end

            XIP_SETUP_CMD: begin
                // Prepare SPI transmit registers with READ command (0x03) + address
                // Align address to 4-byte boundary by masking off lower 2 bits
                xip_reg_addr = 5'h04;  // TX1 register (upper 32 bits)
                xip_reg_wdata = {8'h03, xip_flash_addr[23:2], 2'b00};
                xip_reg_write = 1'b1;
                xip_reg_select = 1'b1;
                xip_reg_enable = 1'b1;
            end

            XIP_SETUP_DUMMY: begin
                // Prepare TX0 register (lower 32 bits) - all zeros for dummy cycles
                xip_reg_addr = 5'h00;  // TX0 register
                xip_reg_wdata = 32'h0;
                xip_reg_write = 1'b1;
                xip_reg_select = 1'b1;
                xip_reg_enable = 1'b1;
            end

            XIP_CONF_CTRL: begin
                // Configure control register (without GO_BSY bit)
                xip_reg_addr = 5'h10;  // Control register
                xip_reg_wdata = ctrl_config;  // Control config without GO_BSY
                xip_reg_write = 1'b1;
                xip_reg_select = 1'b1;
                xip_reg_enable = 1'b1;
            end

            XIP_START: begin
                // Set GO_BSY bit to start transfer
                xip_reg_addr = 5'h10;  // Control register
                xip_reg_wdata = ctrl_config | (1 << 8);  // Set GO_BSY=1 to start transfer
                xip_reg_write = 1'b1;
                xip_reg_select = 1'b1;
                xip_reg_enable = 1'b1;
            end

            XIP_WAIT: begin
                // Monitor the busy bit in control register
                if(spi_busy) begin
                    xip_reg_addr = 5'h10;  // Control register
                    xip_reg_select = 1'b1;
                    xip_reg_enable = 1'b1;
                    xip_reg_write = 1'b0;
                end
            end

            XIP_READ_DATA: begin
                // Read received data from RX0 register and return to CPU
                xip_reg_addr = 5'h00;  // RX0 register
                xip_reg_select = 1'b1;
                xip_reg_write = 1'b0;
                xip_reg_enable = 1'b1;
            end

            XIP_RETURN: begin
                // Byte-swap data if needed for endianness (as per manual.md)
                xip_prdata = {xip_reg_rdata[7:0], xip_reg_rdata[15:8],
                              xip_reg_rdata[23:16], xip_reg_rdata[31:24]};
                xip_pready = 1'b1;
                xip_pslverr = 1'b0;
            end

            default: begin  end
        endcase
    end

    // Extract busy flag from SPI control register
    reg [31:0] xip_reg_rdata;
    reg [31:0] spi_ctrl_reg;
    wire       spi_busy;
    always @(posedge clock or posedge reset) begin
        spi_ctrl_reg <= 32'hffffffff;
        if (xip_state == XIP_WAIT && !xip_reg_write && spi_pready)
            spi_ctrl_reg <= spi_rdata;
        else if (xip_state == XIP_READ_DATA && !xip_reg_write && spi_pready)
            xip_reg_rdata <= spi_rdata;
    end
    assign spi_busy = spi_ctrl_reg[8];  // GO_BSY bit

    reg [4:0]  xip_reg_addr;
    reg [31:0] xip_reg_wdata;
    reg        xip_reg_write;
    reg        xip_reg_select;
    reg        xip_reg_enable;

    reg        xip_pready;
    reg [31:0] xip_prdata;
    reg        xip_pslverr;

    wire [4:0]  spi_addr;
    wire [3:0]  spi_strb;
    wire [31:0] spi_wdata;
    wire        spi_write;
    wire        spi_select;
    wire        spi_enable;
    wire [31:0] spi_rdata;
    wire        spi_pready;
    wire        spi_pslverr;

    // Arbiter
    assign spi_addr   = is_xip_access ? xip_reg_addr   : in_paddr[4:0];
    assign spi_wdata  = is_xip_access ? xip_reg_wdata  : in_pwdata;
    assign spi_write  = is_xip_access ? xip_reg_write  : in_pwrite;
    assign spi_select = is_xip_access ? xip_reg_select : in_psel;
    assign spi_enable = is_xip_access ? xip_reg_enable : in_penable;
    assign spi_strb   = is_xip_access ? 4'hF : in_pstrb;

    // Final APB outputs
    assign in_pready  = is_xip_access ? xip_pready  : spi_pready;
    assign in_prdata  = is_xip_access ? xip_prdata  : spi_rdata;
    assign in_pslverr = is_xip_access ? xip_pslverr : spi_pslverr;

    // Connect SPI master with arbitration
    spi_top u0_spi_top (
                .wb_clk_i(clock),
                .wb_rst_i(reset),
                .wb_adr_i(spi_addr),
                .wb_dat_i(spi_wdata),
                .wb_sel_i(spi_strb),
                .wb_we_i(spi_write),
                .wb_stb_i(spi_select),
                .wb_cyc_i(spi_enable),
                .wb_dat_o(spi_rdata),
                .wb_ack_o(spi_pready),
                .wb_err_o(spi_pslverr),
                .wb_int_o(spi_irq_out),

                .ss_pad_o(spi_ss),
                .sclk_pad_o(spi_sck),
                .mosi_pad_o(spi_mosi),
                .miso_pad_i(spi_miso)
            );

`endif // FAST_FLASH

endmodule
