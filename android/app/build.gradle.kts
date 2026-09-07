plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Dev builds (`.github/workflows/dev_build.yml`, or locally
// `flutter build apk --android-project-arg devBuild=true`) get their own
// applicationId so a test APK installs ALONGSIDE an installed release instead
// of replacing it: no uninstall, no wiped passphrase vault, and the dev copy's
// SAF grants and prefs stay its own. Absent the property every line below is
// inert, so release builds are unchanged.
val isDevBuild = (project.findProperty("devBuild") as String?) == "true"

android {
    namespace = "com.latch.latch"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = if (isDevBuild) "com.latch.latch.dev" else "com.latch.latch"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Two identical "latch" icons side by side would be a coin toss — the
        // launcher label is the only thing distinguishing the two installs.
        manifestPlaceholders["appLabel"] = if (isDevBuild) "Latch dev" else "latch"
    }

    // Plain-JVM unit tests for the framework-free helpers (see
    // ExternalStorageDocIds): `./gradlew :app:testDebugUnitTest`.
    sourceSets {
        getByName("test").kotlin.srcDir("src/test/kotlin")
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
