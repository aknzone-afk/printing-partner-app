"""
Printing Partner backend — one self-contained Flask service on the Oracle VM.

Owner 9-Nov-2026: no OneDrive, no Firebase-admin. The app talks to THIS server
directly, so the server (not the phone) is the source of truth for money.

Endpoints
  GET  /health                 -> {"ok": true}            (no auth)
  POST /verify-payment         screenshot + amount -> Gemini reads it SERVER-SIDE.
                               On a genuine success it returns a short-lived,
                               HMAC-signed token. The phone cannot forge it, so a
                               customer can never fake "payment received".
  POST /ingest                 cropped photos + order meta + the payment token ->
                               filed to the VM disk tree (filer.py). Rejects a
                               missing/forged token (402 payment_required), a stale
                               one (402 token_expired -> app re-verifies), a paid
                               amount that does not match the pack's catalog price
                               (402 amount_mismatch), more photos than the pack
                               (400) and a REUSED UTR (409, one payment, one order).
                               A retry of the SAME order after a lost response
                               answers 200 {duplicate:true} instead of 409 (also
                               when the token has expired meanwhile). An order
                               number whose photos belong to ANOTHER payment is
                               refused (400 order_number_taken) instead of being
                               overwritten; an empty photo is 400 empty_photo; a
                               body beyond the biggest pack x 12 MB is 413.
  POST /chat                   order facts + question -> Gemini order assistant.
  GET  /  /dashboard           merchant browse + per-order ZIP download (password).

Secrets (env, see env.example)
  GEMINI_API_KEY     Google AI Studio key (owner-supplied; the one thing I can't
                     mint myself). Until it is set, /verify-payment and /chat
                     answer 503 ai_unconfigured and the app degrades gracefully.
  PAYMENT_SECRET     random; signs the payment token. Generated on deploy.
  API_TOKEN          shared app<->server token on /verify-payment and /chat
                     (raises the bar on Gemini-quota abuse).
  DASHBOARD_PASSWORD merchant web login.
  DATA_ROOT          where photos + the payments ledger live on this VM's disk.
"""
from __future__ import annotations

import base64
import contextlib
import datetime
import hashlib
import hmac
import io
import json
import os
import secrets
import time
import zipfile
from datetime import timezone
from html import escape
from urllib.parse import quote

from flask import Flask, request, jsonify, Response, abort

from filer import LocalFiler

try:
    import fcntl  # POSIX only (the VM); absent on a Windows dev box
except ImportError:  # pragma: no cover
    fcntl = None

try:
    from zoneinfo import ZoneInfo
    IST = ZoneInfo("Asia/Kolkata")
except Exception:  # pragma: no cover
    IST = timezone(datetime.timedelta(hours=5, minutes=30))

GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "").strip()
PAYMENT_SECRET = os.environ.get("PAYMENT_SECRET", "").encode() or secrets.token_bytes(32)
API_TOKEN = os.environ.get("API_TOKEN", "").strip()
DASHBOARD_PASSWORD = os.environ.get("DASHBOARD_PASSWORD", "").strip()
AMOUNT_TOLERANCE = 1.0            # ±₹1
TOKEN_TTL = 24 * 3600            # token valid 24 h (a resumed upload must not die);
                                 # safe because the UTR inside it is single-use.
GLOBAL_MIN_RUPEES = 150.0        # cheapest pack in the catalog — absolute floor
MAX_PHOTO_BYTES = 12 * 1024 * 1024
MAX_PHOTOS = 200
# placedAt comes from the PHONE's clock. Outside this window (wrong phone date)
# the order is filed under the server's own date, never in a folder the
# merchant would not open ("1-1-1", next year…).
PLACED_MAX_AGE = 45 * 24 * 3600
PLACED_MAX_AHEAD = 24 * 3600

filer = LocalFiler()
app = Flask(__name__)

# ------------------------------------------------------------ price catalog
# The phone states the amount to /verify-payment, so a dishonest client could
# pay ₹10 for a ₹300 pack. The token therefore carries the amount Gemini saw,
# and /ingest insists it covers the cheapest pack of that category+size that
# holds the photos uploaded. catalog.json mirrors print_packages.dart.
_CATALOG: list[dict] = []
try:
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "catalog.json"),
              encoding="utf-8") as _f:
        _CATALOG = json.load(_f).get("packs", [])
except Exception as _e:  # pragma: no cover
    print("WARN catalog.json not loaded:", _e)

_CAT_ALIASES = {"photo": "photos", "photos": "photos", "polaroid": "polaroid",
                "snapbook": "snapbook"}

# Whole-request cap. Without it the body was unbounded: anyone holding the app
# token could park gigabytes in the VM's temp dir before the first check ran
# (tester 10-Nov). The largest honest request is the biggest catalog pack with
# every photo at the per-photo cap; Werkzeug answers 413 beyond that, straight
# from the Content-Length header.
_BIGGEST_PACK = max([int(p["count"]) for p in _CATALOG] or [54])
app.config["MAX_CONTENT_LENGTH"] = _BIGGEST_PACK * MAX_PHOTO_BYTES + 1024 * 1024


def _cap_body(limit: int) -> None:
    """Tighter per-endpoint request cap (Flask >= 3.1; an older Flask keeps the
    global cap above)."""
    try:
        request.max_content_length = limit
    except AttributeError:  # pragma: no cover
        pass


def _norm(s: str) -> str:
    return " ".join(str(s or "").lower().replace("×", "x").replace("inches", "").split())


