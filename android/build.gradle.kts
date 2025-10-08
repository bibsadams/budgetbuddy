import org.gradle.api.tasks.Delete
import org.gradle.api.file.Directory
import com.android.build.gradle.LibraryExtension

// ✅ Add buildscript block FIRST
buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        // Align with AGP 8.5.x
        classpath("com.google.gms:google-services:4.4.2")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// ✅ Optional (if you're customizing build output directory)
val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

// Workaround: some third-party plugins (e.g., flutter_native_timezone 2.0.0)
// may miss an AGP 8+ required namespace. Assign one here to unblock builds.
subprojects {
    if (name == "flutter_native_timezone") {
        plugins.withId("com.android.library") {
            extensions.configure<LibraryExtension>("android") {
                if (namespace == null || namespace!!.isBlank()) {
                    namespace = "dev.fluttercommunity.flutter_native_timezone"
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
