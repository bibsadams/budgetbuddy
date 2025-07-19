import org.gradle.api.tasks.Delete
import org.gradle.api.file.Directory

// ✅ Add buildscript block FIRST
buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        // ✅ Ensure this is the latest stable version
        classpath("com.google.gms:google-services:4.3.15")
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
