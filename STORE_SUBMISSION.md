# Printing Partner - going live on the App Store and Google Play

This is the exact checklist to take Printing Partner public. It mirrors the
pipeline the sibling apps (Sappan, B.B Synthetics) use: a GitHub-hosted macOS
runner + fastlane match + App Store Connect API key for iOS, and a signed AAB
built in CI for Play. **No Mac is needed.**

Steps are marked **[OWNER-ONLY]** where they need an Apple/Google account, a
legal agreement, a keystore, a secret, or the final human *Submit*. Everything
else is already wired in this repo.

PP identity (already set, do NOT change):
- iOS bundle id: `in.printingpartner.printingPartner`
- Android applicationId / namespace: `in.printingpartner.printing_partner` (underscore - intentional, keep separate from the iOS camelCase bundle)
- Apple Team: `DWJM58G45V` - App Store Connect app id `6831645537`, SKU `printingpartner-ios`
- GitHub repo: `aknzone-afk/printing-partner-app`
- fastlane match signing-certs repo (shared): `akn-chat-ios-certs`

---

## 0. One prerequisite for the screenshot + review-video workflows

`store-shots.yml` and `ios-review-video.yml` run Flutter **integration tests**,
which import `package:integration_test`. That package is **not** yet in
`app/pubspec.yaml`. Add it once under `dev_dependencies` (this is the only
pubspec change needed, and it is SDK-pinned so it costs nothing):

```yaml
dev_dependencies:
  flutter_test:
    sdk: flutter
  integration_test:      # <-- add these two lines
    sdk: flutter
  flutter_lints: ^6.0.0
  flutter_launcher_icons: ^0.14.4
```

Then `cd app && flutter pub get`. The `android-release.yml`, `ios-testflight.yml`
and `app-check.yml` workflows do **not** need this and work today.

---

## A. Apple App Store

### A1. Build -> TestFlight (SCRIPTED - already working, builds 1-7 shipped)
- Trigger: Actions tab -> **iOS TestFlight** -> Run workflow (or push an `ios-v*` tag).
- Needs these GitHub **secrets** (already set for builds 1-7): `ASC_KEY_ID`,
  `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64`, `MATCH_GIT_URL`, `MATCH_PASSWORD`,
  `MATCH_SSH_KEY`. Repo **var** `MATCH_READONLY` should be `true` now (first run done).
- Output: a new build on TestFlight (build number auto = latest + 1).

