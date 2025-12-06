/* sframe_stack_example.c - Example demonstrating how to use libsframe for stack tracing
 *
 * This example shows how to:
 * 1. Build and link against libsframe
 * 2. Read SFrame data from an executable
 * 3. Use sframe_find_fre() to get stack unwinding information
 * 4. Perform actual stack tracing of its own execution
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <elf.h>

/* Include sframe headers */
#include "sframe-api.h"

/* Global counter to make stack deeper */
static int global_counter = 0;

/* Structure to hold SFrame section information */
typedef struct {
    void *sframe_data;
    size_t sframe_size;
    uint64_t sframe_vaddr;    /* Virtual address where sframe section is loaded */
    uint64_t text_vaddr;      /* Virtual address of .text section */
} sframe_info_t;

/* Find and map the .sframe section from an ELF file */
static int
load_sframe_section(const char *filename, sframe_info_t *info)
{
    int fd;
    struct stat st;
    void *map;
    Elf64_Ehdr *ehdr;
    Elf64_Shdr *shdr_table;
    char *str_table;

    /* Open and map the ELF file */
    fd = open(filename, O_RDONLY);
    if (fd < 0) {
        perror("open");
        return -1;
    }

    if (fstat(fd, &st) < 0) {
        perror("fstat");
        close(fd);
        return -1;
    }

    map = mmap(NULL, st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (map == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return -1;
    }

    ehdr = (Elf64_Ehdr *)map;

    /* Verify ELF magic */
    if (memcmp(ehdr->e_ident, ELFMAG, SELFMAG) != 0) {
        fprintf(stderr, "Not a valid ELF file\n");
        munmap(map, st.st_size);
        close(fd);
        return -1;
    }

    /* Get section header table */
    shdr_table = (Elf64_Shdr *)((char *)map + ehdr->e_shoff);
    str_table = (char *)map + shdr_table[ehdr->e_shstrndx].sh_offset;

    /* Find .sframe and .text sections */
    for (int i = 0; i < ehdr->e_shnum; i++) {
        const char *name = str_table + shdr_table[i].sh_name;

        if (strcmp(name, ".sframe") == 0) {
            info->sframe_data = malloc(shdr_table[i].sh_size);
            memcpy(info->sframe_data, (char *)map + shdr_table[i].sh_offset,
                   shdr_table[i].sh_size);
            info->sframe_size = shdr_table[i].sh_size;
            info->sframe_vaddr = shdr_table[i].sh_addr;
            printf("Found .sframe section: size=%zu, vaddr=0x%lx\n",
                   info->sframe_size, info->sframe_vaddr);
        }
        else if (strcmp(name, ".text") == 0) {
            info->text_vaddr = shdr_table[i].sh_addr;
            printf("Found .text section: vaddr=0x%lx\n", info->text_vaddr);
        }
    }

    munmap(map, st.st_size);
    close(fd);

    if (!info->sframe_data) {
        fprintf(stderr, "No .sframe section found\n");
        return -1;
    }

    return 0;
}

/* Perform stack unwinding using SFrame information */
static void
demonstrate_stack_unwinding(sframe_decoder_ctx *dctx, uint64_t pc,
                           uint64_t sframe_vaddr)
{
    sframe_frame_row_entry fre;
    int32_t lookup_pc;
    int err;

    printf("\n=== Stack Unwinding Demo ===\n");
    printf("Looking up PC: 0x%lx\n", pc);

    /* Convert absolute PC to relative offset for sframe lookup */
    lookup_pc = (int32_t)(pc - sframe_vaddr);

    /* Find the Frame Row Entry for this PC */
    err = sframe_find_fre(dctx, lookup_pc, &fre);
    if (err != 0) {
        printf("No FRE found for PC 0x%lx (relative: 0x%x)\n", pc, lookup_pc);
        printf("Error: %s\n", sframe_errmsg(err));
        return;
    }

    printf("Found FRE for PC 0x%lx\n", pc);
    printf("FRE start address: 0x%x\n", fre.fre_start_addr);

    /* Extract unwinding information */
    uint8_t base_reg_id = sframe_fre_get_base_reg_id(&fre, &err);
    if (err == 0) {
        printf("Base register: %s\n",
               base_reg_id == SFRAME_BASE_REG_SP ? "SP" : "FP");
    }

    int32_t cfa_offset = sframe_fre_get_cfa_offset(dctx, &fre, &err);
    if (err == 0) {
        printf("CFA offset: %d\n", cfa_offset);
    }

    int32_t ra_offset = sframe_fre_get_ra_offset(dctx, &fre, &err);
    if (err == 0) {
        printf("RA offset: %d\n", ra_offset);
    }

    int32_t fp_offset = sframe_fre_get_fp_offset(dctx, &fre, &err);
    if (err == 0) {
        printf("FP offset: %d\n", fp_offset);
    }
}

/* Get the current executable path on FreeBSD */
static char *
get_executable_path(void)
{
    static char exe_path[1024];
    size_t len = sizeof(exe_path);

    /* On FreeBSD, use sysctl to get the executable path */
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1};
    if (sysctl(mib, 4, exe_path, &len, NULL, 0) == 0) {
        return exe_path;
    }

    /* Fallback: try to read from argv[0] if it's an absolute path */
    return NULL;
}

