plugins {
    id("com.android.application")
}

android {
    namespace = "ai.zktls.sample"
    compileSdk = 36
    defaultConfig {
        applicationId = "ai.zktls.sample"
        minSdk = 24
        targetSdk = 36
        // Play needs a higher versionCode on every upload: ZKTLS_VERSION_CODE sets it.
        versionCode = (System.getenv("ZKTLS_VERSION_CODE") ?: "1").toInt()
        versionName = property("sdkVersion").toString()
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    signingConfigs {
        // The app owner's Play upload key, from ZKTLS_UPLOAD_*; without it the release build is unsigned.
        System.getenv("ZKTLS_UPLOAD_KEYSTORE")?.let { ks ->
            create("upload") {
                storeFile = file(ks)
                storePassword = System.getenv("ZKTLS_UPLOAD_STORE_PASSWORD")
                keyAlias = System.getenv("ZKTLS_UPLOAD_KEY_ALIAS")
                keyPassword = System.getenv("ZKTLS_UPLOAD_KEY_PASSWORD")
            }
        }
    }
    buildTypes {
        release {
            // A partner's release build runs R8, and so does this one, with the SDK's consumer rules only.
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            signingConfigs.findByName("upload")?.let { signingConfig = it }
        }
    }
}

dependencies {
    // In zktls-sdk the sample builds against :sdk; in the releases repository, against Maven Central,
    // exactly as a partner's app does.
    if (findProject(":sdk") != null) implementation(project(":sdk"))
    else implementation("xyz.cr3dentials:zktls-sdk:${property("sdkVersion")}")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
}
