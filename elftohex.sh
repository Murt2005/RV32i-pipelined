#!/bin/bash

source ./site-config.sh

extra=""


$RISCV_PREFIX-objcopy -O binary -j .text -g $1 $1.bin
./dumphex $extra -i $1.bin -o code -base 0 -size 0x10000 -strip -byte
rm $1.bin

$RISCV_PREFIX-objcopy -O binary -R .text -g $1 $1.bin
./dumphex $extra -i $1.bin -o data -base 0 -size 0x10000 -strip -byte
rm $1.bin






