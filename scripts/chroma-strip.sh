#!/usr/bin/env bash
# tandem — chroma-key transparency for gpt-image-2 renders. The model cannot
# emit transparent backgrounds, so the image is generated on a flat key colour
# and this script turns that colour into a real alpha channel.
#
# Backends, best first:
#   python3 + Pillow  graded alpha ramp + edge despill (clean sprite edges)
#   ImageMagick       magick/convert -fuzz … -transparent (binary alpha, coarser)
#
# usage: chroma-strip.sh <input> <output> [key-colour] [tolerance]
#        chroma-strip.sh --check <file>
#   key-colour  '#rrggbb' hex, default '#00ff00' (use '#ff00ff' for green subjects)
#   tolerance   0-100, colour distance treated as background (default 12)
#   --check     verify <file> has an alpha channel that is actually used
# exit codes: 0 ok · 1 processing failure · 2 check failed (no usable alpha)
#             3 no backend available · 64 usage error

set -euo pipefail
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

have_pillow() {
  command -v python3 >/dev/null 2>&1 && python3 -c 'import PIL.Image' >/dev/null 2>&1
}

# im_bin — prints 'magick' (IM7) or 'convert' (IM6), or nothing.
im_bin() {
  if command -v magick >/dev/null 2>&1; then printf 'magick'
  elif command -v convert >/dev/null 2>&1; then printf 'convert'
  fi
}

# --- check mode -------------------------------------------------------------
if [ "${1:-}" = "--check" ]; then
  [ $# -eq 2 ] || die "usage: chroma-strip.sh --check <file>" 64
  [ -f "$2" ] || die "file not found: $2" 64
  if have_pillow; then
    CS_IN="$2" python3 - <<'PY'
import os, sys
from PIL import Image
im = Image.open(os.environ["CS_IN"])
if "A" not in im.getbands():
    print(f"chroma-strip --check: FAIL — {os.environ['CS_IN']} has no alpha channel")
    sys.exit(2)
a = im.convert("RGBA").getchannel("A")
lo, hi = a.getextrema()
if lo == 255:
    print(f"chroma-strip --check: FAIL — alpha channel present but fully opaque")
    sys.exit(2)
n = im.size[0] * im.size[1]
print(f"chroma-strip --check: ok — {im.size[0]}x{im.size[1]}, "
      f"{a.histogram()[0] * 100 // max(n, 1)}% fully transparent, alpha range {lo}-{hi}")
PY
    exit $?
  fi
  IM="$(im_bin)"
  [ -n "$IM" ] || die "no backend to check with — install Pillow (pip3 install Pillow) or ImageMagick (brew install imagemagick)" 3
  if [ "$IM" = "magick" ]; then INFO="$(magick identify -format '%[channels] %[opaque]' "$2" 2>/dev/null)"
  else INFO="$(identify -format '%[channels] %[opaque]' "$2" 2>/dev/null)"; fi
  case "$INFO" in
    *[Aa]lpha*[Ff]alse* | *rgba*[Ff]alse* | *srgba*[Ff]alse*)
      printf 'chroma-strip --check: ok — %s (%s)\n' "$2" "$INFO" ;;
    *)
      printf 'chroma-strip --check: FAIL — no usable alpha in %s (%s)\n' "$2" "$INFO"
      exit 2 ;;
  esac
  exit 0
fi

# --- strip mode -------------------------------------------------------------
[ $# -ge 2 ] || die "usage: chroma-strip.sh <input> <output> [key-colour] [tolerance]" 64
IN="$1" OUT="$2" KEY="${3:-#00ff00}" TOL="${4:-12}"
[ -f "$IN" ] || die "input not found: $IN" 64
case "$KEY" in
  '#'[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) : ;;
  *) die "key colour must be '#rrggbb' hex, got: $KEY" 64 ;;
esac
case "$TOL" in
  '' | *[!0-9]*) die "tolerance must be an integer 0-100, got: $TOL" 64 ;;
esac
[ "$TOL" -le 100 ] || die "tolerance must be an integer 0-100, got: $TOL" 64

if have_pillow; then
  CS_IN="$IN" CS_OUT="$OUT" CS_KEY="$KEY" CS_TOL="$TOL" python3 - <<'PY'
import os
from PIL import Image, ImageChops

inp, outp = os.environ["CS_IN"], os.environ["CS_OUT"]
key = os.environ["CS_KEY"].lstrip("#")
tol = int(os.environ["CS_TOL"])
kr, kg, kb = (int(key[i:i + 2], 16) for i in (0, 2, 4))

img = Image.open(inp).convert("RGB")
# Chebyshev distance to the key colour, channel-wise in C (no numpy needed).
diff = ImageChops.difference(img, Image.new("RGB", img.size, (kr, kg, kb)))
dr, dg, db = diff.split()
dist = ImageChops.lighter(ImageChops.lighter(dr, dg), db)

# Alpha ramp: fully transparent up to t0, fully opaque from t1 — the gradient
# in between keeps anti-aliased sprite edges soft instead of jagged.
t0 = max(1, round(255 * tol / 100))
t1 = min(255, t0 + 60)
lut = [0 if v <= t0 else 255 if v >= t1 else round(255 * (v - t0) / (t1 - t0))
       for v in range(256)]
alpha = dist.point(lut)

# Despill: on non-opaque pixels (the matte edge), clamp the key's dominant
# channel to the max of the other two so borders lose the green/magenta tint.
r, g, b = img.split()
chans = {"r": (r, kr), "g": (g, kg), "b": (b, kb)}
dom = max(chans, key=lambda c: chans[c][1])
others = [c for c in "rgb" if c != dom]
clamped = ImageChops.darker(
    chans[dom][0],
    ImageChops.lighter(chans[others[0]][0], chans[others[1]][0]))
edge = alpha.point(lambda a: 255 if a < 255 else 0)
merged = {dom: Image.composite(clamped, chans[dom][0], edge),
          others[0]: chans[others[0]][0],
          others[1]: chans[others[1]][0]}
out = Image.merge("RGBA", (merged["r"], merged["g"], merged["b"], alpha))
out.save(outp)
n = out.size[0] * out.size[1]
print(f"chroma-strip: {outp} {out.size[0]}x{out.size[1]} — "
      f"{alpha.histogram()[0] * 100 // max(n, 1)}% fully transparent "
      f"(pillow: graded alpha + despill)")
PY
  exit 0
fi

IM="$(im_bin)"
[ -n "$IM" ] || die "no chroma-key backend — install Pillow (pip3 install Pillow) or ImageMagick (brew install imagemagick)" 3
"$IM" "$IN" -alpha set -fuzz "${TOL}%" -transparent "$KEY" "$OUT" \
  || die "ImageMagick failed stripping $KEY from $IN" 1
printf 'chroma-strip: %s (imagemagick: binary alpha, no despill — install Pillow for cleaner edges)\n' "$OUT"
