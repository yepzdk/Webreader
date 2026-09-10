// The plugin is resolved here and applied in `app`, which is the one place its version is
// pinned for the whole build. AGP 9 compiles Kotlin itself, so there is no second plugin.
plugins {
    alias(libs.plugins.android.application) apply false
}
