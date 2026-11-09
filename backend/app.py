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
                               missing/forged token and a REUSED UTR (one payment,
                               one order).
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

from flask import Flask, request, jsonify, Response, abort

from filer import LocalFiler

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

# ---------------------------------------------------------------- Gemini (lazy)
_model = None


def gemini():
    """Return a configured gemini-2.5-flash model, or None if no key is set."""
    global _model
    if not GEMINI_API_KEY:
        return None
    if _model is None:
        import google.generativeai as genai
        genai.configure(api_key=GEMINI_API_KEY)
        _model = genai.GenerativeModel("gemini-2.5-flash")
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


def _ledger_append(rec: dict) -> None:
    with open(_ledger_path(), "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


# --------------------------------------------------------------- payment token
def _make_token(amount: float, utr: str) -> str:
    payload = {"amount": round(float(amount), 2), "utr": utr, "ts": int(time.time())}
    raw = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode()
    body = base64.urlsafe_b64encode(raw).decode()
    sig = hmac.new(PAYMENT_SECRET, body.encode(), hashlib.sha256).hexdigest()[:32]
    return f"{body}.{sig}"


def _check_token(token: str):
    """Return the payload dict if the token is authentic and fresh, else None."""
    try:
        body, sig = token.split(".", 1)
        want = hmac.new(PAYMENT_SECRET, body.encode(), hashlib.sha256).hexdigest()[:32]
        if not hmac.compare_digest(sig, want):
            return None
        payload = json.loads(base64.urlsafe_b64decode(body.encode()))
        if int(time.time()) - int(payload["ts"]) > TOKEN_TTL:
            return None
        return payload
    except Exception:
        return None


def _need_api_token():
    if API_TOKEN and request.headers.get("X-App-Token", "") != API_TOKEN:
        abort(401)


# ----------------------------------------------------------------- endpoints
@app.get("/health")
def health():
    return jsonify(ok=True, ai=bool(GEMINI_API_KEY), ts=int(time.time()))


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
    m = gemini()
    if m is None:
        return jsonify(verified=False, reason="Payment verification is being set up. "
                       "Please try again shortly.", code="ai_unconfigured"), 503
    try:
        expected = float(request.form.get("amount", "0"))
    except ValueError:
        return jsonify(verified=False, reason="Bad amount."), 400
    our_vpa = request.form.get("ourUpiId", "").strip()
    f = request.files.get("screenshot")
    if not f or expected <= 0:
        return jsonify(verified=False, reason="Missing screenshot or amount."), 400
    img = f.read(MAX_PHOTO_BYTES + 1)
    if len(img) > MAX_PHOTO_BYTES:
        return jsonify(verified=False, reason="Screenshot too large."), 413

    try:
        resp = m.generate_content(
            [_PROMPT, {"mime_type": f.mimetype or "image/jpeg", "data": img}],
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
        return jsonify(verified=False, amount=amount, utr=utr, payee=payee,
                       reason=f"The screenshot shows ₹{amount:.0f} but your order is "
                       f"₹{expected:.0f}. Please pay the exact amount.")
    # Hard-reject only on an unambiguous VPA mismatch (apps hide/trim names).
    if our_vpa and vpa:
        a = vpa.lower()
        b = our_vpa.lower()
        if not (a == b or a in b or b in a):
            return jsonify(verified=False, amount=amount, utr=utr, payee=payee,
                           reason="This payment went to a different account. "
                           "Please scan the QR shown here and pay again.")
    if not utr:
        return jsonify(verified=False, amount=amount, payee=payee,
                       reason="We couldn't read the transaction ID (UTR). Please attach "
                       'the full "payment successful" screen that shows the UPI txn ID.')
    if _utr_seen(utr):
        return jsonify(verified=False, amount=amount, utr=utr, payee=payee,
                       reason="This payment reference has already been used for an order.")
    return jsonify(verified=True, amount=amount, utr=utr, payee=payee,
                   reason=f"Payment of ₹{amount:.0f} confirmed. ✅",
                   token=_make_token(amount, utr))


@app.post("/ingest")
def ingest():
    """Files one order's INDIVIDUAL cropped photos to the VM disk tree.
    Requires the HMAC payment token from /verify-payment and a fresh UTR."""
    enforce = os.environ.get("PAYMENT_ENFORCE", "1") != "0"
    meta_raw = request.form.get("order", "{}")
    try:
        meta = json.loads(meta_raw)
    except Exception:
        return jsonify(ok=False, error="bad order json"), 400

    token = request.form.get("token", "")
    payload = _check_token(token) if token else None
    if enforce and not payload:
        return jsonify(ok=False, error="payment_required",
                       reason="Payment not verified."), 402
    utr = (payload or {}).get("utr", "")
    if enforce and utr and _utr_seen(utr):
        return jsonify(ok=False, error="utr_reused"), 409

    files = request.files.getlist("photos")
    if not files:
        return jsonify(ok=False, error="no photos"), 400
    if len(files) > MAX_PHOTOS:
        return jsonify(ok=False, error="too many photos"), 413

    # Price floor: the paid amount (inside the signed token) must cover the
    # pack this order needs. Unknown size -> at least the cheapest pack.
    if enforce and payload:
        paid = float(payload.get("amount") or 0)
        need = min_price_for(str(meta.get("category") or ""),
                             str(meta.get("size") or ""), len(files))
        floor = need if need is not None else GLOBAL_MIN_RUPEES
        if paid + AMOUNT_TOLERANCE < floor:
            app.logger.warning("ingest underpaid: paid %.2f < floor %.2f (%s/%s x%d)",
                               paid, floor, meta.get("category"), meta.get("size"), len(files))
            return jsonify(ok=False, error="underpaid",
                           reason=f"Paid ₹{paid:.0f} but this pack costs "
                                  f"₹{floor:.0f}. Please pay the full amount."), 402
    photos: list[bytes] = []
    for f in files:
        b = f.read(MAX_PHOTO_BYTES + 1)
        if len(b) > MAX_PHOTO_BYTES:
            return jsonify(ok=False, error="photo too large"), 413
        photos.append(b)

    when = datetime.datetime.now(IST)
    placed = meta.get("placedAt")
    if placed:
        try:
            dt = datetime.datetime.fromisoformat(str(placed).replace("Z", "+00:00"))
            when = (dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)).astimezone(IST)
        except Exception:
            pass
    try:
        written = filer.file_order(
            when=when,
            category=str(meta.get("category") or "Other"),
            size=str(meta.get("size") or "Unknown"),
            order_number=str(meta.get("orderNumber") or int(time.time())),
            photos=photos,
        )
    except Exception as e:
        app.logger.error("ingest filing failed: %s", e)
        return jsonify(ok=False, error="filing_failed"), 500

    if payload:
        _ledger_append({
            "orderNumber": str(meta.get("orderNumber") or ""),
            "amount": payload.get("amount"),
            "utr": utr,
            "photos": len(written),
            "at": datetime.datetime.now(IST).isoformat(timespec="seconds"),
        })
    return jsonify(ok=True, filed=len(written))


@app.post("/chat")
def chat():
    _need_api_token()
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
def _safe_join(*parts) -> str:
    root = os.path.realpath(filer.root)
    p = os.path.realpath(os.path.join(root, *parts))
    if p != root and not p.startswith(root + os.sep):
        abort(400)
    return p


def _session_cookie() -> str:
    # Opaque signed value; the password itself never travels in a URL or cookie.
    return hmac.new(PAYMENT_SECRET, b"dashboard-session", hashlib.sha256).hexdigest()


def _auth_ok() -> bool:
    if not DASHBOARD_PASSWORD:
        return False
    return hmac.compare_digest(request.cookies.get("pps", ""), _session_cookie())


@app.post("/login")
def login():
    given = request.form.get("pw", "")
    if not DASHBOARD_PASSWORD or not hmac.compare_digest(given, DASHBOARD_PASSWORD):
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
    base = os.path.join(filer.root, "Printing Partner")
    rel = request.args.get("path", "")
    here = _safe_join("Printing Partner", rel) if rel else (
        base if os.path.isdir(base) else filer.root)
    from urllib.parse import quote
    rows = []
    if os.path.isdir(here):
        for name in sorted(os.listdir(here)):
            full = os.path.join(here, name)
            sub = f"{rel}/{name}".strip("/") if rel else name
            q = quote(sub)
            if os.path.isdir(full):
                n = len(os.listdir(full))
                rows.append(f'<li>\U0001f4c1 <a href="/?path={q}">{name}</a> '
                            f'<small>({n})</small> &nbsp;'
                            f'<a href="/zip?path={q}">⬇ zip</a></li>')
            elif name.lower().endswith(".jpg"):
                rows.append(f'<li>\U0001f5bc <a href="/file?path={q}">{name}</a></li>')
    up = ""
    if rel:
        parent = quote("/".join(rel.split("/")[:-1]))
        up = f'<a href="/?path={parent}">⬅ up</a>'
    return Response(
        '<div style="font-family:system-ui;max-width:720px;margin:24px auto">'
        f'<h2>Printing Partner — orders</h2><p>{up} <b>/{rel}</b></p>'
        f'<ul style="line-height:2;list-style:none;padding:0">{"".join(rows) or "<i>empty</i>"}</ul>'
        '</div>', mimetype="text/html")


@app.get("/file")
def serve_file():
    if not _auth_ok():
        abort(403)
    p = _safe_join("Printing Partner", request.args.get("path", ""))
    if not os.path.isfile(p):
        abort(404)
    with open(p, "rb") as fh:
        return Response(fh.read(), mimetype="image/jpeg")


@app.get("/zip")
def serve_zip():
    if not _auth_ok():
        abort(403)
    p = _safe_join("Printing Partner", request.args.get("path", ""))
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
    return Response(buf.read(), mimetype="application/zip",
                    headers={"Content-Disposition": f'attachment; filename="{label}.zip"'})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
