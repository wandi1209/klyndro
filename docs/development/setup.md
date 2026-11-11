# Development setup

Verified on the development machine described in
[toolchain inventory](toolchain-inventory.md). Adjust versions if your machine differs.

## 1. macOS toolchain

1. Install Xcode (App Store or developer.apple.com), open it once, and accept the licence.
2. Confirm the command line tools point at Xcode:

   ```bash
   xcode-select -p        # expect /Applications/Xcode.app/Contents/Developer
   xcodebuild -version
   swift --version
   ```

3. If `xcode-select` points elsewhere: `sudo xcode-select -s /Applications/Xcode.app`.

## 2. Java

AGP 9.5 requires JDK 17 or newer.

```bash
java -version           # expect 17+
echo "$JAVA_HOME"       # optional, but Gradle uses it when set
```

Any JDK 17+ works (Temurin, Zulu, or an SDKMAN install). The Gradle Wrapper pins Gradle
9.7.1, which is the minimum AGP 9.5 supports.

## 3. Android SDK

Set `ANDROID_HOME` (or `ANDROID_SDK_ROOT`) to your SDK location and install the pieces the
build needs:

```bash
export ANDROID_HOME="$HOME/Library/Android/sdk"

# Platform required by the AndroidX artifacts used here (compileSdk = 37)
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" "platforms;android-37.0"
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" "platform-tools"
```

Notes:

- No global Gradle installation is required; `apps/android/gradlew` downloads/uses Gradle
  9.7.1.
- `local.properties` is not committed. Gradle finds the SDK through `ANDROID_HOME`; if you
  prefer, add `sdk.dir=/path/to/sdk` to `apps/android/local.properties`.
- `platforms;android-37.0` is an **SDK platform**, not an app dependency. It downloads from
  Google's SDK repository; nothing is installed system-wide and no `sudo` is needed.

## 4. Optional device tooling

Only needed for mirroring and on-device testing:

```bash
brew install --cask android-platform-tools   # provides adb
brew install scrcpy
adb version
scrcpy --version
```

On the phone: enable Developer options → USB debugging, then connect by USB and accept the
prompt. Verify with `adb devices -l`.

## 5. Verify everything

```bash
./scripts/check-toolchain.sh
```

The script is read-only. It reports macOS, Xcode, Swift, Java, the Android SDK, installed
platforms/build-tools, `adb`, and `scrcpy`, and exits non-zero if a required piece is
missing.

## 6. First build

```bash
./scripts/build-macos.sh     # Swift tests + Xcode build
./scripts/build-android.sh   # debug APK + JVM tests
```

Artifacts:

- macOS app: `~/Library/Developer/Xcode/DerivedData/Klyndro-*/Build/Products/Debug/Klyndro.app`
- Android APK: `apps/android/app/build/outputs/apk/debug/app-debug.apk`

## Common problems

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Failed to find Platform SDK with path: platforms;android-37` | Platform not installed | Run the `sdkmanager` command above |
| Gradle fails with "Unsupported class file major version" | JDK older than 17 | Point `JAVA_HOME` at a 17+ JDK |
| `Cannot add extension with name 'kotlin'` | `kotlin-android` plugin applied | Remove it; AGP 9 has built-in Kotlin (ADR 0007) |
| Diagnostics shows `adb`/`scrcpy` missing but terminal has them | GUI app inherits a minimal `PATH` | Klyndro probes `/opt/homebrew/bin` and `/usr/local/bin`; install there, or launch from Xcode during development |
| `adb devices` shows `unauthorized` | Debugging prompt not accepted | Unlock the phone and accept |
