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


def section_image(elf_path, sections, objcopy=None):
    """The named sections as one flat image, or b"" if none of them exist"""
    objcopy = objcopy or find_objcopy()
    with tempfile.TemporaryDirectory(prefix="rv32elf-") as tmp:
        out = os.path.join(tmp, "region.bin")
        args = [objcopy, "-O", "binary"]
        for s in sections:
            args += ["-j", s]
        r = subprocess.run(args + [elf_path, out], capture_output=True)
        if r.returncode != 0 or not os.path.exists(out):
            return b""
        with open(out, "rb") as f:
            return f.read()


SDRAM_SECTIONS = [".text", ".rodata", ".data"]


def sdram_images(elf_path, objcopy=None):
    """Returns (boot_stub, sdram_image) for a program linked to run from SDRAM,
    or None if it has no .boot stub and so runs from on-chip memory"""
    boot = section_image(elf_path, [".boot"], objcopy)
    if not boot:
        return None
    return boot, section_image(elf_path, SDRAM_SECTIONS, objcopy)
