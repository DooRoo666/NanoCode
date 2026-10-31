import struct,sys
d=open(sys.argv[1],'rb').read()
ncmds=struct.unpack_from('<I',d,16)[0]
off=32; trie=None
for i in range(ncmds):
    cmd,sz=struct.unpack_from('<II',d,off)
    if cmd==0x80000034:
        trie=struct.unpack_from('<II',d,off+8)
    off+=sz
if not trie: print('no export trie'); sys.exit()
toff,tsize=trie
b=d[toff:toff+tsize]
p=0; names=[]
def walk(p,end,prefix):
    if p>=end: return
    term=0
    while b[p]!=0:
        term=b[p]; p+=1
    p+=1
    if p>=end: return
    child=b[p]; p+=1
    leaf=b[p]; p+=1
    if child and (child&0x80):
        walk(p,end,prefix)
    else:
        c=child
        if c:
            names.append(prefix+b[p:p+c].decode(errors='replace'))
            p+=c
    if leaf and (leaf&0x80):
        walk(p,end,prefix)
    elif leaf:
        names.append(prefix+b[p:p+leaf].decode(errors='replace'))
        p+=leaf
walk(0,len(b),'')
out=sorted(set(n for n in names if n.startswith('_CC')))
print(len(out))
for n in out: print(n)
