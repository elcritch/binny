# SFrame Library Usage Guide

This guide demonstrates how to use the SFrame library from binutils-gdb for stack tracing applications.

## Overview

SFrame (Simple Frame format) is a lightweight stack unwinding format designed for generating stack traces efficiently. It tracks minimal information needed for unwinding:
- Canonical Frame Address (CFA)
- Frame Pointer (FP)
- Return Address (RA)

## Library Structure

The SFrame library is located at `deps/binutils-gdb/libsframe/` and includes:

- **Core files:**
  - `sframe.c` - Main library implementation
  - `sframe-error.c` - Error handling
  - `sframe-dump.c` - Debugging utilities

- **Headers:**
  - `deps/binutils-gdb/include/sframe-api.h` - Public API
  - `deps/binutils-gdb/include/sframe.h` - Format definitions
  - `deps/binutils-gdb/libsframe/sframe-impl.h` - Internal implementation

## Building libsframe

### Method 1: Using the provided build script

```bash
./build_sframe_example.sh
```

### Method 2: Manual build

```bash
cd deps/binutils-gdb/libsframe
./configure --disable-shared --enable-static
make -j$(nproc)
```

### Method 3: Using Makefile

```bash
make -f Makefile.sframe libsframe
```

## Linking Against libsframe

### Compiler Flags

```bash
# Include paths
INCLUDES = -Ideps/binutils-gdb/include \
           -Ideps/binutils-gdb/libsframe \
           -Ideps/binutils-gdb/libctf \
           -Ideps/binutils-gdb/bfd

# Library path
SFRAME_LIB = deps/binutils-gdb/libsframe/.libs/libsframe.a

# Complete compilation command
gcc -g -O2 $INCLUDES -o your_program your_program.c $SFRAME_LIB
```

### CMakeLists.txt Example

```cmake
# Find SFrame headers
find_path(SFRAME_INCLUDE_DIR NAMES sframe-api.h
          PATHS deps/binutils-gdb/include)

# Find SFrame library
find_library(SFRAME_LIBRARY NAMES sframe
             PATHS deps/binutils-gdb/libsframe/.libs)

# Set up target
add_executable(your_program your_program.c)
target_include_directories(your_program PRIVATE ${SFRAME_INCLUDE_DIR})
target_link_libraries(your_program ${SFRAME_LIBRARY})
```

## API Usage

### Key Data Structures

```c
#include "deps/binutils-gdb/include/sframe-api.h"

// Opaque contexts
typedef struct sframe_decoder_ctx sframe_decoder_ctx;
typedef struct sframe_encoder_ctx sframe_encoder_ctx;

// Frame Row Entry (user-facing)
typedef struct sframe_frame_row_entry {
    uint32_t fre_start_addr;
    unsigned char fre_offsets[MAX_OFFSET_BYTES];
    unsigned char fre_info;
} sframe_frame_row_entry;
```

### Creating SFrame Data (Encoding)

```c
// Create encoder
sframe_encoder_ctx *encode = sframe_encode(
    SFRAME_VERSION_2,                    // version
    SFRAME_F_FDE_SORTED,                // flags
    SFRAME_ABI_AMD64_ENDIAN_LITTLE,     // abi/arch
    SFRAME_CFA_FIXED_FP_INVALID,       // fixed FP offset
    -8,                                 // fixed RA offset
    &err
);

// Add function descriptor
unsigned char func_info = sframe_fde_create_func_info(
    SFRAME_FRE_TYPE_ADDR1,              // FRE type
    SFRAME_FDE_TYPE_PCINC               // FDE type
);

sframe_encoder_add_funcdesc_v2(encode, func_start_addr, func_size,
                               func_info, 0, num_fres);

// Add Frame Row Entries
sframe_frame_row_entry fre = {
    .fre_start_addr = 0x10,
    .fre_offsets = {0x10, 0, 0},        // CFA offset
    .fre_info = SFRAME_V1_FRE_INFO(SFRAME_BASE_REG_SP, 1, SFRAME_FRE_OFFSET_1B)
};
sframe_encoder_add_fre(encode, func_idx, &fre);

// Write to buffer
char *buffer = sframe_encoder_write(encode, &size, &err);
```

### Reading SFrame Data (Decoding)

