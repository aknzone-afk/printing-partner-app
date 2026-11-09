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

_CATEGORY_TITLES = {"photos": "Photo", "polaroid": "Polaroid", "snapbook": "Snapbook"}


class LocalFiler:
    def __init__(self) -> None:
        self.root = os.environ.get("DATA_ROOT", "/opt/printing-partner-backend/data")

    @staticmethod
    def _safe(name: str) -> str:
        # Strip characters invalid in a path segment so a size/category label
        # like "3 x 4" or an odd custom name always makes a valid folder.
        out = (name or "").strip()
        for bad in '\\/:*?"<>|':
            out = out.replace(bad, "-")
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

    def file_order(self, *, when, category: str, size: str, order_number: str,
                   photos: list[bytes]) -> list[str]:
        """Write every photo of one order to disk; returns the paths written.
        Atomic per file (temp + os.replace) so a crash never leaves a half file."""
        folder = os.path.join(
            self.root,
            "Printing Partner",
            self.date_folder(when),
            self.category_title(category),
            self._safe(size),
        )
        os.makedirs(folder, exist_ok=True)
        safe_num = self._safe(str(order_number))  # NEVER trust the client value
        root_real = os.path.realpath(self.root)
        written: list[str] = []
        for i, jpg in enumerate(photos):
            name = f"Order {safe_num}{self.photo_letter(i)}.jpg"
            path = os.path.join(folder, name)
            # Defence in depth: a crafted order number must never escape DATA_ROOT.
            if not os.path.realpath(path).startswith(root_real + os.sep):
                raise ValueError(f"unsafe path for order {order_number!r}")
            tmp = path + ".tmp"
            with open(tmp, "wb") as f:
                f.write(jpg)
            os.replace(tmp, path)  # atomic publish
            written.append(path)
        return written
