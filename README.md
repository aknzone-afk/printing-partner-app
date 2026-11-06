# Printing Partner — iOS build repo (no-Mac TestFlight)

Public build-only mirror of the Printing Partner Flutter app (`app/`). A
GitHub-hosted macOS runner builds the iOS app and uploads it to TestFlight using
only an App Store Connect API key — no Mac needed. Same pipeline as the
`akn-zone-app`, `akn-chat-app` and `sappan-sarees-app` repos.

- Apple team: `DWJM58G45V`
- Bundle id: `in.printingpartner.printingPartner`
- Signing: fastlane **match**, certs in private repo `akn-chat-ios-certs` (shared).

## Ship a build

```
gh workflow run ios-testflight.yml -R aknzone-afk/printing-partner-app
```

First run only: repo variable `MATCH_READONLY=false` so match can create the
App Store profile for this bundle id; set it back to `true` after the first
green run.

> Never commit secrets, keys, or customer data — this repo is public.
