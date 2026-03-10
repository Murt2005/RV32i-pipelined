## Bryan hardware examples

This folder contains Bryan's UART transmitter and a simple register-dump protocol, along with a matching MicroPython host script.

- **uart_clk.sv**: Small clock-divider that generates a single-cycle `baud_tick` enable by dividing the incoming FPGA clock by a fixed ratio (here, 12). The UART transmitter uses this tick to step its state machine at the desired baud rate.

- **uart_tx.sv**: 8N1 UART transmitter. When `send` is pulsed in the IDLE state it:
  - latches an 8-bit `data` value
  - shifts out a start bit, 8 data bits (LSB first), and a stop bit on `tx`
  - asserts `busy` while a frame is in progress.

- **register_send.sv**: High-level packetizer that wraps `uart_tx` so you can stream a single 32-bit register value over UART. It:
  - builds a 7-byte packet: `0xAA` header, register number, 32-bit little-endian value, and a CRC-8 byte
  - sequences bytes out one at a time using an internal FSM that handshakes with `uart_tx` via its `busy` flag
  - exposes a simple `send`/`busy` interface so higher-level logic can request new register dumps.

- **main.py**: MicroPython script that runs on the RP2040 host. It:
  - asserts a reset pin into the FPGA fabric
  - configures the FPGA using `fpga.bin` over the `ice` helper
  - opens a high-speed UART (1 Mbaud) to receive register-dump packets
  - reimplements the same CRC-8 in Python and:
    - buffers incoming bytes
    - checks for the `0xAA` header
    - validates frame CRC and prints decoded `xNN = 0xXXXXXXXX` register values.

