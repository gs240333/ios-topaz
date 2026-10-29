#!/bin/bash
# Build the shim and wrap it in a boot.img v1: the wayne (Xiaomi Mi 6X,
# SDM660) ABL follows the stock boot image (header v1, page 2048,
# kernel 0x10008000, ramdisk 0x11000000, tags 0x10000100, DTB appended to the
# kernel). The XNU payload rides appended behind the Image after _end
# (loader.c finds it there first); ABL's own ramdisk/DTB handling is unused.
set -euo pipefail
cd "$(dirname "$0")"
# Cross-compiler if available; a native aarch64 gcc (Alpine box) works too --
# freestanding, -fno-pic, no libc involved.
CC=${CC:-aarch64-linux-gnu-gcc}
command -v "$CC" >/dev/null 2>&1 || CC=gcc
OBJCOPY=${OBJCOPY:-aarch64-linux-gnu-objcopy}
command -v "$OBJCOPY" >/dev/null 2>&1 || OBJCOPY=objcopy
echo "using CC=$CC OBJCOPY=$OBJCOPY"
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra"
mkdir -p out
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done
# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
NM=${NM:-aarch64-linux-gnu-nm}
command -v "$NM" >/dev/null 2>&1 || NM=nm
READELF=${READELF:-aarch64-linux-gnu-readelf}
command -v "$READELF" >/dev/null 2>&1 || READELF=readelf
abs=$($READELF -r out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-N \
	out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image
# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
size=$((16#$($NM out/shim.elf | awk '$3=="_end"{print $1}')))
truncate -s "$size" out/Image
# Ramdisk: an xnu payload (tools/mkpayload.py) if given as $1, else an empty
# newc cpio (ABL dislikes a zero-size ramdisk on some builds) -> diagnostics.
if [ -n "${1:-}" ]; then
	# Append the payload to the Image at the first 4K boundary after _end
	# (loader.c) and grow image_size.
	truncate -s $(( (size + 0xfff) & ~0xfff )) out/Image
	cat "$1" >> out/Image
fi
# Ramdisk: payload travels embedded in the Image; keep a small empty newc
# cpio for the ABL's boot ramdisk (some ABLs dislike zero-size ramdisks).
(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
# The sdm660 ABL only jumps kernels whose blob starts with a gzip stream
# (stock kernels and TWRP are Image.gz+DTB; a raw arm64 Image is accepted by
# fastboot but never executed). Wrap the Image in gzip exactly like the stock
# boot.img layout, append the stock wayne DTB after the stream.
DTB=${WAYNE_DTB:-../../wayne-boot/wayne0.dtb}
[ -f "$DTB" ] || { echo "missing DTB: $DTB" >&2; exit 1; }
gzip -9 -c out/Image > out/Image.gz
cat out/Image.gz "$DTB" > out/blob.bin
python3 ../pack_boot.py --kernel out/blob.bin --ramdisk out/ramdisk.bin \
	--cmdline "console=null" -o out/shim-boot.img
# Host render of the console layout.
gcc -O1 -Wall -o out/host_test console.c host_test.c && ./out/host_test
ls -l out/Image out/shim-boot.img
