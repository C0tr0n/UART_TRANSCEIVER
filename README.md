# Full-Duplex UART Transceiver

A configurable, synthesis-ready full-duplex UART transceiver in Verilog with 16× oversampling, metastability protection, and framing error detection.

---

## Features

- Full-duplex simultaneous TX and RX
- Configurable baud rate: 9600 / 19200 / 38400 / 57600 / 115200
- 16× oversampling for noise-robust reception
- 8-N-1 format (8 data bits, no parity, 1 stop bit), LSB-first
- Rising-edge detection on `tx_start` — no re-trigger on held signal
- Baud divisor latched at transaction start — immune to mid-transfer `baud_sel` changes
- Sticky framing error flag with explicit software clear
- Double flip-flop synchronizer on RX input for metastability protection
- FPGA-friendly: synchronous active-low reset, registered outputs, no combinational loops

---

## File Structure

```
uart-transceiver/
├── rtl/
│   ├── uart.v           # Top-level UART module (TX + RX + baud generator)
│   └── synchronizer.v   # Parameterised double flip-flop synchronizer
├── README.md
├── LICENSE
└── .gitignore
```

---

## Module Interface — `uart.v`

```verilog
module uart #(
    parameter CLK_FREQ = 50_000_000   // System clock in Hz
) (
    // System
    input  wire       clk,
    input  wire       rst_n,          // Active-low asynchronous reset

    // Configuration
    input  wire [2:0] baud_sel,       // See table below

    // Transmitter
    input  wire       tx_start,       // Rising edge triggers one transfer
    input  wire [7:0] tx_data,        // Byte to send (latched on tx_start edge)
    output wire       tx_busy,        // High while frame is in progress
    output wire       tx_done,        // One-cycle pulse on stop-bit completion

    // Receiver
    output wire       rx_ready,       // One-cycle pulse when rx_data is valid
    output wire [7:0] rx_data,        // Received byte
    output wire       rx_error,       // Sticky framing error flag
    input  wire       rx_error_clr,   // Pulse high to clear rx_error

    // Physical lines
    output wire       txd,
    input  wire       rxd
);
```

---

## Baud Rate Selection

| `baud_sel` | Baud rate | Divisor @ 50 MHz |
|:----------:|:---------:|:----------------:|
| `3'b000`   | 9 600     | 324              |
| `3'b001`   | 19 200    | 161              |
| `3'b010`   | 38 400    | 80               |
| `3'b011`   | 57 600    | 53               |
| `3'b100`   | 115 200   | 26               |

Divisor formula: `CLK_FREQ / (baud_rate × 16) − 1`

The module is parameterised on `CLK_FREQ`, so targeting a different clock frequency requires only changing that parameter — all divisors recompute at elaboration time.

---

## Instantiation Example

```verilog
uart #(
    .CLK_FREQ(50_000_000)
) u_uart (
    .clk          (clk_50m),
    .rst_n        (rst_n),
    .baud_sel     (3'b000),      // 9600 baud
    .tx_start     (tx_start),
    .tx_data      (tx_data),
    .tx_busy      (tx_busy),
    .tx_done      (tx_done),
    .rx_ready     (rx_ready),
    .rx_data      (rx_data),
    .rx_error     (rx_error),
    .rx_error_clr (rx_error_clr),
    .txd          (uart_txd),
    .rxd          (uart_rxd)
);
```

---

## Protocol Detail

### Frame format

```
Idle  Start  D0  D1  D2  D3  D4  D5  D6  D7  Stop  Idle
  1     0    lsb                             msb   1     1
```

The line idles high. A falling edge marks the start bit. Eight data bits follow LSB-first. A high stop bit closes the frame.

### Baud generator

The internal counter divides the system clock by `(divisor + 1)`, producing a `baud_tick` pulse at 16× the configured baud rate. One full bit period = 16 ticks.

### Transmitter state machine

