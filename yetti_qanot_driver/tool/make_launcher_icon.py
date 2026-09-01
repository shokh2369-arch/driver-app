"""Build launcher / store icons with the emblem + visible DRIVER label."""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "assets" / "launcher" / "app_icon_source.png"
LAUNCHER_OUT = ROOT / "assets" / "launcher" / "app_icon.png"
# Google Play Console → Main store listing → App icon (512 × 512 PNG, max 1 MB).
STORE_OUT = ROOT / "store_listing" / "icon_512x512.png"
PLAY_ICON_SIZE = 512
CANVAS = 1024
EMBLEM_MAX_FRAC = 0.52
LABEL = "DRIVER"
LABEL_COLOR = (26, 77, 46)  # brand green
STORE_GRAD_TOP = (56, 189, 248)
STORE_GRAD_BOTTOM = (74, 222, 128)


def _font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = (
        Path(r"C:\Windows\Fonts\arialbd.ttf"),
        Path(r"C:\Windows\Fonts\segoeuib.ttf"),
        Path("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"),
        Path("/System/Library/Fonts/Supplemental/Arial Bold.ttf"),
    )
    for path in candidates:
        if path.is_file():
            return ImageFont.truetype(str(path), size=size)
    return ImageFont.load_default()


def _is_fg(r: int, g: int, b: int, a: int) -> bool:
    if a <= 25:
        return False
    return max(abs(r - 255), abs(g - 255), abs(b - 255)) > 15


def extract_emblem(img: Image.Image) -> Image.Image:
    """Crop the pin + wings emblem from the full marketing source (no text)."""
    px = img.load()
    w0, h0 = img.size

    x0, y0, x1, y1 = w0, h0, -1, -1
    row_counts = [0] * h0
    for y in range(h0):
        c = 0
        for x in range(w0):
            r, g, b, a = px[x, y]
            if _is_fg(r, g, b, a):
                c += 1
                x0 = min(x0, x)
                x1 = max(x1, x)
                y0 = min(y0, y)
                y1 = max(y1, y)
        row_counts[y] = c

    if x1 < 0:
        raise SystemExit("No foreground detected in source icon")

    maxc = float(max(row_counts[y0 : y1 + 1]) or 1.0)
    thr = maxc * 0.03
    low = [c < thr for c in row_counts]

    start = int(y0 + (y1 - y0) * 0.25)
    end = int(y0 + (y1 - y0) * 0.85)

    best_len, best_s = 0, None
    run_s = None
    for y in range(start, end + 1):
        if low[y]:
            if run_s is None:
                run_s = y
        elif run_s is not None:
            run_len = y - run_s
            if run_len > best_len:
                best_len, best_s = run_len, run_s
            run_s = None
    if run_s is not None:
        run_len = end + 1 - run_s
        if run_len > best_len:
            best_len, best_s = run_len, run_s

    crop_y1 = int(best_s + 10) if best_len >= 12 and best_s is not None else int(y0 + (y1 - y0) * 0.60)
    crop = img.crop((x0, y0, x1 + 1, max(y0 + 1, crop_y1)))

    px2 = crop.load()
    w2, h2 = crop.size
    cx0, cy0, cx1, cy1 = w2, h2, -1, -1
    for y in range(h2):
        for x in range(w2):
            r, g, b, a = px2[x, y]
            if _is_fg(r, g, b, a):
                cx0 = min(cx0, x)
                cx1 = max(cx1, x)
                cy0 = min(cy0, y)
                cy1 = max(cy1, y)
    if cx1 >= 0:
        crop = crop.crop((cx0, cy0, cx1 + 1, cy1 + 1))
    return crop


