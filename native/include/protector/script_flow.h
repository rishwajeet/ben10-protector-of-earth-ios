#ifndef PROTECTOR_SCRIPT_FLOW_H
#define PROTECTOR_SCRIPT_FLOW_H

#include "protector/cpu.h"

/* Source-derived metadata only: no original bytecode is embedded here. */
typedef struct ProtectorScriptFlowRule {
    const char* name;
    u32 name_offset;
    u32 file_info_size;
    u32 code_offset;
    u32 code_size;
    u32 from_offset;
    u32 to_offset;
    const u32* pointer_offsets;
    u32 pointer_count;
    u64 normalized_hash;
} ProtectorScriptFlowRule;

typedef struct ProtectorScriptFlowMatch {
    const ProtectorScriptFlowRule* rule;
    u32 file_info_base;
    u32 destination;
} ProtectorScriptFlowMatch;

/* Pure, bounded RAM inspection. No counters, faults, guest writes or CPU
 * state changes. The caller owns edition gating and the actual IP change. */
bool protector_script_flow_match(const CPUState* cpu, u32 instruction_pointer,
    const ProtectorScriptFlowRule* rule, ProtectorScriptFlowMatch* output);
bool protector_startup_flow_match(const CPUState* cpu, u32 instruction_pointer,
    ProtectorScriptFlowMatch* output);
const ProtectorScriptFlowRule* protector_startup_flow_rules(size_t* count);

#endif