def min_price_for(category: str, size: str, n_photos: int):
    """Cheapest catalog price (rupees) that covers n_photos for this
    category+size; None when the size can't be resolved."""
    cat = _CAT_ALIASES.get(_norm(category), None)
    sz = _norm(size)
    if cat is None or not sz:
        return None
    cands = [p for p in _CATALOG if p["category"] == cat and
             (_norm(p["size"]) == sz or _norm(p["dimensions"]) == sz)]
    if not cands:
        return None
    fits = [p for p in cands if int(p["count"]) >= n_photos] or \
           [max(cands, key=lambda p: int(p["count"]))]
    return float(min(p["rupees"] for p in fits))


def max_count_for(category: str, size: str):
    """Photo count of the BIGGEST catalog pack of this category+size; None when
    the category/size is not in the catalog."""
    cat = _CAT_ALIASES.get(_norm(category), None)
    sz = _norm(size)
    if cat is None or not sz:
        return None
    counts = [int(p["count"]) for p in _CATALOG if p["category"] == cat and
              (_norm(p["size"]) == sz or _norm(p["dimensions"]) == sz)]
    return max(counts) if counts else None


def canonical_size(category: str, size: str):
    """The catalog's own spelling of this size ("REGULAR", "4 x 6", "4 × 6 inches"
    -> "Regular"); None when it is not in the catalog. The price table accepts
    all of those spellings, so the FOLDER must not depend on which one the
    client happened to send (tester 10-Nov: one size ended up in three folders)."""
    cat = _CAT_ALIASES.get(_norm(category), None)
    sz = _norm(size)
    if cat is None or not sz:
        return None
    for p in _CATALOG:
        if p["category"] == cat and (_norm(p["size"]) == sz or _norm(p["dimensions"]) == sz):
            return str(p["size"])
    return None


def price_for(category: str, size: str, snap_count: int):
    """Exact catalog price (rupees) of the pack (category, size, snapCount);
    None when no such pack exists. This server table is authoritative — the
    snapCount the app sends is only a hint of WHICH pack it claims to be."""
    cat = _CAT_ALIASES.get(_norm(category), None)
    sz = _norm(size)
    if cat is None or not sz or snap_count <= 0:
        return None
    for p in _CATALOG:
        if p["category"] == cat and int(p["count"]) == int(snap_count) and \
                (_norm(p["size"]) == sz or _norm(p["dimensions"]) == sz):
            return float(p["rupees"])
    return None

# ---------------------------------------------------------------- Gemini (lazy)
_model = None


def gemini():
    """Return a configured Gemini model, or None if no key is set.
    Model is env-overridable (GEMINI_MODEL) so a future model swap needs no code
    change — Google retires model names over time."""
    global _model
    if not GEMINI_API_KEY:
        return None
    if _model is None:
        import google.generativeai as genai
        genai.configure(api_key=GEMINI_API_KEY)
        _model = genai.GenerativeModel(os.environ.get("GEMINI_MODEL", "gemini-3.5-flash"))
    return _model


def _extract_json(s: str) -> str:
    i, j = s.find("{"), s.rfind("}")
    return s[i:j + 1] if (i >= 0 and j > i) else s


# ------------------------------------------------------------- payment ledger
def _ledger_path() -> str:
    d = os.path.join(filer.root, "_payments")
    os.makedirs(d, exist_ok=True)
    return os.path.join(d, "payments.jsonl")


def _utr_seen(utr: str) -> bool:
    if not utr:
        return False
    path = _ledger_path()
    if not os.path.exists(path):
        return False
    key = utr.strip().lower()
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            try:
                if str(json.loads(line).get("utr", "")).strip().lower() == key:
                    return True
            except Exception:
                continue
    return False


def _ledger_find(utr: str):
    """The ledger row that already consumed this UTR, or None."""
    if not utr:
        return None
    path = _ledger_path()
    if not os.path.exists(path):
        return None
    key = utr.strip().lower()
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            try:
                rec = json.loads(line)
                if str(rec.get("utr", "")).strip().lower() == key:
                    return rec
            except Exception:
                continue
    return None


def _ledger_append(rec: dict) -> None:
    # Pure-ASCII JSON (\uXXXX escapes): this write must never fail on what the
    # client put in the order number. With ensure_ascii=False a lone surrogate
    # ("\ud800") raised UnicodeEncodeError AFTER the photos were filed, so the
    # UTR never reached the ledger and one payment filed order after order
    # (tester 10-Nov).
    with open(_ledger_path(), "a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")


def _ledger_name_clash(folder: str, names: list[str], utr: str):
    """The ledger row of ANOTHER payment that already owns one of these file
    names in this folder, or None.

    Photos are published with os.replace, so a second paid order sending an
    order number that is already on file (order numbers are sequential, hence
    guessable) silently replaced the first customer's photos (tester 10-Nov).
    Ownership comes from the ledger, not from the disk: files left by a
    crashed half-filing have no ledger row and stay re-uploadable."""
    path = _ledger_path()
    if not os.path.exists(path):
        return None
    mine = set(names)
    key = (utr or "").strip().lower()
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            try:
                rec = json.loads(line)
                if rec.get("folder") != folder:
                    continue
                if str(rec.get("utr", "")).strip().lower() == key:
                    continue
                theirs = filer.order_names(str(rec.get("name") or ""),
                                           int(rec.get("photos") or 0))
                if mine.intersection(theirs):
                    return rec
            except Exception:
                continue
    return None


