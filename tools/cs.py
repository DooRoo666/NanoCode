import struct,sys
d=open(sys.argv[1],'rb').read()
magic,ncmds=struct.unpack_from('<II',d,16)
off=32
for i in range(ncmds):
    cmd,sz=struct.unpack_from('<II',d,off)
    if cmd==0x1d:
        doff,dsz=struct.unpack_from('<II',d,off+8)
        print('LC_CODE_SIGNATURE off',doff,'size',dsz)
    if cmd==0x2:
        print('LC_BUILD_VERSION',struct.unpack_from('<IIIIII',d,off+8))
    if cmd==0x1b:
        print('LC_UUID')
    if cmd==0x0b:
        print('LC_DYSYMTAB')
    if cmd in (0xc,0x22,0x80000022):
        print('LC_LOAD_DYLIB',d[off+8:off+sz].split(b'\0')[0])
    off+=sz
