#include <verilated.h>
#include <iostream>
#include <cstdlib>
#include "Vtop.h"
#if VM_COVERAGE
# include <verilated_cov.h>
#endif

Vtop *top;

vluint64_t main_time = 0;

double sc_time_stamp () {
    return main_time;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    top = new Vtop;

    top->reset = 1;

    top->stall_rate = 0;
    if (const char *sr = std::getenv("RV32_STALL_RATE"))
        top->stall_rate = (unsigned char)std::strtoul(sr, nullptr, 10);

    top->mem_delay = 0;
    if (const char *md = std::getenv("RV32_MEM_LATENCY"))
        top->mem_delay = (unsigned char)std::strtoul(md, nullptr, 10);

    vluint64_t max_time = 2000000;
    if (const char *env = std::getenv("RV32_MAX_CYCLES"))
        max_time = std::strtoull(env, nullptr, 10);

    while (!Verilated::gotFinish()) {
        if (main_time > 10)
            top->reset = 0;
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
        main_time++;
    }

    top->final();

#if VM_COVERAGE
    const char *cov = std::getenv("RV32_COVERAGE_FILE");
    Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
#endif
    delete top;
}
