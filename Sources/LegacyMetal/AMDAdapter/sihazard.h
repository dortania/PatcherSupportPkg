// sihazard.h: fixes for Southern Islands code from the 12.5 AMD shader compiler (sihazard.c): SALU -> s_buffer_load
// wait states, and L1 bypass for loads from memory the shader also writes.
#pragma once
#include <stdbool.h>
#include <stdint.h>

// Returns a malloc'd copy of `code` with the missing wait states inserted (*newBytes long, branch offsets adjusted), or
// NULL when nothing needs to change or the code can't be rewritten safely. *inserted = number of s_nop instructions
// inserted; *unsupported = why the code was left alone, if it had to be.
uint32_t *siFixBufferLoadHazards(const uint32_t *code, uint32_t bytes, uint32_t *newBytes, unsigned *inserted,
                                 const char **unsupported);

// Sets GLC (bypass the vector L1) in place on loads from buffers the shader also writes (same descriptor SGPRs as a
// store or atomic) and on image loads in shaders that store to images. Returns the number of loads changed (0 and
// *unsupported set when the code can't be decoded completely).
unsigned siBypassL1ForWrittenResources(uint32_t *code, uint32_t bytes, const char **unsupported);
