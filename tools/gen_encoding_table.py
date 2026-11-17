#!/usr/bin/env python3
"""Regenerate the copied-instruction validator; LLVM is a build-time tool only.

The pinned VIXL table identifies instruction forms and their fixed bits. LLVM
18.1.3's Apple M1 decoder checks every remaining non-register field combination,
including operand-size restrictions and optional host features. The result is a
reduced binary decision diagram, with no runtime disassembler or allocation.
"""

import argparse
import ctypes
import functools
import hashlib
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "third_party/vixl/decoder-constants-aarch64.h"
OUTPUT = ROOT / "core/encoding_table.h"
SOURCE_HASH = "07d8903eebc63c8cd7b942fc4778d97ca60511d9f63db99d13802d15099abb56"


def decoder(library):
    lib = ctypes.CDLL(library)
    version = [ctypes.c_uint() for _ in range(3)]
    lib.LLVMGetVersion(*(ctypes.byref(x) for x in version))
    if tuple(x.value for x in version) != (18, 1, 3):
        raise ValueError("Regeneration requires LLVM 18.1.3 for reproducible output")
    for part in ("TargetInfo", "Target", "TargetMC", "Disassembler"):
        getattr(lib, "LLVMInitializeAArch64" + part)()
    lib.LLVMCreateDisasmCPUFeatures.argtypes = [ctypes.c_char_p] * 3 + [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p]
    lib.LLVMCreateDisasmCPUFeatures.restype = ctypes.c_void_p
    lib.LLVMDisasmInstruction.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
        ctypes.c_uint64, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_size_t]
    lib.LLVMDisasmInstruction.restype = ctypes.c_size_t
    lib.LLVMDisasmDispose.argtypes = [ctypes.c_void_p]
    context = lib.LLVMCreateDisasmCPUFeatures(b"aarch64", b"apple-m1", b"", None, 0, None, None)
    if not context:
        raise ValueError("Cannot initialize the Apple M1 decoder")
    buffer = ctypes.create_string_buffer(512)

    def accepts(word):
        data = (ctypes.c_ubyte * 4).from_buffer_copy(word.to_bytes(4, "little"))
        return lib.LLVMDisasmInstruction(context, data, 4, 0, buffer, len(buffer)) == 4

    return accepts, lambda: lib.LLVMDisasmDispose(context)


def forms(source):
    pattern = re.compile(r'\{ "(\w+)",\s*\{([\d, ]+)\},\s*\{(.*?)\n    \},\s*\}', re.S)
    graph = {}
    for name, bits, rules in pattern.findall(source):
        bits = [int(x) for x in bits.split(",")]
        children = []
        for text, child in re.findall(r'\{"([01x]+)"_b, "(\w+)"\}', rules):
            assert len(text) == len(bits)
            mask = sum(1 << bit for bit, char in zip(bits, text) if char != "x")
            value = sum(1 << bit for bit, char in zip(bits, text) if char == "1")
            children.append((mask, value, child))
        assert children
        graph[name] = children
    assert len(graph) == source.count('  { "') == 1002

    def walk(name, mask=0, value=0):
        if name not in graph:
            group = (value >> 25) & 15
            if ((mask >> 25) & 15) == 15 and ((group & 14) == 8 or (group & 7) in (5, 7)):
                # These have dedicated translation paths, not native copies.
                if not name.startswith(("adr_", "adrp_", "pac", "aut", "xpac")):
                    yield mask, value, name
            return
        for child_mask, child_value, child in graph[name]:
            if (value ^ child_value) & mask & child_mask:
                continue
            yield from walk(child, mask | child_mask, value | child_value)

    return walk("Root")


def generate(source, accepts):
    nodes = [(-1, 0, 0), (-1, 1, 1)]  # false, true
    unique = {}

    def node(bit, no, yes):
        if no == yes:
            return no
        key = bit, no, yes
        if key not in unique:
            unique[key] = len(nodes)
            nodes.append(key)
        return unique[key]

    @functools.lru_cache(None)
    def union(a, b):
        if a == b or b == 0:
            return a
        if a == 0 or b == 1:
            return b
        if a == 1:
            return 1
        if a > b:
            return union(b, a)
        abit, an, ay = nodes[a]
        bbit, bn, by = nodes[b]
        bit = max(abit, bbit)
        if abit != bit:
            an = ay = a
        if bbit != bit:
            bn = by = b
        return node(bit, union(an, bn), union(ay, by))

    root = 0
    for mask, value, _ in forms(source):
        # Low ten bits are registers/immediates or fixed by the form. Preserve
        # ALL fixed bits, including FP compare opcodes and conditional NZCV.
        low = 1
        for bit in range(10):
            if mask >> bit & 1:
                low = node(bit, 0, low) if value >> bit & 1 else node(bit, low, 0)

        def descend(bit, word):
            if bit < 10:
                return low if accepts(word) else 0
            if mask >> bit & 1:
                child = descend(bit - 1, word)
                return node(bit, 0, child) if value >> bit & 1 else node(bit, child, 0)
            return node(bit, descend(bit - 1, word), descend(bit - 1, word | (1 << bit)))

        root = union(root, descend(31, value))

    compact = [(-1, 0, 0), (-1, 1, 1)]
    mapping = {0: 0, 1: 1}

    def pack(index):
        if index not in mapping:
            bit, no, yes = nodes[index]
            no, yes = pack(no), pack(yes)
            mapping[index] = len(compact)
            compact.append((bit, no, yes))
        return mapping[index]

    root = pack(root)
    assert len(compact) < 65536
    notice = source.split("\nnamespace vixl")[0]
    lines = [notice, "/* Generated by tools/gen_encoding_table.py; do not edit.",
        "   VIXL 8.0.0 + LLVM 18.1.3, apple-m1. See docs/instruction-validation.md. */",
        "#ifndef HENGE_ENCODING_TABLE_H", "#define HENGE_ENCODING_TABLE_H", "",
        "#include <stdint.h>", "",
        "static const struct { uint16_t child[2]; uint8_t bit; } hv_encoding_nodes[] = {",
        "    {{0, 0}, 0}, /* rejected */", "    {{1, 1}, 0}, /* accepted */"]
    lines += [f"    {{{{{no}, {yes}}}, {bit}}}," for bit, no, yes in compact[2:]]
    lines += ["};", f"#define HV_ENCODING_ROOT {root}", "", "#endif", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--llvm", required=True, help="path to LLVM 18.1.3's shared library")
    parser.add_argument("--check", action="store_true", help="verify the committed output")
    args = parser.parse_args()
    data = SOURCE.read_bytes()
    if hashlib.sha256(data).hexdigest() != SOURCE_HASH:
        raise ValueError("Unexpected VIXL input; review the decoder before updating its hash")
    accepts, close = decoder(args.llvm)
    try:
        output = generate(data.decode(), accepts)
    finally:
        close()
    if args.check:
        if OUTPUT.read_text() != output:
            raise SystemExit("encoding_table.h is out of date")
    else:
        OUTPUT.write_text(output)
    print(f"{'Verified' if args.check else 'Wrote'} {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
