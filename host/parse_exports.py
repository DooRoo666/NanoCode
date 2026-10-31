#!/usr/bin/env python3
"""解析 Mach-O 导出 trie，确认 CCLinkerJobExecute 是否真正导出（可 dlsym）。"""
import struct, sys

def parse(path):
    d = open(path, 'rb').read()
    magic = struct.unpack_from('<I', d, 0)[0]
    if magic != 0xfeedfacf:
        print(f'unexpected magic {magic:#x}'); return
    ncmds = struct.unpack_from('<I', d, 16)[0]
    off = 32
    exports_off = exports_size = None
    symtab = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', d, off)
        if cmd == 0x80000022:  # LC_DYLD_EXPORTS_TRIE
            exports_off, exports_size = struct.unpack_from('<II', d, off + 8)
        elif cmd == 0x2:  # LC_SYMTAB
            symtab = struct.unpack_from('<IIII', d, off + 8)
        off += size
    print(f'LC_DYLD_EXPORTS_TRIE: off={exports_off} size={exports_size}')
    print(f'LC_SYMTAB: {symtab}')
    if exports_off is not None and exports_size:
        walk(d, exports_off, exports_size)

def walk(d, base, size):
    """遍历导出 trie，收集所有符号名。"""
    found = []
    def rec(node_off, prefix):
        pos = base + node_off
        if pos >= base + size: return
        terminal = d[pos]; pos += 1
        if terminal:
            # flags = ULEB128, address
            n, pos = uleb(d, pos)
            m, pos = uleb(d, pos)
            if prefix: found.append(prefix)
        nchild = d[pos]; pos += 1
        for _ in range(nchild):
            edge = b''
            while True:
                c = d[pos]; pos += 1
                if c == 0: break
                edge += bytes([c])
            child, pos = uleb(d, pos)
            rec(child, prefix + edge.decode('utf-8', 'replace'))
    rec(0, '')
    print(f'\n导出符号总数: {len(found)}')
    targets = [s for s in found if 'CC' in s or 'Linker' in s]
    print(f'含 CC/Linker: {len(targets)}')
    for s in sorted(targets):
        print('  ', s)

def uleb(d, p):
    v = 0; s = 0
    while True:
        b = d[p]; p += 1
        v |= (b & 0x7f) << s
        if not (b & 0x80): break
        s += 7
    return v, p

if __name__ == '__main__':
    parse(sys.argv[1])
