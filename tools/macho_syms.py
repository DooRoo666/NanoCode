#!/usr/bin/env python3
import struct, sys
path = sys.argv[1]
d = open(path,'rb').read()
ncmds = struct.unpack_from('<I', d, 16)[0]
off=32
symoff=nsyms=stroff=strsize=0
for i in range(ncmds):
    cmd, cmdsize = struct.unpack_from('<II', d, off)
    if cmd==0x2:
        symoff, nsyms, stroff, strsize = struct.unpack_from('<IIII', d, off+8)
    off+=cmdsize
print("nsyms",nsyms,"stroff",stroff)
out=[]
for i in range(nsyms):
    n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from('<IBBHQ', d, symoff+i*16)
    end = d.index(b'\0', stroff+n_strx)
    name = d[stroff+n_strx:end].decode('utf8','replace')
    out.append((name,n_type,n_desc,n_value))
cc=[o for o in out if o[0].startswith('_CC')]
print("CC count",len(cc))
for n,t,de,v in sorted(set(cc)):
    print(f"  {n}  type={t:#x} desc={de:#x}")
