#include <verilated.h>          // Defines common routines
#include <iostream>             // Need std::cout
#include "Vtop.h"               // From Verilating "top.v"

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

    while (!Verilated::gotFinish()) {
        if (main_time > 10)
            top->reset = 0;   // Deassert reset
        top->clk = 1;
        top->eval();
        top->clk = 0;
        top->eval();
        if (top->halt == 1)
            break;
        main_time++;            // Time passes...
    }

    top->final();               // Done simulating
    //    // (Though this example doesn't get here)
    delete top;
}