@contextlib.contextmanager
def _ledger_lock():
    """Exclusive lock over "is this UTR in the ledger? -> file -> append".

    gunicorn runs several workers; without it two simultaneous /ingest calls
    carrying the SAME payment token both saw an empty ledger and both filed
    (tester 10-Nov: one UTR paid for two different orders). flock is held on a
    separate open file per request, so it serialises across worker PROCESSES
    and across threads of one worker alike."""
    if fcntl is None:  # pragma: no cover  (Windows dev box: single process)
        yield
        return
    lock_path = os.path.join(os.path.dirname(_ledger_path()), "payments.lock")
    with open(lock_path, "a") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


def _utr_taken_response(prev: dict, order_number: str):
    """Reply for a UTR that is already in the ledger."""
    # Idempotent retry: the client timed out / lost the response after we had
    # already filed THIS order. Never a second filing, never a false "used for
    # another order" rejection.
    if order_number and str(prev.get("orderNumber") or "") == order_number:
        return jsonify(ok=True, filed=int(prev.get("photos") or 0),
                       duplicate=True, orderNumber=order_number)
    return jsonify(ok=False, error="utr_reused",
                   orderNumber=str(prev.get("orderNumber") or "")), 409


# --------------------------------------------------------------- payment token
def _make_token(amount: float, utr: str) -> str:
    payload = {"amount": round(float(amount), 2), "utr": utr, "ts": int(time.time())}
    raw = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    body = base64.urlsafe_b64encode(raw).decode()
    sig = hmac.new(PAYMENT_SECRET, body.encode(), hashlib.sha256).hexdigest()[:32]
    return f"{body}.{sig}"


def _check_token(token: str, allow_expired: bool = False):
    """Return the payload dict if the token is authentic and fresh, else None.
    With allow_expired=True an authentic-but-stale token is still returned, so
    /ingest can tell "token expired" (re-verify the same screenshot) apart from
    "forged / missing" (payment never verified)."""
    try:
        body, sig = token.split(".", 1)
        want = hmac.new(PAYMENT_SECRET, body.encode(), hashlib.sha256).hexdigest()[:32]
        if not hmac.compare_digest(sig, want):
            return None
        payload = json.loads(base64.urlsafe_b64decode(body.encode()))
        if not allow_expired and int(time.time()) - int(payload["ts"]) > TOKEN_TTL:
            return None
        return payload
    except Exception:
        return None


def _need_api_token():
    if API_TOKEN and request.headers.get("X-App-Token", "") != API_TOKEN:
        abort(401)


