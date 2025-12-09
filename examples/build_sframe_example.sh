#!/usr/bin/env bash

# build_sframe_example.sh - Script to build libsframe and the example program

set -e

echo "Building libsframe and stack tracing example"
echo "============================================="

## Build libsframe first
#echo "1. Building libsframe..."
#cd deps/binutils-gdb/libsframe
#
## Configure if needed
#if [ ! -f Makefile ]; then
#    echo "   Configuring libsframe..."
#    ./configure --prefix=/usr/local --disable-shared --enable-static
#fi
#
## Build the library
#echo "   Compiling libsframe..."
#make -j$(nproc)
#
#cd ../../..

# Build the example
echo "2. Building sframe stack example..."

# Set up include and library paths
# SFRAME_INCLUDES="-Ideps/binutils-gdb/include -Ideps/binutils-gdb/libsframe"
SFRAME_INCLUDES="-Wa,--gsframe -fomit-frame-pointer "
SFRAME_LIBS="-lsframe -lctf -L/usr/local/lib/ "

# Additional includes for dependencies
# ADDITIONAL_INCLUDES="-Ldeps/binutils-gdb/libctf -Ideps/binutils-gdb/bfd"
ADDITIONAL_INCLUDES="-I/usr/local/include/"

echo "   Compiling with:"
echo "   Includes: $SFRAME_INCLUDES $ADDITIONAL_INCLUDES"
echo "   Libraries: $SFRAME_LIBS"

gcc -g -O1 \
    $SFRAME_INCLUDES $ADDITIONAL_INCLUDES \
    -o sframe_stack_example \
    sframe_stack_example.c \
    $SFRAME_LIBS

/usr/local/bin/x86_64-unknown-freebsd15.0-objcopy \
  --dump-section .sframe=sframe_stack_example.sframe \
  sframe_stack_example

echo "3. Build complete!"
echo ""
echo "Usage:"
echo "  ./sframe_stack_example [elf_file] [pc_address]"
echo ""
echo "Examples:"
echo "  ./sframe_stack_example                    # Use current executable"
echo "  ./sframe_stack_example /bin/ls           # Analyze /bin/ls"
echo "  ./sframe_stack_example /bin/ls 0x2000    # Look up specific PC"
echo ""
echo "Note: The executable must be compiled with SFrame support."
echo "      Use GCC with -gsframe or recent versions that generate SFrame by default."
