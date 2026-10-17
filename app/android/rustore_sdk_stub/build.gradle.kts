// Build-time stand-in for the RuStore Push SDK (ru.rustore.sdk:pushclient),
// used while no RuStore project is configured (docs/adr/0008-push-delivery.md
// "Implementation notes (3.9)"). The SDK lives on a VK Maven repository that
// answers 404 to networks outside Russia, GitHub-hosted runners included, so
// the default build and CI could not resolve it. The stub has exactly the
// surface flutter_rustore_push 7.2.0 compiles against; at run time it reports
// RuStore as unavailable. It is never shipped with a configured project:
// app/build.gradle.kts substitutes the real SDK then.
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.pillpal.rustore_sdk_stub"
    // Same as flutter_rustore_push: a library's compileSdk becomes the
    // minimum its consumers must compile against (AAR metadata check).
    compileSdk = 34

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8
    }
}
