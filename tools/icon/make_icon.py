# ruff: noqa: E501  (inline SVG markup reads better unwrapped)
"""Generate the MRRos app icon (default, dark and tinted variants) from code.

The icon: a white robot arm on its pedestal over a translucent cyan "ghost" of itself, offset like
an AR overlay that hasn't been aligned yet, with the robot's base_link axes (X red, Y green,
Z blue) at its foot. That is the app in one picture: align the virtual robot with the real one.

  uvx --with pillow python tools/icon/make_icon.py          # writes the asset catalog PNGs
  uvx --with pillow python tools/icon/make_icon.py --preview /tmp/icon_preview.png

Needs `rsvg-convert` (brew install librsvg). Pillow only flattens the default icon (the App
Store icon must not have an alpha channel).
"""

import argparse
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "ios/MRRos/Assets.xcassets/AppIcon.appiconset"

# Arm pose (1024 x 1024 canvas): shoulder on the pedestal -> elbow -> wrist -> tool.
SHOULDER, ELBOW, WRIST, TOOL = (468, 724), (338, 452), (648, 326), (716, 424)
GHOST_OFFSET = (40, -30)


def arm(color: str, joint_color: str | None, opacity: float = 1.0) -> str:
    def seg(a, b, w):
        return f'<path d="M{a[0]},{a[1]} L{b[0]},{b[1]}" stroke-width="{w}"/>'

    joints = ""
    if joint_color:
        joints = (
            f'<circle cx="{SHOULDER[0]}" cy="{SHOULDER[1]}" r="30" fill="{joint_color}"/>'
            f'<circle cx="{ELBOW[0]}" cy="{ELBOW[1]}" r="24" fill="{joint_color}"/>'
            f'<circle cx="{WRIST[0]}" cy="{WRIST[1]}" r="18" fill="{joint_color}"/>'
        )
    # Gripper: two short prongs at the tool end, perpendicular to the last link.
    dx, dy = TOOL[0] - WRIST[0], TOOL[1] - WRIST[1]
    n = (dx * dx + dy * dy) ** 0.5
    px, py = -dy / n * 34, dx / n * 34
    fx, fy = dx / n * 44, dy / n * 44
    prongs = "".join(
        f'<path d="M{TOOL[0] + s * px},{TOOL[1] + s * py} L{TOOL[0] + s * px + fx},{TOOL[1] + s * py + fy}" stroke-width="22"/>'
        for s in (-1, 1)
    )
    bar = f'<path d="M{TOOL[0] - px},{TOOL[1] - py} L{TOOL[0] + px},{TOOL[1] + py}" stroke-width="22"/>'
    return (
        f'<g fill="none" stroke="{color}" stroke-linecap="round" stroke-linejoin="round" opacity="{opacity}">'
        f"{seg(SHOULDER, ELBOW, 104)}{seg(ELBOW, WRIST, 80)}{seg(WRIST, TOOL, 50)}{bar}{prongs}</g>{joints}"
    )


def pedestal(color: str) -> str:
    return (
        f'<rect x="388" y="716" width="160" height="128" rx="26" fill="{color}"/>'
        f'<rect x="318" y="826" width="300" height="50" rx="20" fill="{color}"/>'
    )


def triad(x: float, y: float, colors: tuple[str, str, str], s: float = 0.6, w: float = 22) -> str:
    axes = [(-150, 64), (165, 58), (0, -185)]
    return "".join(
        f'<line x1="{x}" y1="{y}" x2="{x + dx * s}" y2="{y + dy * s}" stroke="{c}" '
        f'stroke-width="{w}" stroke-linecap="round"/>'
        for (dx, dy), c in zip(axes, colors, strict=True)
    )


