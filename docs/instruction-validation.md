# Instruction encoding validation

Native ALU, SIMD and floating-point copies now require a valid encoding for
the existing Apple M1 baseline before entering the JIT region. Matching the
top-level instruction group alone is insufficient: reserved operand sizes,
immediates and opcode bits can otherwise cause a host SIGILL. Reserved barrier
forms are rejected too; DSB nXS is not enabled because FEAT_XS is not exposed.

Rejected instructions use the existing `HV_OP_UNDEF` path. They terminate the
translated block and deliver a guest synchronous exception with EC=0, IL=1
and ELR pointing at the offending guest instruction. Classification also gates
the grouping planner and superblock translation, before the FP-disabled trap
check. No instruction after the fault may execute.

The check runs during translation, not on each execution of cached code.
`core/encoding_table.h` is a roughly 7 KiB read-only decision diagram. Normal
builds need neither LLVM nor VIXL libraries. The table combines the pinned
VIXL 8.0.0 form masks with LLVM 18.1.3's `apple-m1` decoder; every remaining
non-register field combination is enumerated offline. Fixed low opcode bits
are retained. This also excludes extensions absent on the baseline host.

To regenerate or verify the table on a machine with LLVM 18.1.3:

```sh
python3 tools/gen_encoding_table.py --llvm /usr/lib/llvm-18/lib/libLLVM.so
python3 tools/gen_encoding_table.py --llvm /usr/lib/llvm-18/lib/libLLVM.so --check
python3 tests/check_encoding_table.py --llvm /usr/lib/llvm-18/lib/libLLVM.so
```

`make test-encoding` works without an Apple SDK. It covers valid instructions,
reserved fields and all 16,777,216 words beginning with `0xff`, including the
words in the reported crash. On Apple Silicon, `make test-engine` also checks
guest exception state and absence of later side effects at EL0/EL1, with FP
enabled/disabled, direct chaining, superblocks and flat emission. Actions runs
the exception test again with split JIT mappings and reclaimed-memory poisoning.

This closes the native-copy validation gap; it is not a complete audit of every
privileged instruction's emulation. It cannot identify data that happens to be
a valid instruction, or explain why guest execution entered apparent pixel
data. A guest process or kernel may still terminate when it receives an
undefined-instruction exception. Wallpaper panic/black-screen reports need
separate investigation.
