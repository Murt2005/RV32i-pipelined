/*
 * pico2-ice RP2350 bridge firmware for the RV32I pipelined processor.
 *
 * Forked from pico-ice-sdk/examples/rp2_usb_uart. Three jobs:
 *   1. Export the FPGA's clock
 *   2. Let the FPGA configure and report if it did or not.
 *   3. Bridge bytes between a USB CDC port and the FPGA's UART pins
 */

#include <stdio.h>
#include <string.h>

#include "pico/stdlib.h"
#include "hardware/irq.h"
#include "hardware/gpio.h"
#include "hardware/uart.h"

#include "ice_usb.h"
#include "ice_fpga.h"

#include "tusb.h"

#define UART_TX_PIN 28
#define UART_RX_PIN 29

// must match fpga/ice40/Makefile's CLK_FREQ and BAUD_RATE
#define FPGA_CLK_HZ   AS_MHZ(12)
#define FPGA_BAUD     1000000

// declared in ice_fpga.c but not exported by ice_fpga.h
extern int ice_fpga_configured(const ice_fpga fpga);

extern void (*tud_cdc_rx_cb_table[])(uint8_t);

static void cdc_to_uart0_blocking(uint8_t byte)
{
    uart_putc_raw(uart0, byte);
}

#define RING_SIZE 4096
#define RING_MASK (RING_SIZE - 1)

static volatile uint8_t  ring[RING_SIZE];
static volatile uint32_t ring_head;
static volatile uint32_t ring_tail;
static volatile uint32_t ring_overruns;

static void uart0_rx_to_ring(void)
{
    while (uart_is_readable(uart0)) {
        uint8_t  b    = (uint8_t)uart_getc(uart0);
        uint32_t head = ring_head;
        uint32_t next = (head + 1) & RING_MASK;

        if (next == ring_tail) {
            ring_overruns++;
        } else {
            ring[head] = b;
            ring_head  = next;
        }
    }
}

static void drain_ring_to_cdc(void)
{
    while (ring_tail != ring_head) {
        if (tud_cdc_n_write_available(ICE_USB_UART0_CDC) == 0)
            break;
        tud_cdc_n_write_char(ICE_USB_UART0_CDC, ring[ring_tail]);
        ring_tail = (ring_tail + 1) & RING_MASK;
    }
    tud_cdc_n_write_flush(ICE_USB_UART0_CDC);
}

#define LOG_CDC (1 - ICE_USB_UART0_CDC)

static void log_banner(int cdone)
{
    char msg[192];
    int  n = snprintf(msg, sizeof msg,
                      "\r\npico2-ice RV32I bridge\r\n"
                      "  FPGA clock : %u Hz (GPIO%u, GPOUT0)\r\n"
                      "  UART       : %u baud, TX=GPIO%u RX=GPIO%u\r\n"
                      "  CDONE      : %s\r\n"
                      "  FPGA data  : CDC %u\r\n",
                      (unsigned)FPGA_CLK_HZ, (unsigned)FPGA_DATA.pin_clock,
                      (unsigned)FPGA_BAUD, UART_TX_PIN, UART_RX_PIN,
                      cdone == 0 ? "configured" : "NOT configured",
                      (unsigned)ICE_USB_UART0_CDC);

    tud_cdc_n_write(LOG_CDC, msg, (uint32_t)n);
    tud_cdc_n_write_flush(LOG_CDC);
}

int main(void)
{
    uart_init(uart0, FPGA_BAUD);
    gpio_set_function(UART_TX_PIN, GPIO_FUNC_UART);
    gpio_set_function(UART_RX_PIN, GPIO_FUNC_UART);
    uart_set_hw_flow(uart0, false, false);
    uart_set_format(uart0, 8, 1, UART_PARITY_NONE);
    uart_set_fifo_enabled(uart0, true);

    ice_usb_init();

    ice_fpga_init(FPGA_DATA, FPGA_CLK_HZ);
    ice_fpga_start(FPGA_DATA);

    tud_cdc_rx_cb_table[ICE_USB_UART0_CDC] = &cdc_to_uart0_blocking;

    irq_set_enabled(UART0_IRQ, false);
    irq_remove_handler(UART0_IRQ, irq_get_exclusive_handler(UART0_IRQ));
    irq_set_exclusive_handler(UART0_IRQ, uart0_rx_to_ring);
    irq_set_enabled(UART0_IRQ, true);
    uart_set_irq_enables(uart0, true, false);

    log_banner(ice_fpga_configured(FPGA_DATA));

    while (true) {
        tud_task();
        drain_ring_to_cdc();
    }
    return 0;
}
