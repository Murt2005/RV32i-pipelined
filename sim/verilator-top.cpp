#include <verilated.h>
#include <iostream>
#include <cstdlib>
#include <string>
#include "Vtop.h"
#if VM_COVERAGE
# include <verilated_cov.h>
#endif

// Takes the same plusargs as sim/itop.sv, plus +coverage=<file>

Vtop *top;

vluint64_t main_time = 0;

double sc_time_stamp () {
    return main_time;
}

// The value of +name=value, or "" when it is absent
static std::string plusarg(const char *name) {
    std::string match = Verilated::commandArgsPlusMatch(name);
    std::string prefix = std::string("+") + name;
    return match.rfind(prefix, 0) == 0 ? match.substr(prefix.size()) : "";
}

static unsigned long long plusarg_num(const char *name, unsigned long long dflt) {
    std::string v = plusarg(name);
    return v.empty() ? dflt : std::strtoull(v.c_str(), nullptr, 10);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    top = new Vtop;

    top->reset = 1;
    top->stall_rate = (unsigned char)plusarg_num("stallrate=", 0);
    top->mem_delay = (unsigned char)plusarg_num("memlatency=", 0);
    vluint64_t max_time = plusarg_num("timeout=", 2000000);

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
    std::string cov = plusarg("coverage=");
    Verilated::threadContextp()->coveragep()->write(cov.empty() ? "coverage.dat" : cov.c_str());
#endif
    delete top;
}
