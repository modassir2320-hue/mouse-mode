# Creates mousemode.cur : arrow cursor, left half blue, right half red
from PIL import Image, ImageDraw
import io, struct

S = 32
arrow = [(1,1),(1,24),(7,18),(12,29),(16,27),(11,17),(20,17)]

def make(color):
    im = Image.new("RGBA", (S, S), (0,0,0,0))
    ImageDraw.Draw(im).polygon(arrow, fill=color, outline=(0,0,0,255))
    return im

blue, red = make((30,100,255,255)), make((230,30,30,255))
im = blue.copy()
im.paste(red.crop((8, 0, S, S)), (8, 0))

buf = io.BytesIO(); im.save(buf, "PNG"); png = buf.getvalue()
header = struct.pack("<HHH", 0, 2, 1)
entry = struct.pack("<BBBBHHII", S, S, 0, 0, 1, 1, len(png), 22)
open("mousemode.cur", "wb").write(header + entry + png)
print("mousemode.cur created")
