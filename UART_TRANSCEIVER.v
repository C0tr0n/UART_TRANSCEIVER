`timescale 1ns / 1ps
// ============================================================
// uart.v  -  Full-duplex UART transceiver
// 8-N-1, configurable baud rate, 16x oversampling
// Fixes vs. original:
//   1. Baud counter: compare == divisor-1 (no off-by-one)
//   2. TX start bit driven immediately on state entry
//   3. RX shift register: LSB-first (left-shift into [0])
//   4. tx_start is edge-detected to prevent re-triggering
//   5. baud_divisor latched at transaction start
//   6. rx_error is a sticky latch, cleared by rx_error_clr
// ============================================================
module uart #(
    parameter CLK_FREQ = 50_000_000
)(
    input  wire       clk,
    input  wire       rst_n,

    // Baud rate select  000=9600 001=19200 010=38400 011=57600 100=115200
    input  wire [2:0] baud_sel,

    // TX interface
    input  wire       tx_start,
    input  wire [7:0] tx_data,
    output reg        tx_busy,
    output reg        tx_done,

    // RX interface
    output reg        rx_ready,
    output reg  [7:0] rx_data,
    output reg        rx_error,
    input  wire       rx_error_clr,   // pulse high to clear sticky error

    // Serial lines
    output reg        txd,
    input  wire       rxd
);

// ------------------------------------------------------------
// Baud rate constants  (divisor for 16x oversampling)
// ------------------------------------------------------------
localparam DIV_9600   = CLK_FREQ / (9600   * 16) - 1;
localparam DIV_19200  = CLK_FREQ / (19200  * 16) - 1;
localparam DIV_38400  = CLK_FREQ / (38400  * 16) - 1;
localparam DIV_57600  = CLK_FREQ / (57600  * 16) - 1;
localparam DIV_115200 = CLK_FREQ / (115200 * 16) - 1;

// ------------------------------------------------------------
// Baud generator
// ------------------------------------------------------------
reg [15:0] baud_div_latch;   // latched at transaction start
reg [15:0] baud_counter;
wire       baud_tick = (baud_counter == baud_div_latch);

function [15:0] sel_div;
    input [2:0] s;
    case (s)
        3'b000:  sel_div = DIV_9600;
        3'b001:  sel_div = DIV_19200;
        3'b010:  sel_div = DIV_38400;
        3'b011:  sel_div = DIV_57600;
        3'b100:  sel_div = DIV_115200;
        default: sel_div = DIV_9600;
    endcase
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        baud_counter <= 16'd0;
    else if (baud_tick)
        baud_counter <= 16'd0;
    else
        baud_counter <= baud_counter + 16'd1;
end

// ------------------------------------------------------------
// TX FSM
// ------------------------------------------------------------
localparam TX_IDLE  = 2'd0,
           TX_START = 2'd1,
           TX_DATA  = 2'd2,
           TX_STOP  = 2'd3;

reg [1:0] tx_state;
reg [3:0] tx_sample_count;
reg [2:0] tx_bit_count;
reg [7:0] tx_shift_reg;

// Edge-detect tx_start so a held signal fires exactly once
reg tx_start_r;
wire tx_start_edge = tx_start & ~tx_start_r;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) tx_start_r <= 1'b0;
    else        tx_start_r <= tx_start;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_state        <= TX_IDLE;
        txd             <= 1'b1;
        tx_busy         <= 1'b0;
        tx_done         <= 1'b0;
        tx_sample_count <= 4'd0;
        tx_bit_count    <= 3'd0;
        tx_shift_reg    <= 8'd0;
        baud_div_latch  <= DIV_9600;
    end else begin
        tx_done <= 1'b0;   // default

        case (tx_state)

            TX_IDLE: begin
                txd     <= 1'b1;
                tx_busy <= 1'b0;
                if (tx_start_edge) begin
                    // Latch baud divisor and data, drive start bit NOW
                    baud_div_latch  <= sel_div(baud_sel);
                    tx_shift_reg    <= tx_data;
                    tx_bit_count    <= 3'd0;
                    tx_sample_count <= 4'd0;
                    tx_busy         <= 1'b1;
                    txd             <= 1'b0;   // start bit immediately
                    tx_state        <= TX_START;
                end
            end

            // Wait one full baud period (16 ticks) then move to DATA
            TX_START: begin
                if (baud_tick) begin
                    if (tx_sample_count == 4'd15) begin
                        tx_sample_count <= 4'd0;
                        txd             <= tx_shift_reg[0];   // first data bit
                        tx_shift_reg    <= {1'b0, tx_shift_reg[7:1]};
                        tx_bit_count    <= 3'd1;
                        tx_state        <= TX_DATA;
                    end else begin
                        tx_sample_count <= tx_sample_count + 4'd1;
                    end
                end
            end

            TX_DATA: begin
                if (baud_tick) begin
                    if (tx_sample_count == 4'd15) begin
                        tx_sample_count <= 4'd0;
                        if (tx_bit_count == 3'd7) begin
                            txd      <= 1'b1;   // stop bit
                            tx_state <= TX_STOP;
                        end else begin
                            txd          <= tx_shift_reg[0];
                            tx_shift_reg <= {1'b0, tx_shift_reg[7:1]};
                            tx_bit_count <= tx_bit_count + 3'd1;
                        end
                    end else begin
                        tx_sample_count <= tx_sample_count + 4'd1;
                    end
                end
            end

            TX_STOP: begin
                if (baud_tick) begin
                    if (tx_sample_count == 4'd15) begin
                        tx_done         <= 1'b1;
                        tx_busy         <= 1'b0;
                        tx_sample_count <= 4'd0;
                        tx_state        <= TX_IDLE;
                    end else begin
                        tx_sample_count <= tx_sample_count + 4'd1;
                    end
                end
            end

            default: tx_state <= TX_IDLE;
        endcase
    end
end

// ------------------------------------------------------------
// RXD synchronizer  (double flip-flop, metastability protection)
// ------------------------------------------------------------
reg rxd_ff1, rxd_ff2, rxd_ff3;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rxd_ff1 <= 1'b1;
        rxd_ff2 <= 1'b1;
        rxd_ff3 <= 1'b1;
    end else begin
        rxd_ff1 <= rxd;
        rxd_ff2 <= rxd_ff1;
        rxd_ff3 <= rxd_ff2;
    end
end

wire rxd_sync        = rxd_ff2;
wire start_detected  = (rxd_ff3 == 1'b1) && (rxd_ff2 == 1'b0);   // falling edge

// ------------------------------------------------------------
// RX FSM
// ------------------------------------------------------------
localparam RX_IDLE  = 2'd0,
           RX_START = 2'd1,
           RX_DATA  = 2'd2,
           RX_STOP  = 2'd3;

reg [1:0] rx_state;
reg [3:0] rx_sample_count;
reg [3:0] rx_bit_count;
reg [7:0] rx_shift_reg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rx_state        <= RX_IDLE;
        rx_ready        <= 1'b0;
        rx_error        <= 1'b0;
        rx_data         <= 8'd0;
        rx_sample_count <= 4'd0;
        rx_bit_count    <= 4'd0;
        rx_shift_reg    <= 8'd0;
    end else begin
        rx_ready <= 1'b0;   // default: pulse for one cycle

        // Sticky error cleared externally
        if (rx_error_clr)
            rx_error <= 1'b0;

        case (rx_state)

            RX_IDLE: begin
                rx_sample_count <= 4'd0;
                rx_bit_count    <= 4'd0;
                if (start_detected)
                    rx_state <= RX_START;
            end

            // Sample the middle of the start bit (tick 7 = half of 16)
            // to confirm it is genuinely low (not a glitch)
            RX_START: begin
                if (baud_tick) begin
                    if (rx_sample_count == 4'd7) begin
                        if (rxd_sync == 1'b0) begin
                            rx_sample_count <= 4'd0;
                            rx_state        <= RX_DATA;
                        end else begin
                            rx_error <= 1'b1;   // false start / glitch
                            rx_state <= RX_IDLE;
                        end
                    end else begin
                        rx_sample_count <= rx_sample_count + 4'd1;
                    end
                end
            end

            // Sample each data bit at its centre (tick 15)
            // Shift LSB-first: first received bit ends up in rx_shift_reg[0]
            RX_DATA: begin
                if (baud_tick) begin
                    if (rx_sample_count == 4'd15) begin
                        rx_sample_count <= 4'd0;
                        // Left-shift so first received bit lands at LSB after 8 shifts
                        rx_shift_reg    <= {rx_shift_reg[6:0], rxd_sync};
                        rx_bit_count    <= rx_bit_count + 4'd1;
                        if (rx_bit_count == 4'd7)
                            rx_state <= RX_STOP;
                    end else begin
                        rx_sample_count <= rx_sample_count + 4'd1;
                    end
                end
            end

            RX_STOP: begin
                if (baud_tick) begin
                    if (rx_sample_count == 4'd15) begin
                        rx_sample_count <= 4'd0;
                        if (rxd_sync == 1'b1) begin
                            rx_data  <= rx_shift_reg;
                            rx_ready <= 1'b1;
                        end else begin
                            rx_error <= 1'b1;   // framing error
                        end
                        rx_state <= RX_IDLE;
                    end else begin
                        rx_sample_count <= rx_sample_count + 4'd1;
                    end
                end
            end

            default: rx_state <= RX_IDLE;
        endcase
    end
end

endmodule
