"""Package generated PNG representations into a standard ICNS container."""
import pathlib, struct, sys
root, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
representations = [('icp4',16,1),('ic11',16,2),('icp5',32,1),('ic12',32,2),('ic07',128,1),('ic13',128,2),('ic08',256,1),('ic14',256,2),('ic09',512,1),('ic10',512,2)]
chunks=[]
for tag,size,scale in representations:
    suffix = '@2x' if scale == 2 else ''
    png=(root/f'icon_{size}x{size}{suffix}.png').read_bytes()
    assert png[:8] == b'\x89PNG\r\n\x1a\n'
    chunks.append(tag.encode()+struct.pack('>I',len(png)+8)+png)
data=b''.join(chunks)
target.write_bytes(b'icns'+struct.pack('>I',len(data)+8)+data)
