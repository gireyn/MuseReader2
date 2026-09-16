import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Keep signing secrets out of the repository. Values may be supplied through
// Gradle/local properties or the existing adjacent JustPiano signing config.
val localProperties = Properties().apply {
    val file = rootProject.file("local.properties")
    if (file.isFile) {
        file.inputStream().use(::load)
    }
}
val adjacentSigningProperties = Properties().apply {
    val file = rootProject.projectDir.parentFile?.parentFile
        ?.resolve("JustPiano/JP-Android/gradle.properties")
    if (file?.isFile == true) {
        file.inputStream().use(::load)
    }
}

fun signingProperty(vararg names: String): String? =
    names.firstNotNullOfOrNull { name ->
        providers.gradleProperty(name).orNull
            ?: localProperties.getProperty(name)
            ?: adjacentSigningProperties.getProperty(name)
            ?: providers.environmentVariable(name).orNull
    }

fun requiredSigningProperty(value: String?, description: String): String =
    value?.takeIf(String::isNotBlank)
        ?: error("Release signing requires $description")

val releaseStoreFile = rootProject.file("key.jks")
check(releaseStoreFile.isFile) {
    "Release signing requires ${releaseStoreFile.absolutePath}"
}
val releaseStorePassword = requiredSigningProperty(
    signingProperty("RELEASE_STORE_PASSWORD", "sign.store.password"),
    "RELEASE_STORE_PASSWORD or sign.store.password",
)
val releaseKeyAlias = signingProperty("RELEASE_KEY_ALIAS", "sign.key.alias") ?: "as2134u"
val releaseKeyPassword = requiredSigningProperty(
    signingProperty("RELEASE_KEY_PASSWORD", "sign.key.password") ?: releaseStorePassword,
    "RELEASE_KEY_PASSWORD or sign.key.password",
)

val museReaderRoot = rootProject.projectDir.parentFile
val museScoreSource = project.findProperty("museScoreSourceDir")?.toString()
    ?: File(museReaderRoot.parentFile, "MuseScore-3.6.2").canonicalPath
val museReaderQt = project.findProperty("museReaderQtDir")?.toString()
    ?: File(museReaderRoot, "build/toolchains/qt/android/5.15.2/android").canonicalPath
// Qt's Android shared libraries use JNI_OnLoad to bind to the QtNative
// runtime class. Flutter does not use QtActivity, so androiddeployqt is not
// involved and the runtime jar must be packaged explicitly. Without it
// libQt5Core fails its JNI bootstrap with "initJNI failed" before the
// MuseScore bridge can initialize.
val museReaderQtAndroidJar = File(museReaderQt, "jar/QtAndroid.jar")
val museReaderQtBaseSource = project.findProperty("museReaderQtBaseSourceDir")?.toString()
    ?: File(museReaderRoot, "build/toolchains/src/qtbase-everywhere-src-5.15.2").canonicalPath
val museReaderSoundfont = File(museReaderRoot, "assets/sound/MS Basic.sf3").canonicalPath
val museReaderCmakeArgs = listOf(
    "-DMUSE_READER_BUILD_MUSESCORE_SOURCE=ON",
    "-DMUSE_READER_WITH_FLUIDSYNTH=ON",
    "-DMUSESCORE_SOURCE_DIR=$museScoreSource",
    "-DMUSE_READER_SOUNDFONT_PATH=$museReaderSoundfont",
    "-DMUSE_READER_QTBASE_SOURCE_DIR=$museReaderQtBaseSource",
    "-DQt5_DIR=$museReaderQt/lib/cmake/Qt5",
    "-DCMAKE_PREFIX_PATH=$museReaderQt",
    "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=NEVER",
    "-DANDROID_STL=c++_shared",
)

android {
    namespace = "icu.ringona.musereader"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "icu.ringona.musereader"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters.clear()
            abiFilters += "arm64-v8a"
        }

        externalNativeBuild {
            cmake {
                arguments += museReaderCmakeArgs
            }
        }
    }

    signingConfigs {
        create("release") {
            storeFile = releaseStoreFile
            storePassword = releaseStorePassword
            keyAlias = releaseKeyAlias
            keyPassword = releaseKeyPassword
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation(files(museReaderQtAndroidJar))
}
