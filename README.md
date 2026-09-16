# MuseReader

MuseReader 是一个 Android/iOS 双端 Flutter 只读谱面阅读器。它支持通过系统文件选择器打开 `MSCX` 和 `MSCZ`，使用 MuseScore 3.6.2 原生排版器生成分页谱面，并按同一份展开反复后的原生时间线播放、定位和高亮音符。导入的谱面会复制到应用私有的持久目录，并在应用重启后自动恢复到谱面库。产品界面不包含编辑、保存或导出功能。

## 移动端原生状态

两个移动端目标均锁定为 arm64，并默认要求原生核心：

| 平台 | 目标 | 原生交付 |
| --- | --- | --- |
| Android | `arm64-v8a`，NDK `28.2.13676358` | `libmuse_reader_engine.so` 静态吸收 `libmscore`、qzip、FreeType、qminimal 与资源；APK 同时携带 Qt 5.15.2 Core/Gui/Widgets/Xml/Svg、Qt Android JNI runtime (`QtAndroid.jar`) 和 `libc++_shared.so` |
| iOS | `iphoneos/arm64`，最低 iOS 13 | `MuseReaderEngine.framework` 静态吸收 Qt 5.15.2、`libmscore`、qzip、FreeType、qminimal 与资源，仅保留 Apple 系统动态依赖 |

`ScoreRepository` 对 Android/iOS 使用 `MUSE_READER_REQUIRE_NATIVE=true` 的 fail-closed 语义，原生核心缺失或初始化失败时会明确报错，不会静默切换到兼容排版。构建脚本仍显式传入该 define，避免发布命令的意图不清晰。Dart 兼容解析器仅保留给非移动端测试和开发诊断。

## 精确渲染与进度

原生适配器位于 [native/musescore_engine/muse_reader_engine.cpp](native/musescore_engine/muse_reader_engine.cpp)，直接复用附件 MuseScore 3.6.2 的核心路径：

1. `MasterScore::loadMsc()` 读取 `MSCX/MSCZ`。
2. `MasterScore::doLayout()` 生成 MuseScore 原生页面布局。
3. `Score::print()` 将每页绘制为 PNG，Flutter 只负责显示、缩放和平移。
4. `Score::renderMidi(..., expandRepeats=true, ...)` 生成展开反复后的播放事件。
5. `Score::utick2utime()` 通过原生 `TempoMap` 与 `RepeatList` 生成整数微秒时间。

阅读器默认使用连续多页画布：所有已排版页面按顺序显示在同一视图中，页面之间保留纸张间距；单指拖动可浏览整份谱面，双指手势会围绕手势中心缩放整份谱面（倍率范围 0.8×–4×）。这对应 MuseScore 3.6.2 `ScoreView` 的页面画布和 `QPinchGesture` 行为，而不是在单页 `PageView` 中分别缩放页面。顶部的“适应页面”按钮可恢复默认的适合宽度视图，底部页码按钮会在多页画布中定位到指定页面。

页面图像、音符 `startUs/endUs` 和 `Note::pageBoundingRect()` 均来自同一个已排版的 `MasterScore`。播放指针、拖动、变速、分页与高亮因此共享同一时间源和几何坐标，不经过 Flutter 的二次排版或 tick 估算。

## 微分音播放

MuseScore/Xen Tuner 等插件写入的每个音符 `Note::tuning`（单位为 cents）会随
播放事件一路传递到原生 FluidSynth。音符的整数 MIDI `pitch` 与 cents 偏移分开
保存，因此同一个 MIDI 键上的不同微分音可以同时发声，不会互相覆盖；带有
MuseScore `<Events>` 的装饰音/分解播放事件也会保留其相对音高和时值。FluidSynth
音频后端不可用时，Android/iOS 的兼容振荡器使用相同的频率公式作为开发期备用路径。

## 构建与打包

要求 macOS、Xcode、Flutter、CMake、`curl`、`bsdtar`、`shasum`，以及相邻目录中的 MuseScore 源码：

