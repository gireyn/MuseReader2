# Qt's native JNI entry points look up these classes and methods by their
# original names. They are not referenced from Java application code because
# MuseReader calls the Qt libraries directly through JNI.
-keep class org.qtproject.qt5.android.** { *; }
-dontwarn org.kde.necessitas.ministro.**