### A2. Generate review assets (SCRIPTED - new in this change)
- **[do section 0 first]**
- **Store screenshots**: Actions -> **Store screenshots** -> Run workflow.
  Download the `store-screenshots` artifact, choose frames, size them to Apple's
  required resolutions, and place them in `app/ios/fastlane/screenshots/en-US/`
  (see that folder's README).
- **Review demo video** (Apple Guideline 2.1): Actions -> **iOS review video** ->
  Run workflow. Download the `printing-partner-review-video` artifact; attach the
  `.mp4` in App Store Connect under App Review Information if the reviewer asks,
  or keep it on hand.

### A3. Fill the App Store listing (SCRIPTED push + **[OWNER-ONLY]** content)
- Edit the metadata placeholders in `app/ios/fastlane/metadata/en-US/`:
  `description.txt`, `keywords.txt`, `promotional_text.txt`, `release_notes.txt`,
  and the three URLs `support_url.txt`, `marketing_url.txt`, `privacy_url.txt`
  (replace the `PLACEHOLDER` hosts with real pages). `name.txt` ("Printing
  Partner") and `subtitle.txt` are set; adjust `copyright.txt` if needed.
- Push metadata + screenshots:
  ```
  cd app/ios
  bundle exec fastlane ios metadata       # text only
  bundle exec fastlane ios screenshots    # screenshots only
  # or both at once (and submit when ready - see A4):
  bundle exec fastlane ios release
  ```
  These lanes use the same `ASC_*` env/secrets as TestFlight. Run locally with
  those env vars set, or add a small workflow if you prefer CI.

### A4. **[OWNER-ONLY]** In App Store Connect (console) - answer + Submit
These cannot be scripted and are the owner's call:
- **App Privacy** (data-collection) questionnaire. PP collects: the mobile
  number + delivery address typed at checkout, the photos uploaded for printing,
  and an anonymous Firebase uid. No ads, no IDFA, no tracking.
- **Age rating** questionnaire.
- **Pricing and Availability**: Free; choose countries (India at minimum).
- **Export Compliance**: standard HTTPS only -> "uses exempt encryption".
- Attach **build 7** (or newer) from TestFlight to the version.
- **Add for Review**, then **Submit**. (The `release` lane can submit for you if
  you set `SUBMIT_FOR_REVIEW=true`, but the default is `false` so nothing
  submits by accident - the human Submit stays the owner's decision.)

> Note (from `print_collage_tool_ios.md`): a single-business utility risks Apple
> Guideline 4.2/4.3. Decide TestFlight-only vs public before submitting.

---

## B. Google Play

### B1. **[OWNER-ONLY, one-time]** Create the Android upload keystore
PP has **no** upload keystore yet - `android-release.yml` hard-fails without it
(by design, so a debug-signed AAB is never mistaken for a release). Generate it
offline and back it up OUTSIDE the repo (losing it means a brand-new Play
listing):
```
keytool -genkey -v -keystore printing-partner-upload.jks -storetype JKS \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
# e.g. keep it at C:\BotSecrets\printing-partner-upload.jks
```
Then copy `app/android/key.properties.example` -> `app/android/key.properties`
and fill `storeFile` / `storePassword` / `keyAlias` / `keyPassword`.
(`key.properties` and `*.jks` are git-ignored - never commit them.)

### B2. Build the signed release AAB (SCRIPTED - already wired, better than Sappan)
- For CI, add two GitHub **secrets** (owner runs `gh secret set`; Claude is
  blocked from writing secrets):
  - `ANDROID_KEYSTORE_B64` = base64 of the `.jks`  (`base64 -w0 printing-partner-upload.jks`)
  - `ANDROID_KEY_PROPERTIES` = the full text of `key.properties` (with `storeFile=upload-keystore.jks`)
- Trigger: Actions -> **Android release (AAB)** -> Run workflow (or push an
  `android-v*` tag). It restores the keystore from the secrets, runs
  `flutter build appbundle --release`, scrubs the key, and uploads
  `printing-partner-release-aab`. Without the secrets it fails loudly.
- (You can also build locally once `key.properties` exists:
  `cd app && flutter build appbundle --release`.)

> Android workflow reconciliation: this repo keeps the single, correct
> `android-release.yml` (upload-key signed, hard-fails without the keystore).
> The siblings' older `android-build.yml` only produces a DEBUG-signed AAB and
> re-signs on the shop PC - it is intentionally **not** copied here.

### B3. **[OWNER-ONLY]** Create the Play Console app + enrol in Play App Signing
- PP has no Play listing, no track, no Play App Signing enrollment yet.
- Create the app in Play Console, upload the AAB to the **Internal** track first;
  accept **Play App Signing** on first upload (Google re-signs; your upload key
  only signs uploads).
- Google now forces personal accounts through a **Closed test (~12 testers x 14
  days)** before Production. Run that cohort.

### B4. **[OWNER-ONLY]** Fill the Play listing + declarations, then promote
- Store listing: title ("Printing Partner"), short + full description, app icon,
  feature graphic, phone screenshots (reuse the `store-shots` PNGs).
- **Data safety** form, **content rating** questionnaire, target audience,
  pricing (Free) and countries.
- Promote **Closed test -> Production** and submit. Final Submit is the owner's call.

### B5. **[OWNER-ONLY, optional]** Automate Play uploads later
- No sibling has a committed `fastlane supply` / Play API lane, so none is added
  here - uploading the AAB artifact by hand is the current path.
- To automate, create PP's **own** Play service-account JSON (do NOT reuse
  Sappan's `play-upload@`, which is scoped to the Sappan project), grant it on
  the PP Play app, add it as the `PLAY_SERVICE_ACCOUNT_JSON` secret, and add a
  `fastlane supply` lane + a workflow step that uploads the AAB from B2.

---

## GitHub secrets / vars summary

Already set (iOS, from builds 1-7): `ASC_KEY_ID`, `ASC_ISSUER_ID`,
`ASC_KEY_P8_BASE64`, `MATCH_GIT_URL`, `MATCH_PASSWORD`, `MATCH_SSH_KEY`;
var `MATCH_READONLY=true`.

**To add (owner runs `gh secret set` / `gh variable set`):**
- `ANDROID_KEYSTORE_B64` - base64 of the upload keystore (B1/B2)
- `ANDROID_KEY_PROPERTIES` - full text of `android/key.properties` (B2)
- `PLAY_SERVICE_ACCOUNT_JSON` - only if automating Play uploads (B5)

Claude cannot read or write secrets (classifier-blocked); the owner sets these.

---

## ⬛ CURRENT STATUS (10-Nov-2026) — what Claude finished vs what needs YOU

### Apple App Store — STAGED, needs ~5 min from you (one-time)
Everything is prepared and partly uploaded. The automated tool (fastlane deliver)
**cannot create a brand-new app's FIRST version** (Apple API returns "No data" —
a known limitation); it will work for all future updates once the first version
exists. So the first submission is done once in the console:

1. Sign in at **appstoreconnect.apple.com** → My Apps → **Printing Partner**.
2. The listing text (name, subtitle, description, keywords, support/privacy URL,
   category Photo & Video) is already uploaded. The **screenshots** are in the
   repo at `app/ios/fastlane/screenshots/en-US/` — upload the 3 PNGs to the
   6.9" display (drag-drop), or tell Claude to run `fastlane screenshots` once
   the version exists.
3. **App Privacy** → answer: Photos/Videos = *App Functionality*, **not** used for
   tracking; Name/Phone/Address = *App Functionality*. No data used to track.
4. **Age rating** → all *None* → 4+.  **Pricing** → Free.  Availability → India
   (and anywhere else you want).
5. **Build** → select build 9 (already on TestFlight). Export compliance is
   pre-answered (no encryption).
6. **Add for Review → Submit.**
> Prefer Claude to drive it? Sign in to App Store Connect in the app's browser
> and say "done" — Claude will do every click except your password/2FA.

### Google Play — PREPARED, needs you (unavoidable one-time setup + Google's gate)
`android-release.yml` builds a signed release **.aab** when the keystore secrets
are present; `build.gradle.kts` is wired. Remaining steps are genuinely owner-only:

1. **Create the upload keystore** (offline, back it up outside the repo):
   `keytool -genkey -v -keystore printing-partner-upload.jks -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias upload`
2. **Set GitHub secrets** (Claude is blocked from writing secrets):
   `ANDROID_KEYSTORE_B64` = `base64 -w0 printing-partner-upload.jks`,
   `ANDROID_KEY_PROPERTIES` = the filled `key.properties` text.
3. **Play Console** → create the app "Printing Partner", enrol in Play App Signing.
4. Upload the .aab (from `android-release.yml`), fill **Data safety** (same as
   App Privacy above), **content rating**, store listing (reuse the iOS text +
   screenshots), pricing = Free.
5. Google requires **personal accounts to run a closed test with ≥12 testers for
   14 days** before Production — then promote to Production and submit.
