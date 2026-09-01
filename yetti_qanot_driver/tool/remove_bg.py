"""Remove black background from rider/driver source PNGs.

Uses a scanline flood-fill from the image borders so that dark internal
details (e.g. the rider's hair, the car's tinted windows) are preserved
while only the connected black background is made transparent.

After masking, the image is auto-cropped to the visible bounding box so
the marker scales nicely on the map.
"""

from __future__ import annotations

import os
import sys
from collections import deque

from PIL import Image

SRC_DIR = r"C:\Users\user\.cursor\projects\d-driver-app\assets"
DST_DIR = r"D:\driver app\yetti_qanot_driver\assets\icons"

JOBS = [
    {
        # Person-in-pin → rider / pickup marker.
        "src": "c__Users_user_AppData_Roaming_Cursor_User_workspaceStorage_0b623d358cb33b5916b7e71229301003_images_rider-pin-d8293f30-f729-4167-9736-972358b74c23.png",
        "dst": "rider_pin.png",
        # Threshold below which pixels are considered "background black"
        # for flood-fill purposes. Higher → more aggressive removal.
        "bg_threshold": 28,
        # Feather range (in luminance units) above the threshold over
        # which we ramp alpha from 0 → 255 to avoid hard edges.
        "feather": 18,
    },
    {
        # Top-down Tesla → driver position marker.
        "src": "c__Users_user_AppData_Roaming_Cursor_User_workspaceStorage_0b623d358cb33b5916b7e71229301003_images_driver-car-de7b6e86-2d89-4788-93c6-c56de20b5c19.png",
        "dst": "driver_car.png",
        "bg_threshold": 24,
        "feather": 16,
    },
]


def flood_fill_background(img: Image.Image, threshold: int) -> bytearray:
    """Return a bytearray (W*H) where 1 = background pixel, 0 = foreground."""
    w, h = img.size
    rgb = img.convert("RGB").tobytes()
    bg = bytearray(w * h)

    def lum(idx: int) -> int:
        r = rgb[idx * 3]
        g = rgb[idx * 3 + 1]
        b = rgb[idx * 3 + 2]
        # Rec. 601 luma; close enough for this purpose.
        return (r * 299 + g * 587 + b * 114) // 1000

    q: deque[int] = deque()

    def push(x: int, y: int) -> None:
        i = y * w + x
        if bg[i]:
            return
        if lum(i) > threshold:
            return
        bg[i] = 1
        q.append(i)

    for x in range(w):
        push(x, 0)
        push(x, h - 1)
    for y in range(h):
        push(0, y)
        push(w - 1, y)

    while q:
        i = q.popleft()
        x = i % w
        y = i // w
        if x > 0:
            push(x - 1, y)
        if x < w - 1:
            push(x + 1, y)
        if y > 0:
            push(x, y - 1)
        if y < h - 1:
            push(x, y + 1)

    return bg


def remove_background(src_path: str, dst_path: str, threshold: int, feather: int) -> None:
    img = Image.open(src_path).convert("RGB")
    w, h = img.size
    bg_mask = flood_fill_background(img, threshold)
    rgb = img.tobytes()

    out = bytearray(w * h * 4)

    for i in range(w * h):
        r = rgb[i * 3]
        g = rgb[i * 3 + 1]
        b = rgb[i * 3 + 2]
        if bg_mask[i]:
            out[i * 4 + 0] = 0
            out[i * 4 + 1] = 0
            out[i * 4 + 2] = 0
            out[i * 4 + 3] = 0
            continue

        lum = (r * 299 + g * 587 + b * 114) // 1000
        if lum <= threshold:
            alpha = 255
        elif lum <= threshold + feather:
            t = (lum - threshold) / max(1, feather)
            alpha = int(round(t * 255))
        else:
            alpha = 255

        out[i * 4 + 0] = r
        out[i * 4 + 1] = g
        out[i * 4 + 2] = b
        out[i * 4 + 3] = alpha

    rgba = Image.frombytes("RGBA", (w, h), bytes(out))
    bbox = rgba.getbbox()
    if bbox is not None:
        rgba = rgba.crop(bbox)

    os.makedirs(os.path.dirname(dst_path), exist_ok=True)
    rgba.save(dst_path, format="PNG", optimize=True)
    print(f"  -> {dst_path}  ({rgba.size[0]}x{rgba.size[1]})")


def main() -> int:
    for job in JOBS:
        src = os.path.join(SRC_DIR, job["src"])
        dst = os.path.join(DST_DIR, job["dst"])
        if not os.path.isfile(src):
            print(f"!! missing source: {src}", file=sys.stderr)
            return 1
        print(f"processing {job['dst']}")
        remove_background(src, dst, job["bg_threshold"], job["feather"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
