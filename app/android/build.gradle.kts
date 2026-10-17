import java.util.Base64

// The RuStore SDK is on a VK Maven repository that does not answer outside
// Russia (GitHub-hosted runners get 404). A build without a RuStore project
// therefore compiles flutter_rustore_push against :rustore_sdk_stub (see
// docs/adr/0008-push-delivery.md); only a build with a project resolves the
// real SDK. The decision is made once, here, for every project, and app/
// build.gradle.kts reads the project id from the extras. CI checks a
// configured manifest with the stub by setting
// ORG_GRADLE_PROJECT_pillpalRustoreSdk=stub.
val rootDartDefines: Map<String, String> =
    (project.findProperty("dart-defines") as String?)
        ?.split(",").orEmpty()
        .filter { it.isNotBlank() }
        .map { String(Base64.getDecoder().decode(it)) }
        .associate { it.substringBefore("=") to it.substringAfter("=", "") }

// RuStore Push exists in the RU region only (the server refuses its tokens
// elsewhere): no region means no RuStore. Same identifier pattern as
// app/lib/src/push/push_config.dart.
val rustoreProjectId: String? =
    if (rootDartDefines["PILLPAL_REGION"] == "ru")
        rootDartDefines["PILLPAL_RUSTORE_PROJECT_ID"]
            ?.trim()
            ?.takeIf { Regex("^[A-Za-z0-9_:.\\-]+$").matches(it) }
    else
        null
val useRustoreSdkStub: Boolean =
    rustoreProjectId == null || project.findProperty("pillpalRustoreSdk") == "stub"
extra["pillpal.rustoreProjectId"] = rustoreProjectId
extra["pillpal.useRustoreSdkStub"] = useRustoreSdkStub

subprojects {
    if (useRustoreSdkStub) {
        configurations.configureEach {
            resolutionStrategy.dependencySubstitution {
                substitute(module("ru.rustore.sdk:pushclient")).using(project(":rustore_sdk_stub"))
            }
        }
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
        // RuStore Push SDK (docs/adr/0008-push-delivery.md §1), for its own
        // coordinates only. Reachable from Russia; other networks get 404, so
        // builds without a RuStore project never resolve it (app/build.gradle.kts).
        maven {
            url = uri("https://artifactory-external.vkpartner.ru/artifactory/maven")
            content {
                includeGroupByRegex("ru\\.rustore(\\..*)?")
                includeGroupByRegex("com\\.vk(\\..*)?")
            }
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// workmanager_android 0.9.x (milestone 3.7) compiles its Kotlin only through
// AGP 9's built-in Kotlin: it skips `kotlin-android` for AGP >= 9. This
// project keeps built-in Kotlin off (gradle.properties) because other
// plugins (home_widget) apply the Kotlin Gradle Plugin themselves, so that
// one plugin gets the Kotlin plugin here, with the JVM target of its own Java
// options (1.8). Without it WorkmanagerPlugin is never compiled.
subprojects {
    if (name == "workmanager_android") {
        pluginManager.withPlugin("com.android.library") {
            apply(plugin = "org.jetbrains.kotlin.android")
            extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension> {
                compilerOptions.jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8)
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
