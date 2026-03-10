#
# THIS GOES ON THE *PICO*
#

from machine import UART, Pin
import time
import ice

# Init UART first to be able to read debug signals immediately
uart = UART(1, baudrate=115200, tx=Pin(24), rx=Pin(27))

fpga = ice.fpga(cdone=Pin(40), clock=Pin(21), creset=Pin(31), cram_cs=Pin(5), cram_mosi=Pin(4), cram_sck=Pin(6), frequency=12)
file = open("hardware.bin", "br")
fpga.start()
fpga.cram(file)

def sample_rx():
    t0 = time.ticks_ms()
    while time.ticks_diff(time.ticks_ms(), t0) < 500:
        if uart.any():
            print(uart.read(), end="")
    print("\nPI: finished")
