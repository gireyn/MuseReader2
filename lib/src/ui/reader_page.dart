import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../model/audio_item.dart';
import '../model/score_document.dart';
import '../model/score_library_entry.dart';
import '../playback/advance_policy.dart';
import '../playback/audio_playback_controller.dart';
import '../playback/playback_controller.dart';
import '../playback/playback_handle.dart';
import '../playback/score_queue.dart';
import '../services/file_picker_service.dart';
import '../services/media_commands.dart';
import '../services/media_player_bridge.dart';
import 'score_page_painter.dart';
import 'toggle_button.dart';

class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    this.document,
    this.audio,
    this.queue,
    this.loadEntry,
    this.autoplay = false,
    this.useInternalTitles = true,
  }) : assert(
         document != null || audio != null,
         'ReaderPage needs either a score document or an audio item.',
       );

  /// Engraved MuseScore document; null when [audio] is set.
  final ScoreDocument? document;

  /// Audio file played by the platform media player; null for scores.
  final AudioItem? audio;

  /// 内部标题: when false the header shows the file name (no extension) and
  /// the author line is hidden.
  final bool useInternalTitles;

  /// Play queue of the current collection, carrying the hidden golden-ratio
  /// memory and the loop mode. When null (standalone usage, tests) the
  /// previous/next/loop row is hidden and no auto-advance happens.
  final ReaderQueue? queue;

  /// Hydrates (opens + caches) one collection entry by its source path. Only
  /// needed while [queue] is provided, because 上一首/下一首 and the end of a
  /// piece may target any entry of the collection.
  final Future<ScoreLibraryEntry> Function(String sourcePath)? loadEntry;

  /// Start playing as soon as the page is shown (开始随机 entry point).
  final bool autoplay;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  static const _restartBackThresholdUs = 3 * 1000 * 1000;

  ScoreDocument? _document;
  AudioItem? _audio;
  late PlaybackHandle _playback;
  GlobalKey<_MultiPageScoreViewportState> _scoreViewportKey =
      GlobalKey<_MultiPageScoreViewportState>();
  int _visiblePage = 0;
  bool _switching = false;
  bool _wasPlaying = false;

  /// Fallback for a finished piece that never handed over: the position
  /// sampling timer can be starved while the app is in the background, so a
  /// low-frequency watchdog re-checks the ended state and advances.
  Timer? _advanceWatchdog;
  int _stalledEndTicks = 0;

  /// 熄屏不打断下一首: default on; the user's choice is remembered.
  static const _advanceWhenScreenOffKey = 'advance_when_screen_off';
  bool _advanceWhenScreenOff = true;
  bool _advanceSettingTouched = false;

  /// A finished piece whose advance was suppressed because the screen was off.
  bool _pendingAdvance = false;

  /// Score-specific view of the transport (null while an audio file plays).
  PlaybackController? get _scorePlayback =>
      _document == null || _playback is! PlaybackController
      ? null
      : _playback as PlaybackController;

  String get _currentId => _document?.sourcePath ?? _audio!.sourcePath;

  String get _headerTitle {
    final document = _document;
    if (document != null) {
      return widget.useInternalTitles
          ? (document.title.isEmpty
                ? scoreDisplayName(document.fileName)
                : document.title)
          : scoreDisplayName(document.fileName);
    }
    return _audio!.displayTitle(useInternalTitles: widget.useInternalTitles);
  }

  @override
  void initState() {
    super.initState();
    _document = widget.document;
    _audio = widget.audio;
    _playback = _createPlayback()..addListener(_onPlaybackChanged);
    widget.queue
      ?..setCurrentId(_currentId)
      ..addListener(_onQueueChanged);
    unawaited(_restoreAdvancePreference());
    MediaCommands.onPauseRequested = _pauseFromPlatform;
    MediaCommands.onMediaCompleted = _mediaCompleted;
    MediaCommands.onScoreCompleted = _scoreCompleted;
    MediaCommands.onScreenOn = _screenTurnedOn;
    _advanceWatchdog = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _checkStalledAdvance(),
    );
    if (widget.autoplay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_play());
      });
    }
  }

  PlaybackHandle _createPlayback() {
    final document = _document;
    if (document != null) {
      return PlaybackController(document);
    }
    final audio = _audio!;
    return AudioPlaybackController(
      audio.sourcePath,
      durationUs: audio.durationUs,
    );
  }

  Future<void> _restoreAdvancePreference() async {
    final stored = await FilePickerService().readBooleanPreference(
      _advanceWhenScreenOffKey,
      fallback: true,
    );
    if (!mounted || _advanceSettingTouched) return;
    if (stored != _advanceWhenScreenOff) {
      setState(() => _advanceWhenScreenOff = stored);
    }
  }

  void _setAdvanceWhenScreenOff(bool value) {
    if (_advanceWhenScreenOff == value) return;
    _advanceSettingTouched = true;
    setState(() => _advanceWhenScreenOff = value);
    unawaited(
      FilePickerService().writeBooleanPreference(
        _advanceWhenScreenOffKey,
        value,
      ),
    );
  }

  /// Stop action of the playback notification: pause this reader.
  Future<void> _pauseFromPlatform() async {
    if (!mounted) return;
    await _playback.pause();
  }

  /// The platform media player reached the end of the current audio file.
  void _mediaCompleted() {
    if (!mounted) return;
    final playback = _playback;
    if (playback is AudioPlaybackController) playback.handleCompleted();
  }

  /// The embedded score renderer reached the end of its audio stream.
  void _scoreCompleted() {
    if (!mounted) return;
    final playback = _playback;
    if (playback is PlaybackController) playback.handleCompleted();
  }

  /// The screen came back on: with 熄屏不打断下一首 off, load the next piece so
  /// the reader only waits for the ▶ button (no auto-play).
  void _screenTurnedOn() {
    if (!mounted) return;
    unawaited(_preloadPendingAdvance());
  }

  /// Loads the piece whose advance was suppressed while the screen was off.
  /// Playback stays paused; the ▶ button starts it.
  Future<void> _preloadPendingAdvance() async {
    if (!_pendingAdvance || _switching) return;
    final queue = widget.queue;
    if (queue == null) return;
    if (!await MediaPlayerBridge.screenIsOn()) return;
    if (!mounted || !_pendingAdvance) return;
    final index = queue.endOfPieceIndex();
    if (index == null) return;
    _pendingAdvance = false;
    await _switchToPiece(queue.ids[index], autoplay: false);
  }

  /// Low-frequency safety net: a piece that has ended without the queue moving
  /// on (for example because the sampling timer was not scheduled while the
  /// screen was off) is advanced here.
  void _checkStalledAdvance() {
    if (!mounted || _switching) return;
    final queue = widget.queue;
    if (queue == null) return;
    final duration = _playback.durationUs;
    if (duration <= 0 || _playback.isPlaying) {
      _stalledEndTicks = 0;
      return;
    }
    if (_playback.positionUs < duration) {
      _stalledEndTicks = 0;
      return;
    }
    if (queue.effectiveLoop == PlayLoop.none) return;
    // A suppressed advance waits for the screen to come back (then the piece is
    // preloaded, still paused) and for the ▶ button to start it.
    if (_pendingAdvance) {
      unawaited(_preloadPendingAdvance());
      return;
    }
    _stalledEndTicks += 1;
    // Two ticks (≈4 s) so the normal end path has every chance to run first.
    if (_stalledEndTicks < 2) return;
    _stalledEndTicks = 0;
    unawaited(_handlePieceEnded());
  }

  void _onQueueChanged() {
    if (mounted) setState(() {});
  }

  void _onPlaybackChanged() {
    if (!mounted) return;
    final wasPlaying = _wasPlaying;
    _wasPlaying = _playback.isPlaying;
    // Every playback start lands in the queue's hidden golden-ratio memory:
    // the transport play button, a resume after pause, a manual piece switch
    // and the automatic advance at the end of a piece all count as "played".
    // Without this the memory could miss a piece and 随机（记忆） would be able
    // to pick the piece that just finished.
    if (!wasPlaying && _playback.isPlaying) {
      widget.queue?.recordCurrent();
      _stalledEndTicks = 0;
    }
    final scorePlayback = _scorePlayback;
    final document = _document;
    if (scorePlayback != null && document != null) {
      final cursor = scorePlayback.cursorPosition;
      final page = cursor?.pageIndex ?? scorePlayback.currentPage;
      final pageChanged = page != _visiblePage;
      if (pageChanged &&
          (scorePlayback.isPlaying || scorePlayback.cursorVisible) &&
          document.pages.isNotEmpty) {
        _visiblePage = page;
      }
      if (cursor != null && scorePlayback.cursorVisible) {
        _scoreViewportKey.currentState?.followCursor(
          cursor,
          animate: scorePlayback.isPlaying && !_reduceMotion,
        );
      } else if (pageChanged && scorePlayback.cursorVisible) {
        _scoreViewportKey.currentState?.focusPage(
          page,
          animate: !_reduceMotion,
        );
      }
    }
    // A piece ended when playback stopped itself at the end of the document.
    // The controller has no end callback, so infer it from the transition
    // playing -> stopped with the position pinned at the duration.
    final ended =
        wasPlaying &&
        !_playback.isPlaying &&
        _playback.durationUs > 0 &&
        _playback.positionUs >= _playback.durationUs;
    setState(() {});
    if (ended) {
      unawaited(_handlePieceEnded());
    }
  }

  @override
  void dispose() {
    if (MediaCommands.onPauseRequested == _pauseFromPlatform) {
      MediaCommands.onPauseRequested = null;
    }
    if (MediaCommands.onMediaCompleted == _mediaCompleted) {
      MediaCommands.onMediaCompleted = null;
    }
    if (MediaCommands.onScoreCompleted == _scoreCompleted) {
      MediaCommands.onScoreCompleted = null;
    }
    if (MediaCommands.onScreenOn == _screenTurnedOn) {
      MediaCommands.onScreenOn = null;
    }
    _advanceWatchdog?.cancel();
    _advanceWatchdog = null;
    widget.queue?.removeListener(_onQueueChanged);
    _playback.dispose();
    super.dispose();
  }

  /// Playback of the current piece stopped at its end: follow the loop mode.
  /// "播完停止" leaves the stopped state alone; every other mode hands the
  /// turn to the next scheduled piece and keeps playing (单曲循环 replays the
  /// same document).
  Future<void> _handlePieceEnded() async {
    final queue = widget.queue;
    if (queue == null || _switching) return;
    if (_pendingAdvance) return;
    final index = queue.endOfPieceIndex();
    if (index == null) return;
    // 熄屏不打断下一首 off: keep this piece while the screen is off; the ▶
    // button continues with the next piece after the screen is back on.
    if (suppressAdvanceForScreenOff(
      advanceWhenScreenOff: _advanceWhenScreenOff,
      screenOn: await MediaPlayerBridge.screenIsOn(),
    )) {
      if (mounted) _pendingAdvance = true;
      return;
    }
    await _switchToPiece(queue.ids[index], autoplay: true);
  }

  /// Transport ▶/⏸: a suppressed advance resumes the playlist instead of
  /// replaying the finished piece.
  Future<void> _onPlayPausePressed() async {
    if (_pendingAdvance) {
      _pendingAdvance = false;
      await _handlePieceEnded();
      return;
    }
    await _playback.toggle();
  }

  /// The "next piece" control. Manual switches keep playing only when
  /// playback was already running; otherwise the piece is loaded and left
  /// paused at its start, mirroring the reference player.
  Future<void> _goToNextPiece() async {
    final queue = widget.queue;
    if (queue == null || _switching) return;
    final index = queue.manualNextIndex();
    if (index == null) return;
    await _switchToPiece(queue.ids[index], autoplay: _playback.isPlaying);
  }

  /// The "previous piece" control: walk the golden-ratio memory history
  /// first; a piece that has not been played for long restarts instead; then
  /// fall back to stepping back through the collection.
  Future<void> _goToPreviousPiece() async {
    final queue = widget.queue;
    if (queue == null || _switching) return;
    final autoplay = _playback.isPlaying;
    final memoryTarget = queue.memoryPrevIndex();
    if (memoryTarget != null) {
      await _switchToPiece(queue.ids[memoryTarget], autoplay: autoplay);
      return;
    }
    if (_playback.positionUs > _restartBackThresholdUs) {
      if (autoplay) {
        await _playback.restart();
        await _play();
      } else {
        await _playback.restart();
      }
      return;
    }
    final stepBack = queue.stepBackIndex();
    if (stepBack != null) {
      await _switchToPiece(queue.ids[stepBack], autoplay: autoplay);
      return;
    }
    if (autoplay) {
      await _playback.restart();
      await _play();
    } else {
      await _playback.restart();
    }
  }

  /// Start playback. The queue memory is updated by [_onPlaybackChanged] on
  /// the resulting stopped→playing transition, so every start path is
  /// recorded exactly once.
  Future<void> _play() => _playback.play();

  /// Load and open another collection entry, keeping the reader in place.
  /// The score viewport is rebuilt under a fresh key so zoom and page state
  /// never leak between pieces.
  Future<void> _switchToPiece(String id, {required bool autoplay}) async {
    final queue = widget.queue;
    if (queue == null) return;
    _pendingAdvance = false;
    if (id == _currentId) {
      // Same piece (single-loop replay or restart): no load needed.
      await _playback.restart();
      if (autoplay) await _play();
      return;
    }
    if (_switching) return;
    final loader = widget.loadEntry;
    if (loader == null) return;
    setState(() => _switching = true);
    ScoreLibraryEntry? hydrated;
    try {
      hydrated = await loader(id);
    } on Object {
      hydrated = null;
    }
    if (!mounted) return;
    final entry = hydrated;
    final document = entry?.document;
    final isAudioEntry = entry?.isAudio == true;
    if (entry == null || (document == null && !isAudioEntry)) {
      setState(() => _switching = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(isAudioEntry ? '打开音频失败' : '打开谱面失败')),
        );
      return;
    }
    _playback.dispose();
    if (isAudioEntry) {
      _document = null;
      _audio = AudioItem.fromEntry(entry);
    } else {
      _document = document;
      _audio = null;
    }
    queue.setCurrentId(id);
    _playback = _createPlayback()..addListener(_onPlaybackChanged);
    _scoreViewportKey = GlobalKey<_MultiPageScoreViewportState>();
    _visiblePage = 0;
    _wasPlaying = false;
    setState(() => _switching = false);
    if (autoplay) {
      await _play();
    }
  }

  void _selectLoop(PlayLoop loop) {
    widget.queue?.setLoop(loop);
  }

  Future<void> _changePage(int page) async {
    final document = _document;
    if (document == null || document.pages.isEmpty) return;
    final next = page.clamp(0, document.pages.length - 1).toInt();
    _visiblePage = next;
    _scoreViewportKey.currentState?.focusPage(next, animate: !_reduceMotion);
    if (!mounted) return;
    setState(() {});
  }

  bool get _reduceMotion =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// Mirror MuseScore's PLAY-state mouse handling.  The native score view
  /// resolves the nearby note, promotes it to its parent chord, and seeks the
  /// unrolled sequencer tick.  PlaybackEvent.resolvedClickStartUs() carries
  /// that parent tick on the expanded timeline, so the Flutter equivalent can
  /// hand the target to the existing audio-aware seek path.
  void _onScorePageTap(int pageIndex, Offset pagePosition, double proximity) {
    // MuseScore only treats score clicks specially while ViewState::PLAY is
    // active.  Pausing/stopping returns the desktop view to NORMAL, so a
    // reader tap outside active playback must remain inert as well.
    final document = _document;
    if (document == null || !_playback.isPlaying || _switching) return;
    final target = document.playbackTimeAtPagePosition(
      pageIndex,
      pagePosition.dx,
      pagePosition.dy,
      proximity: proximity,
    );
    if (target == null) return;
    unawaited(_playback.seekToUs(target));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = _scorePlayback?.activeEventIndexes.toSet() ?? const <int>{};
    final queue = widget.queue;
    final document = _document;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: _switching ? null : () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back),
          tooltip: '返回谱面库',
        ),
        title: Text(
          _headerTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium,
        ),
        actions: [
          if (document != null)
            IconButton(
              onPressed: () => _scoreViewportKey.currentState?.resetView(),
              icon: const Icon(Icons.fit_screen_outlined),
              tooltip: '适应页面',
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(
                    color: theme.colorScheme.surfaceContainerHigh,
                    child: document != null
                        ? _MultiPageScoreViewport(
                            key: _scoreViewportKey,
                            document: document,
                            activeEventIndexes: active,
                            playbackCursor: _scorePlayback?.cursorPosition,
                            onPageTap: _onScorePageTap,
                            onPageChanged: (page) {
                              if (page != _visiblePage && mounted) {
                                setState(() => _visiblePage = page);
                              }
                            },
                          )
                        : _AudioPanel(
                            item: _audio!,
                            useInternalTitles: widget.useInternalTitles,
                            error: _playback is AudioPlaybackController
                                ? (_playback as AudioPlaybackController).error
                                : null,
                          ),
                  ),
                ),
                if (_switching)
                  Positioned.fill(
                    child: ColoredBox(
                      color: theme.colorScheme.surfaceContainerHigh.withValues(
                        alpha: 0.72,
                      ),
                      child: Center(
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 16,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Text(
                                  document != null ? '正在载入谱面…' : '正在载入音频…',
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (queue != null) ...[
            _PieceSwitcherBar(
              queue: queue,
              enabled: !_switching,
              onPrevious: _goToPreviousPiece,
              onNext: _goToNextPiece,
              onSelectLoop: _selectLoop,
            ),
          ],
          if (queue != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
              child: Center(
                child: MuseToggleButton(
                  label: '熄屏不打断下一首',
                  value: _advanceWhenScreenOff,
                  onChanged: _setAdvanceWhenScreenOff,
                  dense: true,
                ),
              ),
            ),
          _TransportBar(
            playback: _playback,
            page: _visiblePage,
            pageCount: document?.pages.length,
            onPageChanged: _changePage,
            onPlayPause: _onPlayPausePressed,
          ),
        ],
      ),
    );
  }
}

