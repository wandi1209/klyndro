// Android Gradle Plugin 9 enables built-in Kotlin support, so no `kotlin-android`
// plugin is applied here or in the module build file. See
// https://developer.android.com/build/migrate-to-built-in-kotlin
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.compose.compiler) apply false
}
