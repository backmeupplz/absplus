import java.util.Properties

plugins { id("com.android.application") }

// Upload key lives outside git: keystore.properties + the .jks it points to (see play/README.md)
val keys = Properties().apply { rootProject.file("keystore.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) } }

android {
    namespace = "com.borodutch.absplus"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.borodutch.absplus"
        minSdk = 29
        targetSdk = 36
        versionCode = 5
        versionName = "1.2.0"
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
    testOptions { unitTests.isIncludeAndroidResources = true }
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
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16.1")
}
