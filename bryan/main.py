"""
MicroPython host script for Bryan's register-dump UART protocol.

Responsibilities:
- hold the FPGA in reset while it is configured with `fpga.bin`
- open a high-speed UART (1 Mbaud) to receive debug frames
- implement the same CRC-8 (poly 0x07) used in `register_send.sv`
- parse and pretty-print 7-byte register-dump packets from the FPGA.
"""

from machine import UART, Pin
import time
import ice
import struct

# FPGA-side reset that gates the soft core while we reconfigure and set up UART.
resetPin = Pin(30, Pin.OUT)
resetPin.value(1)

# UART1 RX is wired from the FPGA `tx` pin; TX is unused on the RP2040 side.
uart = UART(1, baudrate=1000000, rx=Pin(25), tx=None)
HEADER = 0xAA


def crc8_byte(crc, data):
    """Update a running CRC-8 (poly 0x07) with one byte."""
    crc ^= data
    for _ in range(8):
        if crc & 0x80:
            crc = ((crc << 1) ^ 0x07) & 0xFF
        else:
            crc = (crc << 1) & 0xFF
    return crc


def crc8_packet(data):
    """Compute CRC-8 over an iterable of bytes."""
    crc = 0
    for b in data:
        crc = crc8_byte(crc, b)
    return crc


# Give USB/UART and the board some time to settle after power-on.
time.sleep(0.2)

# Configure the FPGA fabric from an on-board `fpga.bin` bitstream.
fpga = ice.fpga(
    cdone=Pin(40),
    clock=Pin(21),
    creset=Pin(31),
    cram_cs=Pin(5),
    cram_mosi=Pin(4),
    cram_sck=Pin(6),
    frequency=12,
)
file = open("fpga.bin", "br")
fpga.start()
fpga.cram(file)

# Allow the soft core inside the FPGA to start running.
time.sleep(1)
resetPin.value(0)

# Sliding buffer of bytes received from the FPGA.
buffer = bytearray()

while True:
    # Accumulate any newly-arrived UART bytes into the buffer.
    if uart.any():
        data = uart.read(64)
        if data:
            buffer.extend(data)

    # Attempt to decode as many complete 7-byte frames as are available.
    while len(buffer) >= 7:
        # Search for the 0xAA header byte at the start of a frame.
        if buffer[0] != HEADER:
            buffer.pop(0)
            continue

        frame = buffer[:7]
        calc_crc = crc8_packet(frame[:6])
        rx_crc = frame[6]

        if calc_crc != rx_crc:
            print("CRC error")
            buffer.pop(0)
            continue

        reg_num = frame[1]
        reg_val = struct.unpack("<I", frame[2:6])[0]
        print("x{:02d} = 0x{:08X}".format(reg_num, reg_val))
        buffer = buffer[7:]

    time.sleep_ms(1)
