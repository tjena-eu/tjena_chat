plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "eu.tjena.bridgespike"
    compileSdk = 35
    defaultConfig {
        applicationId = "eu.tjena.bridgespike"
        minSdk = 29
        targetSdk = 35
        versionCode = 1
        versionName = "0.0.1-spike"
        ndk { abiFilters += "arm64-v8a" }
    }
    // Step 0 item 3: the bridge binary ships as lib*.so and must be extracted
    // to nativeLibraryDir (the only app location Android 10+ lets us exec from).
    packaging {
        jniLibs {
            useLegacyPackaging = true
            keepDebugSymbols += "**/libmautrixwhatsapp.so"
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
