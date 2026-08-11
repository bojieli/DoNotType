plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "app.donottype"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.donottype"
        // InputMethodService recording in-process needs nothing exotic; 26 keeps the audio and
        // coroutine APIs used here available without desugaring.
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    // Signed with the upload keystore when one is present, which in practice means CI with the
    // secret configured. A local `assembleRelease` without it produces an unsigned APK rather than
    // failing the build -- being unable to make a release build on a laptop would be worse than a
    // build you cannot ship.
    signingConfigs {
        create("upload") {
            val keystore = rootProject.file("release.keystore")
            if (keystore.exists()) {
                storeFile = keystore
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
                    ?: System.getenv("ANDROID_KEYSTORE_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (rootProject.file("release.keystore").exists()) {
                signingConfig = signingConfigs.getByName("upload")
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        viewBinding = false
    }

    sourceSets["main"].java.srcDir("src/main/kotlin")
    sourceSets["androidTest"].java.srcDir("src/androidTest/kotlin")
    // The contract is shared, not duplicated: PROMPT.md is copied out of the repo root at build
    // time so Android cannot drift from macOS or from what the eval harness measures.
    sourceSets["main"].assets.srcDir(layout.buildDirectory.dir("generated/assets"))
}

val syncContract by tasks.registering(Copy::class) {
    from(rootProject.file("../PROMPT.md"))
    into(layout.buildDirectory.dir("generated/assets"))
}

tasks.named("preBuild") { dependsOn(syncContract) }

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.json:json:20240303")
    testImplementation("junit:junit:4.13.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test:rules:1.6.1")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
}
