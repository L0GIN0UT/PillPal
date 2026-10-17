plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (CLAUDE.md "CI / CD"): app-release.yml decodes the upload
// keystore from the ANDROID_KEYSTORE_BASE64 secret and passes its path and
// credentials in the environment. Without them the release build is signed
// with the debug key: installable for testing, not uploadable to a store.
val releaseKeystore: java.io.File? =
    System.getenv("ANDROID_KEYSTORE_PATH")?.takeIf { it.isNotBlank() }?.let { file(it) }

// Invite links (docs/adr/0009-invite-links.md): the https hosts of the verified
// App Links come from the same --dart-define the app parses links with
// (PILLPAL_LINK_HOSTS="ru=host,eu=host"), so the manifest and the Dart code
// cannot disagree. Flutter hands the defines to Gradle base64-encoded.
// Without them the placeholder hosts apply (never verified, never routable).
val placeholderLinkHosts = "ru=links-ru.pillpal.invalid,eu=links-eu.pillpal.invalid"
val linkHosts: Map<String, String> = run {
    val defines = (project.findProperty("dart-defines") as String?)
        ?.split(",").orEmpty()
        .filter { it.isNotBlank() }
        .map { String(java.util.Base64.getDecoder().decode(it)) }
        .associate { it.substringBefore("=") to it.substringAfter("=", "") }
    (defines["PILLPAL_LINK_HOSTS"]?.takeIf { it.isNotBlank() } ?: placeholderLinkHosts)
        .split(",")
        .map { it.split("=") }
        .filter { it.size == 2 && it[0].isNotBlank() && it[1].isNotBlank() }
        .associate { it[0].trim().lowercase() to it[1].trim().lowercase() }
}

android {
    namespace = "com.pillpal.pillpal"
    // flutter_local_notifications 22 needs compileSdk >= 35 (36 used by the
    // plugin) and minSdk 24 (docs/adr/0001-local-notifications.md §5).
    compileSdk = maxOf(flutter.compileSdkVersion, 36)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required by flutter_local_notifications (java.time on old APIs).
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.pillpal.pillpal"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 24)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["linkHostRu"] = linkHosts["ru"] ?: "links-ru.pillpal.invalid"
        manifestPlaceholders["linkHostEu"] = linkHosts["eu"] ?: "links-eu.pillpal.invalid"
    }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = releaseKeystore
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(
                if (releaseKeystore != null) "release" else "debug",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
