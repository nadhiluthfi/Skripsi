plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.skripsi"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    defaultConfig {
        applicationId = "com.example.skripsi"
        minSdk = 33
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        missingDimensionStrategy("library", "sdk")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(project(":polar_sdk"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}
