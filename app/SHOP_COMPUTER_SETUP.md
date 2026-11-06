# Printing Partner — Setup on a New Computer (e.g. Shop PC)

This project's **source code lives in OneDrive** so it syncs between home and shop:
`D:\OneDrive\CLE\printing-partner\app\` (Windows; on Mac/Linux the OneDrive path will differ).

Build tools (Flutter SDK, JDK, Android SDK) are **per-machine** — they do NOT sync.
You need to install them locally on each computer.

---

## One-time setup on a new computer

### 1. Install OneDrive and let it sync
Sign in to OneDrive with the same Microsoft account. Wait for `OneDrive\CLE\printing-partner\` to download.

### 2. Install Flutter + JDK + Android SDK
Easiest: download the zips and unpack to `D:\PrintingPartner\tools\` (same paths as home — env vars below will match):

- **Flutter 3.41.9 stable** → `D:\PrintingPartner\tools\flutter\`
  https://docs.flutter.dev/release/archive
- **JDK 17** (Eclipse Temurin or OpenJDK) → `D:\PrintingPartner\tools\jdk17\`
  https://adoptium.net/temurin/releases/?version=17
- **Android SDK** (only if you want to build the APK; web works without it)
  Easiest: install Android Studio, then point `ANDROID_HOME` at its SDK path.

If you use different paths on the shop PC, just adjust the env-var values below.

### 3. Open PowerShell and set env vars for each session
```powershell
$env:JAVA_HOME = "D:\PrintingPartner\tools\jdk17"
$env:GRADLE_USER_HOME = "D:\PrintingPartner\tools\gradle-home"
$env:PUB_CACHE = "D:\PrintingPartner\tools\pub-cache"
$env:Path = "$env:JAVA_HOME\bin;D:\PrintingPartner\tools\flutter\bin;$env:Path"
```
Or save these permanently with `setx` so you don't retype every time.

### 4. Junction `build/` and `.dart_tool/` outside OneDrive (REQUIRED)
OneDrive will lock files inside `build\flutter_assets` while Flutter is hot-reloading, breaking every run. Junctions point these folders at local disk so OneDrive never sees them.

```powershell
$proj = "D:\OneDrive\CLE\printing-partner\app"
$cache = "D:\PrintingPartner\build-cache\app"
New-Item -ItemType Directory -Force -Path "$cache\build", "$cache\.dart_tool" | Out-Null
if (Test-Path "$proj\build") { Remove-Item "$proj\build" -Recurse -Force }
if (Test-Path "$proj\.dart_tool") { Remove-Item "$proj\.dart_tool" -Recurse -Force }
cmd /c mklink /J "$proj\build" "$cache\build"
cmd /c mklink /J "$proj\.dart_tool" "$cache\.dart_tool"
```

Verify with `Get-Item "$proj\build", "$proj\.dart_tool"` — both should show `LinkType: Junction`.

### 5. Fetch packages
```powershell
cd "D:\OneDrive\CLE\printing-partner\app"
flutter pub get
```

### 6. Run it
```powershell
flutter run -d chrome --web-port=8080   # web (fastest)
flutter run -d android                  # Android phone in dev mode
flutter build apk --release             # APK for installing on phones
```

---

## Daily workflow

- Edit code in `D:\OneDrive\CLE\printing-partner\app\lib\`
- OneDrive auto-syncs changes within seconds
- On the other computer, you'll see new code arrive automatically — just `flutter run` again

### Avoid editing on both computers simultaneously
OneDrive can create conflicted-copy files if both machines change the same file at the same time. Close the project on one side before working on the other.

### What's NOT in OneDrive (regenerates locally each run)
- `build/`
- `.dart_tool/`
- `android/.gradle/`
- `D:\PrintingPartner\tools\` (Flutter SDK, JDK, etc.)

If you ever see `.dart_tool/` start syncing into OneDrive, right-click → Free up space, or add it to OneDrive's "Storage Sense" exclusions.

---

## Quick commands cheat-sheet

```powershell
# Web dev
flutter run -d chrome --web-port=8080

# Android APK release
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk

# Hot reload while running: press r
# Hot restart: press R
# Quit: q
```
