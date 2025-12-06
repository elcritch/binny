/* sframe_stack_example.c - Example demonstrating how to use libsframe for stack tracing
 *
 * This example shows how to:
 * 1. Build and link against libsframe
 * 2. Read SFrame data from an executable
 * 3. Use sframe_find_fre() to get stack unwinding information
 * 4. Perform basic stack tracing
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <elf.h>

/* Include sframe headers */
#include "sframe-api.h"

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

/* Dump SFrame section information */
static void
dump_sframe_info(sframe_decoder_ctx *dctx)
{
    printf("\n=== SFrame Section Information ===\n");
    printf("Version: %d\n", sframe_decoder_get_version(dctx));
    printf("ABI/Arch: %d\n", sframe_decoder_get_abi_arch(dctx));
    // printf("Flags: 0x%x\n", sframe_decoder_get_flags(dctx));
    printf("Number of FDEs: %d\n", sframe_decoder_get_num_fidx(dctx));
    printf("Fixed FP offset: %d\n", sframe_decoder_get_fixed_fp_offset(dctx));
    printf("Fixed RA offset: %d\n", sframe_decoder_get_fixed_ra_offset(dctx));

    /* List all functions */
    printf("\n=== Function Descriptors ===\n");
    uint32_t num_fdes = sframe_decoder_get_num_fidx(dctx);
    for (uint32_t i = 0; i < num_fdes; i++) {
        uint32_t num_fres, func_size;
        int32_t func_start_addr;
        unsigned char func_info;
        int err;

        err = sframe_decoder_get_funcdesc(dctx, i, &num_fres, &func_size,
                                         &func_start_addr, &func_info);
        if (err == 0) {
            printf("FDE %d: start=0x%x, size=%d, fres=%d, info=0x%x\n",
                   i, func_start_addr, func_size, num_fres, func_info);
        }
    }
}

int main(int argc, char *argv[])
{
    sframe_info_t sframe_info = {0};
    sframe_decoder_ctx *dctx;
    int err;

    printf("SFrame Stack Tracing Example\n");
    printf("============================\n");

    /* Use the current executable if no file specified */
    const char *filename = (argc > 1) ? argv[1] : "/proc/self/exe";

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

    /* Dump SFrame information */
    dump_sframe_info(dctx);

    /* Demonstrate stack unwinding for a few example PCs */
    if (argc > 2) {
        /* Use PC provided as command line argument */
        uint64_t pc = strtoull(argv[2], NULL, 0);
        demonstrate_stack_unwinding(dctx, pc, sframe_info.sframe_vaddr);
    } else {
        /* Use some example PCs relative to text section */
        uint64_t example_pcs[] = {
            sframe_info.text_vaddr + 0x10,
            sframe_info.text_vaddr + 0x100,
            sframe_info.text_vaddr + 0x1000
        };

        for (int i = 0; i < 3; i++) {
            demonstrate_stack_unwinding(dctx, example_pcs[i],
                                      sframe_info.sframe_vaddr);
        }
    }

    /* Cleanup */
    sframe_decoder_free(&dctx);
    free(sframe_info.sframe_data);

    return 0;
}
