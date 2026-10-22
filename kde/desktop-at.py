#!/usr/bin/env python3
"""When the Plasma desktop first showed, from a run's frames (run-native.sh
OUT/frames, best with GEX_PPM_EVERY=1): the first frame whose bottom rows are
the panel (mostly Breeze's light grey) over a wallpaper (no colour taking
most of the upper screen). Prints that frame, its time and the seconds
since the first frame.

    kde/desktop-at.py OUT/frames
"""
import os, sys, time
from collections import Counter


def read_ppm(path):
    with open(path, 'rb') as f:
        d = f.read()
    parts, i = [], 0
    while len(parts) < 4:
        j = d.index(b'\n', i)
        line = d[i:j]
        i = j + 1
        if line.startswith(b'#'):
            continue
        parts += line.split()
    w, h = int(parts[1]), int(parts[2])
    return w, h, d[i:]


def is_desktop(path):
    w, h, px = read_ppm(path)
    light = total = 0
    for y in range(h - 40, h, 4):
        for x in range(0, w, 8):
            o = (y * w + x) * 3
            total += 1
            if min(px[o], px[o + 1], px[o + 2]) > 200:
                light += 1
    top = Counter(px[(y * w + x) * 3:(y * w + x) * 3 + 3] for y in range(0, h - 80, 16) for x in range(0, w, 16))
    biggest = top.most_common(1)[0][1] / sum(top.values())
    return light / total > 0.5 and biggest < 0.2


def main():
    d = sys.argv[1]
    frames = sorted(f for f in os.listdir(d) if f.endswith('.ppm'))
    if not frames:
        sys.exit('no frames')
    t0 = os.path.getmtime(os.path.join(d, frames[0]))
    for f in frames:
        p = os.path.join(d, f)
        if is_desktop(p):
            t = os.path.getmtime(p)
            print('%s %s %.0f s after the first frame' % (f, time.strftime('%T', time.localtime(t)), t - t0))
            return
    print('no desktop in %d frames' % len(frames))
    sys.exit(1)


if __name__ == '__main__':
    main()
