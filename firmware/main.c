/*
 * pico2-ice RP2350 bridge firmware for the RV32I pipelined processor.
 *
 * Forked from pico-ice-sdk/examples/rp2_usb_uart. Three jobs:
 *   1. Export the FPGA's clock (it has no crystal).
 *   2. Let the FPGA configure, and report whether it did.
 *   3. Bridge bytes between a USB CDC port and the FPGA's UART pins.
 *
 * Two things differ from the upstream example, both of which are wrong on this
 * board rather than merely suboptimal -- see the notes at each site.
 */

#include <stdio.h>
#include <string.h>

// pico-sdk
#include "pico/stdlib.h"
#include "hardware/irq.h"
#include "hardware/gpio.h"
#include "hardware/uart.h"

// pico-ice-sdk
#include "ice_usb.h"
#include "ice_fpga.h"

#include "tusb.h"

/*
 * The FPGA UART pins.
 *
 * The upstream example hardcodes GPIO0/GPIO1. On pico2-ice those are the
 * onboard LEDs (pico2_ice.h: ICE_LED_GREEN_PIN 0, ICE_LED_RED_PIN 1), so the
 * example produces total silence on both CDC ports.
 *
 * pico2_ice.h leaves ICE_UART_TX/ICE_UART_RX defined as 255, i.e. unrouted, so
 * these come from the schematic (Board/Rev1/pico2-ice.pdf), cross-checked
 * against pico-ice-sdk/rtl/pico2_ice.pcf:
 *
 *   RP2350 GPIO28 (uart0 TX) -> net ICE_9  -> iCE40 pin 9  = FPGA rx_pin
 *   RP2350 GPIO29 (uart0 RX) <- net ICE_11 <- iCE40 pin 11 = FPGA tx_pin
 */
#define UART_TX_PIN 28
#define UART_RX_PIN 29

/*
 * MUST match fpga/ice40/Makefile's CLK_FREQ and BAUD_RATE. The FPGA's baud
 * divisor is a synthesis-time constant, so a mismatch garbles bytes rather
 * than producing silence.
 *
 * 12 MHz, not the SDK's 48 MHz default: it is the crystal frequency exactly, so
 * ice_fpga_init() passes XOSC straight through with divisor 1 and a clean 50%
 * duty cycle -- no fractional divider, so no jitter on the FPGA's only clock.
 * 1 Mbaud is then an exact /12 of it.
 *
 * The design's post-place-and-route fMax is 13.1 MHz, so this runs with about
 * 9% static margin. That is thinner than ideal, which is why the 12 MHz build
 * is validated on silicon (full regression plus randomised differential
 * testing) rather than on the timing estimate alone.
 */
#define FPGA_CLK_HZ   AS_MHZ(12)
#define FPGA_BAUD     1000000

/* Declared in ice_fpga.c but not exported by ice_fpga.h. */
extern int ice_fpga_configured(const ice_fpga fpga);

/* Installed by ice_usb.c; we overwrite our entry to fix the dropped-byte bug. */
extern void (*tud_cdc_rx_cb_table[])(uint8_t);

/* --------------------------------------------------------------------------
 * Fix 1: host -> FPGA. The SDK's bridge is
 *     if (uart_is_writable(uart0)) uart_putc(uart0, byte);
 * which silently discards the byte once the RP2350's 32-deep UART TX FIFO is
 * full. Program images are kilobytes, so this would corrupt every load.
 *
 * Blocking instead lets TinyUSB's CDC flow control NAK the host, which is the
 * backpressure that actually exists in this path.
 * -------------------------------------------------------------------------- */
static void cdc_to_uart0_blocking(uint8_t byte)
{
    uart_putc_raw(uart0, byte);
}

/* --------------------------------------------------------------------------
 * Fix 2: FPGA -> host. The SDK services this from the UART0 RX interrupt and
 * calls tud_cdc_n_write_char()/tud_cdc_n_write_flush() there. Under
 * CFG_TUSB_OS=OPT_OS_NONE TinyUSB has no locking, so that races the main
 * loop's tud_task() and can wedge CDC and DFU together, needing a power cycle.
 *
 * Demote the ISR to a ring-buffer producer and drain from the main loop, so
 * there is exactly one TinyUSB caller.
 * -------------------------------------------------------------------------- */
#define RING_SIZE 4096                      /* power of two */
#define RING_MASK (RING_SIZE - 1)

static volatile uint8_t  ring[RING_SIZE];
static volatile uint32_t ring_head;         /* written by ISR  */
static volatile uint32_t ring_tail;         /* written by main */
static volatile uint32_t ring_overruns;

static void uart0_rx_to_ring(void)
{
    while (uart_is_readable(uart0)) {
        uint8_t  b    = (uint8_t)uart_getc(uart0);
        uint32_t head = ring_head;
        uint32_t next = (head + 1) & RING_MASK;

        if (next == ring_tail) {
            ring_overruns++;                /* drop, but count it */
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

/* --------------------------------------------------------------------------
 * Startup banner on the *other* CDC port (the one not bridged to the FPGA).
 *
 * This is where the real CDONE check is surfaced. The DFU manifest callback
 * reports the result of ice_fpga_start(), which unconditionally returns 0
 * without ever polling CDONE -- which is why dfu-util prints "Device's
 * firmware is corrupt" on every successful flash. ice_fpga_configured() is the
 * honest answer.
 *
 * The RGB LED is deliberately left alone: it is wired to both chips, and the
 * gateware drives it (heartbeat / running / halted). Driving it from here too
 * would be contention.
 * -------------------------------------------------------------------------- */
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

    /* Enumerates 2x CDC-ACM + DFU, and installs its own UART0 IRQ handler. */
    ice_usb_init();

    ice_fpga_init(FPGA_DATA, FPGA_CLK_HZ);
    ice_fpga_start(FPGA_DATA);

    /* Apply fix 1: replace the SDK's dropping CDC->UART callback. */
    tud_cdc_rx_cb_table[ICE_USB_UART0_CDC] = &cdc_to_uart0_blocking;

    /* Apply fix 2: take over UART0's RX interrupt from the SDK. */
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
