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
