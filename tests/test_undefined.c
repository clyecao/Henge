#include "dispatch.h"
#include "invalid_encodings.h"

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static HvMachine machine;
static HvCpu cpu;
static int failures, checks;

static void check(const char *what, uint64_t got, uint64_t want, uint32_t word) {
    checks++;
    if (got != want) {
        fprintf(stderr, "%08x: %s = %llx, expected %llx\n", word, what,
                (unsigned long long)got, (unsigned long long)want);
        failures++;
    }
}

int main(void) {
    alarm(120);
    setvbuf(stdout, NULL, _IONBF, 0);
    const uint64_t pa = 0x10000, vbar = 0x18000;
    uint32_t *ram = aligned_alloc(16384, 65536);
    if (!ram || hv_machine_init(&machine, 4 << 20)) return 1;
    unsigned count = sizeof invalid_encodings / sizeof *invalid_encodings;
    for (unsigned i = 0; i < count; i++) {
        uint32_t *p = ram + i * 8;
        p[0] = 0xd2800020; /* mov x0, #1 */
        p[1] = 0x14000001; /* b next: chained block entry */
        p[2] = 0xb5000063; /* cbnz x3, end: fall through, optionally a superblock */
        p[3] = invalid_encodings[i];
        p[4] = 0xd2800040; /* mov x0, #2: must never execute */
        p[5] = 0xd503201f;
    }
    hv_machine_add_ram(&machine, pa, 65536, ram, 1);
    for (int mode = 0; mode < 4; mode++) {
        machine.chain = mode != 0;
        machine.slow_mem = mode == 0;
        hv_knob[HV_K_SUPERBLOCKS] = mode >= 2;
        hv_knob[HV_K_TEST2] = mode == 3; /* flat emission, too */
        hv_flush_blocks(&machine); /* no CPUs running; discard the previous mode's translations */
        for (unsigned i = 0; i < count; i++) {
            uint64_t start = pa + i * 32, fault = start + 12;
            for (int el = 0; el <= 1; el++) for (int fp = 0; fp <= 1; fp++) for (int head = 0; head <= 1; head++) {
                hv_cpu_reset(&cpu, &machine);
                cpu.el = el;
                cpu.spsel = el;
                cpu.cpacr_el1 = fp ? 3ull << 20 : 0;
                cpu.pc = head ? fault : start;
                cpu.vbar_el1 = vbar;
                cpu.sp = pa + 0xc000;
                cpu.sp_el1 = pa + 0xf000;
                cpu.x[0] = 99;
                machine.stop_pc = vbar + (el ? 0x200 : 0x400);
                machine.stop_pc2 = start + 20; /* fail cleanly if an encoding is incorrectly treated as a NOP */
                uint64_t before = machine.stats.exceptions;
                int result = hv_run(&cpu);
                check("reaches exception vector", cpu.pc, machine.stop_pc, invalid_encodings[i]);
                check("returns at stop PC", result, HV_EXIT_HALT, invalid_encodings[i]);
                check("undefined ESR, even with FP disabled", cpu.esr_el1, 0x02000000, invalid_encodings[i]);
                check("faulting guest PC", cpu.elr_el1, fault, invalid_encodings[i]);
                check("no instruction after the fault executes", cpu.x[0], head ? 99 : 1, invalid_encodings[i]);
                check("one guest exception", machine.stats.exceptions - before, 1, invalid_encodings[i]);
                check("saved source EL", cpu.spsr_el1 & 15, el ? 5 : 0, invalid_encodings[i]);
            }
        }
    }
    hv_machine_free(&machine);
    free(ram);
    printf("Undefined instruction delivery: %d checks, %d failures (EL0/EL1, FP on/off, chains, superblocks, flat emission)\n", checks, failures);
    return failures != 0;
}
