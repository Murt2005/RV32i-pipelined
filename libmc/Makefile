#
include ../site-config.sh

CC=$(RISCV_PREFIX)-gcc
AS=$(RISCV_PREFIX)-as
LD=$(RISCV_PREFIX)-ar

SSFLAGS=-march=rv32i -mabi=ilp32
CCFLAGS=-std=gnu99 -O1 -march=rv32i -mabi=ilp32 -Wno-builtin-declaration-mismatch -Ilibmc
LDFLAGS=

FILES_S=mmio.s
FILES_C=*.c

.c.o:
	$(CC) $(CCFLAGS) -c $*.c

.s.o:
	$(AS) $(SSFLAGS) -c $*.s -o $*.o

libmc.a: $(FILES_S:.s=.o) $(FILES_C:.c=.o)
	$(CC) $(CCFLAGS) -c *.c
	$(LD) $(LDFLAGS) q libmc.a *.o

clean:
	rm -f *.o libmc.a
