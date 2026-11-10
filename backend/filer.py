"""
Printing Partner — local filer (stores order photos on the Oracle VM's own disk).

Owner 9-Nov-2026: no OneDrive — everything lives directly on the Oracle Free VM.
Files each order's INDIVIDUAL photos into a folder tree on this server:

    {DATA_ROOT}/Printing Partner/{D-M-YYYY}/{Category}/{Size}/Order {N}{A|B|C}.jpg

Only the date/category/size folders that got orders are created; scales to
thousands/day. The merchant browses + downloads via the web dashboard
(dashboard.py). ₹0 — the owner's own VM disk, no cloud-storage bill.

Env:
    DATA_ROOT   base directory (default /opt/printing-partner-backend/data)
"""
from __future__ import annotations

import os
import shutil

# "photo" is accepted by the price table (app.py _CAT_ALIASES) as an alias of
# "photos": it must land in the SAME folder, not in a second "photo" one.
_CATEGORY_TITLES = {"photos": "Photo", "photo": "Photo", "polaroid": "Polaroid",
                    "snapbook": "Snapbook"}

# One path segment may be 255 BYTES on ext4. Cap what the client can push into
# it so "Order {n}{AA}.jpg.tmp" always fits (tester fix: a 300-char order
# number answered 500 filing_failed).
_MAX_SEGMENT_BYTES = 120


class LocalFiler:
    def __init__(self) -> None:
        self.root = os.environ.get("DATA_ROOT", "/opt/printing-partner-backend/data")

    @staticmethod
    def _safe(name: str) -> str:
        # Strip characters invalid in a path segment so a size/category label
        # like "3 x 4" or an odd custom name always makes a valid folder.
        # Control characters (NUL, newline…) and lone surrogates would make
        # open() raise, so they go too; the result is capped in bytes.
        out = (name or "").strip()
        out = "".join("-" if (c in '\\/:*?"<>|' or ord(c) < 32 or ord(c) == 127) else c
                      for c in out)
        out = out.encode("utf-8", "ignore")[:_MAX_SEGMENT_BYTES].decode("utf-8", "ignore")
        return out.strip(" .") or "Unknown"

    def category_title(self, slug_or_title: str) -> str:
        s = (slug_or_title or "").strip()
        # Sanitize the category too (agent fix): an unmapped custom category
        # could otherwise carry a path separator.
        return self._safe(_CATEGORY_TITLES.get(s.lower(), s or "Other"))

    @staticmethod
    def date_folder(dt) -> str:
        return f"{dt.day}-{dt.month}-{dt.year}"

    @staticmethod
    def photo_letter(index: int) -> str:
        # 0 -> A, 25 -> Z, 26 -> AA … (bijective base-26, never runs out).
        index += 1
        s = ""
        while index > 0:
            index, r = divmod(index - 1, 26)
            s = chr(65 + r) + s
        return s

    def order_folder(self, when, category: str, size: str) -> str:
        """Folder of one order, RELATIVE to DATA_ROOT."""
        return os.path.join("Printing Partner", self.date_folder(when),
                            self.category_title(category), self._safe(size))

    def order_stem(self, order_number) -> str:
        """The sanitized order number as it appears in the file names."""
        return self._safe(str(order_number))  # NEVER trust the client value

    def order_names(self, stem: str, count: int) -> list[str]:
        """File names of an order of `count` photos (stem = order_stem())."""
        return [f"Order {stem}{self.photo_letter(i)}.jpg" for i in range(count)]

    def file_order(self, *, when, category: str, size: str, order_number: str,
                   photos: list) -> list[str]:
        """Write every photo of one order to disk; returns the paths written.
        Each photo is bytes or a readable binary file object (an upload's
        spooled temp file) - the latter is copied in 1 MB pieces, so a big
        order never sits in RAM. Atomic per file (temp + os.replace) so a crash
        never leaves a half file."""
        folder = os.path.join(self.root, self.order_folder(when, category, size))
        os.makedirs(folder, exist_ok=True)
        root_real = os.path.realpath(self.root)
        written: list[str] = []
        names = self.order_names(self.order_stem(order_number), len(photos))
        for name, jpg in zip(names, photos):
            path = os.path.join(folder, name)
            # Defence in depth: a crafted order number must never escape DATA_ROOT.
            if not os.path.realpath(path).startswith(root_real + os.sep):
                raise ValueError(f"unsafe path for order {order_number!r}")
            tmp = path + ".tmp"
            with open(tmp, "wb") as f:
                if isinstance(jpg, (bytes, bytearray, memoryview)):
                    f.write(jpg)
                else:
                    jpg.seek(0)
                    shutil.copyfileobj(jpg, f, 1024 * 1024)
            os.replace(tmp, path)  # atomic publish
            written.append(path)
        return written