```text
/Volumes/Files/Github/
├── MuseReader/
└── MuseScore-3.6.2/
```

执行完整 arm64 构建：

```sh
./tool/build_mobile_arm64.sh all
```

脚本会从 Qt 官方归档下载并校验 Qt 5.15.2 Android/iOS Core、Gui、Widgets、Xml、Svg 组件、Android JNI runtime（`QtAndroid.jar`）和 Android qminimal 所需的 QtBase 源码，然后直接从 MuseScore 3.6.2 源码交叉编译 `libmscore` 及依赖。也可只构建一个平台或只审计已有产物：

```sh
./tool/build_mobile_arm64.sh android
./tool/build_mobile_arm64.sh ios
./tool/build_mobile_arm64.sh verify
```

默认输出：

- `build/releases/MuseReader-android-arm64-release.apk`
- `build/releases/MuseReader-ios-arm64-unsigned.ipa`
- `ios/Frameworks/MuseReaderEngine.framework`

可通过 `MUSESCORE_SOURCE_DIR` 覆盖源码位置。Android release 使用 `android/key.jks`，签名密码从本地 Gradle 配置读取且不写入仓库；iOS IPA 未签名。上架或真机分发前仍必须确认 Android keystore 和 Apple Team/Provisioning Profile 符合分发要求后重新签名构建。

等价的最终 Flutter 命令为：

```sh
flutter build apk --release --target-platform android-arm64 \
  --dart-define=MUSE_READER_REQUIRE_NATIVE=true
flutter build ios --release --no-codesign \
  --dart-define=MUSE_READER_REQUIRE_NATIVE=true
```

## 开发验证

```sh
flutter analyze
flutter test
```

应用图标迁移自 MuseScore 3.6.2 的
`assets/musescore-icon-round.svg`，项目内的源文件为
`assets/branding/muse_reader_icon.svg`。源图标采用不透明的全幅渐变背景，
由 iOS/Android 在运行时应用原生圆角或形状遮罩，避免透明角落显示黑边；
Android 自适应前景另留出安全区边距。平台 PNG 由配套的 macOS 渲染器生成；
调整图标时同步更新 SVG 及 Android 自适应图标的前景矢量，然后运行
`swift tool/generate_app_icons.swift`，
即可重新生成 Android 各密度图标和 iOS AppIcon 资源。

脚本的 `verify` 模式还会检查 APK 只含 `arm64-v8a`、所需 Qt/NDK 运行库均已打包、iOS Runner/Flutter/App/原生 Framework 都只含 arm64，并确认 C ABI 导出符号存在。

主要源码入口：

- [lib/src/services/score_repository.dart](lib/src/services/score_repository.dart)：原生核心强制策略。
- [lib/src/services/muse_score_bridge.dart](lib/src/services/muse_score_bridge.dart)：原生 JSON 到 Flutter 谱面模型的映射。
- [lib/src/playback/playback_controller.dart](lib/src/playback/playback_controller.dart)：微秒时间线、拖动、变速和高亮状态。
- [lib/src/ui/reader_page.dart](lib/src/ui/reader_page.dart)：只读阅读界面。
- [android/app/src/main/kotlin/icu/ringona/musereader/MainActivity.kt](android/app/src/main/kotlin/icu/ringona/musereader/MainActivity.kt)：Android 文件选择、JNI 通道和音频调度。
- [ios/Runner/AppDelegate.swift](ios/Runner/AppDelegate.swift)：iOS 文件选择、C ABI 通道和音频调度。

附件源码中的说明文件属于 MuseScore 自身，不是 MuseReader 的产品需求。本项目只采用实现只读加载、原生排版和播放时间线所需的代码，不引入编辑器功能。

## 许可证

MuseScore 3.6.2 代码采用 GPLv2，移动包还包含 Qt 5.15.2、FreeType 与 qzip。分发前必须遵守 [NOTICE-MUSESCORE.md](NOTICE-MUSESCORE.md)、Qt 官方许可条款及附件源码中的许可证、通知和对应源代码提供义务。
