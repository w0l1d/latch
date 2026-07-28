allprojects {
    repositories {
        google()
        mavenCentral()
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
subprojects {
    project.evaluationDependsOn(":app")
}

// AGP 9 can supply Kotlin support itself ("built-in Kotlin"), replacing the
// org.jetbrains.kotlin.android plugin — but our plugin dependencies disagree
// about which era they're in, and the switch is one global flag:
//
//   - jni 1.0.1 skips `apply plugin: 'kotlin-android'` when AGP >= 9 and then
//     uses a top-level `kotlin { }` block, so it needs built-in Kotlin ON.
//   - file_picker 10.3.10 applies org.jetbrains.kotlin.android unconditionally,
//     which AGP 9 rejects outright, so it needs built-in Kotlin OFF.
//
// Built-in Kotlin therefore stays OFF (in gradle.properties) and the single
// project that assumes otherwise gets the plugin applied for it, which restores
// the `kotlin { }` extension its build script expects. Drop this once jni
// applies the plugin itself or file_picker stops doing so.
subprojects {
    if (name == "jni") {
        pluginManager.apply("org.jetbrains.kotlin.android")
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
