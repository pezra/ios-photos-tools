"""Makes test photos: JPEGs with EXIF dates spread over several years.

Names repeat every 300 photos (IMG_0001 again in a later year), like a camera counter wrapping, so
name clashes come up. Each picture has its own noise, so no two files are the same size by accident.

    python3 make-fixtures.py OUT_DIR [COUNT]
"""
import os
import random
import sys
from datetime import datetime, timedelta

from PIL import Image

out = sys.argv[1]
count = int(sys.argv[2]) if len(sys.argv) > 2 else 300
os.makedirs(out, exist_ok=True)
rng = random.Random(1)
start = datetime(2015, 1, 1, 9, 0, 0)

for i in range(count):
    taken = start + timedelta(days=int(i * 3650 / max(count, 1)), minutes=rng.randrange(600))
    name = "IMG_%04d.JPG" % (i % 300 + 1)
    folder = os.path.join(out, str(taken.year))
    os.makedirs(folder, exist_ok=True)
    width, height = 640, 480
    image = Image.new("RGB", (width, height), (rng.randrange(256), rng.randrange(256), rng.randrange(256)))
    pixels = image.load()
    for _ in range(2000):
        pixels[rng.randrange(width), rng.randrange(height)] = (rng.randrange(256), rng.randrange(256), rng.randrange(256))
    exif = Image.Exif()
    stamp = taken.strftime("%Y:%m:%d %H:%M:%S")
    exif[0x0132] = stamp  # DateTime
    exif[0x9003] = stamp  # DateTimeOriginal
    image.save(os.path.join(folder, name), "JPEG", quality=85, exif=exif.tobytes())

print("Made %d photos in %s, in year folders." % (count, out))
