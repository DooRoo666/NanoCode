import struct,sys
d=open(sys.argv[1],'rb').read()
magic,ncmds=struct.unpack_from('<II',d,16)
print('magic',d[:4].hex(),'ncmds',ncmds)
off=32
names={0x1:'SEGMENT',0x19:'SEGMENT_64',0x2:'SYMTAB',0xb:'DYSYMTAB',0xc:'LOAD_DYLIB',0x80000022:'DYLD_INFO',0x1d:'CODE_SIGN',0x1e:'SEGMENT_SPLIT_INFO',0x26:'FUNCTION_STARTS',0x29:'DATA_IN_CODE',0x2a:'SOURCE_VERSION',0x32:'BUILD_VERSION',0x80000028:'MAIN',0x80000034:'DYLD_EXPORTS_TRIE',0x1f:'REEXPORT_DYLIB',0x8000001f:'REEXPORT_DYLIB',0x24:'VERSION_MIN',0x25:'FUNCTION_STARTS'}
for i in range(ncmds):
    cmd,sz=struct.unpack_from('<II',d,off)
    n=names.get(cmd,hex(cmd))
    extra=''
    if cmd in (0xc,0x18,0x1f,0x80000018,0x8000001f):
        nameo=struct.unpack_from('<I',d,off+8)[0]
        extra=d[off+nameo:d.index(b'\0',off+nameo)].decode()
    if cmd==0x19:
        segname=d[off+8:off+24].split(b'\0')[0].decode()
        extra='seg='+segname
    print(n,extra)
    off+=sz
