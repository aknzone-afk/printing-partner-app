"""12x18 gang-sheet PDF builder — a faithful port of the app's sheet_pdf.dart
layout so the Telegram order PDF matches what the shop would print: photos are
packed onto 12x18 master sheets (densest orientation), one PDF page per sheet,
then the shop prints and cuts. Falls back to None for unknown packs (caller then
uses one-photo-per-page).

Dimensions mirror app/lib/models/print_packages.dart exactly (inches):
card W x H, and the image area (polaroid has a square image + white strip)."""
from __future__ import annotations

import io
import math

SHEET_W_IN = 12.0
SHEET_H_IN = 18.0
DPI = 300
JPEG_Q = 88

# (category, normalized-label) -> (cardW, cardH, imageW, imageH) inches.
LAYOUT = {
    ("photos", "regular mini"): (3.0, 4.0, 3.0, 4.0),
    ("photos", "classic mini"): (4.0, 4.5, 4.0, 4.5),
    ("photos", "regular"): (4.0, 6.0, 4.0, 6.0),
    ("photos", "classic large"): (6.0, 6.0, 6.0, 6.0),
    ("photos", "regular large"): (6.0, 9.0, 6.0, 9.0),
    ("photos", "regular xtra-large"): (9.0, 12.0, 9.0, 12.0),
    ("polaroid", "vintage mini"): (3.0, 4.0, 2.7, 2.7),
    ("polaroid", "vintage"): (4.0, 4.5, 3.55, 3.55),
    ("polaroid", "vintage large"): (5.7, 6.0, 5.1, 5.1),
    ("snapbook", "4 x 6 snapbook"): (4.0, 6.0, 4.0, 6.0),
    ("snapbook", "6 x 6 snapbook"): (6.0, 6.0, 6.0, 6.0),
    ("snapbook", "6 x 9 snapbook"): (6.0, 9.0, 6.0, 9.0),
}
_CAT = {"photo": "photos", "photos": "photos",
        "polaroid": "polaroid", "snapbook": "snapbook"}


def _norm(s: str) -> str:
    return " ".join(str(s or "").lower().replace("×", "x").replace("inches", "").split())


def _cover(im, w, h):
    """Resize+center-crop im to exactly w x h (BoxFit.cover)."""
    from PIL import Image
    if w <= 0 or h <= 0:
        return Image.new("RGB", (max(1, w), max(1, h)), "white")
    sw, sh = im.size
    scale = max(w / sw, h / sh)
    nw, nh = max(1, int(sw * scale + 0.5)), max(1, int(sh * scale + 0.5))
    im = im.resize((nw, nh), Image.LANCZOS)
    left, top = (nw - w) // 2, (nh - h) // 2
    return im.crop((left, top, left + w, top + h))


def render_sheets(photos, category, size_label):
    """Build and return the list of 12x18 sheet images (PIL), or None if the
    pack isn't in LAYOUT."""
    if not photos:
        return None
    key = (_CAT.get(_norm(category), _norm(category)), _norm(size_label))
    dims = LAYOUT.get(key)
    if not dims:
        return None
    try:
        from PIL import Image, ImageDraw
        cardW, cardH, imgW, imgH = dims
        # Densest orientation (same rule as print_packages.perSheetOn / _fit).
        colsP, rowsP = int(SHEET_W_IN // cardW), int(SHEET_H_IN // cardH)
        colsL, rowsL = int(SHEET_W_IN // cardH), int(SHEET_H_IN // cardW)
        if colsP * rowsP >= colsL * rowsL:
            cols, rows, cw_in, ch_in, rotate = colsP, rowsP, cardW, cardH, False
        else:
            cols, rows, cw_in, ch_in, rotate = colsL, rowsL, cardH, cardW, True
        if cols < 1 or rows < 1:
            return None
        per_sheet = cols * rows
        has_strip = (imgW != cardW) or (imgH != cardH)
        margin_in = (cardW - imgW) / 2.0   # = top margin (polaroid; square image)

        sheet_w = int(SHEET_W_IN * DPI)
        sheet_h = int(SHEET_H_IN * DPI)
        # GridView fills the width: cell width = sheet/cols, height by card aspect.
        cell_w = sheet_w // cols
        cell_h = int(round(cell_w * (ch_in / cw_in)))

        n = len(photos)
        total = math.ceil(n / per_sheet)
        pages = []
        for s in range(total):
            sheet = Image.new("RGB", (sheet_w, sheet_h), "white")
            draw = ImageDraw.Draw(sheet)
            for idx in range(per_sheet):
                gi = s * per_sheet + idx
                if gi >= n:
                    break
                r, c = divmod(idx, cols)
                x, y = c * cell_w, r * cell_h
                try:
                    im = Image.open(io.BytesIO(photos[gi])).convert("RGB")
                except Exception:
                    continue
                if rotate:
                    im = im.rotate(90, expand=True)  # CCW, upright after cut
                if not has_strip:
                    sheet.paste(_cover(im, cell_w, cell_h), (x, y))
                else:
                    # Polaroid: white card, square image centered with top margin,
                    # white caption strip fills the remaining bottom.
                    iw = int(round(imgW / cw_in * cell_w))
                    ih = int(round(imgH / ch_in * cell_h))
                    lx = x + int(round(margin_in / cw_in * cell_w))
                    ly = y + int(round(margin_in / ch_in * cell_h))
                    sheet.paste(_cover(im, iw, ih), (lx, ly))
            # Crop ticks at the sheet edges at each cell boundary.
            tick = int(0.12 * DPI)
            used_rows = min(rows, math.ceil(min(per_sheet, n - s * per_sheet) / cols))
            for c in range(cols + 1):
                xx = min(c * cell_w, sheet_w - 1)
                draw.line([(xx, 0), (xx, tick)], fill=(150, 150, 150), width=2)
                yb = used_rows * cell_h
                draw.line([(xx, yb - tick), (xx, yb)], fill=(150, 150, 150), width=2)
            for r in range(used_rows + 1):
                yy = min(r * cell_h, sheet_h - 1)
                draw.line([(0, yy), (tick, yy)], fill=(150, 150, 150), width=2)
                draw.line([(cols * cell_w - tick, yy), (cols * cell_w, yy)],
                          fill=(150, 150, 150), width=2)
            pages.append(sheet)
        return pages or None
    except Exception:
        return None


def build_sheets_pdf(photos, category, size_label):
    """Return a multi-page PDF (bytes) of 12x18 gang sheets, or None if the pack
    isn't in LAYOUT (caller falls back to one-photo-per-page)."""
    pages = render_sheets(photos, category, size_label)
    if not pages:
        return None
    try:
        buf = io.BytesIO()
        pages[0].save(buf, format="PDF", save_all=True, append_images=pages[1:],
                      quality=JPEG_Q, resolution=float(DPI))
        return buf.getvalue()
    except Exception:
        return None
