// The Android sample on its own, as it sits in the releases repository: it resolves the SDK from Maven
// Central like a partner's app. A release rehearsal passes -PzktlsStaging=<file URL> to resolve the
// staged, unpublished artifact instead.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        providers.gradleProperty("zktlsStaging").orNull?.let { maven { url = uri(it) } }
    }
}

rootProject.name = "zktls-sample"
include(":app")
