# pico2-ice UART demo

This example was created and tested with apio, but should work for your choice of build/synthesis with minor modification. You must also make sure the pico firmware is running micropython.

## Intended behavior

After starting the device with the provided micropython script (main.py) and the built iCE FPGA bin, connect to the device with your serial com program (e.g. picocom). Hold SW2, which maps to the reset signal, then call `sample_rx()` on the pico REPL. You might see some garbage output (maybe a few lines), which is expected. If you let go of SW2 and run `sample_rx()`, you should see a couple extremely long strings delineated with `b'...'` wrapping across multiple lines, where `...` is many repeated "HELLO" strings.

Data in this example is only transmitted from the iCE FGPA to the pico, not vice versa.

## Setup

Assuming the above requirement - that picocom and apio are installed, and the board is using the friendly micropython firmware - building is simply done with `apio build`. You can then copy the _build/default/hardware.bin to the board, along with main.py (make a backup of the board's main.py if needed).

Then follow along with the intended behavior above.

You can verify what the signals look like in a waveform visualizer by running `apio sim`, BUT you will want to change the simpleuart module's `.DEFAULT_DIV` paramter in top.sv from `103` to `1`, to shrink the timescale accordingly. REMEMBER to switch it back to `103` when synthesizing for your board.