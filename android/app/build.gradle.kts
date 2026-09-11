plugins {
    alias(libs.plugins.android.application)
}

android {
    namespace = "dk.yepz.webreader"
    compileSdk = 36

    // Optional, and only about size: AGP strips the packaged `.so`s with the NDK's
    // `llvm-strip`, and with no NDK in sight it packages the Swift runtime unstripped —
    // around 104 MB per APK instead of 74. Nothing in this module is compiled with the NDK
    // (the Swift side already used one to produce `jniLibs`), so a missing one is a warning
    // at package time and never a failed build.
    //
    // The revision is read off the NDK rather than pinned: AGP refuses to use an `ndkPath`
    // whose `Pkg.Revision` disagrees with `ndkVersion`, and the version that matters is
    // whichever one the Swift SDK was linked against.
    (providers.gradleProperty("webreader.ndkPath").orNull
        ?: System.getenv("ANDROID_NDK_ROOT")
        ?: System.getenv("ANDROID_NDK_HOME"))
        ?.let { path ->
            val revision = file("$path/source.properties").takeIf { it.isFile }
                ?.readLines()
                ?.firstOrNull { it.startsWith("Pkg.Revision") }
                ?.substringAfter('=')
                ?.trim()
            if (revision != null) {
                ndkPath = path
                ndkVersion = revision
            }
        }

    defaultConfig {
        applicationId = "dk.yepz.webreader"
        // 28 is the floor the Swift runtime for Android is built against
        // (`aarch64-unknown-linux-android28`), so it is the floor of the app too.
        minSdk = 28
        targetSdk = 36
        versionCode = 3
        versionName = "0.14.0"
    }

    // One APK per ABI, and no universal one. The Swift runtime is around 74 MB of stripped
    // `.so` per architecture, so a universal APK would be twice that for no reason — every
    // device installs exactly one of them.
    //
    // The ABI list is read off `jniLibs` rather than written down here, because a written
    // list lies in both directions: an ABI listed but not built ships an APK that installs
    // and then dies in `System.loadLibrary`, and an ABI built but not listed is silently
    // thrown away. `Scripts/build-android.sh` clears the whole tree before it writes, so
    // what is on disk is exactly what the last cross-build produced.
    //
    // Nothing there at all is not a misconfiguration: the `.so`s are build outputs and are
    // not in git, so a checkout that has never run the script — CI's Kotlin job — has no
    // native code to split on, and the split switches itself off rather than asking AGP to
    // honour an empty include list.
    val builtAbis = file("src/main/jniLibs")
        .listFiles()
        ?.filter { it.isDirectory && it.list()?.any { name -> name.endsWith(".so") } == true }
        ?.map { it.name }
        ?.sorted()
        .orEmpty()

    splits {
        abi {
            isEnable = builtAbis.isNotEmpty()
            reset()
            include(*builtAbis.toTypedArray())
            isUniversalApk = false
        }
    }

    buildTypes {
        release {
            // R8 must not touch the JNI entry point or the JavaScript interface: both are
            // reached by name from outside the Kotlin world and neither has a Java caller
            // for R8 to trace. See `proguard-rules.pro`.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"),
                          "proguard-rules.pro")
        }
    }

    packaging {
        jniLibs {
            // `Scripts/build-android.sh` writes ReaderKit and the Swift runtime into
            // `src/main/jniLibs`, which is the default location, so nothing declares it here.
            // Uncompressed and page-aligned is what lets the loader map them straight out of
            // the APK instead of unpacking a Swift runtime's worth of `.so` on install.
            useLegacyPackaging = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        // Everything the app draws natively is two views; a layout file is cheaper to read
        // than the code that would build them.
        viewBinding = true
        // `BuildConfig.DEBUG` gates WebView contents debugging. A remote inspector attached
        // to a release build would expose every page the reader has open.
        buildConfig = true
    }
}

dependencies {
    implementation(libs.androidx.core)
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.activity)
    implementation(libs.androidx.documentfile)
    implementation(libs.androidx.webkit)
    implementation(libs.material)
}
