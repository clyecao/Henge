#ifndef HENGE_TEST_INVALID_ENCODINGS_H
#define HENGE_TEST_INVALID_ENCODINGS_H

#include <stdint.h>

/* Raw words are intentional: an assembler must refuse these encodings. */
static const uint32_t invalid_encodings[] = {
    0xff0c0c0c, 0xff080808, 0xff060608, 0xff09090b, /* previous SIGILL log */
    0xff000002, 0xff111113, 0xffffffff,
    0x0ee08420, /* ADD vector: size=64 with Q=0 */
    0x5e208420, /* ADD scalar: size must be 64 */
    0x0e000400, /* DUP: imm5=0 */
    0x0e100c00, /* DUP general: 64-bit elements with Q=0 */
    0x2e024020, /* EXT .8b: byte index 8 is out of range */
    0x1ea22820, /* FADD: reserved FP type */
    0x1e622021, /* FCMP: reserved low opcode bit */
    0x1e580020, /* FCVTZS W: fixed-point scale outside 1..32 */
    0x2f400420, /* USHR vector: 64-bit elements with Q=0 */
    0x0bc20020, /* ADD shifted: ROR is reserved */
    0x0b028020, /* ADD W: shift amount >=32 */
    0x8b225420, /* ADD extended: shift amount >4 */
    0x0a028020, /* AND W: shift amount >=32 */
    0x12400020, /* logical immediate W: N=1 */
    0x1200fc20, /* logical immediate: all-one element */
    0x52c00000, /* MOVZ W: halfword selector 2 */
    0xb2800000, /* move wide: reserved opc */
    0x93400020 ^ (1u << 22), /* bitfield: sf != N */
    0x13008020, /* bitfield W: imms >=32 */
    0x13808020, /* EXTR W: lsb >=32 */
    0x9ac01020, /* data-processing 2 source: unallocated opcode */
    0xfa401010, /* CCMP: reserved bit 4 */
    0xd503301f, /* unallocated barrier opcode */
    0xd50331ff, /* SB: reserved CRm bit */
    0x1e634020, /* BF16: not in the supported Apple M1 baseline */
};

#endif