def _gradient_bg(size: int) -> Image.Image:
    base = Image.new("RGB", (size, size))
    px = base.load()
    for y in range(size):
        t = y / max(1, size - 1)
        r = int(STORE_GRAD_TOP[0] * (1 - t) + STORE_GRAD_BOTTOM[0] * t)
        g = int(STORE_GRAD_TOP[1] * (1 - t) + STORE_GRAD_BOTTOM[1] * t)
        b = int(STORE_GRAD_TOP[2] * (1 - t) + STORE_GRAD_BOTTOM[2] * t)
        for x in range(size):
            px[x, y] = (r, g, b)
    return base.convert("RGBA")


def _compose_icon(
    *,
    background: Image.Image,
    emblem: Image.Image,
    label: str,
    label_color: tuple[int, int, int],
    label_size_frac: float = 0.11,
) -> Image.Image:
    canvas = background.copy().convert("RGBA")
    size = canvas.size[0]

    font_size = max(48, int(size * label_size_frac))
    font = _font(font_size)
    draw = ImageDraw.Draw(canvas)
    bbox = draw.textbbox((0, 0), label, font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]

    label_band = int(th * 1.55)
    emblem_max_h = int(size * EMBLEM_MAX_FRAC)
    emblem_max_w = int(size * 0.78)
    ew, eh = emblem.size
    scale = min(emblem_max_w / ew, emblem_max_h / eh)
    new_w, new_h = int(round(ew * scale)), int(round(eh * scale))
    resized = emblem.resize((new_w, new_h), Image.Resampling.LANCZOS)

    total_h = new_h + label_band
    top_y = (size - total_h) // 2
    ox = (size - new_w) // 2
    canvas.alpha_composite(resized, (ox, top_y))

    tx = (size - tw) // 2
    ty = top_y + new_h + (label_band - th) // 2
    draw.text((tx, ty), label, fill=label_color, font=font)
    return canvas


def build_launcher_icon(emblem: Image.Image) -> Image.Image:
    bg = Image.new("RGBA", (CANVAS, CANVAS), (255, 255, 255, 255))
    icon = _compose_icon(
        background=bg,
        emblem=emblem,
        label=LABEL,
        label_color=LABEL_COLOR,
    )
    rgb = icon.convert("RGB")
    rgb.save(LAUNCHER_OUT, "PNG", optimize=True)
    print(f"Wrote {LAUNCHER_OUT}")
    return rgb


def build_play_store_icon(launcher: Image.Image) -> None:
    """512×512 high-res icon — same artwork as the installed launcher (Play requirement)."""
    STORE_OUT.parent.mkdir(parents=True, exist_ok=True)
    play = launcher.resize((PLAY_ICON_SIZE, PLAY_ICON_SIZE), Image.Resampling.LANCZOS)
    if play.size != (PLAY_ICON_SIZE, PLAY_ICON_SIZE):
        raise SystemExit(f"Play icon must be {PLAY_ICON_SIZE}px, got {play.size}")
    play.save(STORE_OUT, "PNG", optimize=True)
    print(f"Wrote {STORE_OUT} ({PLAY_ICON_SIZE}x{PLAY_ICON_SIZE})")


def build_store_gradient_icon(emblem: Image.Image) -> None:
    """Optional marketing variant (gradient) — not required for Play upload."""
    bg = _gradient_bg(PLAY_ICON_SIZE)
    icon = _compose_icon(
        background=bg,
        emblem=emblem,
        label=LABEL,
        label_color=(255, 255, 255),
        label_size_frac=0.13,
    )
    grad_out = ROOT / "store_listing" / "icon_512x512_gradient.png"
    icon.convert("RGB").save(grad_out, "PNG", optimize=True)
    print(f"Wrote {grad_out}")


def main() -> None:
    if not SRC.is_file():
        raise SystemExit(f"Missing source: {SRC}")
    src = Image.open(SRC).convert("RGBA")
    emblem = extract_emblem(src)
    launcher_rgb = build_launcher_icon(emblem)
    build_play_store_icon(launcher_rgb)
    build_store_gradient_icon(emblem)


if __name__ == "__main__":
    main()
