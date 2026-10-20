#include "protector/cpu.h"

/*
 * Establish the retail Wii low-memory ABI that IOS and the apploader normally
 * leave for a main DOL. RBNEG9's TMD requests IOS21, whose MEM2 reservation
 * ends at 0x933E0000. These are guest-visible platform facts, not a serialized
 * emulator state.
 */
void protector_prepare_wii_boot(CPUState* cpu) {
    if (!cpu) {
        return;
    }

    cpu->msr = 0x00002032u;
    cpu->hid2 = 0xE0000000u;
    cpu->gpr[1] = 0x8004D4BCu;

    mem_write32(cpu, 0x80000020u, 0x0D15EA5Eu);
    mem_write32(cpu, 0x80000024u, 0x00000001u);
    mem_write32(cpu, 0x80000028u, GC_MAIN_RAM_SIZE);
    mem_write32(cpu, 0x8000002Cu, 0x00000023u);
    mem_write32(cpu, 0x80000030u, 0u);
    mem_write32(cpu, 0x80000034u, 0x817FEC60u);
    mem_write32(cpu, 0x800000F0u, GC_MAIN_RAM_SIZE);
    mem_write32(cpu, 0x800000F4u, 0x8179B500u);
    mem_write32(cpu, 0x800000F8u, 0x0E7BE2C0u);
    mem_write32(cpu, 0x800000FCu, 0x2B73A840u);

    mem_write32(cpu, 0x80003100u, GC_MAIN_RAM_SIZE);
    mem_write32(cpu, 0x80003104u, GC_MAIN_RAM_SIZE);
    mem_write32(cpu, 0x80003108u, 0x81800000u);
    mem_write32(cpu, 0x8000310Cu, 0u);
    mem_write32(cpu, 0x80003110u, 0u);
    mem_write32(cpu, 0x80003118u, WII_MEM2_SIZE);
    mem_write32(cpu, 0x8000311Cu, WII_MEM2_SIZE);
    mem_write32(cpu, 0x80003120u, 0x93400000u);
    mem_write32(cpu, 0x80003124u, 0x90000800u);
    mem_write32(cpu, 0x80003128u, 0x933E0000u);
    mem_write32(cpu, 0x80003130u, 0x933E0000u);
    mem_write32(cpu, 0x80003134u, 0x93400000u);
    mem_write32(cpu, 0x80003138u, 0x00000011u);
    mem_write32(cpu, 0x80003140u, 0x0015040Fu);
    mem_write32(cpu, 0x80003148u, 0x933E0000u);
    mem_write32(cpu, 0x8000314Cu, 0x93400000u);
    mem_write32(cpu, 0x80003158u, 0x0000FF01u);
    mem_write32(cpu, 0x800030D8u, 0xFFFFFFFFu);
    mem_write16(cpu, 0x800030E6u, 0x8201u);
    mem_write8(cpu, 0x8000315Cu, 0x80u);
    mem_write16(cpu, 0x8000315Eu, 0x0113u);
    mem_write32(cpu, 0x80003184u, 0x80000000u);

    for (u32 address = 0x80003000u;
         address <= 0x80003038u;
         address += 4u) {
        mem_write32(cpu, address, 0u);
    }
}
