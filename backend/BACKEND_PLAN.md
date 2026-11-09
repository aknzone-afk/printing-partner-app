# Printing Partner backend — as deployed (9-Nov-2026)

One Flask service on the owner's **Oracle Free VM** (130.210.24.18, Ubuntu, `ubuntu`),
behind **Caddy** (automatic Let's Encrypt HTTPS) at **https://130-210-24-18.nip.io**.
No OneDrive. No Firebase-admin. ₹0.

## Why this shape
- The phone must never be trusted for money → `/verify-payment` runs Gemini **on the
  server** and returns an **HMAC-signed token**; `/ingest` only files photos when that
  token is valid and the **UTR has never been used** (ledger `_payments/payments.jsonl`).
- No Firebase service-account needed → nothing for the owner to generate in the console.
- Dashboard login is POST + signed HttpOnly cookie; the password never sits in a URL.
- Gunicorn binds **127.0.0.1:8080 only**; Caddy is the only thing on 80/443.

## Folder tree (VM disk, `DATA_ROOT=/opt/printing-partner-backend/data`)
```
Printing Partner/{D-M-YYYY}/{Photo|Polaroid|Snapbook}/{size}/Order {N}{A|B|C…}.jpg
_payments/payments.jsonl        # append-only ledger: orderNumber, amount, utr, at
```
Only date/category/size folders that got orders exist. `filer.py` sanitises every
segment and realpath-guards against DATA_ROOT.

## Endpoints
| Route | Auth | Purpose |
|---|---|---|
| `GET /health` | none | `{ok, ai}` — `ai:false` until GEMINI_API_KEY is set |
| `POST /verify-payment` | `X-App-Token` | screenshot+amount → Gemini → `{verified, reason, amount, utr, payee, token}` |
| `POST /ingest` | payment `token` | cropped JPEGs + `{orderNumber, category, size, placedAt}` → filed to disk |
| `POST /chat` | `X-App-Token` | order facts + question → Gemini reply |
| `GET /`, `POST /login`, `/file`, `/zip` | dashboard cookie | merchant browse + per-folder ZIP |

## Files (this folder = source of truth; mirrored in `pp-repo/backend/`)
`app.py` · `filer.py` · `requirements.txt` · `printing-partner-backend.service` · `env.example`

## Ops
```bash
# deploy (from the PC; key = YouTubeAutoReply/oracle-deploy/oracle_vm_key)
scp -i KEY app.py filer.py requirements.txt ubuntu@130.210.24.18:/opt/printing-partner-backend/
ssh -i KEY ubuntu@130.210.24.18 'sudo systemctl restart printing-partner-backend && systemctl is-active printing-partner-backend'
# logs
ssh -i KEY ubuntu@130.210.24.18 'journalctl -u printing-partner-backend -n 50 --no-pager'
# set the Gemini key (owner supplies the value)
ssh -i KEY ubuntu@130.210.24.18 'sed -i "s|^GEMINI_API_KEY=.*|GEMINI_API_KEY=PASTE|" /opt/printing-partner-backend/.env && sudo systemctl restart printing-partner-backend'
```
Secrets live only in `/opt/printing-partner-backend/.env` on the VM (chmod 600).

## Still owner-gated
1. **Oracle VCN ingress for TCP 80 + 443** (Console → Networking → VCN → Default
   Security List → Add Ingress Rule, source 0.0.0.0/0). Until then the HTTPS URL is
   unreachable from the internet (Caddy will finish the cert automatically once open).
2. **GEMINI_API_KEY** (Google AI Studio) — paste into `.env` as above.
3. Store accounts: Apple Developer / Play Console submission, Android release keystore.
