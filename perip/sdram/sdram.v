module sdram #(
    // Parameterize memory dimensions (can match actual SDRAM part or be smaller for simulation)
    parameter DATA_WIDTH = 16,            // Data bus width (16 bits)
    parameter BANK_COUNT = 4,            // Number of banks (e.g., 4)
    parameter ROW_BITS   = 13,           // Row address width (e.g., 13 bits for 8192 rows)
    parameter COL_BITS   = 9             // Column address width (e.g., 9 bits for 512 columns)
)(
    input                   clk,        // SDRAM clock (positive edge)
    input                   cke,        // Clock enable (ignored in model if always 1)
    input                   cs,       // Chip select (active low)
    input                   ras,      // Row address strobe (active low)
    input                   cas,      // Column address strobe (active low)
    input                   we,       // Write enable (active low)
    input       [1:0]       ba,         // Bank address
    input       [12:0]      a,       // Address bus (A[12:0])
    input       [1:0]       dqm,        // Data mask for writes (1=mask byte, 0=write byte)
    inout       [DATA_WIDTH-1:0] dq
);

    // Memory storage: one open row per bank, with the memory array
    // Use a multi-dimensional array to represent the memory structure directly
    reg [DATA_WIDTH-1:0] mem_array [0:BANK_COUNT-1][0:(1<<ROW_BITS)-1][0:(1<<COL_BITS)-1];

    // Registers to track open row in each bank (0 indicates no open row)
    reg open_bank [0:BANK_COUNT-1]; 
    reg [ROW_BITS-1:0] open_row  [0:BANK_COUNT-1];

    // Mode register and decoded settings (defaults: CAS latency 2, burst length 2 sequential)
    reg [12:0] mode_reg;
    integer cas_latency_cycles = 2;        // CAS latency in cycles (e.g., 2)
    integer burst_length = 2;             // Burst length in beats (e.g., 2)
    reg burst_type_interleaved = 0;       // Burst type (0=sequential, 1=interleaved)

    // Internal state for handling ongoing read/write bursts
    reg [COL_BITS-1:0] burst_col;
    reg [ROW_BITS-1:0] burst_row;
    reg [1:0]          burst_bank;
    integer read_latency_count = 0;
    integer write_latency_count = 0;
    integer read_burst_count = 0;
    integer write_burst_count = 0;
    reg auto_precharge_pending = 0;   // indicates if an auto-precharge was requested on the last command
    reg dq_output_enable = 0;
    reg [DATA_WIDTH-1:0] data_out;
    assign dq = dq_output_enable ? data_out : {DATA_WIDTH{1'bz}};

    reg [DATA_WIDTH-1:0] current_val;
    reg [DATA_WIDTH-1:0] new_val;
    reg [DATA_WIDTH-1:0] bcurrent_val;
    reg [DATA_WIDTH-1:0] bnew_val;

    // Helper task: decode mode register for CAS latency and burst length
    task decode_mode_register(input [12:0] new_mode);
        begin
            // CAS Latency is usually bits A6-A4 of mode register
            case (new_mode[6:4])
                3'b010: cas_latency_cycles = 2;
                3'b011: cas_latency_cycles = 3;
                default: cas_latency_cycles = 2;  // default to 2 if unsupported value
            endcase
            // Burst Length is bits A2-A0 of mode register
            case (new_mode[2:0])
                3'b000: burst_length = 1;
                3'b001: burst_length = 2;
                3'b010: burst_length = 4;
                3'b011: burst_length = 8;
                default: burst_length = 2;  // default to 2
            endcase
            // Burst Type (A3): 0 = sequential, 1 = interleaved (we will assume sequential for simplicity)
            burst_type_interleaved = new_mode[3];
        end
    endtask

    // Initialize memory and open rows
    integer b, r, c;
    initial begin
        // Initialize memory to 0 for simulation
        for(b = 0; b < BANK_COUNT; b = b + 1) begin
            for(r = 0; r < (1<<ROW_BITS); r = r + 1) begin
                for(c = 0; c < (1<<COL_BITS); c = c + 1) begin
                    mem_array[b][r][c] = {DATA_WIDTH{1'b0}};
                end
            end
            open_bank[b] = 1'b0;
            open_row[b]  = {ROW_BITS{1'b0}};
        end
        mode_reg = 13'b0;
        cas_latency_cycles = 2;
        burst_length = 2;
        burst_type_interleaved = 0;
    end

    // Main SDRAM operation logic on each clock cycle
    always @(posedge clk) begin
        dq_output_enable <= 0;
        // Default: do nothing each cycle unless a command or ongoing burst is active
        // Decrement any active latency counters
        if (read_latency_count > 0) 
            read_latency_count <= read_latency_count - 1;
        if (write_latency_count > 0)
            write_latency_count <= write_latency_count - 1;

        // 1. Decode the current command based on control lines (cs, ras, cas, we)
        // Only consider commands when chip is selected (CS# low) and clock enabled
        if (cke && !cs) begin
            // ACTIVE command: opens a row
            if (!ras &&  cas &&  we) begin 
                // ACTIVE: RAS#=0, CAS#=1, WE#=1
                open_bank[ba] <= 1'b1;
                open_row[ba]  <= a[ROW_BITS-1:0];   // row address is on a bus
                // Note: The controller must ensure any previously open row in this bank was precharged before a new ACTIVE
            end
            // LOAD MODE REGISTER command
            else if (!ras && !cas && !we) begin 
                // LOAD MODE: RAS#=0, CAS#=0, WE#=0 (A12..A0 carries mode value)
                mode_reg <= a;
                decode_mode_register(a);
                // After a mode set, CAS latency and burst length are updated
            end
            // READ or READ with AUTO-PRECHARGE
            else if ( ras && !cas &&  we) begin 
                // READ: RAS#=1, CAS#=0, WE#=1
                burst_bank <= ba;
                burst_row  <= open_row[ba];               // use previously activated row
                burst_col  <= a[COL_BITS-1:0];         // column address from a bus
                read_burst_count <= burst_length;
                read_latency_count <= cas_latency_cycles - 1; // start CAS latency countdown
                write_burst_count <= 0;                   // end. any write in progress
                auto_precharge_pending <= a[10];       // A10 = 1 indicates auto-precharge request
            end
            // WRITE or WRITE with AUTO-PRECHARGE
            else if ( ras && !cas && !we) begin 
                // WRITE: RAS#=1, CAS#=0, WE#=0
                burst_bank <= ba;
                burst_row  <= open_row[ba];
                burst_col  <= a[COL_BITS-1:0];
                write_burst_count <= 1;
                read_burst_count <= 0;      // end. any read in progress
                auto_precharge_pending <= a[10];  // track auto-precharge request
            end
            // PRECHARGE (close row)
            else if (!ras &&  cas && !we) begin 
                // PRECHARGE: RAS#=0, CAS#=1, WE#=0 (A10 determines all banks or single bank)
                if (a[10] == 1'b1) begin 
                    // Precharge ALL banks
                    integer b;
                    for (b = 0; b < BANK_COUNT; b = b + 1) begin
                        open_bank[b] <= 1'b0;
                    end
                end else begin 
                    // Precharge specified bank (ba)
                    open_bank[ba] <= 1'b0;
                end
                // (Any open row in the precharged bank is now closed)
            end
            // AUTO REFRESH 
            else if (!ras && !cas &&  we) begin 
                // REFRESH: RAS#=0, CAS#=0, WE#=1
                // In this model, treat refresh as a NOP (no explicit memory action).
                // We assume the controller issues refresh only when all banks are precharged.
                // (No changes to open rows or memory contents in simulation)
            end
            // NOP / Deselect
            else if ( ras &&  cas &&  we) begin 
                // NOP: RAS#=1, CAS#=1, WE#=1 (CS#=0) or 
                // Deselect: CS#=1 (which is outside this if-block because cs must be 0 here)
                // Do nothing (just idle)
            end
            // (Burst Terminate command (RAS#=1,CAS#=1,WE#=0) is not explicitly handled; not expected in this controller)
        end

        // 2. Handle read data output when CAS latency has elapsed
        if (read_latency_count <= 1 && read_burst_count > 0) begin
            // It's time to output the next read data beat
            // Access memory array directly with multi-dimensional indexing
            data_out <= mem_array[burst_bank][burst_row][burst_col];
            read_burst_count <= read_burst_count - 1;
            dq_output_enable <= 1;
            
            // Increment column for next beat (sequential burst)
            burst_col <= burst_col + 1;
            if (burst_col == (1 << COL_BITS) - 1) begin 
                burst_col <= 0; // wrap around column if at end. (in sequential burst)
            end
            
            // If that was the last data beat of the burst:
            if (read_burst_count == 1) begin
                // If auto-precharge was requested on this read, close the row now
                if (auto_precharge_pending) begin
                    open_bank[burst_bank] <= 1'b0;
                end
                auto_precharge_pending <= 1'b0;
            end
        end

        // 3. Handle write data input when write latency has elapsed
        if (ras && !cas && !we) begin
            // It's time to capture the next write data beat from the controller
            // Read current memory value to apply byte masking
            current_val = mem_array[ba][open_row[ba]][a[COL_BITS-1:0]];
            
            // Apply DQM mask: if a DQM bit is high, do NOT overwrite that byte
            // (Assume DATA_WIDTH=16, two DQM bits: dqm[0] for lower byte, dqm[1] for upper byte)
            new_val = dq;
            if (dqm[0]) begin
                new_val[7:0] = current_val[7:0];       // mask lower byte
            end
            if (dqm[1]) begin
                new_val[15:8] = current_val[15:8];     // mask upper byte
            end
            
            // Write the (masked) new data into memory using multi-dimensional indexing
            mem_array[ba][open_row[ba]][a[COL_BITS-1:0]] <= new_val;
        end

        if(write_burst_count > 0) begin
            // It's time to capture the next write data beat from the controller
            // Read current memory value to apply byte masking
            bcurrent_val = mem_array[burst_bank][burst_row][burst_col+1];
            
            // Apply DQM mask: if a DQM bit is high, do NOT overwrite that byte
            // (Assume DATA_WIDTH=16, two DQM bits: dqm[0] for lower byte, dqm[1] for upper byte)
            bnew_val = dq;
            if (dqm[0]) begin
                bnew_val[7:0] = bcurrent_val[7:0];       // mask lower byte
            end
            if (dqm[1]) begin
                bnew_val[15:8] = bcurrent_val[15:8];     // mask upper byte
            end
            
            // Write the (masked) new data into memory using multi-dimensional indexing
            mem_array[burst_bank][burst_row][burst_col+1] <= bnew_val;
            write_burst_count <= write_burst_count - 1;

            // If last beat written:
            if (write_burst_count == 1) begin 
                // If auto-precharge was requested on this write, close the row now
                if (auto_precharge_pending) begin
                    open_bank[burst_bank] <= 1'b0;
                end
                auto_precharge_pending <= 1'b0;
            end
        end

    end // always @(posedge clk)
endmodule
