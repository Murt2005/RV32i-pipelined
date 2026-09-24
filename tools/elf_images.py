"""Turn an ELF into the memory images the simulator and reference model load."""

import os
import subprocess
import tempfile


def find_objcopy():
    """The RISC-V objcopy, from site-config.sh if it names one"""
    cfg = os.path.join(os.path.dirname(__file__), "..", "site-config.sh")
    if os.path.exists(cfg):
        for line in open(cfg):
            if line.startswith("RISCV_PREFIX="):
                cand = line.split("=", 1)[1].strip() + "-objcopy"
                if os.path.exists(cand):
                    return cand
    for cand in ("riscv64-unknown-elf-objcopy", "riscv-none-embed-objcopy",
                 "riscv64-elf-objcopy"):
        try:
            subprocess.run([cand, "--version"], check=True, capture_output=True)
            return cand
        except (OSError, subprocess.CalledProcessError):
            continue
    raise RuntimeError("no RISC-V objcopy found; set RISCV_PREFIX in site-config.sh")


def elf_to_images(elf_path, objcopy=None):
    """Returns (text_bytes, data_bytes), split the same way as elftohex.sh"""
    objcopy = objcopy or find_objcopy()
    with tempfile.TemporaryDirectory(prefix="rv32elf-") as tmp:
        def extract(args, name):
            out = os.path.join(tmp, name)
            subprocess.run([objcopy] + args + [elf_path, out],
                           check=True, capture_output=True)
            with open(out, "rb") as f:
                return f.read()

        text = extract(["-j", ".text", "-O", "binary"], "text.bin")
        # .bss is zero by definition, and including it would pad the image
        data = extract(["-R", ".text", "-R", ".bss", "-O", "binary"], "data.bin")
    return text, data
