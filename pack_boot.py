#!/usr/bin/env python3
"""Pack an Android boot image, wayne layout proven by TWRP (it boots).

TWRP-wayne: header v0, page 4096, kernel 0x8000, ramdisk 0x1000000,
tags 0x100, os_version 0x2004012b. The stock Xiaomi boot.img uses
v1/2048/0x10008000, but the shim now ships with a DTB appended and the
TWRP-style header is the one verified to jump on this ABL.
Verify with tools/unpack_bootv2.py.
"""
import argparse, hashlib, struct

PAGE = 4096


def rnd(n):
    return (n + PAGE - 1) // PAGE * PAGE


ap = argparse.ArgumentParser()
ap.add_argument('--kernel', required=True)
ap.add_argument('--ramdisk', required=True)
ap.add_argument('-o', '--out', required=True)
ap.add_argument('--cmdline', default='console=null')
ap.add_argument('--os-version', default='0x2004012b')
a = ap.parse_args()

k = open(a.kernel, 'rb').read()
r = open(a.ramdisk, 'rb').read()

hdr = bytearray(PAGE)
hdr[0:8] = b'ANDROID!'
struct.pack_into('<10I', hdr, 8,
                 len(k), 0x8000,		# kernel_size, kernel_addr (TWRP-style)
                 len(r), 0x1000000,		# ramdisk_size, ramdisk_addr
                 0, 0xf00000,		# second_size, second_addr (as TWRP)
                 0x100, PAGE,		# tags_addr, page_size
                 0, int(a.os_version, 16))	# header_version 0, os_version
hdr[64:64 + len(a.cmdline)] = a.cmdline.encode()	# cmdline field (512B) @64
# id @576: SHA1 over kernel+ramdisk+second -- this ABL verifies it
# ("Failed to load/authenticate boot image: 00000050" when zeroed).
hdr[576:596] = hashlib.sha1(k + r).digest()

with open(a.out, 'wb') as f:
    f.write(hdr)
    f.write(k)
    f.write(b'\0' * (rnd(len(k)) - len(k)))
    f.write(r)
    f.write(b'\0' * (rnd(len(r)) - len(r)))
print(f'{a.out}: kernel {len(k)}, ramdisk {len(r)}')