/* SFrame-based stack unwinding without frame pointers */
static void
print_sframe_stack_trace(sframe_decoder_ctx *dctx, sframe_info_t *sframe_info)
{
    uint64_t rsp;
    int frame_count = 0;
    const int max_frames = 10;

    printf("\n=== Stack Trace ===\n");

    /* Get the current stack pointer */
    __asm__("movq %%rsp, %0" : "=r" (rsp));

    printf("Starting from current stack pointer: 0x%lx\n", rsp);

    /* Walk stack manually by examining return addresses */
    uint64_t start_rsp = rsp;
    while (frame_count < max_frames && (rsp - start_rsp) < 1024) {
        /* Look at return address at current stack position */
        uint64_t *stack_ptr = (uint64_t *)rsp;
        bool found_frame = false;

        /* Skip a few words to find a reasonable return address */
        for (int i = 0; i < 8; i++) {
            uint64_t candidate_pc = stack_ptr[i];

            /* Check if this looks like a valid PC in our text section */
            if (candidate_pc >= sframe_info->text_vaddr &&
                candidate_pc < (sframe_info->text_vaddr + 0x10000)) {

                printf("Frame %d: PC=0x%lx", frame_count, candidate_pc);

                sframe_frame_row_entry fre;
                /* SFrame uses signed relative addressing */
                int32_t lookup_pc = (int32_t)(candidate_pc - sframe_info->text_vaddr);
                printf(" (rel: 0x%x)", (uint32_t)lookup_pc);
                int err = sframe_find_fre(dctx, lookup_pc, &fre);

                if (err == 0) {
                    printf(" [SFrame: start=0x%x]", fre.fre_start_addr);
                } else {
                    printf(" [No SFrame]");
                }
                printf("\n");

                /* Move up the stack for next frame */
                rsp += (i + 1) * 8;
                frame_count++;
                found_frame = true;
                break;
            }
        }

        /* If we didn't find any valid PCs in this search, advance a bit */
        if (!found_frame) {
            rsp += 8;
        }
    }

    printf("Total frames found: %d\n", frame_count);
}

/* Function to increment global counter and call next level */
static void
stack_function_6(sframe_decoder_ctx *dctx, sframe_info_t *sframe_info)
{
    printf("In stack_function_4, counter = %d\n", global_counter);
    print_sframe_stack_trace(dctx, sframe_info);
    global_counter += 4;
}

/* Function to increment global counter and call next level */
static void
stack_function_5(sframe_decoder_ctx *dctx, sframe_info_t *sframe_info)
{
    printf("In stack_function_3, counter = %d\n", global_counter);
    stack_function_6(dctx, sframe_info);
    global_counter += 3;
}

/* Function to increment global counter and call next level */
static void
stack_function_4(sframe_decoder_ctx *dctx, sframe_info_t *sframe_info)
{
    printf("In stack_function_3, counter = %d\n", global_counter);
    stack_function_5(dctx, sframe_info);
    global_counter += 3;
}

/* Function to increment global counter and call next level */
static void
stack_function_3(sframe_decoder_ctx *dctx, sframe_info_t *sframe_info)
{
    printf("In stack_function_3, counter = %d\n", global_counter);
    stack_function_4(dctx, sframe_info);
    global_counter += 3;
}

/* Function to increment global counter and call next level */
static void
stack_function_2(sframe_decoder_ctx *dctx, sframe_info_t *sframe_info)
{
    printf("In stack_function_2, counter = %d\n", global_counter);
    stack_function_3(dctx, sframe_info);
    global_counter += 2;
}

/* Function to increment global counter and call next level */
static void
stack_function_1(sframe_decoder_ctx *dctx, sframe_info_t *sframe_info)
{
    printf("In stack_function_1, counter = %d\n", global_counter);
    stack_function_2(dctx, sframe_info);
    global_counter += 1;
}

int main(int argc, char *argv[])
{
    sframe_info_t sframe_info = {0};
    sframe_decoder_ctx *dctx;
    int err;
    const char *filename;
    char *exe_path;

    printf("SFrame Stack Tracing Example\n");
    printf("============================\n");

    /* Get the current executable path for FreeBSD */
    exe_path = get_executable_path();
    filename = (argc > 1) ? argv[1] : (exe_path ? exe_path : "./sframe_stack_example");

    printf("Loading SFrame data from: %s\n", filename);

    /* Load SFrame section from ELF file */
    if (load_sframe_section(filename, &sframe_info) < 0) {
        fprintf(stderr, "Failed to load SFrame section\n");
        return 1;
    }

    /* Initialize SFrame decoder */
    dctx = sframe_decode(sframe_info.sframe_data, sframe_info.sframe_size, &err);
    if (!dctx) {
        fprintf(stderr, "Failed to initialize SFrame decoder: %s\n",
                sframe_errmsg(err));
        free(sframe_info.sframe_data);
        return 1;
    }

    printf("\n=== Creating nested function calls to print stack trace ===\n");

    /* Start the chain of function calls that will print the stack trace */
    stack_function_1(dctx, &sframe_info);

    printf("\nFinal counter value: %d\n", global_counter);

    /* Cleanup */
    sframe_decoder_free(&dctx);
    free(sframe_info.sframe_data);

    return 0;
}
