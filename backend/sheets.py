"""12x18 gang-sheet PDF builder — a faithful port of the app's sheet_pdf.dart
layout so the Telegram order PDF matches what the shop would print: photos are
packed onto 12x18 master sheets (densest orientation), one PDF page per sheet,
then the shop prints and cuts. Falls back to None for unknown packs (caller then
uses one-photo-per-page).

Memory: the VM is a ~956 MB Oracle free tier and one 300-DPI 12x18 sheet is a
~58 MB RGB image. So sheets are produced ONE AT A TIME (a generator), and the
PDF is assembled by writing each sheet to a temp JPEG and re-opening them lazily
-- peak resident memory stays at roughly a single sheet no matter how many
photos the order has, instead of holding every page at once.

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


def _plan(category, size_label):
    """Resolve the pack to a concrete sheet plan, or None if unknown. Computed
    once and shared by every sheet so the layout math is not repeated."""
    key = (_CAT.get(_norm(category), _norm(category)), _norm(size_label))
    dims = LAYOUT.get(key)
    if not dims:
        return None
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
    sheet_w = int(SHEET_W_IN * DPI)
    sheet_h = int(SHEET_H_IN * DPI)
    cell_w = sheet_w // cols            # GridView fills the width
    cell_h = int(round(cell_w * (ch_in / cw_in)))
    return {
        "cols": cols, "rows": rows, "cw_in": cw_in, "ch_in": ch_in,
        "rotate": rotate, "per_sheet": cols * rows,
        "has_strip": (imgW != cardW) or (imgH != cardH),
        "margin_in": (cardW - imgW) / 2.0,
        "imgW": imgW, "imgH": imgH,
        "sheet_w": sheet_w, "sheet_h": sheet_h,
        "cell_w": cell_w, "cell_h": cell_h,
    }


def _read_bytes(src):
    """Return raw JPEG bytes from either bytes OR a file-like stream. /ingest
    passes Werkzeug upload streams that the filer has ALREADY read to EOF, so we
    seek(0) first; samples pass plain bytes. (Opening a stream with
    io.BytesIO(stream) silently failed -> every photo skipped -> blank sheets.)"""
    if isinstance(src, (bytes, bytearray, memoryview)):
        return bytes(src)
    try:
        src.seek(0)
    except Exception:
        pass
    return src.read()


def _render_sheet(photos, start, p):
    """Render a single 12x18 sheet image for photos[start : start+per_sheet]."""
    from PIL import Image, ImageDraw
    cols, rows = p["cols"], p["rows"]
    cell_w, cell_h = p["cell_w"], p["cell_h"]
    sheet_w, sheet_h = p["sheet_w"], p["sheet_h"]
    per_sheet = p["per_sheet"]
    n = len(photos)
    sheet = Image.new("RGB", (sheet_w, sheet_h), "white")
    draw = ImageDraw.Draw(sheet)
    for idx in range(per_sheet):
        gi = start + idx
        if gi >= n:
            break
        r, c = divmod(idx, cols)
        x, y = c * cell_w, r * cell_h
        try:
            im = Image.open(io.BytesIO(_read_bytes(photos[gi]))).convert("RGB")
        except Exception:
            continue
        if p["rotate"]:
            im = im.rotate(90, expand=True)  # CCW, upright after cut
        if not p["has_strip"]:
            sheet.paste(_cover(im, cell_w, cell_h), (x, y))
        else:
            # Polaroid: white card, square image centered with top margin,
            # white caption strip fills the remaining bottom.
            iw = int(round(p["imgW"] / p["cw_in"] * cell_w))
            ih = int(round(p["imgH"] / p["ch_in"] * cell_h))
            lx = x + int(round(p["margin_in"] / p["cw_in"] * cell_w))
            ly = y + int(round(p["margin_in"] / p["ch_in"] * cell_h))
            sheet.paste(_cover(im, iw, ih), (lx, ly))
        im.close()
    # Crop ticks at the sheet edges at each cell boundary.
    tick = int(0.12 * DPI)
    used_rows = min(rows, math.ceil(min(per_sheet, n - start) / cols))
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
    return sheet


def iter_sheets(photos, category, size_label):
    """Yield the 12x18 sheet images one at a time (so the caller can process and
    free each before the next is built). Yields nothing for an unknown pack."""
    if not photos:
        return
    p = _plan(category, size_label)
    if not p:
        return
    per_sheet = p["per_sheet"]
    total = math.ceil(len(photos) / per_sheet)
    for s in range(total):
        yield _render_sheet(photos, s * per_sheet, p)


def render_sheets(photos, category, size_label):
    """Build and return the list of 12x18 sheet images (PIL), or None if the
    pack isn't in LAYOUT. Prefer iter_sheets / build_sheets_pdf on the VM; this
    materialises every page at once and is for callers that truly need the list."""
    try:
        pages = list(iter_sheets(photos, category, size_label))
        return pages or None
    except Exception:
        return None


def build_sheets_pdf(photos, category, size_label):
    """Return a multi-page PDF (bytes) of 12x18 gang sheets, or None if the pack
    isn't in LAYOUT (caller falls back to one-photo-per-page).

    Streams: each sheet is written to a temp JPEG and freed, then the JPEGs are
    re-opened lazily and written into the PDF one page at a time, so peak memory
    is ~one sheet rather than the whole order."""
    import os
    import tempfile
    try:
        from PIL import Image
    except Exception:
        return None
    tmps = []
    try:
        for sheet in iter_sheets(photos, category, size_label):
            fd, path = tempfile.mkstemp(suffix=".jpg", prefix="pp_sheet_")
            os.close(fd)
            sheet.save(path, format="JPEG", quality=JPEG_Q)
            sheet.close()               # free the ~58 MB image immediately
            tmps.append(path)
        if not tmps:
            return None
        imgs = [Image.open(p) for p in tmps]   # lazy: pixels not decoded yet
        buf = io.BytesIO()
        imgs[0].save(buf, format="PDF", save_all=True, append_images=imgs[1:],
                     resolution=float(DPI))   # PIL decodes one page at a time
        for im in imgs:
            try:
                im.close()
            except Exception:
                pass
        return buf.getvalue()
    except Exception:
        return None
    finally:
        for p in tmps:
            try:
                os.remove(p)
            except Exception:
                pass