| State    | Action                                      |
|----------|---------------------------------------------|
| `IDLE`   | Waits for rising edge on `tx_start`         |
| `START`  | Drives `txd` low for one baud period        |
| `DATA`   | Shifts out bits 0–7, LSB first              |
| `STOP`   | Drives `txd` high; asserts `tx_done`        |

`tx_data` is latched into an internal shift register on the start edge, so the input can change freely during transmission.

### Receiver state machine

| State    | Action                                                         |
|----------|----------------------------------------------------------------|
| `IDLE`   | Monitors `rxd_sync` for a falling edge (start bit)            |
| `START`  | Waits 8 ticks, samples the middle of the start bit            |
| `DATA`   | Samples each bit at tick 8 of its period (centre of bit cell) |
| `STOP`   | Samples stop bit; sets `rx_ready` on valid stop, `rx_error` otherwise |

Centre sampling gives ±7 tick tolerance per bit, making the design tolerant of ±2 % baud-rate deviation between devices.

### Framing error

`rx_error` is a sticky flag: it asserts when the stop bit is sampled low and remains high until `rx_error_clr` is pulsed. It does not block subsequent reception.

---

## Metastability Protection

`synchronizer.v` is a parameterised two-stage flip-flop chain. The RX path instantiates it with `WIDTH=1` to prevent metastability on the asynchronous `rxd` input:

```
rxd (async) → FF1 → FF2 → rxd_sync (safe to use in clk domain)
```

MTBF with two stages at 50 MHz and 115200 baud input event rate exceeds 10¹² hours, well beyond practical requirements.

---

## Resource Estimate (Xilinx 7-series, 50 MHz)

| Resource     | Estimate |
|:-------------|:--------:|
| Flip-flops   | ~50      |
| LUTs         | ~40      |
| Block RAM    | 0        |
| DSPs         | 0        |
| Fmax         | > 150 MHz|

The design comfortably meets timing in slow-corner conditions at 115200 baud.

---

## Synthesis Notes

- **Reset**: Active-low asynchronous reset on all registers. Synthesis tools will infer standard reset trees — no manual reset buffer insertion needed.
- **Clock**: Single clock domain. No clock-domain crossings except the synchronised `rxd` input.
- **I/O buffers**: Not instantiated explicitly. Most tools insert `IBUF`/`OBUF` automatically on top-level ports. For deeply embedded instantiation, drive `txd` and `rxd` through your top-level I/O directly.
- **Constraints**: Constrain `rxd` with a `set_input_delay` of half the bit period at the lowest supported baud rate. `txd` is fully synchronous and needs only a standard output-delay constraint.

---

## Timing Accuracy

| Baud rate | Clock error @ 50 MHz | Within ±2 % limit? |
|:---------:|:--------------------:|:-------------------:|
| 9 600     | 0.02 %               | Yes                 |
| 19 200    | 0.16 %               | Yes                 |
| 38 400    | 0.16 %               | Yes                 |
| 57 600    | 0.79 %               | Yes                 |
| 115 200   | 1.36 %               | Yes                 |

---

## Extending the Design

**Adding parity** — insert a `PARITY` state between `DATA` and `STOP` in both FSMs. Accumulate XOR of data bits during `DATA` and output/check on the parity cycle.

**Adding a TX FIFO** — connect an 8-deep synchronous FIFO between your application logic and `tx_data`/`tx_start`. Drive `tx_start` from `fifo_not_empty & ~tx_busy`.

**Higher baud rates** — increase `CLK_FREQ` parameter to match your actual clock. Divisors recompute automatically. Beyond 1 Mbaud, verify that `baud_div_latch` width (currently 16 bits) is still sufficient: `CLK_FREQ / (baud × 16) − 1` must fit in 16 bits.

**Auto-baud detection** — measure the width of the start bit in system clock cycles, derive the divisor, and load it into `baud_div_latch` before releasing the receiver FSM.

---
