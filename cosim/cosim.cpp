// Lockstep co-simulation: steps Spike once for every instruction the core retires,
// and stops at the first difference
//
//   Vcosim_top <elf> [+memlatency=N] [+stallrate=N] [+timeout=cycles]
//
// Run it from the folder holding the program's hex images, like the other simulators

#include "Vcosim_top.h"
#include <verilated.h>

#include <riscv/cfg.h>
#include <riscv/processor.h>
#include <riscv/simif.h>
#include <fesvr/elfloader.h>
#include <fesvr/memif.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <vector>

// The simulation top's memory map: IMEM, DMEM (with MMIO at its top) and SDRAM
struct region {
    uint32_t base;
    std::vector<char> bytes;
};

class memory : public simif_t, public chunked_memif_t {
public:
    std::vector<region> regions = {
        {0x00010000, std::vector<char>(0x10000)},
        {0x00020000, std::vector<char>(0x10000)},
        {0x80000000, std::vector<char>(0x100000)},
    };
    cfg_t cfg;
    std::map<size_t, processor_t*> harts;

    char* addr_to_mem(reg_t addr) override {
        for (auto& r : regions)
            if (addr >= r.base && addr < r.base + r.bytes.size())
                return &r.bytes[addr - r.base];
        return nullptr;
    }

    // Nothing outside the memory map exists, so Spike raises an access fault
    bool mmio_load(reg_t, size_t, uint8_t*) override { return false; }
    bool mmio_store(reg_t, size_t, const uint8_t*) override { return false; }
    void proc_reset(unsigned) override {}
    const cfg_t& get_cfg() const override { return cfg; }
    const std::map<size_t, processor_t*>& get_harts() const override { return harts; }
    const char* get_symbol(uint64_t) override { return nullptr; }

    // For Spike's ELF loader
    void read_chunk(addr_t addr, size_t len, void* dst) override {
        for (size_t i = 0; i < len; i++) ((char*)dst)[i] = *addr_to_mem(addr + i);
    }
    void write_chunk(addr_t addr, size_t len, const void* src) override {
        for (size_t i = 0; i < len; i++) {
            char* p = addr_to_mem(addr + i);
            if (p) *p = ((const char*)src)[i];
        }
    }
    void clear_chunk(addr_t addr, size_t len) override {
        for (size_t i = 0; i < len; i++) {
            char* p = addr_to_mem(addr + i);
            if (p) *p = 0;
        }
    }
    size_t chunk_align() override { return 4; }
    size_t chunk_max_size() override { return 4096; }

    uint32_t word(uint32_t addr) {
        uint32_t v = 0;
        for (int i = 0; i < 4; i++) {
            char* p = addr_to_mem(addr + i);
            v |= (uint32_t)(uint8_t)(p ? *p : 0) << (8 * i);
        }
        return v;
    }
};

static uint32_t plusarg(const char* name, uint32_t fallback) {
    const char* match = Verilated::commandArgsPlusMatch(name);
    const char* eq = std::strchr(match, '=');
    return eq ? (uint32_t)std::strtoul(eq + 1, nullptr, 0) : fallback;
}

// Values the two are free to disagree on: cycle counts (as CSRs or MMIO words) and
// the ID registers, whose values each implementation chooses
static bool is_impl_defined_read(uint32_t insn, uint32_t mem_addr, uint32_t rmask) {
    uint32_t opcode = insn & 0x7f, funct3 = (insn >> 12) & 7, csr = insn >> 20;
    if (opcode == 0x73 && funct3 != 0)
        return csr == 0xB00 || csr == 0xB80 || csr == 0xC00 || csr == 0xC80 ||
               (csr >= 0xF11 && csr <= 0xF13);
    return opcode == 0x03 && rmask && (mem_addr == 0x0002FFF0 || mem_addr == 0x0002FFF4);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2 || argv[1][0] == '+') {
        std::cerr << "usage: Vcosim_top <elf> [+memlatency=N] [+stallrate=N] [+timeout=N]\n";
        return 2;
    }

    memory mem;
    mem.cfg.isa = "rv32im_zicsr_zicntr";
    mem.cfg.priv = "m";
    mem.cfg.pmpregions = 0;
    mem.cfg.trigger_count = 0;

    memif_t memif(&mem);
    reg_t entry;
    load_elf(argv[1], &memif, &entry, 0);

    processor_t spike(mem.cfg.isa, mem.cfg.priv, &mem.cfg, &mem, 0, false, nullptr, std::cerr);
    mem.harts[0] = &spike;
    state_t* s = spike.get_state();
    s->pc = 0x00010000;                 // the core's reset PC

    Vcosim_top top;
    top.mem_delay = plusarg("memlatency=", 0);
    top.stall_rate = plusarg("stallrate=", 0);
    uint32_t timeout = plusarg("timeout=", 2000000);

    uint32_t regs[32] = {0};            // the core's registers, rebuilt from RVFI
    uint64_t retired = 0;

    auto fail = [&](const char* what, uint32_t core, uint32_t ref) {
        std::printf("MISMATCH after %llu instructions, at pc %08x (insn %08x): %s: core %08x, spike %08x\n",
                    (unsigned long long)retired, top.rvfi_pc_rdata, top.rvfi_insn, what, core, ref);
        std::exit(1);
    };

    top.reset = 1;
    for (uint32_t cycle = 0; cycle < timeout; cycle++) {
        if (cycle == 10) top.reset = 0;
        top.clk = 1;
        top.eval();

        if (!top.reset && top.rvfi_valid) {
            if ((uint32_t)s->pc != top.rvfi_pc_rdata) fail("pc", top.rvfi_pc_rdata, s->pc);
            uint32_t insn = mem.word(top.rvfi_pc_rdata);
            if (insn != top.rvfi_insn) fail("instruction", top.rvfi_insn, insn);

            spike.step(1);
            retired++;

            if ((uint32_t)s->pc != top.rvfi_pc_wdata) fail("next pc", top.rvfi_pc_wdata, s->pc);

            uint32_t rd = top.rvfi_rd_addr;
            if (rd) {
                regs[rd] = top.rvfi_rd_wdata;
                if (is_impl_defined_read(top.rvfi_insn, top.rvfi_mem_addr, top.rvfi_mem_rmask))
                    s->XPR.write(rd, regs[rd]);
            }
            for (int i = 1; i < 32; i++) {
                if ((uint32_t)s->XPR[i] != regs[i]) {
                    char what[8];
                    std::snprintf(what, sizeof what, "x%d", i);
                    fail(what, regs[i], (uint32_t)s->XPR[i]);
                }
            }

            for (int b = 0; b < 4; b++) {
                if (!(top.rvfi_mem_wmask >> b & 1)) continue;
                uint32_t addr = top.rvfi_mem_addr + b;
                char* p = mem.addr_to_mem(addr);
                uint8_t core = top.rvfi_mem_wdata >> (8 * b), ref = p ? *p : 0;
                if (core != ref) fail("stored byte", core, ref);
            }
        }

        top.clk = 0;
        top.eval();
        if (top.halt) {
            std::printf("%llu instructions match\nTOHOST=%u\n", (unsigned long long)retired,
                        mem.word(0x0002FFC0));
            return 0;
        }
    }
    std::printf("TIMEOUT after %u cycles, %llu instructions matched\n", timeout,
                (unsigned long long)retired);
    return 1;
}
