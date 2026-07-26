#include <verilated.h>          // Defines common routines
#include <iostream>             // Need std::cout
#include <cstdlib>
#include "Vtop.h"               // From Verilating "top.v"
#if VM_COVERAGE
# include <verilated_cov.h>
#endif

Vtop *top;                      // Instantiation of module

vluint64_t main_time = 0;       // Current simulation time
// This is a 64-bit integer to reduce wrap over issues and
// allow modulus.  This is in units of the timeprecision
// used in Verilog (or from --timescale-override)

double sc_time_stamp () {       // Called by $time in Verilog
    return main_time;           // converts to double, to match
                               // what SystemC does
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);   // Remember args

    top = new Vtop;             // Create instance

    top->reset = 1;           // Set some inputs

    // Same knob as the iverilog testbench's +stallrate.
    top->stall_rate = 0;
    if (const char *sr = std::getenv("RV32_STALL_RATE"))
        top->stall_rate = (unsigned char)std::strtoul(sr, nullptr, 10);

    // Watchdog, so a program that never halts cannot hang a coverage sweep.
    vluint64_t max_time = 2000000;
    if (const char *env = std::getenv("RV32_MAX_CYCLES"))
        max_time = std::strtoull(env, nullptr, 10);

    while (!Verilated::gotFinish()) {
        if (main_time > 10)
            top->reset = 0;   // Deassert reset
        top->clk = 1;
        top->eval();
        top->clk = 0;
        top->eval();
        if (top->halt == 1)
            break;
        if (main_time > max_time) {
            std::cout << "TIMEOUT" << std::endl;
            break;
        }
        main_time++;            // Time passes...
    }

    top->final();               // Done simulating

#if VM_COVERAGE
    // One file per run; the Makefile merges them with verilator_coverage.
    const char *cov = std::getenv("RV32_COVERAGE_FILE");
    Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
#endif
    //    // (Though this example doesn't get here)
    delete top;
}
