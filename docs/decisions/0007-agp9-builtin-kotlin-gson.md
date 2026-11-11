# 0007 — AGP 9 built-in Kotlin and Gson tree codec on Android

Status: Accepted (M0), implemented and verified

## Context

The Android toolchain in this environment is AGP 9.5.1 with Gradle 9.7.1. AGP 9 enables
**built-in Kotlin**: applying `org.jetbrains.kotlin.android` is now an error, and `kapt` is
replaced by `com.android.legacy-kapt`. The Compose compiler Gradle plugin is still required
and must match the Kotlin version AGP bundles (2.2.10 for AGP 9.5.1).

For JSON, the natural Kotlin choice is kotlinx.serialization, but it needs a Kotlin compiler
plugin — exactly the mechanism that built-in Kotlin changes. Using Gson's tree API avoids
compiler plugins entirely.

## Decision

- Declare `com.android.application` 9.5.1 and `org.jetbrains.kotlin.plugin.compose` 2.2.10
  (matching AGP's bundled Kotlin). No `kotlin-android` plugin, no kapt/KSP.
- Parse and validate the wire format with **Gson's `JsonObject` tree API**, not reflection
  and not codegen. Validation is explicit and testable on the JVM.

## Consequences

- No compiler-plugin/Kotlin-version coupling beyond the Compose plugin, which is pinned in
  the version catalog with a comment explaining why 2.2.10 is not the newest release.
- Envelope validation is hand-written, so it is covered by unit tests and mirrors the Swift
  implementation's ordering exactly. Typed message bodies arrive with their features.
- Gson adds ~280 KB to the APK. Acceptable for the clarity it buys; kotlinx.serialization
  can be reconsidered if AGP's built-in Kotlin gains first-class support for its plugin.
- `compileSdk = 37` is required by current AndroidX artifacts, so the SDK platform
  `android-37.0` must be installed (see `docs/development/setup.md`).
- Revisit trigger: AGP 10 removes the built-in Kotlin opt-out; any kapt-based dependency
  added later will need a KSP migration, which this decision keeps cheap.
