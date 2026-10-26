pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
plugins {
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}
dependencyResolutionManagement {
    repositories { google(); mavenCentral() }
}
rootProject.name = "bridge-exec-spike"
include(":app")
