	.text
	.globl _start

_start:
	# Minimal UART bring-up:
	# - set stack pointer
	# - repeatedly write 'H' to 0x0002FFF8 with a small delay

	li      sp, (0x00021000 - 16)

	li      t0, 0x0002FFF8    # UART MMIO

uart_loop:
	li      t1, 'H'
	sw      t1, 0(t0)

	# crude delay loop so we don't saturate the UART
	li      t2, 5000
delay_loop:
	addi    t2, t2, -1
	bnez    t2, delay_loop

	j       uart_loop
