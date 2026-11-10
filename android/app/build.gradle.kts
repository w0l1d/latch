import java.util.Properties

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

// Release signing. The keystore and its passwords never enter the repository:
// `android/key.properties` is gitignored, and `release.yml` writes it from
// repository secrets on the runner (see docs/agents/builds-ci-and-provenance.md).
//
// Why the fallback below is guarded: through v1.0.17 this block was the Flutter
// template's `signingConfigs.getByName("debug")`, so every published APK was
// debug-signed. The debug keystore is generated per machine, so each CI runner
// produced a *different* certificate — and Android compares signatures at
// install time. The result was that v1.0.16 could not be updated to v1.0.17 in
// place; the only path was uninstall → install, which wipes app-private storage
// and with it the passphrase vault. It also meant no Play upload was possible.
//
// Two guards keep that from recurring silently:
//   * `-PrequireReleaseSigning=true` (set by release.yml) turns a missing
//     key.properties into a configuration-time failure, before anything is built.
//   * The fallback to the debug key exists only so `flutter run --release` still
//     works locally; it warns loudly so nobody mistakes the artifact for shippable.
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
val keystoreProperties = Properties().apply {
    if (hasReleaseKeystore) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

val requireReleaseSigning =
    (project.findProperty("requireReleaseSigning") as String?) == "true"

if (requireReleaseSigning && !hasReleaseKeystore) {
    throw GradleException(
        "Release signing is required (-PrequireReleaseSigning=true) but android/key.properties " +
            "is missing. Refusing to build: Gradle would sign this release with the debug key, " +
            "which Play rejects and which no installed APK can upgrade over."
    )
}

val missingKeystoreProperties = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    .filter { keystoreProperties.getProperty(it).isNullOrBlank() }
if (hasReleaseKeystore && missingKeystoreProperties.isNotEmpty()) {
    throw GradleException(
        "android/key.properties is missing required entries: " +
            missingKeystoreProperties.joinToString(", ")
    )
}

// Dev builds are debug-key by design (own applicationId, reinstall-fodder), so
// warning on every push to develop would be noise that trains people to ignore it.
if (!hasReleaseKeystore && !requireReleaseSigning && !isDevBuild) {
    logger.warn(
        "android/key.properties is absent: the release variant will be signed with the DEBUG key. " +
            "That artifact is for local `flutter run --release` only — never publish it."
    )
}

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

    signingConfigs {
        // Only declared when the file exists: a half-configured "release" block
        // would fail at signing time with a null storeFile instead of here.
        if (hasReleaseKeystore) {
            create("release") {
                // Relative to android/, so the same key.properties works locally
                // and on a runner wherever the keystore was written.
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                // keytool has produced PKCS12 by default since JDK 9; naming such a
                // file `.jks` does not change its format, so state the type.
                storeType = keystoreProperties.getProperty("storeType", "PKCS12")
            }
        }
    }

    buildTypes {
        release {
            // The debug branch is unreachable when -PrequireReleaseSigning=true:
            // the check above has already failed the build by then.
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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