/// A continuous score canvas.  MuseScore's desktop view keeps the laid-out
/// pages in one canvas (and offers a two-page zoom preset); doing the same in
/// Flutter means that the reader opens on a multi-page view instead of a
/// single-page carousel.  The one [InteractiveViewer] around the whole canvas
/// is also important: a two-finger gesture can cross the gap between pages and
/// still scales the score as one document.
class _MultiPageScoreViewport extends StatefulWidget {
  const _MultiPageScoreViewport({
    super.key,
    required this.document,
    required this.activeEventIndexes,
    required this.playbackCursor,
    required this.onPageTap,
    required this.onPageChanged,
  });

  final ScoreDocument document;
  final Set<int> activeEventIndexes;
  final ScoreCursorPosition? playbackCursor;
  final void Function(int pageIndex, Offset pagePosition, double proximity)
  onPageTap;
  final ValueChanged<int> onPageChanged;

  @override
  State<_MultiPageScoreViewport> createState() =>
      _MultiPageScoreViewportState();
}

class _MultiPageScoreViewportState extends State<_MultiPageScoreViewport>
    with SingleTickerProviderStateMixin {
  static const _pageHorizontalInset = 14.0;
  static const _pageVerticalInset = 18.0;
  static const _minScale = 0.8;
  static const _maxScale = 4.0;
  static const _boundaryMargin = EdgeInsets.all(80);

  late final TransformationController _transformationController;
  late final AnimationController _animationController;
  late final CurvedAnimation _easeAnimation;
  Animation<Matrix4>? _transformAnimation;

  List<double> _pageTops = const [];
  double _canvasWidth = 0;
  double _canvasHeight = 0;
  Size _viewportSize = Size.zero;
  int? _pendingPage;
  ScoreCursorPosition? _pendingCursor;
  int _lastReportedPage = 0;
  int? _lastFollowPage;

  @override
  void initState() {
    super.initState();
    _transformationController = TransformationController()
      ..addListener(_onTransformationChanged);
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(_applyTransformAnimation);
    _easeAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _easeAnimation.dispose();
    _animationController.dispose();
    _transformationController
      ..removeListener(_onTransformationChanged)
      ..dispose();
    super.dispose();
  }

  /// Move a page near the top of the viewport while preserving the current
  /// zoom level.  Calls made before the first layout are replayed once page
  /// geometry is known.
  void focusPage(int page, {bool animate = true}) {
    if (_pageTops.isEmpty || _viewportSize == Size.zero) {
      _pendingPage = page;
      return;
    }
    final safePage = page.clamp(0, _pageTops.length - 1).toInt();
    final matrix = _transformationController.value;
    final scale = matrix.getMaxScaleOnAxis().clamp(_minScale, _maxScale);
    final translation = matrix.getTranslation();
    final targetY = _clampTranslationY(
      -_pageTops[safePage] * scale + _pageVerticalInset,
      scale,
    );
    final target = matrix.clone()
      ..setTranslationRaw(translation.x, targetY, translation.z);
    if (animate) {
      _animateTo(target);
    } else {
      _animationController.stop();
      _transformationController.value = target;
    }
    _reportPage(safePage);
    _lastFollowPage = null;
  }

  /// Keep the playback cursor in a comfortable reading position.  MuseScore
  /// uses a smooth horizontal control cursor at roughly 30% of the viewport;
  /// in this vertical page canvas we apply the same anchor to both axes and
  /// only move when the cursor leaves a safety band.  This avoids restarting
  /// an animation on every 16ms playback heartbeat.
  void followCursor(ScoreCursorPosition cursor, {bool animate = true}) {
    if (_pageTops.isEmpty || _viewportSize == Size.zero) {
      _pendingCursor = cursor;
      return;
    }
    if (cursor.pageIndex < 0 ||
        cursor.pageIndex >= widget.document.pages.length) {
      return;
    }
    final sceneRect = _sceneRectForCursor(cursor);
    final matrix = _transformationController.value;
    final scale = matrix.getMaxScaleOnAxis();
    if (scale <= 0) return;
    final screenRect = MatrixUtils.transformRect(matrix, sceneRect);
    final pageChanged = _lastFollowPage != cursor.pageIndex;
    final horizontalMargin = _viewportSize.width * 0.08;
    final verticalMargin = _viewportSize.height * 0.14;
    final safeRect = Rect.fromLTRB(
      horizontalMargin,
      verticalMargin,
      math.max(horizontalMargin, _viewportSize.width - horizontalMargin),
      math.max(verticalMargin, _viewportSize.height - verticalMargin),
    );
    if (!pageChanged && safeRect.contains(screenRect.center)) return;
    if (!pageChanged && _animationController.isAnimating) return;

    final targetX = _clampTranslationX(
      _viewportSize.width * 0.30 - sceneRect.center.dx * scale,
      scale,
    );
    final targetY = _clampTranslationY(
      _viewportSize.height * 0.35 - sceneRect.center.dy * scale,
      scale,
    );
    final translation = matrix.getTranslation();
    final target = matrix.clone()
      ..setTranslationRaw(targetX, targetY, translation.z);
    if (animate) {
      _animateTo(target);
    } else {
      _animationController.stop();
      _transformationController.value = target;
    }
    _lastFollowPage = cursor.pageIndex;
    _reportPage(cursor.pageIndex);
  }

  /// Restore the default fit-width view.  The canvas width is the viewport
  /// width, so the identity matrix is the same as the MuseScore page-width
  /// preset for the mobile reader.
  void resetView() {
    _animationController.stop();
    _transformationController.value = Matrix4.identity();
    _lastFollowPage = null;
    _reportPage(0);
  }

  void _animateTo(Matrix4 target) {
    _animationController.stop();
    _transformAnimation = Matrix4Tween(
      begin: _transformationController.value.clone(),
      end: target,
    ).animate(_easeAnimation);
    _animationController
      ..reset()
      ..forward();
  }

  void _applyTransformAnimation() {
    final animation = _transformAnimation;
    if (animation != null && mounted) {
      _transformationController.value = animation.value;
    }
  }

  void _onInteractionStart(ScaleStartDetails _) {
    _animationController.stop();
    _lastFollowPage = null;
  }

  void _onInteractionUpdate(ScaleUpdateDetails _) {
    // InteractiveViewer applies the scale around the gesture focal point
    // before this callback, matching MuseScore's pinch implementation.
    _reportPage(_pageForCurrentViewport());
  }

  void _onTransformationChanged() {
    // This listener also covers programmatic page jumps and resetView().
    _reportPage(_pageForCurrentViewport());
  }

  int _pageForCurrentViewport() {
    if (_pageTops.isEmpty) return 0;
    final matrix = _transformationController.value;
    final scale = matrix.getMaxScaleOnAxis();
    if (scale <= 0) return _lastReportedPage;
    final translationY = matrix.getTranslation().y;
    final sceneTop = (-translationY / scale).clamp(0.0, _canvasHeight);
    // Use a point a little below the top edge so a page remains selected while
    // its bottom margin is crossing the viewport.
    final probe = sceneTop + (_viewportSize.height / scale) * 0.18;
    var page = 0;
    for (var index = 1; index < _pageTops.length; index++) {
      if (_pageTops[index] > probe) break;
      page = index;
    }
    return page;
  }

  Rect _sceneRectForCursor(ScoreCursorPosition cursor) {
    final pageIndex = cursor.pageIndex
        .clamp(0, math.max(0, widget.document.pages.length - 1))
        .toInt();
    final page = widget.document.pages[pageIndex];
    final pageWidth = math.max(1.0, _canvasWidth - _pageHorizontalInset * 2);
    final safePageWidth = page.width <= 0 ? 1.0 : page.width;
    final scaleX = pageWidth / safePageWidth;
    final scaleY = page.height <= 0 ? scaleX : pageWidth / safePageWidth;
    final pageTop = _pageTops[pageIndex];
    final rect = cursor.rect;
    return Rect.fromLTWH(
      _pageHorizontalInset + rect.left * scaleX,
      pageTop + rect.top * scaleY,
      rect.width * scaleX,
      rect.height * scaleY,
    );
  }

  void _reportPage(int page) {
    if (page == _lastReportedPage) return;
    _lastReportedPage = page;
    widget.onPageChanged(page);
  }

  double _clampTranslationY(double translationY, double scale) {
    final scaledHeight = _canvasHeight * scale;
    final minTranslation =
        _viewportSize.height - scaledHeight - _boundaryMargin.bottom;
    final maxTranslation = _boundaryMargin.top;
    // A very short synthetic/test page can be smaller than the viewport. In
    // that case the two bounds overlap in reverse order; keep it centered
    // instead of passing an invalid range to num.clamp().
    if (minTranslation > maxTranslation) {
      return (minTranslation + maxTranslation) / 2;
    }
    return translationY.clamp(minTranslation, maxTranslation).toDouble();
  }

  double _clampTranslationX(double translationX, double scale) {
    final scaledWidth = _canvasWidth * scale;
    final minTranslation =
        _viewportSize.width - scaledWidth - _boundaryMargin.right;
    final maxTranslation = _boundaryMargin.left;
    if (minTranslation > maxTranslation) {
      return (minTranslation + maxTranslation) / 2;
    }
    return translationX.clamp(minTranslation, maxTranslation).toDouble();
  }

  ({List<double> tops, double height}) _layoutMetrics(double width) {
    final pageWidth = math.max(1.0, width - _pageHorizontalInset * 2);
    final tops = <double>[];
    var top = 0.0;
    for (var index = 0; index < widget.document.pages.length; index++) {
      final page = widget.document.pages[index];
      final safePageWidth = page.width <= 0 ? 1.0 : page.width;
      final pageHeight = pageWidth * page.height / safePageWidth;
      tops.add(top + _pageVerticalInset);
      top += pageHeight + _pageVerticalInset * 2;
    }
    return (tops: tops, height: math.max(top, 1.0));
  }

  void _updateLayoutMetrics(
    BoxConstraints constraints,
    List<double> pageTops,
    double canvasHeight,
  ) {
    final nextViewport = Size(constraints.maxWidth, constraints.maxHeight);
    final changed =
        _canvasWidth != constraints.maxWidth ||
        _canvasHeight != canvasHeight ||
        _viewportSize != nextViewport ||
        _pageTops.length != pageTops.length;
    _canvasWidth = constraints.maxWidth;
    _canvasHeight = canvasHeight;
    _viewportSize = nextViewport;
    _pageTops = pageTops;
    if (changed && _pendingPage != null) {
      final page = _pendingPage;
      _pendingPage = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && page != null) focusPage(page, animate: false);
      });
    }
    if (changed && _pendingCursor != null) {
      final cursor = _pendingCursor;
      _pendingCursor = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && cursor != null) {
          followCursor(cursor, animate: false);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final metrics = _layoutMetrics(constraints.maxWidth);
        _updateLayoutMetrics(constraints, metrics.tops, metrics.height);
        final pageWidth = math.max(
          1.0,
          constraints.maxWidth - _pageHorizontalInset * 2,
        );
        final pages = <Widget>[
          for (var index = 0; index < widget.document.pages.length; index++)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: _pageHorizontalInset,
                vertical: _pageVerticalInset,
              ),
              child: _PageViewport(
                page: widget.document.pages[index],
                pageNumber: index,
                width: pageWidth,
                activeEventIndexes: widget.activeEventIndexes,
                playbackCursor: widget.playbackCursor?.pageIndex == index
                    ? widget.playbackCursor!.rect
                    : null,
                activePageRects: _activePageRects(index),
                activeNotes: _activeNotes(index),
                onTap: (position, proximity) => widget.onPageTap(
                  index,
                  position,
                  proximity / _currentTransformScale,
                ),
              ),
            ),
        ];
        final canvas = SizedBox(
          width: constraints.maxWidth,
          height: metrics.height,
          child: Column(mainAxisSize: MainAxisSize.min, children: pages),
        );
        return Semantics(
          container: true,
          label: '多页谱面视图，双指缩放',
          child: InteractiveViewer(
            key: const ValueKey('multi-page-score-interactive-viewer'),
            constrained: false,
            alignment: Alignment.topLeft,
            minScale: _minScale,
            maxScale: _maxScale,
            panEnabled: true,
            scaleEnabled: true,
            boundaryMargin: _boundaryMargin,
            clipBehavior: Clip.hardEdge,
            transformationController: _transformationController,
            onInteractionStart: _onInteractionStart,
            onInteractionUpdate: _onInteractionUpdate,
            child: canvas,
          ),
        );
      },
    );
  }

  List<ScoreRect> _activePageRects(int pageIndex) {
    final rects = <ScoreRect>[];
    for (final eventIndex in widget.activeEventIndexes) {
      if (eventIndex < 0 || eventIndex >= widget.document.events.length) {
        continue;
      }
      final event = widget.document.events[eventIndex];
      for (final highlight in event.highlights) {
        if (_pageIndexMatches(highlight.pageIndex, pageIndex)) {
          _addUniqueRect(rects, highlight.rect);
        }
      }
      if (!_eventBelongsToPage(event, pageIndex)) continue;
      final rect = _usableNoteRect(event);
      if (rect != null) _addUniqueRect(rects, rect);
    }
    return rects;
  }

  void _addUniqueRect(List<ScoreRect> rects, ScoreRect candidate) {
    final duplicate = rects.any(
      (rect) =>
          rect.left == candidate.left &&
          rect.top == candidate.top &&
          rect.width == candidate.width &&
          rect.height == candidate.height,
    );
    if (!duplicate) rects.add(candidate);
  }

  List<PlaybackEvent> _activeNotes(int pageIndex) {
    final notes = <PlaybackEvent>[];
    for (final eventIndex in widget.activeEventIndexes) {
      if (eventIndex < 0 || eventIndex >= widget.document.events.length) {
        continue;
      }
      final event = widget.document.events[eventIndex];
      if (!_eventBelongsToPage(event, pageIndex)) continue;
      if (_usableNoteRect(event) != null) notes.add(event);
    }
    return notes;
  }

  /// Tap details are delivered in the page's scene coordinates (the inverse
  /// of InteractiveViewer's transform). MuseScore's selection proximity is
  /// specified in physical screen pixels, so divide the base page-space
  /// tolerance by the current zoom before handing it to the document hit
  /// tester.
  double get _currentTransformScale {
    final scale = _transformationController.value.getMaxScaleOnAxis();
    return scale.isFinite && scale > 0 ? scale : 1.0;
  }

  bool _eventBelongsToPage(PlaybackEvent event, int pagePosition) {
    return _pageIndexMatches(event.pageIndex, pagePosition);
  }

  bool _pageIndexMatches(int? sourcePage, int pagePosition) {
    if (sourcePage == null) return pagePosition == 0;
    if (sourcePage == pagePosition) return true;
    if (pagePosition < 0 || pagePosition >= widget.document.pages.length) {
      return false;
    }
    return sourcePage == widget.document.pages[pagePosition].index;
  }
}

