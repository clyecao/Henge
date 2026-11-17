#!/usr/bin/env python3
"""Optional LLVM differential check; no Apple SDK or guest images needed."""

import argparse
import ctypes
import importlib.util
from pathlib import Path
import random
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("generator", ROOT / "tools/gen_encoding_table.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--llvm", required=True)
    args = parser.parse_args()
    accepts, close = generator.decoder(args.llvm)
    tested = copied = 0
    try:
        with tempfile.TemporaryDirectory(prefix="henge-encoding-") as directory:
            library = Path(directory) / "classify.so"
            subprocess.run(["clang", "-std=c11", "-O2", "-shared", "-fPIC",
                str(ROOT / "core/classify.c"), "-o", str(library)], check=True)
            implementation = ctypes.CDLL(str(library))
            classify = implementation.hv_classify
            classify.argtypes = [ctypes.c_uint32]
            classify.restype = ctypes.c_int

            def check(word):
                nonlocal tested, copied
                tested += 1
                if classify(word) == 0:  # HV_INSN_COPY: must be executable on the baseline host.
                    copied += 1
                    if not accepts(word):
                        raise AssertionError(f"Illegal instruction copied: {word:08x}")

            random_words = random.Random(138)
            for _ in range(1_000_000):
                check(random_words.getrandbits(32))
            # Exercise operand fields intentionally omitted from generation's
            # enumeration. Fixed low opcode bits are retained, not guessed.
            for mask, value, _ in generator.forms(generator.SOURCE.read_text()):
                free = ~mask & 0xffffffff
                candidates = [value, value | free]
                candidates += [value | (random_words.getrandbits(32) & free) for _ in range(32)]
                for word in candidates:
                    check(word)
                representative = next((word for word in candidates if accepts(word)), None)
                if representative is not None:
                    for low in range(1024):
                        word = (representative & ~0x3ff) | (value & 0x3ff) | (low & free)
                        check(word)
    finally:
        close()
    print(f"LLVM differential check: {tested} words, {copied} native copies, no illegal copies")


if __name__ == "__main__":
    main()
