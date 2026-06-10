import zlib, struct, base64, math

N = 36  # icon size (px)

def png(rgba, w, h):
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type 0
        raw += rgba[y*w*4:(y+1)*w*4]
    def chunk(typ, data):
        c = struct.pack(">I", len(data)) + typ + data
        return c + struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff)
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)  # 8-bit RGBA
    idat = zlib.compress(bytes(raw), 9)
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")

def clamp(v, lo, hi): return max(lo, min(hi, v))

# State badge colors (RGB). Waves are a neutral gray visible on light+dark.
WAVE = (150, 150, 150)
BADGE = {
    "stopped":   None,
    "starting":  (240, 190, 70),   # amber ring
    "running":   (70, 200, 120),   # green dot
    "needslogin":(235, 90, 90),    # red "!"
}

def gen(state):
    nf = float(N); c = (nf - 1.0) / 2.0
    hw = nf * 0.05; amp = nf * 0.055
    k = (2*math.pi) / (nf * 0.62)
    bases = [0.27, 0.50, 0.73]; half_w = nf * 0.40
    bx = by = nf * 0.76; knock = nf * 0.25

    def disc(d, rr): return clamp(rr + 0.5 - d, 0.0, 1.0)
    def sring(d, rr, h): return clamp(h + 0.5 - abs(d - rr), 0.0, 1.0)

    buf = bytearray(N*N*4)
    badge = BADGE[state]
    for y in range(N):
        for x in range(N):
            px, py = float(x), float(y)
            a = 0.0
            if abs(px - c) <= half_w:
                for b in bases:
                    yy = nf*b + amp*math.sin((px - c)*k)
                    a = max(a, clamp(hw + 0.5 - abs(py - yy), 0.0, 1.0))
            col = WAVE
            ga = 0.0
            if badge is not None:
                db = math.hypot(px - bx, py - by)
                a *= 1.0 - disc(db, knock)  # knock out halo
                if state == "running":
                    ga = disc(db, nf*0.15)
                elif state == "starting":
                    ga = sring(db, nf*0.135, nf*0.05)
                elif state == "needslogin":
                    cyy = clamp(py, by - nf*0.13, by + nf*0.02)
                    bar = clamp(nf*0.05 + 0.5 - math.hypot(px - bx, py - cyy), 0.0, 1.0)
                    dot = clamp(nf*0.055 + 0.5 - math.hypot(px - bx, py - (by + nf*0.11)), 0.0, 1.0)
                    ga = max(bar, dot)
            i = (y*N + x)*4
            if ga > a:
                r, g, bl = badge; alpha = ga
            else:
                r, g, bl = WAVE; alpha = a
            buf[i] = r; buf[i+1] = g; buf[i+2] = bl
            buf[i+3] = int(round(alpha*255))
    return base64.b64encode(png(buf, N, N)).decode()

for s in ["stopped", "starting", "running", "needslogin"]:
    print(s, gen(s))