class _PageViewport extends StatelessWidget {
  const _PageViewport({
    required this.page,
    required this.pageNumber,
    required this.width,
    required this.activeEventIndexes,
    required this.playbackCursor,
    required this.activePageRects,
    required this.activeNotes,
    required this.onTap,
  });

  final ScorePage page;
  final int pageNumber;
  final double width;
  final Set<int> activeEventIndexes;
  final ScoreRect? playbackCursor;
  final List<ScoreRect> activePageRects;
  final List<PlaybackEvent> activeNotes;
  final void Function(Offset position, double proximity)? onTap;

  @override
  Widget build(BuildContext context) {
    final safePageWidth = page.width <= 0 ? 1.0 : page.width;
    final height = math.max(1.0, width * page.height / safePageWidth);
    final content = page.imageBytes != null
        ? _NativePageStack(
            page: page,
            width: width,
            height: height,
            activePageRects: activePageRects,
            activeNotes: activeNotes,
            playbackCursor: playbackCursor,
          )
        : CustomPaint(
            size: Size(width, height),
            painter: ScorePagePainter(
              page: page,
              activeEventIndexes: activeEventIndexes,
              inkColor: museScoreInkColor,
              accentColor: museScorePlaybackColor,
              playbackCursor: playbackCursor,
            ),
          );
    final safePageHeight = page.height <= 0 ? 1.0 : page.height;
    return Semantics(
      container: true,
      label: '第 ${pageNumber + 1} 页',
      hint: '播放时点击音符可跳转',
      child: GestureDetector(
        key: ValueKey<String>('score-page-$pageNumber'),
        behavior: HitTestBehavior.opaque,
        onTapUp: onTap == null
            ? null
            : (details) {
                final local = details.localPosition;
                onTap!(
                  Offset(
                    local.dx * safePageWidth / width,
                    local.dy * safePageHeight / height,
                  ),
                  // MuseScore's default selection proximity is six screen
                  // pixels.  Convert it to the page coordinate space before
                  // hit-testing so A4 native pages (which are much wider
                  // than the Flutter viewport) remain equally forgiving.
                  6.0 * safePageWidth / width,
                );
              },
        child: Material(
          elevation: 3,
          color: museScorePaperColor,
          child: SizedBox(width: width, height: height, child: content),
        ),
      ),
    );
  }
}

