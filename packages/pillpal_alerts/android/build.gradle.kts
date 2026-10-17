plugins {
    id("com.android.library")
}

group = "com.pillpal.alerts"
version = "1.0"

android {
    namespace = "com.pillpal.alerts"
    // Same as the other plugins of the app that need no newer API: a
    // library's compileSdk is the minimum its consumers must compile against.
    compileSdk = 34

    defaultConfig {
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
}