# ----------------------------------------------------------------- endpoints
def _sniff_mime(b: bytes) -> str:
    """Gemini rejects application/octet-stream, and phones send screenshots in
    several formats, so decide the type from the bytes, not the client header."""
    if b[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if b[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if b[:4] == b"RIFF" and b[8:12] == b"WEBP":
        return "image/webp"
    if b[4:12] in (b"ftypheic", b"ftypheix", b"ftypmif1", b"ftypmsf1"):
        return "image/heic"
    return "image/jpeg"


@app.get("/health")
def health():
    return jsonify(ok=True, ai=bool(GEMINI_API_KEY), catalog=len(_CATALOG),
                   ts=int(time.time()))


_PROMPT = (
    'You are verifying an Indian UPI payment screenshot (GPay, PhonePe, Paytm, '
    'BHIM or a bank app). Return ONLY one compact JSON object, no markdown, keys '
    'exactly: {"status":"success|failed|pending|unknown","amount":<rupees or '
    'null>,"utr":"<UTR/UPI ref/txn id or empty>","payeeName":"<receiver name or '
    'empty>","payeeUpiId":"<receiver VPA or empty>"}. amount is a plain number '
    '(₹1,499.00 -> 1499). status is "success" only if the screen clearly '
    'shows the payment completed. If not a UPI payment screenshot, use "unknown".'
)


@app.post("/verify-payment")
def verify_payment():
    _need_api_token()
    _cap_body(MAX_PHOTO_BYTES + 1024 * 1024)   # one screenshot, nothing more
    # Validate the request BEFORE the "AI not configured" answer, so a broken
    # request is a 400 whether or not the Gemini key is set.
    try:
        expected = float(request.form.get("amount", "0"))
    except ValueError:
        return jsonify(verified=False, reason="Bad amount."), 400
    our_vpa = request.form.get("ourUpiId", "").strip()
    our_name = request.form.get("ourName", "").strip()
    f = request.files.get("screenshot")
    if not f or not (expected > 0):   # "not >" also refuses NaN
        return jsonify(verified=False, reason="Missing screenshot or amount."), 400
    img = f.read(MAX_PHOTO_BYTES + 1)
    if len(img) > MAX_PHOTO_BYTES:
        return jsonify(verified=False, reason="Screenshot too large."), 413
    m = gemini()
    if m is None:
        return jsonify(verified=False, reason="Payment verification is being set up. "
                       "Please try again shortly.", code="ai_unconfigured"), 503

    try:
        resp = m.generate_content(
            [_PROMPT, {"mime_type": _sniff_mime(img), "data": img}],
            request_options={"timeout": 30},
        )
        data = json.loads(_extract_json((resp.text or "").strip()))
    except Exception as e:
        app.logger.warning("gemini verify failed: %s", e)
        return jsonify(verified=False, reason="Couldn't verify right now. "
                       "Check your internet and try again."), 502

    status = str(data.get("status", "unknown")).lower()
    try:
        amount = float(data.get("amount"))
    except (TypeError, ValueError):
        amount = None
    utr = str(data.get("utr", "")).strip()
    vpa = str(data.get("payeeUpiId", "")).strip()
    name = str(data.get("payeeName", "")).strip()
    payee = vpa or name

    if status != "success":
        reason = ("That screenshot shows the payment FAILED. Please pay again and re-attach."
                  if status == "failed" else
                  'Couldn\'t read a successful payment. Please attach a clear '
                  '"payment successful" screenshot.')
        return jsonify(verified=False, reason=reason, amount=amount, utr=utr, payee=payee)
    if amount is None:
        return jsonify(verified=False, reason="Couldn't read the amount. "
                       "Please attach a clearer screenshot.", utr=utr, payee=payee)
    if abs(amount - expected) > AMOUNT_TOLERANCE:
        if amount > expected:
            reason = (f"The screenshot shows ₹{amount:.0f} but your order is only "
                      f"₹{expected:.0f}. Please contact the shop to adjust or refund "
                      f"the extra ₹{amount - expected:.0f}.")
        else:
            reason = (f"The screenshot shows ₹{amount:.0f} but your order is "
                      f"₹{expected:.0f}. Please pay the full amount.")
        return jsonify(verified=False, amount=amount, utr=utr, payee=payee, reason=reason)
    # Hard-reject only on an unambiguous VPA mismatch (apps hide/trim names).
    if our_vpa and vpa:
        a = vpa.lower()
        b = our_vpa.lower()
        if not (a == b or a in b or b in a):
            return jsonify(verified=False, amount=amount, utr=utr, payee=payee,
                           reason="This payment went to a different account. "
                           "Please scan the QR shown here and pay again.")
    elif our_name and not vpa:
        # No VPA on the screenshot: the payee is otherwise UNCHECKED, so a
        # customer could have paid someone else (tester 10-Nov). Fall back to
        # the receiver NAME — require at least two tokens of our name to appear
        # (case-insensitive) so a screenshot that does not clearly show OUR
        # account is rejected rather than trusted.
        want = [t for t in our_name.lower().split() if len(t) >= 2]
        need = min(2, len(want))
        if need and sum(1 for t in want if t in name.lower()) < need:
            return jsonify(verified=False, amount=amount, utr=utr, payee=payee,
                           reason="Attach the full screenshot that clearly "
                           "shows who you paid.")
    if not utr:
        return jsonify(verified=False, amount=amount, payee=payee,
                       reason="We couldn't read the transaction ID (UTR). Please attach "
                       'the full "payment successful" screen that shows the UPI txn ID.')
    if _utr_seen(utr):
        return jsonify(verified=False, amount=amount, utr=utr, payee=payee,
                       reason="This payment reference has already been used for an order.")
    # Stash the payment screenshot keyed by UTR so /ingest can forward it to the
    # shop's Telegram (the screenshot is not sent to /ingest). Best-effort.
    _save_payment_shot(utr, img)
    return jsonify(verified=True, amount=amount, utr=utr, payee=payee,
                   reason=f"Payment of ₹{amount:.0f} confirmed. ✅",
                   token=_make_token(amount, utr))


def notify_telegram(text: str) -> None:
    """Best-effort post to the shop's Telegram group. Never raises, so it can
    never fail an order. Reads TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID at call
    time; silent no-op if either is unset."""
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    chat = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
    if not token or not chat:
        return
    try:
        import urllib.request
        import urllib.parse
        data = urllib.parse.urlencode({
            "chat_id": chat,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": "true",
        }).encode()
        urllib.request.urlopen(  # noqa: S310 (fixed Telegram host)
            urllib.request.Request(
                f"https://api.telegram.org/bot{token}/sendMessage", data=data),
            timeout=10).read()
    except Exception as e:  # pragma: no cover
        app.logger.warning("telegram notify failed: %s", e)


def build_order_pdf(photos, caps=(2000, 1400, 1000), quality=85):
    """One photo per page as a single PDF, downscaled so the whole file fits
    Telegram's ~50MB bot limit. Full-resolution photos stay on disk / the
    dashboard; this PDF is the shop's quick printable copy. None on failure."""
    if not photos:
        return None
    try:
        import io
        from PIL import Image
        data = None
        for cap in caps:
            imgs = []
            for b in photos:
                try:
                    im = Image.open(io.BytesIO(b)).convert("RGB")
                    im.thumbnail((cap, cap))
                    imgs.append(im)
                except Exception:
                    continue
            if not imgs:
                return None
            buf = io.BytesIO()
            imgs[0].save(buf, format="PDF", save_all=True,
                         append_images=imgs[1:], quality=quality, resolution=200.0)
            data = buf.getvalue()
            if len(data) <= 45 * 1024 * 1024:
                return data
        return data   # smallest attempt, even if still large
    except Exception as e:  # pragma: no cover
        app.logger.warning("order pdf build failed: %s", e)
        return None


def send_telegram_document(data, filename, caption=""):
    """Best-effort: post a file (the order PDF) to the shop group. Never raises."""
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    chat = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
    if not token or not chat or not data:
        return
    try:
        import requests
        requests.post(
            f"https://api.telegram.org/bot{token}/sendDocument",
            data={"chat_id": chat, "caption": caption[:1000], "parse_mode": "HTML"},
            files={"document": (filename, data, "application/pdf")},
            timeout=90,
        )
    except Exception as e:  # pragma: no cover
        app.logger.warning("telegram document failed: %s", e)


def send_telegram_photo(data, caption=""):
    """Best-effort: post an image (the payment screenshot) inline. Never raises."""
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    chat = os.environ.get("TELEGRAM_CHAT_ID", "").strip()
    if not token or not chat or not data:
        return
    try:
        import requests
        requests.post(
            f"https://api.telegram.org/bot{token}/sendPhoto",
            data={"chat_id": chat, "caption": caption[:1000], "parse_mode": "HTML"},
            files={"photo": ("payment.jpg", data, "image/jpeg")},
            timeout=60,
        )
    except Exception as e:  # pragma: no cover
        app.logger.warning("telegram photo failed: %s", e)


def _shot_path(utr: str) -> str:
    d = os.path.join(filer.root, "_payments", "shots")
    os.makedirs(d, exist_ok=True)
    safe = "".join(c for c in str(utr) if c.isalnum())[:64] or "x"
    return os.path.join(d, safe + ".jpg")


def _save_payment_shot(utr: str, img: bytes) -> None:
    if not utr or not img:
        return
    try:
        with open(_shot_path(utr), "wb") as f:
            f.write(img)
    except Exception as e:  # pragma: no cover
        app.logger.warning("save payment shot failed: %s", e)


def _take_payment_shot(utr: str):
    """Read + delete the stashed screenshot for this UTR (one-shot)."""
    if not utr:
        return None
    p = _shot_path(utr)
    try:
        if os.path.exists(p):
            with open(p, "rb") as f:
                b = f.read()
            with contextlib.suppress(Exception):
                os.remove(p)
            return b
    except Exception as e:  # pragma: no cover
        app.logger.warning("read payment shot failed: %s", e)
    return None


@app.post("/ingest")
def ingest():
    """Files one order's INDIVIDUAL cropped photos to the VM disk tree.
    Requires the HMAC payment token from /verify-payment and a fresh UTR."""
    _need_api_token()
    enforce = os.environ.get("PAYMENT_ENFORCE", "1") != "0"
    meta_raw = request.form.get("order", "{}")
    try:
        meta = json.loads(meta_raw)
        if not isinstance(meta, dict):
            raise ValueError("order must be an object")
    except Exception:
        return jsonify(ok=False, error="bad order json"), 400
    # A lone surrogate ("\ud800") is legal in JSON but cannot be written as
    # UTF-8: replace it here, once, so the file name, the ledger row and the
    # JSON answer all carry the same clean value. Blank ("   ") counts as none.
    order_number = str(meta.get("orderNumber") or "").encode("utf-8", "replace").decode("utf-8").strip()

    token = request.form.get("token", "")
    payload = _check_token(token) if token else None
    if enforce and not payload:
        # Authentic but stale -> the app re-verifies the SAME screenshot for the
        # SAME order (the UTR is not in the ledger yet). Forged/missing -> no
        # payment was ever verified.
        stale = _check_token(token, allow_expired=True) if token else None
        if stale:
            # ...unless this pass already filed its order: the answer was lost
            # and the app retries only after 24 h. Saying "expired" then sends
            # the customer to re-verify a UTR the ledger already holds ("already
            # used") - a dead end for an order that IS filed (tester 10-Nov).
            prev = _ledger_find(str(stale.get("utr") or ""))
            if prev is not None:
                return _utr_taken_response(prev, order_number)
            return jsonify(ok=False, error="token_expired",
                           reason="Your upload pass expired. Please re-attach "
                                  "the payment screenshot."), 402
        return jsonify(ok=False, error="payment_required",
                       reason="Payment not verified."), 402
    utr = (payload or {}).get("utr", "")
    if enforce and utr:
        # Fast path (no lock): ledger rows are append-only, so a hit is final.
        # A miss is re-checked under the lock right before filing.
        prev = _ledger_find(utr)
        if prev is not None:
            return _utr_taken_response(prev, order_number)

    files = request.files.getlist("photos")
    if not files:
        return jsonify(ok=False, error="no photos"), 400
    if len(files) > MAX_PHOTOS:
        return jsonify(ok=False, error="too many photos"), 413

    # The pack this order claims to be. snapCount is required so the server can
    # tie the PAID amount to the exact (category, size, snapCount) price.
    try:
        snap_count = int(meta.get("snapCount") or 0)
    except (TypeError, ValueError, OverflowError):   # Overflow: 1e999 / Infinity
        snap_count = 0
    if snap_count > 0 and len(files) > snap_count:
        return jsonify(ok=False, error="too_many_photos",
                       reason=f"This pack holds {snap_count} photos; "
                              f"{len(files)} were sent."), 400

    # Price tie: the paid amount (inside the signed token) must match the pack
    # being filed. The server table (catalog.json) is authoritative; the app's
    # amountRupees is ignored. Legacy clients without snapCount fall back to
    # the cheapest pack that holds the photos uploaded.
    if enforce and payload:
        paid = float(payload.get("amount") or 0)
        category = str(meta.get("category") or "")
        size = str(meta.get("size") or "")
        exact = price_for(category, size, snap_count) if snap_count > 0 else None
        if snap_count > 0 and exact is None:
            app.logger.warning("ingest unknown pack %.80r/%.80r x%d", category, size, snap_count)
            return jsonify(ok=False, error="unknown_pack",
                           reason="This print pack is not in the catalog."), 400
        if exact is None:
            # Legacy client (no snapCount). The price tie must still hold: the
            # category+size has to be in the catalog and the photos have to fit
            # its biggest pack — otherwise ₹150 filed ANY number of photos under
            # ANY folder name (tester 10-Nov).
            biggest = max_count_for(category, size)
            if biggest is None:
                app.logger.warning("ingest unknown pack %.80r/%.80r (no snapCount)", category, size)
                return jsonify(ok=False, error="unknown_pack",
                               reason="This print pack is not in the catalog."), 400
            if len(files) > biggest:
                return jsonify(ok=False, error="too_many_photos",
                               reason=f"The biggest pack of this size holds {biggest} "
                                      f"photos; {len(files)} were sent."), 400
        need = exact if exact is not None else min_price_for(category, size, len(files))
        floor = need if need is not None else GLOBAL_MIN_RUPEES
        if paid + AMOUNT_TOLERANCE < floor:
            app.logger.warning("ingest amount mismatch: paid %.2f < price %.2f (%.80r/%.80r x%d, %d photos)",
                               paid, floor, category, size, snap_count, len(files))
            return jsonify(ok=False, error="amount_mismatch",
                           reason=f"Paid ₹{paid:.0f} but this pack costs "
                                  f"₹{floor:.0f}. Please pay the full amount."), 402
    # The photos stay in Werkzeug's spooled temp files and are COPIED to their
    # place by the filer. They used to be read into one list first: an order of
    # N photos held N x (up to 12 MB) of RAM at once - on a 1 GB VM a single
    # big order (or one token replayed with an oversized last photo, which is
    # refused only after the others were read) could exhaust it (tester 10-Nov).
    photos = []
    for f in files:
        f.stream.seek(0, os.SEEK_END)
        nbytes = f.stream.tell()
        f.stream.seek(0)
        if nbytes > MAX_PHOTO_BYTES:
            return jsonify(ok=False, error="photo too large"), 413
        if nbytes == 0:
            # Never file (and charge the payment for) a photo that is not there.
            return jsonify(ok=False, error="empty_photo",
                           reason="One of the photos arrived empty. Please try again."), 400
        photos.append(f.stream)

    now = datetime.datetime.now(IST)
    when = now
    placed = meta.get("placedAt")
    if placed:
        try:
            dt = datetime.datetime.fromisoformat(str(placed).replace("Z", "+00:00"))
            cand = (dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)).astimezone(IST)
            if -PLACED_MAX_AGE <= (cand - now).total_seconds() <= PLACED_MAX_AHEAD:
                when = cand
        except Exception:
            pass
    # Folder names come from the catalog, never from the client's spelling.
    raw_category = str(meta.get("category") or "")
    raw_size = str(meta.get("size") or "")
    file_category = _CAT_ALIASES.get(_norm(raw_category)) or raw_category or "Other"
    file_size = canonical_size(raw_category, raw_size) or raw_size or "Unknown"
    file_number = order_number or str(int(time.time()))
    folder = filer.order_folder(when, file_category, file_size)
    stem = filer.order_stem(file_number)
    # ONE critical section for "UTR still free? -> file -> ledger row". The
    # request body is fully received by now, so the lock only covers local disk
    # writes (milliseconds), never a slow phone upload.
    with _ledger_lock():
        if enforce and utr:
            prev = _ledger_find(utr)
            if prev is not None:
                return _utr_taken_response(prev, order_number)
        if payload:
            clash = _ledger_name_clash(folder, filer.order_names(stem, len(photos)), utr)
            if clash is not None:
                # 400, not 409: the app reads 409 as "this UTR is in the ledger".
                app.logger.warning("ingest order number %.80r already on file for another payment",
                                   order_number)
                return jsonify(ok=False, error="order_number_taken",
                               reason="This order number already has photos on file."), 400
        try:
            written = filer.file_order(
                when=when,
                category=file_category,
                size=file_size,
                order_number=file_number,
                photos=photos,
            )
        except Exception as e:
            app.logger.error("ingest filing failed: %s", e)
            return jsonify(ok=False, error="filing_failed"), 500

        if payload:
            _ledger_append({
                "orderNumber": order_number,
                "amount": payload.get("amount"),
                "utr": utr,
                "photos": len(written),
                "at": datetime.datetime.now(IST).isoformat(timespec="seconds"),
                # where + under which name the photos went: lets the next order
                # prove it is not about to replace them (_ledger_name_clash).
                "folder": folder,
                "name": stem,
            })
    # The merchant's copy of WHO the order is for. The shop used to receive only
    # the photos — no customer name / phone / address (tester 10-Nov). Written
    # next to the photos, length-capped, and best-effort: a failure here must
    # never fail an order whose photos are already on disk.
    try:
        details = (
            f"Order: {order_number or file_number}\n"
            f"Name: {str(meta.get('customerName') or '')[:120]}\n"
            f"Phone: {str(meta.get('customerPhone') or '')[:20]}\n"
            f"Address:\n{str(meta.get('address') or '')[:500]}\n"
            f"Photos: {len(written)}\n"
            f"Placed: {datetime.datetime.now(IST).isoformat(timespec='seconds')}\n"
        )
        disk_folder = os.path.join(filer.root, folder)
        os.makedirs(disk_folder, exist_ok=True)
        with open(os.path.join(disk_folder, f"Order {stem} details.txt"),
                  "w", encoding="utf-8") as _df:
            _df.write(details)
    except Exception as _e:   # pragma: no cover
        app.logger.warning("ingest details write failed: %s", _e)

    # Post the order to the shop's Telegram group as THREE things, then a
    # separator (owner 10-Nov): 1) full ship-to details in one text, 2) the
    # print-ready PDF of all photos, 3) the customer's payment screenshot.
    try:
        oid = escape(order_number or file_number)
        amt = (payload or {}).get("amount")
        utr_val = str((payload or {}).get("utr") or "")
        name = escape(str(meta.get('customerName') or '—'))
        phone = escape(str(meta.get('customerPhone') or '—'))
        addr = escape((str(meta.get('address') or '').strip() or '—')[:600])
        text = [
            f"🆕 <b>New order #{oid}</b>",
            f"📦 {escape(raw_category)} · {escape(raw_size)} · {len(written)} photos",
        ]
        if amt:
            text.append(f"💰 ₹{float(amt):.0f} paid"
                        + (f" · UTR {escape(utr_val)}" if utr_val else ""))
        text += ["", "🚚 <b>Ship to</b>",
                 f"👤 {name}", f"📞 {phone}", f"🏠 {addr}"]
        notify_telegram("\n".join(text))
        # 2) print-ready PDF of all the photos
        pdf = build_order_pdf(photos)
        if pdf:
            send_telegram_document(
                pdf, f"Order {order_number or file_number}.pdf",
                f"🖨 Order #{oid} — all {len(written)} photos (print-ready)")
        # 3) the customer's payment screenshot (stashed by /verify-payment)
        shot = _take_payment_shot(utr_val)
        if shot:
            send_telegram_photo(shot, f"💳 Payment — Order #{oid}")
        # separator before the next order
        notify_telegram("➖➖➖➖➖➖➖➖➖➖")
    except Exception as _e:   # pragma: no cover
        app.logger.warning("telegram order notify failed: %s", _e)
    return jsonify(ok=True, filed=len(written))


@app.post("/chat")
def chat():
    _need_api_token()
    _cap_body(1024 * 1024)   # get_json() reads the whole body into RAM
    m = gemini()
    if m is None:
        return jsonify(reply="The order assistant is being set up. Please try again "
                       "shortly, or contact the shop directly."), 503
    body = request.get_json(silent=True) or {}
    facts = str(body.get("facts", "")).strip()
    message = str(body.get("message", "")).strip()
    if not message:
        return jsonify(reply="Please type your question."), 400
    history = body.get("history") or []
    sys = (
        "You are the order-status assistant for a photo-printing shop called "
        "Printing Partner. Answer ONLY from the order facts below. Be short, warm "
        "and clear. If asked something the facts don't cover, say you don't have "
        "that detail and suggest contacting the shop. Never invent dates, prices "
        "or statuses.\n\nORDER FACTS:\n" + (facts or "(no order selected)")
    )
    convo = [{"role": "user", "parts": [sys]},
             {"role": "model", "parts": ["Understood. How can I help with your order?"]}]
    for h in history[-10:]:
        role = "model" if str(h.get("role")) == "assistant" else "user"
        convo.append({"role": role, "parts": [str(h.get("text", ""))]})
    convo.append({"role": "user", "parts": [message]})
    try:
        resp = m.generate_content(convo, request_options={"timeout": 30})
        return jsonify(reply=(resp.text or "").strip() or "Sorry, please try again.")
    except Exception as e:
        app.logger.warning("gemini chat failed: %s", e)
        return jsonify(reply="I couldn't answer right now. Please try again shortly."), 502


# ------------------------------------------------------------------ dashboard
def _orders_path(rel: str) -> str:
    """Resolve a dashboard ?path= INSIDE the orders tree, or abort(400).
    The base is "{DATA_ROOT}/Printing Partner", not DATA_ROOT itself: "?path=.."
    used to reach the payments ledger next to it (tester 10-Nov)."""
    base = os.path.realpath(os.path.join(filer.root, "Printing Partner"))
    try:
        p = os.path.realpath(os.path.join(base, rel or ""))
    except ValueError:      # embedded NUL byte
        abort(400)
    if p != base and not p.startswith(base + os.sep):
        abort(400)
    return p


def _session_cookie() -> str:
    # Opaque signed value; the password itself never travels in a URL or cookie.
    return hmac.new(PAYMENT_SECRET, b"dashboard-session", hashlib.sha256).hexdigest()


def _auth_ok() -> bool:
    if not DASHBOARD_PASSWORD:
        return False
    # bytes, not str: compare_digest raises TypeError on a non-ASCII str (-> 500).
    return hmac.compare_digest(request.cookies.get("pps", "").encode("utf-8", "replace"),
                               _session_cookie().encode())


@app.post("/login")
def login():
    given = request.form.get("pw", "")
    if not DASHBOARD_PASSWORD or not hmac.compare_digest(
            given.encode("utf-8", "replace"), DASHBOARD_PASSWORD.encode("utf-8")):
        time.sleep(1.5)  # slow brute force
        return Response("Wrong password. <a href='/'>Back</a>", status=403,
                        mimetype="text/html")
    resp = Response(status=302, headers={"Location": "/"})
    resp.set_cookie("pps", _session_cookie(), httponly=True, secure=True,
                    samesite="Lax", max_age=12 * 3600)
    return resp


@app.get("/")
@app.get("/dashboard")
def dashboard():
    if not _auth_ok():
        return Response(
            '<form method="post" action="/login" '
            'style="font-family:system-ui;max-width:320px;margin:15vh auto">'
            '<h2>Printing Partner</h2><p>Merchant login</p>'
            '<input name="pw" type="password" placeholder="Password" autofocus '
            'style="width:100%;padding:10px;font-size:16px"/>'
            '<button style="margin-top:10px;padding:10px 16px;font-size:16px">Open</button>'
            '</form>', mimetype="text/html")
    rel = request.args.get("path", "")
    here = _orders_path(rel)     # before any order exists: no folder -> "empty"
    rows = []
    if os.path.isdir(here):
        for name in sorted(os.listdir(here)):
            full = os.path.join(here, name)
            sub = f"{rel}/{name}".strip("/") if rel else name
            q = quote(sub)
            # Every name / path shown is client-influenced (order number, the
            # ?path= itself): escape it, never write it raw into the page.
            shown = escape(name)
            if os.path.isdir(full):
                n = len(os.listdir(full))
                rows.append(f'<li>\U0001f4c1 <a href="/?path={q}">{shown}</a> '
                            f'<small>({n})</small> &nbsp;'
                            f'<a href="/zip?path={q}">⬇ zip</a></li>')
            elif name.lower().endswith(".jpg"):
                rows.append(f'<li>\U0001f5bc <a href="/file?path={q}">{shown}</a></li>')
            elif name.lower().endswith(".txt"):
                rows.append(f'<li>\U0001f4c4 <a href="/file?path={q}">{shown}</a></li>')
    up = ""
    if rel:
        parent = quote("/".join(rel.split("/")[:-1]))
        up = f'<a href="/?path={parent}">⬅ up</a>'
    return Response(
        '<div style="font-family:system-ui;max-width:720px;margin:24px auto">'
        f'<h2>Printing Partner — orders</h2><p>{up} <b>/{escape(rel)}</b></p>'
        f'<ul style="line-height:2;list-style:none;padding:0">{"".join(rows) or "<i>empty</i>"}</ul>'
        '</div>', mimetype="text/html")


@app.get("/file")
def serve_file():
    if not _auth_ok():
        abort(403)
    p = _orders_path(request.args.get("path", ""))
    if not os.path.isfile(p):
        abort(404)
    # The order details are a .txt next to the photos; everything else served
    # here is a JPEG.
    mime = "text/plain; charset=utf-8" if p.lower().endswith(".txt") else "image/jpeg"
    with open(p, "rb") as fh:
        return Response(fh.read(), mimetype=mime)


@app.get("/zip")
def serve_zip():
    if not _auth_ok():
        abort(403)
    p = _orders_path(request.args.get("path", ""))
    if not os.path.isdir(p):
        abort(404)
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _dirs, files in os.walk(p):
            for fn in files:
                fp = os.path.join(root, fn)
                z.write(fp, os.path.relpath(fp, p))
    buf.seek(0)
    label = os.path.basename(p) or "orders"
    # HTTP headers are latin-1: a folder name outside it made gunicorn drop the
    # response ("Invalid HTTP Header"). ASCII fallback + RFC 5987 UTF-8 name.
    ascii_label = "".join(c if (32 <= ord(c) < 127 and c not in '"\\') else "_"
                          for c in label)
    return Response(buf.read(), mimetype="application/zip",
                    headers={"Content-Disposition":
                             f'attachment; filename="{ascii_label}.zip"; '
                             f"filename*=UTF-8''{quote(label, safe='')}.zip"})


# ------------------------------------------------------- legal / support pages
# Apple and Google require a public privacy-policy URL (and a support URL) for
# the store listing. Served here so they are live at HTTPS with zero extra infra.
_PAGE_CSS = (
    "body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;"
    "max-width:720px;margin:32px auto;padding:0 18px;color:#1a1f36;line-height:1.6}"
    "h1{font-size:24px}h2{font-size:18px;margin-top:28px}"
    "a{color:#5B4FE9}small{color:#667}"
)

_PRIVACY_HTML = f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Printing Partner — Privacy Policy</title><style>{_PAGE_CSS}</style></head><body>
<h1>Printing Partner — Privacy Policy</h1>
<p><small>Last updated: November 2026</small></p>
<p>Printing Partner ("we", "the app") prints the photos you choose and delivers
them to you. This policy explains what we collect and why. We keep it simple: we
only use your information to make and deliver your order.</p>
<h2>What we collect</h2>
<ul>
<li><b>Photos you select</b> — used only to print your order. They are sent to our
printing server, printed, and removed after the order is fulfilled.</li>
<li><b>Delivery details</b> — your name, mobile number and address, used only to
deliver your order and contact you about it.</li>
<li><b>Payment screenshot</b> — the UPI payment screenshot you attach is read only
to confirm your payment amount and reference. We do not store card or bank
credentials; payment happens entirely inside your own UPI app.</li>
</ul>
<h2>What we do NOT do</h2>
<ul>
<li>We do not sell or share your information with advertisers.</li>
<li>We do not track you across other apps or websites.</li>
<li>We do not require an account, login or password.</li>
</ul>
<h2>How it is stored</h2>
<p>Your order photos and details are stored on our own private server and used
only to produce and deliver your order, then removed on a routine schedule.</p>
<h2>Your choices</h2>
<p>To have your data or a past order removed, contact us (see the support page).
You can delete photos from your own device at any time.</p>
<h2>Children</h2>
<p>Printing Partner is a general-audience printing service and is not directed at
children under 13.</p>
<h2>Contact</h2>
<p>Questions about this policy? See <a href="/support">our support page</a>.</p>
</body></html>"""

_SUPPORT_HTML = f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Printing Partner — Support</title><style>{_PAGE_CSS}</style></head><body>
<h1>Printing Partner — Support</h1>
<p>Need help with an order? We're happy to help.</p>
<h2>How to reach us</h2>
<p>Use the in-app chat on your order, or contact the shop directly. Please keep
your order number handy so we can find it quickly.</p>
<h2>Common questions</h2>
<ul>
<li><b>How do I pay?</b> Scan the QR on the payment screen with any UPI app, or tap
a UPI app button to pay directly, then attach the "payment successful" screenshot.</li>
<li><b>How long does delivery take?</b> Typically 3–5 days from order.</li>
<li><b>Can I change or cancel an order?</b> Contact us as soon as possible and we
will do our best before it goes to print.</li>
</ul>
<p><small>Printing Partner</small></p>
</body></html>"""


@app.get("/privacy")
def privacy():
    return Response(_PRIVACY_HTML, mimetype="text/html")


@app.get("/support")
def support():
    return Response(_SUPPORT_HTML, mimetype="text/html")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