class _NativePageStack extends StatelessWidget {
  const _NativePageStack({
    required this.page,
    required this.width,
    required this.height,
    required this.activePageRects,
    required this.activeNotes,
    required this.playbackCursor,
  });

  final ScorePage page;
  final double width;
  final double height;
  final List<ScoreRect> activePageRects;
  final List<PlaybackEvent> activeNotes;
  final ScoreRect? playbackCursor;

  @override
  Widget build(BuildContext context) {
    final safePageWidth = page.width <= 0 ? 1.0 : page.width;
    final safePageHeight = page.height <= 0 ? 1.0 : page.height;
    final scaleX = width / safePageWidth;
    final scaleY = height / safePageHeight;
    final pageRect = Rect.fromLTWH(0, 0, width, height);
    final recoloredRects = <Rect>[];
    final fallbackNotes = <PlaybackEvent>[];
    final fallbackRects = <ScoreRect>[];
    bool addRecoloredRect(ScoreRect? sourceRect) {
      final scaled = sourceRect == null
          ? null
          : Rect.fromLTWH(
              sourceRect.left * scaleX,
              sourceRect.top * scaleY,
              sourceRect.width * scaleX,
              sourceRect.height * scaleY,
            );
      final clipped = scaled == null || !scaled.isFinite
          ? null
          : scaled.intersect(pageRect);
      if (clipped != null &&
          clipped.isFinite &&
          clipped.width > 0 &&
          clipped.height > 0) {
        if (!recoloredRects.contains(clipped)) recoloredRects.add(clipped);
        return true;
      }
      return false;
    }

    // Repaint the existing page pixels inside every native highlight region.
    // A tied playback event contributes all noteheads plus narrow regions that
    // trace each tie segment, including segments on another system or page.
    for (final rect in activePageRects) {
      addRecoloredRect(rect);
    }
    for (final note in activeNotes) {
      // Legacy payloads only expose a single note rectangle. Keep their
      // geometric painter as a last-resort compatibility path when that
      // rectangle cannot be filtered in place.
      if (!addRecoloredRect(_usableNoteRect(note))) {
        // Keep the geometric painter as a last-resort compatibility path for
        // old/partial native payloads that do not contain usable geometry.
        fallbackNotes.add(note);
        final rect = _usableNoteRect(note);
        if (rect != null &&
            rect.isFinite &&
            rect.width > 0 &&
            rect.height > 0) {
          fallbackRects.add(rect);
        }
      }
    }

    final recoloredPage = recoloredRects.isEmpty
        ? null
        : Positioned.fill(
            child: IgnorePointer(
              child: ClipPath(
                clipBehavior: Clip.hardEdge,
                clipper: _NoteRectsClipper(recoloredRects),
                child: ColorFiltered(
                  // Paint the same rasterized page through a color filter only
                  // inside the note clips.  This keeps the original page
                  // pixels underneath the antialiased edge without drawing a
                  // second notehead shape.
                  colorFilter: _playbackNoteColorFilter,
                  child: Image.memory(
                    page.imageBytes!,
                    width: width,
                    height: height,
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.high,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
          );

    return Stack(
      clipBehavior: Clip.hardEdge,
      children: [
        Image.memory(
          page.imageBytes!,
          width: width,
          height: height,
          fit: BoxFit.fill,
          filterQuality: FilterQuality.high,
          gaplessPlayback: true,
        ),
        ?recoloredPage,
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _PlaybackOverlayPainter(
                pageWidth: page.width,
                pageHeight: page.height,
                rects: fallbackRects,
                notes: fallbackNotes,
                cursor: playbackCursor,
                color: museScorePlaybackColor,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

ScoreRect? _usableNoteRect(PlaybackEvent note) {
  final pageRect = note.pageRect;
  if (pageRect != null &&
      pageRect.isFinite &&
      pageRect.width > 0 &&
      pageRect.height > 0) {
    return pageRect;
  }
  final legacyRect = note.noteheadRect;
  if (legacyRect != null &&
      legacyRect.isFinite &&
      legacyRect.width > 0 &&
      legacyRect.height > 0) {
    return legacyRect;
  }
  return null;
}

/// MuseScore's page image is opaque, so this matrix can replace the grayscale
/// ink under an active note with the playback blue while preserving the
/// antialiased edge between ink and paper.  For a grayscale source value
/// [luma], the result is `white * luma + playbackBlue * (1 - luma)`.
const _playbackNoteColorFilter = ColorFilter.matrix(<double>[
  0.299,
  0.587,
  0.114,
  0,
  0,
  0.180572549,
  0.354501961,
  0.068847059,
  0,
  101,
  0.075043137,
  0.14732549,
  0.028611765,
  0,
  191,
  0,
  0,
  0,
  1,
  0,
]);

/// Clips the filtered page copy to the union of all currently active notehead
/// and tie regions. Keeping this as one clip/filter pair avoids creating a
/// widget and a separate composited layer for every small region.
class _NoteRectsClipper extends CustomClipper<Path> {
  const _NoteRectsClipper(this.rects);

  final List<Rect> rects;

  @override
  Path getClip(Size size) {
    final path = Path();
    for (final rect in rects) {
      if (rect.isFinite && !rect.isEmpty) path.addRect(rect);
    }
    return path;
  }

  @override
  bool shouldReclip(covariant _NoteRectsClipper oldClipper) {
    if (identical(rects, oldClipper.rects)) return false;
    if (rects.length != oldClipper.rects.length) return true;
    for (var index = 0; index < rects.length; index++) {
      if (rects[index] != oldClipper.rects[index]) return true;
    }
    return false;
  }
}

class _PlaybackOverlayPainter extends CustomPainter {
  const _PlaybackOverlayPainter({
    required this.pageWidth,
    required this.pageHeight,
    required this.rects,
    this.notes = const [],
    this.cursor,
    required this.color,
  });

  final double pageWidth;
  final double pageHeight;
  final List<ScoreRect> rects;
  final List<PlaybackEvent> notes;
  final ScoreRect? cursor;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (pageWidth <= 0 || pageHeight <= 0) return;
    final scaleX = size.width / pageWidth;
    final scaleY = size.height / pageHeight;
    final pageRect = Rect.fromLTWH(0, 0, size.width, size.height);

    // MuseScore marks every sounding note with the voice colour before it
    // paints the translucent position cursor.  Native pages with usable
    // rectangles are recoloured by _NativePageStack; this painter is only the
    // geometric compatibility path for older/partial payloads.
    for (final note in notes) {
      final noteRect = _usableNoteRect(note);
      if (noteRect == null || !noteRect.isFinite) continue;
      _drawMarkedNote(
        canvas,
        Rect.fromLTWH(
          noteRect.left * scaleX,
          noteRect.top * scaleY,
          noteRect.width * scaleX,
          noteRect.height * scaleY,
        ),
        filled: note.noteheadFilled,
      );
    }
    // Keep compatibility with callers that only have rectangles (documents
    // produced by an older bridge).  _NativePageStack passes only geometry
    // that could not be handled by the in-place filter, so this branch cannot
    // paint a second mark for notes that were recoloured above.
    if (notes.isEmpty) {
      final mark = Paint()..color = color;
      for (final rect in rects) {
        final scaled = Rect.fromLTWH(
          rect.left * scaleX,
          rect.top * scaleY,
          rect.width * scaleX,
          rect.height * scaleY,
        );
        canvas.drawOval(scaled, mark);
      }
    }

    final cursorRect = cursor;
    if (cursorRect == null || !cursorRect.isFinite) return;
    final scaledCursor = Rect.fromLTWH(
      cursorRect.left * scaleX,
      cursorRect.top * scaleY,
      cursorRect.width * scaleX,
      cursorRect.height * scaleY,
    ).intersect(pageRect);
    if (scaledCursor.isEmpty) return;
    final cursorPaint = Paint()
      ..color = color.withValues(alpha: 50 / 255.0)
      ..style = PaintingStyle.fill;
    canvas.drawRect(scaledCursor, cursorPaint);
  }

  void _drawMarkedNote(Canvas canvas, Rect rect, {required bool filled}) {
    if (rect.isEmpty) return;
    final headPaint = Paint()
      ..color = color
      ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
      // Keep the outline light enough that the existing white interior of a
      // hollow head remains visible at normal page scale.
      ..strokeWidth = math.max(1.0, math.min(rect.width, rect.height) * 0.16);
    canvas.save();
    canvas.translate(rect.center.dx, rect.center.dy);
    canvas.rotate(-0.22);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: rect.width,
        height: rect.height,
      ),
      headPaint,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _PlaybackOverlayPainter oldDelegate) =>
      oldDelegate.rects != rects ||
      oldDelegate.notes != notes ||
      oldDelegate.cursor != cursor ||
      oldDelegate.pageWidth != pageWidth ||
      oldDelegate.pageHeight != pageHeight ||
      oldDelegate.color != color;
}

/// The previous-piece / next-piece / loop-mode row shown above the transport
/// bar while the reader runs inside a collection (a [ReaderQueue] exists).
/// Only these three items live here; the hidden golden-ratio memory list is
/// deliberately never displayed.
class _PieceSwitcherBar extends StatelessWidget {
  const _PieceSwitcherBar({
    required this.queue,
    required this.enabled,
    required this.onPrevious,
    required this.onNext,
    required this.onSelectLoop,
  });

  final ReaderQueue queue;
  final bool enabled;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<PlayLoop> onSelectLoop;

  static IconData _loopIcon(PlayLoop loop) => switch (loop) {
    PlayLoop.randomMemory => Icons.shuffle_rounded,
    PlayLoop.sequential => Icons.repeat_rounded,
    PlayLoop.single => Icons.repeat_one_rounded,
    PlayLoop.none => Icons.stop_circle_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasMultiple = queue.hasMultiple;
    final loop = queue.loop;
    final canSwitch = enabled && hasMultiple;
    final loopOptions = hasMultiple
        ? PlayLoop.values
        : const <PlayLoop>[PlayLoop.single];
    final switchButtons = [
      IconButton(
        onPressed: canSwitch ? onPrevious : null,
        icon: const Icon(Icons.skip_previous_rounded),
        color: theme.colorScheme.onSurfaceVariant,
        tooltip: '上一首',
      ),
      const SizedBox(width: 4),
      IconButton(
        onPressed: canSwitch ? onNext : null,
        icon: const Icon(Icons.skip_next_rounded),
        color: theme.colorScheme.onSurfaceVariant,
        tooltip: '下一首',
      ),
    ];
    final loopButton = PopupMenuButton<PlayLoop>(
      onSelected: enabled ? onSelectLoop : null,
      tooltip: '循环模式',
      itemBuilder: (context) => [
        for (final option in loopOptions)
          CheckedPopupMenuItem<PlayLoop>(
            value: option,
            checked: option == loop,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_loopIcon(option), size: 18),
                const SizedBox(width: 10),
                Text(option.label),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _loopIcon(loop),
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              queue.effectiveLoop.label,
              maxLines: 1,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.arrow_drop_down_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
    return Material(
      color: theme.colorScheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ...switchButtons,
                const SizedBox(width: 6),
                loopButton,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder shown while an audio file plays: there is no engraving to
/// display, so the panel names the item and the bottom transport does the work.
class _AudioPanel extends StatelessWidget {
  const _AudioPanel({
    required this.item,
    required this.useInternalTitles,
    this.error,
  });

  final AudioItem item;
  final bool useInternalTitles;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final author = item.displayAuthor(useInternalTitles: useInternalTitles);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.audiotrack_rounded,
              size: 64,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 18),
            Text(
              item.displayTitle(useInternalTitles: useInternalTitles),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge,
            ),
            if (author.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                author,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 18),
            Text(
              error ?? '音频文件（无谱面）',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: error == null
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.error,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransportBar extends StatelessWidget {
  const _TransportBar({
    required this.playback,
    required this.page,
    required this.pageCount,
    required this.onPageChanged,
    required this.onPlayPause,
  });

  final PlaybackHandle playback;
  final int page; // only used by the score page navigator
  final int? pageCount; // null for audio items: no page navigator
  final Future<void> Function(int page) onPageChanged;
  final Future<void> Function() onPlayPause;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
            child: AnimatedBuilder(
              animation: playback,
              builder: (context, _) {
                final progress = playback.progress.clamp(0.0, 1.0).toDouble();
                final currentTime = formatScoreDuration(playback.positionUs);
                final totalTime = formatScoreDuration(playback.durationUs);
                final timeline = Slider(
                  value: progress,
                  onChanged: playback.durationUs == 0
                      ? null
                      : (value) => playback.seekToUs(
                          (value * playback.durationUs).round(),
                        ),
                  semanticFormatterCallback: (value) =>
                      '${formatScoreDuration((value * playback.durationUs).round())}，共 $totalTime',
                );
                final playbackTime = Semantics(
                  label: '已播放 $currentTime，共 $totalTime',
                  child: ExcludeSemantics(
                    child: Text(
                      '$currentTime/$totalTime',
                      maxLines: 1,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                );
                final restartButton = IconButton(
                  onPressed: playback.restart,
                  icon: const Icon(Icons.restart_alt_rounded),
                  color: theme.colorScheme.onSurfaceVariant,
                  tooltip: '从头开始',
                );
                final playButton = Semantics(
                  toggled: playback.isPlaying,
                  child: IconButton.filled(
                    onPressed: onPlayPause,
                    icon: Icon(
                      playback.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 28,
                    ),
                    tooltip: playback.isPlaying ? '暂停' : '播放',
                    style: IconButton.styleFrom(
                      minimumSize: const Size.square(56),
                      maximumSize: const Size.square(56),
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: theme.colorScheme.onPrimary,
                    ),
                  ),
                );
                final pageControls = pageCount == null
                    ? null
                    : _PageNavigator(
                        page: page,
                        pageCount: pageCount!,
                        onPageChanged: onPageChanged,
                      );
                return LayoutBuilder(
                  builder: (context, constraints) {
                    final textScale =
                        MediaQuery.textScalerOf(context).scale(14) / 14;
                    final wide =
                        constraints.maxWidth >= 700 && textScale <= 1.4;
                    if (wide) {
                      return Row(
                        children: [
                          restartButton,
                          const SizedBox(width: 8),
                          playButton,
                          const SizedBox(width: 16),
                          playbackTime,
                          const SizedBox(width: 8),
                          Expanded(child: timeline),
                          if (pageControls != null) ...[
                            const SizedBox(width: 16),
                            pageControls,
                          ],
                        ],
                      );
                    }

                    final narrow =
                        constraints.maxWidth < 300 || textScale > 1.8;
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Expanded(child: timeline),
                            const SizedBox(width: 8),
                            playbackTime,
                          ],
                        ),
                        const SizedBox(height: 2),
                        if (narrow) ...[
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              restartButton,
                              const SizedBox(width: 8),
                              playButton,
                            ],
                          ),
                          if (pageControls != null) ...[
                            const SizedBox(height: 4),
                            pageControls,
                          ],
                        ] else
                          Row(
                            children: [
                              restartButton,
                              const SizedBox(width: 8),
                              playButton,
                              if (pageControls != null) ...[
                                const Spacer(),
                                pageControls,
                              ],
                            ],
                          ),
                      ],
                    );
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _PageNavigator extends StatelessWidget {
  const _PageNavigator({
    required this.page,
    required this.pageCount,
    required this.onPageChanged,
  });

  final int page;
  final int pageCount;
  final Future<void> Function(int page) onPageChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final safePageCount = math.max(1, pageCount);
    final safePage = page.clamp(0, safePageCount - 1).toInt();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: safePage > 0 ? () => onPageChanged(safePage - 1) : null,
            icon: const Icon(Icons.chevron_left_rounded),
            tooltip: '上一页',
          ),
          Semantics(
            label: '第 ${safePage + 1} 页，共 $safePageCount 页',
            child: ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  '${safePage + 1}/$safePageCount',
                  maxLines: 1,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: safePage + 1 < pageCount
                ? () => onPageChanged(safePage + 1)
                : null,
            icon: const Icon(Icons.chevron_right_rounded),
            tooltip: '下一页',
          ),
        ],
      ),
    );
  }
}
