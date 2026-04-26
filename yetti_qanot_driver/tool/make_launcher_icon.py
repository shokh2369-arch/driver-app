from __future__ import annotations

from pathlib import Path

from PIL import Image


def main() -> None:
    src = Path(r"d:\driver app\yetti_qanot_driver\assets\launcher\app_icon_source.png")
    out = Path(r"d:\driver app\yetti_qanot_driver\assets\launcher\app_icon.png")
    img = Image.open(src).convert("RGBA")
    px = img.load()
    w0, h0 = img.size

    def is_fg(r: int, g: int, b: int, a: int) -> bool:
        if a <= 25:
            return False
        # sufficiently far from white
        return max(abs(r - 255), abs(g - 255), abs(b - 255)) > 15

    x0, y0, x1, y1 = w0, h0, -1, -1
    row_counts = [0] * h0
    for y in range(h0):
        c = 0
        for x in range(w0):
            r, g, b, a = px[x, y]
            if is_fg(r, g, b, a):
                c += 1
                if x < x0:
                    x0 = x
                if x > x1:
                    x1 = x
                if y < y0:
                    y0 = y
                if y > y1:
                    y1 = y
        row_counts[y] = c

    if x1 < 0:
        raise SystemExit("No foreground detected")

    # Find a low-density horizontal gap between emblem and text.
    maxc = float(max(row_counts[y0 : y1 + 1]) or 1.0)
    thr = maxc * 0.03
    low = [c < thr for c in row_counts]

    start = int(y0 + (y1 - y0) * 0.25)
    end = int(y0 + (y1 - y0) * 0.85)

    best_len, best_s, best_e = 0, None, None
    run_s = None
    for y in range(start, end + 1):
        if bool(low[y]):
            if run_s is None:
                run_s = y
        else:
            if run_s is not None:
                run_len = y - run_s
                if run_len > best_len:
                    best_len, best_s, best_e = run_len, run_s, y - 1
                run_s = None
    if run_s is not None:
        run_len = end + 1 - run_s
        if run_len > best_len:
            best_len, best_s, best_e = run_len, run_s, end

    if best_len >= 12 and best_s is not None:
        # Crop to the emblem above the whitespace gap (keep a bit of swoosh).
        crop_y1 = int(best_s + 10)
    else:
        crop_y1 = int(y0 + (y1 - y0) * 0.60)

    crop = img.crop((x0, y0, x1 + 1, max(y0 + 1, crop_y1)))

    # Tighten crop again.
    px2 = crop.load()
    w2, h2 = crop.size
    cx0, cy0, cx1, cy1 = w2, h2, -1, -1
    for y in range(h2):
        for x in range(w2):
            r, g, b, a = px2[x, y]
            if is_fg(r, g, b, a):
                if x < cx0:
                    cx0 = x
                if x > cx1:
                    cx1 = x
                if y < cy0:
                    cy0 = y
                if y > cy1:
                    cy1 = y
    if cx1 >= 0:
        crop = crop.crop((cx0, cy0, cx1 + 1, cy1 + 1))

    canvas_size = 1024
    canvas = Image.new("RGBA", (canvas_size, canvas_size), (255, 255, 255, 255))

    max_dim = int(canvas_size * 0.70)
    w, h = crop.size
    scale = min(max_dim / w, max_dim / h)
    new_w, new_h = int(round(w * scale)), int(round(h * scale))
    resized = crop.resize((new_w, new_h), Image.Resampling.LANCZOS)

    ox = (canvas_size - new_w) // 2
    # Optical centering: nudge slightly upward, but never clip.
    oy = (canvas_size - new_h) // 2 - int(canvas_size * 0.03)
    if oy < 0:
        oy = 0
    canvas.alpha_composite(resized, (ox, oy))

    canvas.convert("RGB").save(out, "PNG", optimize=True)
    print(f"Wrote {out} (emblem {new_w}x{new_h} on {canvas_size}x{canvas_size})")


if __name__ == "__main__":
    main()

