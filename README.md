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

## 内部标题与音频文件

谱面库标题行中，“内部标题”按钮位于“打开目录”正上方、与之同宽（默认关闭）：
关闭时卡片与阅读器标题显示**去掉扩展名的文件名**并隐藏作者；开启时显示文件
自身的元数据标题与作者。该开关通过平台侧偏好（`use_internal_titles`）持久保存，
对谱面与音频一视同仁。

音频文件是收藏中的一等条目：`mp3, wav, wave, ogg, oga, opus, flac, m4a, aac,
mp4, m4b, wma, aif, aiff, amr, 3gp` 均可被单文件导入、目录导入与谱面库列表识别。
它们通过与 mscz_an_Audio 相同的 Android `MediaPlayer` 后端播放（`com.musereader/media`
通道），并复用完全相同的传输控制：播放/暂停/重播/拖动进度、上一首/下一首、全部循环
模式、黄金比例随机记忆、播完自动续播、“开始随机”，以及借助前台服务与唤醒锁实现的
息屏后台播放。标题/艺术家标签与时长来自 `MediaMetadataRetriever`：开启“内部标题”
时显示标签，关闭时显示文件名。音频条目的播放区域显示“音频文件（无谱面）”面板并隐藏
页码导航，谱面与音频可混合在同一收藏中。

## 目录授权（打开目录）

首次使用需要系统 SAF 选择器（`ACTION_OPEN_DOCUMENT_TREE`）授权一个目录；授权后
应用会持久保存该授权，之后“打开目录”直接进入应用内浏览器，只有首次授权、更换目录
或重新授权时才会再次打开系统选择器。

系统选择器的“USE THIS FOLDER”按钮只有在它已经**导航进一个可授权目录**后才会出现：
默认位置常常是“最近使用”或上次的位置（下载目录与存储根目录在 Android 11+ 根本不
可授权），因此按钮要等到用户手动切换目录才出现。为让按钮一打开就可用，应用启动
选择器时会带上 `DocumentsContract.EXTRA_INITIAL_URI`：优先指向当前已授权的目录
（文档 URI 形式），否则取第一个存在的标准公共目录（`Documents`/`Music`/`Pictures`，
Android 11 之前还包含 `Downloads`），都探测不到时退回 `Music`（每个媒体卷都有），
选择器无法解析该位置时只会退回它自己的默认位置，因此这样做没有副作用。每次打开
选择器都会向 logcat 输出一行 `[MuseReader] folder picker opening at <uri>`。

应用内浏览器的底部栏（确认目录/取消）在页面出现的第一帧就在位：目录内容还在读取
时“确认目录”可见但不可点，读取完成后立即变为可点。若系统选择器仍然没有显示确认
按钮，用户空手返回时谱面库会提示“先进入任意子目录再返回，按钮就会出现”。

### 导入的失败保护与原子性

导入是**原子**的：新文件先复制到一个暂存目录（`imports-<uuid>.staging`），只有全部
复制成功后才删除目录里已经过时的文件并把暂存文件移入（`replaceImportedScores`）。
因此读取中途失败（提供者掉线、文件被移除）时磁盘上仍是**原来那一套谱面**，而不是
旧文件与半截新文件的混合；失败会通过 `folder_import_failed` 上报，界面提示“导入目录
失败，请重试”。

- **不把慢导入当成空目录**：Dart 侧的等待不会超时，因为超时无法取消原生复制，而
  “空目录”会把整个收藏清空；平台返回空结果时抛出异常而不是返回空列表。
- **不可读的目录不能确认**：列目录失败时（红色提示条 + 重新授权）确认目录保持禁用，
  避免把无法读取的目录当作空目录导入。
- **导入期间不能离开**：确认目录与系统返回在手势期间都被拦住，否则结果会被丢弃，
  而磁盘上的复制仍在继续。
- **相同文件原地复用**：同名同大小的文件不重新复制，元数据/封面/文档缓存（sidecar）
  与文件一起保留，只有不再存在的谱面及其缓存才会被清除（`preservedImportNames`）。

## 加载顺序与息屏行为

- **“开始随机”加载提示**：随机选中的谱面需要原生排版时，谱面库会显示与阅读器
  切换曲目相同的“正在载入谱面…”卡片，准备好后再打开播放界面并开始播放。
- **缩略图/页数/时长按可见优先**：以后台排版时“最后构建出的那张卡片”（即当前
  视口最下方的一张，例如可见 c,d,e 时的 e）为锚点，先向上回走到收藏开头，再向下
  继续到末尾：c,d,e 可见时顺序为 e,d,c,b,a,f,g,h。锚点每帧更新（滚动后会重新
  对齐），但正在渲染的那一张永不被中断；首次选择会等列表完成一次布局，因此不会
  盲目从第 1 条开始。每次选择都会向 logcat 输出一行
  `[MuseReader] loading <文件> (anchor <锚点>)` 便于核对实际顺序。
- **“熄屏不打断下一首”**（播放界面 上一首/下一首/循环模式 行下方，默认开启，记忆
  用户选择）：开启时保持现在的行为；关闭后，熄屏期间当前曲目仍会继续播放，但
  播完不会自动切到下一首；重新点亮屏幕后会自动载入下一首（保持暂停），再按播放
  键才开始播放。仅当曲目结束的那一刻屏幕处于关闭状态时才生效；谱面与音频同等
  适用。该开关与“循环模式”按钮同高，位于其下方。

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
