import struct,sys
d=open(sys.argv[1],'rb').read()
magic,ncmds=struct.unpack_from('<II',d,16)
off=32
for i in range(ncmds):
    cmd,sz=struct.unpack_from('<II',d,off)
    if cmd in (0xc,0x18,0x1f,0x80000018,0x8000001f):
        nameo=struct.unpack_from('<I',d,off+8)[0]
        e=d.index(b'\0',off+nameo)
        print(hex(cmd), d[off+nameo:e].decode())
    if cmd==0x32:
        print('LC_BUILD_VERSION platform',struct.unpack_from('<I',d,off+8)[0],'minos',d[off+12:off+16].hex())
    off+=sz
