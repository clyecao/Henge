#include "classify.h"
#include "invalid_encodings.h"

#include <stdio.h>

static int failures;

static void check(uint32_t word, HvInsnKind want) {
    HvInsnKind got = hv_classify(word);
    if (got != want) {
        fprintf(stderr, "%08x: %s, expected %s\n", word, hv_insn_kind_name(got), hv_insn_kind_name(want));
        failures++;
    }
}

int main(void) {
    /* Assembled with LLVM's Apple M1 target; include stolen GPRs and the
       optional FP16/crypto/FlagM/FCMA/FHM instructions exposed to macOS. */
    static const uint32_t valid[] = {
        0x8b020020, 0x8b27d3e6, 0x3100078f, 0x92089e5c, 0x138f7cc7, 0x72bfffe6,
        0x131f7cc7, 0xfa4f138f, 0xba1f84cf, 0x3a000b8d, 0x1e622820, 0x1ee22820,
        0x9eae001c, 0x9eaf0381, 0x1e622020, 0x1e602038, 0x9e580026, 0x1e4280e1,
        0x1e7e0026, 0x1e684041, 0x4e228420, 0x6f400420, 0x4e183c3c, 0x0e1f2c27,
        0x4e181f80, 0x2e023820, 0x4fa21820, 0x6f827820, 0x4e829420, 0x4e22ec20,
        0x4e284820, 0x0ee2e020, 0x5e024020, 0xce628020, 0xce020c20, 0x9adc4ce6,
        0x9b427c20, 0x9bc27c20, /* SMULH, UMULH with the required Ra=31 */
    };
    for (unsigned i = 0; i < sizeof valid / sizeof *valid; i++) check(valid[i], HV_INSN_COPY);
    for (unsigned i = 0; i < sizeof invalid_encodings / sizeof *invalid_encodings; i++)
        check(invalid_encodings[i], HV_INSN_UNDEFINED);
    check(0xd50330ff, HV_INSN_BARRIER); /* SB */
    check(0xd5033f9f, HV_INSN_BARRIER); /* DSB SY */
    check(0xd5033fbf, HV_INSN_BARRIER); /* DMB SY */
    check(0xd5033fdf, HV_INSN_BARRIER); /* ISB */
    check(0xd5033f5f, HV_INSN_BARRIER); /* CLREX */
    check(0xd503201f, HV_INSN_COPY);    /* NOP */
    check(0xd503245f, HV_INSN_COPY);    /* BTI C */
    check(0xd50320ff, HV_INSN_PAC);     /* XPACLRI */

    /* Every possible opaque BGRA-like word, not a blacklist of logged colors. */
    for (uint32_t low = 0; low < (1u << 24); low++) {
        uint32_t word = 0xff000000 | low;
        if (hv_classify(word) != HV_INSN_UNDEFINED) {
            check(word, HV_INSN_UNDEFINED);
            break;
        }
    }
    printf("Encoding validation: valid ALU/FP/SIMD/extensions, reserved fields and all 2^24 FF-prefixed words; %d failures\n", failures);
    return failures != 0;
}