```c
// Decode SFrame data
sframe_decoder_ctx *dctx = sframe_decode(buffer, size, &err);

// Get section information
uint8_t version = sframe_decoder_get_version(dctx);
uint8_t abi_arch = sframe_decoder_get_abi_arch(dctx);
uint32_t num_fdes = sframe_decoder_get_num_fidx(dctx);

// Look up unwinding info for a PC
sframe_frame_row_entry fre;
int32_t relative_pc = pc - base_address;
err = sframe_find_fre(dctx, relative_pc, &fre);

if (err == 0) {
    // Extract unwinding information
    int32_t cfa_offset = sframe_fre_get_cfa_offset(dctx, &fre, &err);
    int32_t ra_offset = sframe_fre_get_ra_offset(dctx, &fre, &err);
    int32_t fp_offset = sframe_fre_get_fp_offset(dctx, &fre, &err);
    uint8_t base_reg = sframe_fre_get_base_reg_id(&fre, &err);
}
```

### Stack Unwinding Process

```c
void unwind_stack(uint64_t current_pc, uint64_t current_sp,
                  sframe_decoder_ctx *dctx, uint64_t base_addr) {
    sframe_frame_row_entry fre;
    int32_t lookup_pc = current_pc - base_addr;

    if (sframe_find_fre(dctx, lookup_pc, &fre) == 0) {
        // Get CFA (Canonical Frame Address)
        int32_t cfa_offset = sframe_fre_get_cfa_offset(dctx, &fre, &err);
        uint8_t base_reg = sframe_fre_get_base_reg_id(&fre, &err);

        uint64_t cfa;
        if (base_reg == SFRAME_BASE_REG_SP) {
            cfa = current_sp + cfa_offset;
        } else {
            // Frame pointer based
            cfa = current_fp + cfa_offset;
        }

        // Get return address
        int32_t ra_offset = sframe_fre_get_ra_offset(dctx, &fre, &err);
        uint64_t return_addr = *(uint64_t*)(cfa + ra_offset);

        // Get previous frame pointer if tracked
        int32_t fp_offset = sframe_fre_get_fp_offset(dctx, &fre, &err);
        uint64_t prev_fp = *(uint64_t*)(cfa + fp_offset);

        // Continue unwinding...
        unwind_stack(return_addr, cfa, dctx, base_addr);
    }
}
```

## Examples

### Simple Test Program

See `simple_sframe_test.c` for a minimal example that:
1. Creates an encoder context
2. Adds function descriptors and frame row entries
3. Encodes to a buffer
4. Decodes and verifies the data
5. Performs lookups

### Full Stack Tracing Example

See `sframe_stack_example.c` for a complete example that:
1. Loads SFrame data from ELF files
2. Demonstrates stack unwinding
3. Shows how to extract all unwinding information

## Supported Architectures

- **AMD64** (`SFRAME_ABI_AMD64_ENDIAN_LITTLE`)
  - Fixed RA offset: -8 (CFA-8)
  - Tracks: CFA, optionally FP

- **AArch64** (`SFRAME_ABI_AARCH64_ENDIAN_LITTLE/BIG`)
  - Tracks: CFA, RA, FP (if frame record created)
  - Supports pointer authentication

- **s390x** (`SFRAME_ABI_S390X_ENDIAN_BIG`)
  - CFA = SP + 160 at call site
  - Tracks: CFA, optionally RA, FP
  - Supports register-based saves

## Error Handling

```c
// Check for errors
if (err != 0) {
    printf("Error: %s\n", sframe_errmsg(err));
}

// Common error codes
SFRAME_ERR_VERSION_INVAL    // Unsupported version
SFRAME_ERR_NOMEM           // Out of memory
SFRAME_ERR_INVAL           // Corrupt SFrame data
SFRAME_ERR_FDE_NOTFOUND    // Function not found
SFRAME_ERR_FRE_NOTFOUND    // Frame row entry not found
```

## Building Your Application

### Complete Example

```bash
# 1. Build libsframe
make -f Makefile.sframe libsframe

# 2. Build your application
make -f Makefile.sframe example

# 3. Test it
./sframe_stack_example
```

### Manual Compilation

```bash
gcc -g -O2 \
    -Ideps/binutils-gdb/include \
    -Ideps/binutils-gdb/libsframe \
    -o your_program your_program.c \
    deps/binutils-gdb/libsframe/.libs/libsframe.a
```

## Notes

- SFrame data is typically found in `.sframe` ELF sections
- PCs in SFrame are relative offsets, not absolute addresses
- The library is designed for minimal overhead in stack tracing
- For production use, consider memory mapping SFrame sections
- Always check return values and use `sframe_errmsg()` for errors

## References

- SFrame format specification: `deps/binutils-gdb/include/sframe.h`
- API documentation: `deps/binutils-gdb/include/sframe-api.h`
- Test examples: `deps/binutils-gdb/libsframe/testsuite/`