import java.util.Properties

plugins { id("com.android.application") }

// Upload key lives outside git: keystore.properties + the .jks it points to (see play/README.md)
val keys = Properties().apply { rootProject.file("keystore.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) } }
// -Pplay builds the Play bundle with Google's in-app review card (src/play). The default build, which F-Droid makes and checks
// against our APK, gets src/fdroid's no-op instead and holds no Google Play code.
val play = providers.gradleProperty("play").isPresent

android {
    namespace = "com.borodutch.absplus"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.borodutch.absplus"
        minSdk = 29
        targetSdk = 36
        versionCode = 8
        versionName = "1.2.3"
    }
    // Without the key (e.g. on F-Droid's build server) release builds come out unsigned.
    signingConfigs {
        if (keys.isNotEmpty()) create("upload") {
            storeFile = rootProject.file(keys.getProperty("storeFile"))
            storePassword = keys.getProperty("storePassword")
            keyAlias = keys.getProperty("keyAlias")
            keyPassword = keys.getProperty("keyPassword")
        }
    }
    // F-Droid rejects APKs carrying Google's encrypted dependency block, which blocks reproducible builds there. Play still gets it from the bundle.
    dependenciesInfo { includeInApk = false }
    // The in-app language list in Android 13+ settings comes from the values-* folders.
    androidResources { generateLocaleConfig = true }
    sourceSets["main"].kotlin.srcDir(if (play) "src/play/java" else "src/fdroid/java")
    testOptions {
        unitTests.isIncludeAndroidResources = true
        // Robolectric suites are independent (own servers on port 0), so they split across JVMs.
        unitTests.all { it.maxParallelForks = (Runtime.getRuntime().availableProcessors() / 2).coerceIn(1, 4) }
    }
    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            signingConfig = signingConfigs.findByName("upload")
        }
    }
}

dependencies {
    implementation("androidx.media3:media3-exoplayer:1.11.1")
    implementation("androidx.media3:media3-session:1.11.1")
    implementation("com.google.android.material:material:1.14.0")
    if (play) implementation("com.google.android.play:review:2.0.2")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
}