def scene(*, arm_color, joint_color, ghost_color, ghost_opacity, axes, background: str = "") -> str:
    gx, gy = GHOST_OFFSET
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
{background}
<g transform="translate({gx},{gy})">{arm(ghost_color, None, ghost_opacity)}</g>
{pedestal(arm_color)}
{arm(arm_color, joint_color)}
{triad(262, 896, axes)}
</svg>"""


RGB_AXES = ("#FF453A", "#30D158", "#0A84FF")
NAVY_BG = """<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
<stop offset="0" stop-color="#1B2A44"/><stop offset="1" stop-color="#0A111E"/></linearGradient></defs>
<rect width="1024" height="1024" fill="url(#bg)"/>"""

VARIANTS = {
    # Opaque, for the App Store and the default home screen.
    "AppIcon.png": dict(
        arm_color="#F2F5FA",
        joint_color="#14213A",
        ghost_color="#64D2FF",
        ghost_opacity=0.55,
        axes=RGB_AXES,
        background=NAVY_BG,
    ),
    # Dark mode: transparent background (iOS draws its own dark backdrop).
    "AppIcon-Dark.png": dict(
        arm_color="#EEF2F8",
        joint_color="#1A1A1E",
        ghost_color="#64D2FF",
        ghost_opacity=0.6,
        axes=RGB_AXES,
    ),
    # Tinted: grayscale on transparent; iOS colours it with the user's tint.
    "AppIcon-Tinted.png": dict(
        arm_color="#FFFFFF",
        joint_color="#000000",
        ghost_color="#FFFFFF",
        ghost_opacity=0.38,
        axes=("#B8B8B8", "#B8B8B8", "#FFFFFF"),
    ),
}


def render(svg: str, out: Path) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as f:
        f.write(svg)
    subprocess.run(["rsvg-convert", "-w", "1024", "-h", "1024", f.name, "-o", str(out)], check=True)


def flatten(path: Path) -> None:
    from PIL import Image

    Image.open(path).convert("RGB").save(path)


def preview(dest: Path, files: dict[str, Path]) -> None:
    """Each variant as iOS shows it (rounded square; dark/tinted over a dark backdrop), large
    and at home-screen sizes."""
    from PIL import Image, ImageDraw

    def masked(img, size, backdrop):
        canvas = Image.new("RGBA", (size, size), backdrop)
        canvas.alpha_composite(img.resize((size, size), Image.LANCZOS))
        mask = Image.new("L", (size, size), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            (0, 0, size - 1, size - 1), radius=size * 0.2237, fill=255
        )
        out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        out.paste(canvas, (0, 0), mask)
        return out

    backdrops = {
        "AppIcon.png": (0, 0, 0, 255),
        "AppIcon-Dark.png": (24, 24, 28, 255),
        "AppIcon-Tinted.png": (24, 24, 28, 255),
    }
    sheet = Image.new("RGBA", (3 * 380, 470), (236, 236, 240, 255))
    for i, (name, path) in enumerate(files.items()):
        img = Image.open(path).convert("RGBA")
        if name == "AppIcon-Tinted.png":  # simulate an iOS tint (orange): luminance x tint colour
            lum = img.convert("L")
            img = Image.merge(
                "RGBA",
                [lum.point(lambda v, c=c: v * c // 255) for c in (255, 159, 10)] + [img.split()[3]],
            )
        x = i * 380 + 40
        sheet.alpha_composite(masked(img, 300, backdrops[name]), (x, 20))
        sheet.alpha_composite(masked(img, 60, backdrops[name]), (x + 110, 360))
        sheet.alpha_composite(masked(img, 40, backdrops[name]), (x + 190, 370))
    sheet.save(dest)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", type=Path, help="also write a preview sheet here")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    files = {}
    for name, params in VARIANTS.items():
        path = OUT / name
        render(scene(**params), path)
        files[name] = path
    flatten(OUT / "AppIcon.png")
    print(f"wrote {', '.join(files)} to {OUT.relative_to(ROOT)}")
    if args.preview:
        preview(args.preview, files)
        print(f"preview: {args.preview}")


if __name__ == "__main__":
    main()
