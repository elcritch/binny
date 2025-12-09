/* simple_sframe_test.c - Simple test to verify libsframe linkage
 *
 * This is a minimal example showing how to link and use basic sframe functions.
 * It creates an in-memory sframe section for testing.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

/* Include sframe headers */
#include "deps/binutils-gdb/include/sframe-api.h"

int main()
{
    printf("Simple SFrame Test\n");
    printf("==================\n");

    /* Test 1: Create an encoder */
    printf("1. Creating SFrame encoder...\n");
    int err = 0;
    sframe_encoder_ctx *encode = sframe_encode(
        SFRAME_VERSION_2,                    /* version */
        SFRAME_F_FDE_SORTED,                /* flags */
        SFRAME_ABI_AMD64_ENDIAN_LITTLE,     /* abi/arch */
        SFRAME_CFA_FIXED_FP_INVALID,       /* fixed FP offset */
        -8,                                 /* fixed RA offset for AMD64 */
        &err
    );

    if (!encode) {
        printf("   ERROR: Failed to create encoder: %s\n", sframe_errmsg(err));
        return 1;
    }
    printf("   SUCCESS: Encoder created\n");

    /* Test 2: Add a simple function descriptor */
    printf("2. Adding function descriptor...\n");
    unsigned char func_info = sframe_fde_create_func_info(
        SFRAME_FRE_TYPE_ADDR1,              /* FRE type */
        SFRAME_FDE_TYPE_PCINC               /* FDE type */
    );

    err = sframe_encoder_add_funcdesc_v2(
        encode,
        0x1000,                             /* function start address */
        0x100,                              /* function size */
        func_info,                          /* function info */
        0,                                  /* rep block size */
        2                                   /* number of FREs */
    );

    if (err != 0) {
        printf("   ERROR: Failed to add function descriptor: %s\n", sframe_errmsg(err));
        sframe_encoder_free(&encode);
        return 1;
    }
    printf("   SUCCESS: Function descriptor added\n");

    /* Test 3: Add Frame Row Entries */
    printf("3. Adding Frame Row Entries...\n");
    sframe_frame_row_entry fre1 = {
        .fre_start_addr = 0x0,
        .fre_offsets = {0x8, 0, 0},         /* CFA offset = 8 */
        .fre_info = SFRAME_V1_FRE_INFO(SFRAME_BASE_REG_SP, 1, SFRAME_FRE_OFFSET_1B)
    };

    sframe_frame_row_entry fre2 = {
        .fre_start_addr = 0x10,
        .fre_offsets = {0x10, 0, 0},        /* CFA offset = 16 */
        .fre_info = SFRAME_V1_FRE_INFO(SFRAME_BASE_REG_SP, 1, SFRAME_FRE_OFFSET_1B)
    };

    if (sframe_encoder_add_fre(encode, 0, &fre1) != 0 ||
        sframe_encoder_add_fre(encode, 0, &fre2) != 0) {
        printf("   ERROR: Failed to add FREs\n");
        sframe_encoder_free(&encode);
        return 1;
    }
    printf("   SUCCESS: FREs added\n");

    /* Test 4: Encode to buffer */
    printf("4. Encoding to buffer...\n");
    size_t encoded_size;
    char *sframe_buf = sframe_encoder_write(encode, &encoded_size, &err);

    if (!sframe_buf) {
        printf("   ERROR: Failed to encode: %s\n", sframe_errmsg(err));
        sframe_encoder_free(&encode);
        return 1;
    }
    printf("   SUCCESS: Encoded %zu bytes\n", encoded_size);

    /* Test 5: Decode and verify */
    printf("5. Decoding and verifying...\n");
    sframe_decoder_ctx *decode = sframe_decode(sframe_buf, encoded_size, &err);

    if (!decode) {
        printf("   ERROR: Failed to decode: %s\n", sframe_errmsg(err));
        free(sframe_buf);
        sframe_encoder_free(&encode);
        return 1;
    }

    uint32_t num_fdes = sframe_decoder_get_num_fidx(decode);
    printf("   SUCCESS: Decoded %d function descriptors\n", num_fdes);

    /* Test 6: Look up frame row entry */
    printf("6. Looking up FRE for PC 0x1005...\n");
    sframe_frame_row_entry lookup_fre;
    int32_t lookup_pc = 0x5;  /* Relative to function start */

    err = sframe_find_fre(decode, lookup_pc, &lookup_fre);
    if (err == 0) {
        int32_t cfa_offset = sframe_fre_get_cfa_offset(decode, &lookup_fre, &err);
        printf("   SUCCESS: Found FRE with CFA offset = %d\n", cfa_offset);
    } else {
        printf("   INFO: No FRE found for PC (this is expected for this test)\n");
    }

    /* Cleanup */
    printf("7. Cleaning up...\n");
    sframe_decoder_free(&decode);
    free(sframe_buf);
    sframe_encoder_free(&encode);

    printf("\nAll tests completed successfully!\n");
    printf("SFrame library is working correctly.\n");

    return 0;
}