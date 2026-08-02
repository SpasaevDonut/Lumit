# Regenerates every raster icon from the SVG sources in assets/brand/
# (docs/15-DESIGN.md, brand section; decision K-251).
#
# In plain terms: the SVGs are the only artwork anyone edits. The operating
# systems want pixels, not drawings — Windows wants one .ico holding several
# PNG sizes, macOS wants loose PNGs — so this script renders each SVG at every
# needed size and packs the results. Each size is rendered straight from the
# SVG (not scaled down from a big render), which is what keeps the small sizes
# crisp.
#
#   pip install resvg-py pillow
#   python scripts/gen-icons.py
#
# Outputs (all committed):
#   flutter_ui/windows/runner/resources/app_icon.ico   <- lumit-mark.svg (bare)
#   flutter_ui/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_*.png
#                                                      <- lumit-icon.svg (tile)
#   assets/brand/lumit-project.ico                     <- lumit-project.svg (.lum)
#   assets/brand/lumit-preset.ico                      <- lumit-preset.svg (.lumfx)
#
# The file-type .ico files wait in assets/brand until an installer exists to
# register the .lum/.lumfx associations (docs/TODO.md, Later).

import io
from pathlib import Path

import resvg_py
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
BRAND = ROOT / "assets" / "brand"

ICO_SIZES = [256, 128, 64, 48, 32, 24, 16]
MAC_SIZES = [16, 32, 64, 128, 256, 512, 1024]


def render(svg_path: Path, size: int) -> Image.Image:
    png = bytes(resvg_py.svg_to_bytes(svg_string=svg_path.read_text(), width=size))
    return Image.open(io.BytesIO(png)).convert("RGBA")


def write_ico(svg_path: Path, out: Path) -> None:
    frames = [render(svg_path, s) for s in ICO_SIZES]
    frames[0].save(
        out,
        format="ICO",
        append_images=frames[1:],
        sizes=[(s, s) for s in ICO_SIZES],
    )
    print(f"{out.relative_to(ROOT)}: {ICO_SIZES}")


def main() -> None:
    write_ico(
        BRAND / "lumit-mark.svg",
        ROOT / "flutter_ui" / "windows" / "runner" / "resources" / "app_icon.ico",
    )
    write_ico(BRAND / "lumit-project.svg", BRAND / "lumit-project.ico")
    write_ico(BRAND / "lumit-preset.svg", BRAND / "lumit-preset.ico")

    iconset = (
        ROOT / "flutter_ui" / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    )
    for s in MAC_SIZES:
        render(BRAND / "lumit-icon.svg", s).save(iconset / f"app_icon_{s}.png")
    print(f"{iconset.relative_to(ROOT)}: {MAC_SIZES}")


if __name__ == "__main__":
    main()
