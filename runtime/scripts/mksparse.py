"""Makes a sparse disc image for a phone: the disc's sectors with data, at the same sector numbers, minus the files a build does
not need (another language's voices, an online mode), behind a table of extents. Every sector left out reads as zeros
(runtime/src/disc.cpp reads this format next to plain images).

usage: python mksparse.py image.iso out.sparse [--drop PATTERN ...]
  PATTERN: a disc path or glob (fnmatch, upper case), e.g. SOUNDS/FRA/* or ON_LINS.UMD

Format: "PS2SPRS1", the disc's size (u64), the number of extents (u32), 4 bytes free, then per extent: first sector (u32),
sectors (u32), offset of its data in this file (u64); extents sorted by sector, the data after the table, 2048-byte aligned.
"""
import argparse
import fnmatch
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from disc import SECTOR, Image  # noqa: E402

ZERO = bytes(SECTOR)
GAP = 32  # zero runs shorter than this many sectors stay inside an extent (fewer extents, a few KB more)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('image')
    parser.add_argument('out')
    parser.add_argument('--drop', action='append', default=[])
    a = parser.parse_args()
    image = Image(a.image)
    total = image.size // SECTOR
    dropped = []
    for path, _, sector, size in image.files():
        if any(fnmatch.fnmatch(path.upper(), p.upper()) for p in a.drop):
            dropped.append((sector, (size + SECTOR - 1) // SECTOR, path))
    gone = bytearray(total)
    for sector, count, path in dropped:
        gone[sector:sector + count] = b'\x01' * min(count, total - sector)
        print('drop %-40s %8.1f MB' % (path, count * SECTOR / 1048576))

    # one pass over the disc: which sectors hold data
    keep = bytearray(total)
    chunk = 4096
    f = image.file
    f.seek(0)
    for start in range(0, total, chunk):
        data = f.read(min(chunk, total - start) * SECTOR)
        for i in range(len(data) // SECTOR):
            s = start + i
            if not gone[s] and data[i * SECTOR:(i + 1) * SECTOR] != ZERO:
                keep[s] = 1
        if start % (chunk * 64) == 0:
            print('  scanned %d / %d sectors' % (start, total), flush=True)

    extents = []
    s = 0
    while s < total:
        if not keep[s]:
            s += 1
            continue
        begin = s
        end = s + 1
        while end < total:
            if keep[end]:
                end += 1
                continue
            run = end
            while run < total and not keep[run] and run - end < GAP:
                run += 1
            if run < total and keep[run] and run - end < GAP and not any(gone[end:run]):
                end = run
                continue
            break
        extents.append((begin, end - begin))
        s = end

    table = 24 + 16 * len(extents)
    data_start = (table + SECTOR - 1) // SECTOR * SECTOR
    offset = data_start
    header = bytearray(b'PS2SPRS1' + struct.pack('<QI', image.size, len(extents)) + bytes(4))
    for begin, count in extents:
        header += struct.pack('<IIQ', begin, count, offset)
        offset += count * SECTOR
    with open(a.out, 'wb') as out:
        out.write(header + bytes(data_start - len(header)))
        for begin, count in extents:
            f.seek(begin * SECTOR)
            left = count
            while left:
                n = min(left, 4096)
                block = f.read(n * SECTOR)
                out.write(block)
                left -= n
    kept = sum(c for _, c in extents)
    print('%d extents, %.1f MB of %.1f MB kept -> %s (%.1f MB)' % (len(extents), kept * SECTOR / 1048576, image.size / 1048576, a.out,
                                                                  os.path.getsize(a.out) / 1048576))


if __name__ == '__main__':
    main()
