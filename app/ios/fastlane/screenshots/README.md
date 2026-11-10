# App Store screenshots

`fastlane deliver` (the `release` / `screenshots` lanes in the Fastfile) uploads
the PNGs it finds under this folder, one sub-folder per locale:

```
fastlane/screenshots/
  en-US/
    01_home.png
    02_photo_packages.png
    ...
```

## Where the PNGs come from

Run the **Store screenshots** workflow (`.github/workflows/store-shots.yml`,
Actions tab -> Run workflow). It drives `integration_test/store_shots_test.dart`
on an Android emulator and uploads a `store-screenshots` artifact. Download it,
pick the frames you want, and drop them into `en-US/` here (renamed/ordered),
sized to Apple's required resolutions:

- iPhone 6.9" (1320 x 2868 or 2868 x 1320) - required
- iPhone 6.5"/6.7" - required if targeting those devices
- iPad 13" (2064 x 2752) - required only if the app supports iPad

The same PNGs feed the Play listing (Play accepts phone screenshots at the
native emulator resolution). Keep this folder's contents out of the IPA - they
are upload assets only.
