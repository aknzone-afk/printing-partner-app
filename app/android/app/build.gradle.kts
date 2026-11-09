import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ---------------------------------------------------------------------------
// Release signing.
//
// The upload keystore details live in android/key.properties (git-ignored,
// see android/key.properties.example for the format). When that file is
// present the release build is signed with the owner's upload key; when it is
// absent (CI, a fresh clone, a developer machine) we fall back to the debug
// key so `flutter build apk --release` / `flutter run --release` still work.
// A debug-signed build can NEVER be uploaded to Play, so the fallback is safe.
// ---------------------------------------------------------------------------
val keystorePropertiesFile: File = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore: Boolean = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
    for (required in listOf("storeFile", "storePassword", "keyAlias", "keyPassword")) {
        if (keystoreProperties.getProperty(required).isNullOrBlank()) {
            throw GradleException(
                "android/key.properties is missing '$required'. " +
                    "See android/key.properties.example."
            )
        }
    }
}

android {
    namespace = "in.printingpartner.printing_partner"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "in.printingpartner.printing_partner"
        // compileSdk / targetSdk come from the Flutter SDK (36 on Flutter 3.41),
        // which satisfies Play's >= 35 requirement; minSdk 24 from Flutter.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                // storeFile may be absolute, or relative to the android/ folder.
                val storePath = keystoreProperties.getProperty("storeFile")
                val resolved = File(storePath).let { f ->
                    if (f.isAbsolute) f else rootProject.file(storePath)
                }
                if (!resolved.exists()) {
                    throw GradleException(
                        "Keystore not found at ${resolved.absolutePath} " +
                            "(storeFile in android/key.properties)."
                    )
                }
                storeFile = resolved
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "[printing_partner] android/key.properties not found - " +
                        "release build is signed with the DEBUG key (not uploadable to Play)."
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
