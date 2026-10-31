import struct, sys, mmap

path = sys.argv[1]
f = open(path, 'rb')
m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)

magic, cputype, cpusub, ftype, ncmds, sizeofcmds, flags = struct.unpack('<7I', m[0:28])
print("magic=%08x cputype=%010x ftype=%d ncmds=%d" % (magic, cputype, ftype, ncmds))

off = 32
symtab = None
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack('<2I', m[off:off+8])
    if cmd == 0x2:
        symtab = struct.unpack('<4I', m[off+8:off+24])
    off += cmdsize

print("LC_SYMTAB =", symtab)
if not symtab:
    print("no symtab")
    sys.exit(1)

symoff, nsyms, stroff, strsize = symtab
print("nsyms=%d strsize=%d" % (nsyms, strsize))

# nl_symbol_ptr 16 字节一项
targets = [b'CCLinkerJobExecute', b'CCJobCreate', b'CCLinker', b'CCDriverCreateJobs']
found = {}
for i in range(nsyms):
    p = symoff + i*16
    strx, ntype, sect, desc, value = struct.unpack('<IBBhQ', m[p:p+16])
    if strx == 0 or strx >= strsize:
        continue
    e = m.find(b'\0', stroff+strx, stroff+strsize)
    name = m[stroff+strx:e]
    for t in targets:
        if name == t or name == b'_' + t:
            found.setdefault(t.decode(), []).append((name.decode(), ntype, value))

print("\n=== 结果 ===")
for t in targets:
    k = t.decode()
    if k in found:
        for nm, nt, val in found[k]:
            ext = "N_EXT->导出" if (nt & 1) else "本地"
            print("  %-22s type=0x%02x %s 0x%x" % (nm, nt, ext, val))
    else:
        print("  %-22s 未找到" % k)

m.close()
