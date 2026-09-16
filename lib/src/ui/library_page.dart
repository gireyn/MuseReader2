import 'package:flutter/material.dart';

import '../model/score_document.dart';
import '../model/score_library_entry.dart';
import '../playback/playback_controller.dart';
import '../playback/score_queue.dart';
import '../services/file_picker_service.dart';
import '../services/media_commands.dart';
import '../services/score_library_cache.dart';
import '../services/score_repository.dart';
import 'folder_picker_page.dart';
import 'reader_page.dart';
import 'score_page_painter.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, this.repository, this.libraryCache});

  /// Optional injection points for tests: the default implementations read
  /// real files through the native engine.
  final ScoreRepository? repository;
  final ScoreLibraryCache? libraryCache;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late final _repository = widget.repository ?? ScoreRepository();
  final _picker = FilePickerService();
  late final _libraryCache = widget.libraryCache ?? ScoreLibraryCache();
  final _entries = <ScoreLibraryEntry>[];
  final _openingPaths = <String>{};

  /// In-memory retention budget for fully opened score documents.
  ///
  /// Every hydrated [ScoreDocument] keeps all rendered page images and the
  /// playback event list, so playing through a large collection must not
  /// accumulate one document per piece. Only the [\_maxRetainedDocuments]
  /// most recently used non-bundled documents stay loaded; older ones are
  /// demoted back to metadata-only entries (cover + sidecar metadata) and
  /// reopen cheaply from the gzipped document sidecar written by
  /// [MuseScoreBridge] (no second native render).
  static const _maxRetainedDocuments = 5;

  /// Source paths of hydrated documents, most recently used first. Mirrors
  /// the collection so eviction never touches an entry outside this list.
  final _retentionOrder = <String>[];
  ReaderQueue? _queue;
  bool _loading = true;
  String? _error;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    MediaCommands.attach();
    MediaCommands.onMemoryPressure = _handleMemoryPressure;
    _loadLibrary();
  }

  @override
  void dispose() {
    if (MediaCommands.onMemoryPressure == _handleMemoryPressure) {
      MediaCommands.onMemoryPressure = null;
    }
    MediaCommands.detach();
    _queue?.dispose();
    super.dispose();
  }

  /// Android reports memory pressure through `Activity.onTrimMemory`.
  /// Decoded page images are dropped first; from RUNNING_LOW on, every
  /// hydrated document beyond the one on screen is released as well (they
  /// reload cheaply from the gzipped document sidecar).
  void _handleMemoryPressure(int level) {
    if (!mounted) return;
    PaintingBinding.instance.imageCache.clear();
    if (level < 10) return;
    setState(() {
      for (var index = 0; index < _entries.length; index++) {
        final entry = _entries[index];
        if (entry.document != null && !entry.isBundled) {
          _entries[index] = _demotedCopy(entry);
        }
      }
      _retentionOrder.clear();
    });
  }

  Future<void> _loadLibrary() async {
    final generation = ++_loadGeneration;
    String? firstError;

    var importedPaths = const <String>[];
    try {
      importedPaths = await _picker.listImportedScoreFiles();
    } catch (error) {
      firstError = '无法读取已保存谱面：$error';
    }
    final seenPaths = <String>{};
    final uniquePaths = importedPaths
        .where(seenPaths.add)
        .toList(growable: false);
    final placeholders = [
      for (final path in uniquePaths) ScoreLibraryEntry.placeholder(path),
      // The bundled demo is only a stand-in for an empty collection: once the
      // device owns imported scores it must not rejoin the playlist on every
      // app launch.
      if (uniquePaths.isEmpty) ScoreLibraryEntry.bundledDemo(),
    ];
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _entries
        ..clear()
        ..addAll(placeholders);
      _retentionOrder.clear();
      _loading = false;
      _error = firstError;
    });
    _syncQueue();

    // Metadata and thumbnail sidecars are small and can hydrate after the
    // first usable library frame. Full MuseScore documents are loaded only
    // when the user opens a score.
    final cachedEntries = await Future.wait(
      uniquePaths.map(_libraryCache.readOrPlaceholder),
    );
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      for (final cached in cachedEntries) {
        final index = _entries.indexWhere(
          (entry) => entry.sourcePath == cached.sourcePath,
        );
        if (index >= 0 && _entries[index].document == null) {
          _entries[index] = cached;
        }
      }
    });
  }

  Future<void> _reloadLibrary() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    await _loadLibrary();
  }

  /// (Re)create the play queue so it mirrors the collection shown by the
  /// library. A fresh queue means a fresh golden-ratio memory: imports and
  /// library reloads start a new session, exactly like reopening a folder in
  /// the reference player.
  void _syncQueue() {
    final ids = [for (final entry in _entries) entry.sourcePath];
    final previous = _queue;
    _queue = ReaderQueue(ids: ids);
    previous?.dispose();
  }

  Future<void> _importScore() async {
    final path = await _picker.pickScoreFile();
    if (!mounted || path == null) return;
    final extension = path.split('.').last.toLowerCase();
    if (extension != 'mscx' && extension != 'mscz') {
      _showMessage('请选择 MSCX 或 MSCZ 谱面文件。');
      return;
    }
    final entry = ScoreLibraryEntry.placeholder(path);
    setState(() {
      _entries.removeWhere((item) => item.sourcePath == path);
      _entries.insert(0, entry);
      _error = null;
    });
    _syncQueue();
    await _openEntry(entry);
  }

  /// Open the in-app directory browser. Confirming replaces the whole
  /// collection with the valid scores of the chosen folder (the bundled demo
  /// is no longer part of the collection afterwards, mirroring the reference
  /// player where opening a folder replaces its playlist).
  Future<void> _importFolder() async {
    final paths = await Navigator.of(context).push<List<String>>(
      MaterialPageRoute<List<String>>(
        builder: (_) => FolderPickerPage(picker: _picker),
      ),
    );
    if (!mounted || paths == null) return;
    final seen = <String>{};
    final uniquePaths = paths.where(seen.add).toList(growable: false);
    final placeholders = [
      for (final path in uniquePaths) ScoreLibraryEntry.placeholder(path),
    ];
    setState(() {
      _entries
        ..clear()
        ..addAll(placeholders);
      _retentionOrder.clear();
      _loading = false;
      _error = null;
    });
    _syncQueue();
    _showMessage(
      uniquePaths.isEmpty ? '所选目录中没有可用的谱面文件' : '已导入 ${uniquePaths.length} 份谱面',
    );

    // Metadata and thumbnail sidecars are small and can hydrate quietly; the
    // documents themselves are still loaded lazily when a score is opened.
    final cachedEntries = await Future.wait(
      uniquePaths.map(_libraryCache.readOrPlaceholder),
    );
    if (!mounted) return;
    setState(() {
      for (final cached in cachedEntries) {
        final index = _entries.indexWhere(
          (entry) => entry.sourcePath == cached.sourcePath,
        );
        if (index >= 0 && _entries[index].document == null) {
          _entries[index] = cached;
        }
      }
    });
  }

  /// Open a score card: hydrate the document when needed, then push the
  /// reader with the current play queue and a loader for neighbouring pieces.
  Future<void> _openEntry(ScoreLibraryEntry entry) async {
    final loaded = entry.document;
    if (loaded != null) {
      if (!entry.isBundled) _markRetained(entry.sourcePath);
      _openReader(entry);
      return;
    }
    try {
      final hydrated = await _loadEntryById(entry.sourcePath);
      if (!mounted || hydrated.document == null) return;
      _openReader(hydrated);
    } catch (error) {
      if (!mounted) return;
      _showMessage('打开谱面失败');
      setState(() => _error = '$error');
    }
  }

  /// Load and hydrate one collection entry, keeping the library list in sync.
  /// Used by the reader for 上一首/下一首/loop switches, which may target any
  /// entry of the collection at any time.
  Future<ScoreLibraryEntry> _loadEntryById(String sourcePath) async {
    final indexOf = _entries.indexWhere(
      (entry) => entry.sourcePath == sourcePath,
    );
    if (indexOf < 0) {
      throw StateError('谱面不在当前谱面库中：$sourcePath');
    }
    final entry = _entries[indexOf];
    final loaded = entry.document;
    if (loaded != null) return entry;
    if (!_openingPaths.add(sourcePath)) {
      // Another request is hydrating the same entry (for example the card
      // was opened twice in quick succession). Wait for it to settle.
      while (mounted && _openingPaths.contains(sourcePath)) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      final settledIndex = _entries.indexWhere(
        (item) => item.sourcePath == sourcePath,
      );
      final settled = settledIndex < 0 ? null : _entries[settledIndex];
      if (settled?.document == null) {
        throw StateError('谱面尚未就绪：$sourcePath');
      }
      return settled!;
    }
    setState(() {});
    try {
      final document = entry.isBundled
          ? await _repository.openAsset(entry.assetPath!)
          : await _repository.open(entry.sourcePath);
      final hydrated = entry.isBundled
          ? ScoreLibraryEntry.fromDocument(document, assetPath: entry.assetPath)
          : await _libraryCache.write(document);
      if (mounted) {
        setState(() {
          final index = _entries.indexWhere(
            (item) => item.sourcePath == entry.sourcePath,
          );
          if (index >= 0 && _entries[index].document == null) {
            _entries[index] = hydrated;
          }
          _openingPaths.remove(entry.sourcePath);
          _error = null;
          if (!entry.isBundled &&
              index >= 0 &&
              _entries[index].document != null) {
            _retentionOrder
              ..remove(entry.sourcePath)
              ..insert(0, entry.sourcePath);
          }
        });
        _trimRetainedDocuments();
      }
      return hydrated;
    } catch (error) {
      if (mounted) {
        setState(() {
          _openingPaths.remove(entry.sourcePath);
          _error = '$error';
        });
      }
      rethrow;
    }
  }

  void _openReader(ScoreLibraryEntry entry, {bool autoplay = false}) {
    final queue = _queue;
    final document = entry.document;
    if (queue == null || document == null) return;
    queue.setCurrentId(entry.sourcePath);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderPage(
          document: document,
          queue: queue,
          loadEntry: _loadEntryById,
          autoplay: autoplay,
        ),
      ),
    );
  }

  /// 开始随机: pick one piece with the same golden-ratio memory chooser that
  /// drives random playback (so recently played pieces are skipped), force the
  /// loop mode to 随机（记忆） and start playing immediately.
  Future<void> _startRandom() async {
    final queue = _queue;
    if (queue == null || _loading || _entries.isEmpty) return;
    queue.setLoop(PlayLoop.randomMemory);
    final ids = [for (final entry in _entries) entry.sourcePath];
    final chosen = ids.length <= 1
        ? ids.first
        : (queue.memory.chooseNext(ids) ?? ids.first);
    queue.setCurrentId(chosen);
    try {
      final hydrated = await _loadEntryById(chosen);
      if (!mounted || hydrated.document == null) return;
      _openReader(hydrated, autoplay: true);
    } catch (error) {
      if (!mounted) return;
      _showMessage('打开谱面失败');
      setState(() => _error = '$error');
    }
  }

  /// Move a hydrated source path to the front of the retention order.
  void _markRetained(String sourcePath) {
    _retentionOrder
      ..remove(sourcePath)
      ..insert(0, sourcePath);
  }

  /// Metadata-only copy of a hydrated entry: the cover and sidecar metadata
  /// stay so the card keeps its preview, but the heavy [ScoreDocument] is
  /// released. Reopening later reloads the gzipped document sidecar (or the
  /// native renderer as a fallback) on demand.
  ScoreLibraryEntry _demotedCopy(ScoreLibraryEntry entry) {
    return ScoreLibraryEntry(
      sourcePath: entry.sourcePath,
      fileName: entry.fileName,
      format: entry.format,
      title: entry.title,
      composer: entry.composer,
      pageCount: entry.pageCount,
      durationUs: entry.durationUs,
      coverBytes: entry.coverBytes,
      assetPath: entry.assetPath,
    );
  }

  /// Demote the least recently used documents beyond the retention budget
  /// (bundled demo is never part of the budget). Keeps memory bounded when a
  /// collection is played through continuously.
  void _trimRetainedDocuments() {
    if (!mounted || _retentionOrder.length <= _maxRetainedDocuments) return;
    final demote = <String>[];
    var retainedCount = 0;
    for (final path in _retentionOrder) {
      final hydrated = _entries.any(
        (entry) =>
            entry.sourcePath == path &&
            !entry.isBundled &&
            entry.document != null,
      );
      if (!hydrated) continue;
      retainedCount += 1;
      if (retainedCount > _maxRetainedDocuments) demote.add(path);
    }
    if (demote.isEmpty) return;
    setState(() {
      for (final path in demote) {
        final index = _entries.indexWhere(
          (entry) =>
              entry.sourcePath == path &&
              !entry.isBundled &&
              entry.document != null,
        );
        if (index < 0) continue;
        _entries[index] = _demotedCopy(_entries[index]);
        _retentionOrder.remove(path);
      }
    });
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _dismissError() {
    setState(() => _error = null);
  }

  @override
  Widget build(BuildContext context) {
    final appBarInset = _libraryHorizontalInset(
      MediaQuery.sizeOf(context).width,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('MuseReader'),
        titleSpacing: appBarInset,
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final horizontal = _libraryHorizontalInset(width);
            final contentWidth = width - horizontal * 2;
            final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
            final columns = contentWidth >= 760 && textScale <= 1.25 ? 2 : 1;
            return CustomScrollView(
              key: const PageStorageKey<String>('score-library-scroll'),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(horizontal, 24, horizontal, 20),
                  sliver: SliverToBoxAdapter(
                    child: _LibraryHeader(
                      onImport: _loading ? null : _importScore,
                      onOpenFolder: _loading ? null : _importFolder,
                      documentCount: _entries.length,
                      loading: _loading,
                    ),
                  ),
                ),
                if (_loading)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 16),
                    sliver: const SliverToBoxAdapter(
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  ),
                if (_error != null)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 16),
                    sliver: SliverToBoxAdapter(
                      child: _ErrorStrip(
                        message: _error!,
                        onRetry: _reloadLibrary,
                        onDismiss: _dismissError,
                      ),
                    ),
                  ),
                if (_loading)
                  _LibraryItems(
                    horizontalPadding: horizontal,
                    columns: columns,
                    loading: true,
                    entries: const [],
                    openingPaths: const {},
                    onOpen: _openEntry,
                  )
                else if (_entries.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyLibrary(
                      onImport: _importScore,
                      onOpenFolder: _importFolder,
                    ),
                  )
                else
                  _LibraryItems(
                    horizontalPadding: horizontal,
                    columns: columns,
                    loading: false,
                    entries: _entries,
                    openingPaths: _openingPaths,
                    onOpen: _openEntry,
                  ),
              ],
            );
          },
        ),
      ),
      bottomNavigationBar: _loading || _entries.isEmpty
          ? null
          : _RandomStartBar(onStart: _startRandom),
    );
  }
}

/// Bottom bar of the library: 开始随机 picks a piece with the golden-ratio
/// memory chooser and starts playing in 随机（记忆） mode.
class _RandomStartBar extends StatelessWidget {
  const _RandomStartBar({required this.onStart});

  final VoidCallback onStart;

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
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onStart,
                icon: const Icon(Icons.shuffle_rounded),
                label: const Text('开始随机'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

double _libraryHorizontalInset(double width) {
  if (width > 1184) return (width - 1120) / 2;
  if (width >= 720) return 32;
  return 16;
}

class _LibraryHeader extends StatelessWidget {
  const _LibraryHeader({
    required this.onImport,
    required this.onOpenFolder,
    required this.documentCount,
    required this.loading,
  });

  final VoidCallback? onImport;
  final VoidCallback? onOpenFolder;
  final int documentCount;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('谱面库', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(
          loading ? '正在整理谱面' : '$documentCount 份谱面',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    final importButton = FilledButton.icon(
      onPressed: onImport,
      icon: const Icon(Icons.add_rounded),
      label: const Text('导入谱面'),
    );
    final folderButton = FilledButton.tonalIcon(
      onPressed: onOpenFolder,
      icon: const Icon(Icons.add_rounded),
      label: const Text('打开目录'),
    );
    final scaledBody = MediaQuery.textScalerOf(context).scale(14);
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 520 || scaledBody > 18;
        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              title,
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: importButton),
                  const SizedBox(width: 12),
                  Expanded(child: folderButton),
                ],
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: title),
            const SizedBox(width: 24),
            importButton,
            const SizedBox(width: 12),
            folderButton,
          ],
        );
      },
    );
  }
}

class _LibraryItems extends StatelessWidget {
  const _LibraryItems({
    required this.horizontalPadding,
    required this.columns,
    required this.loading,
    required this.entries,
    required this.openingPaths,
    required this.onOpen,
  });

  final double horizontalPadding;
  final int columns;
  final bool loading;
  final List<ScoreLibraryEntry> entries;
  final Set<String> openingPaths;
  final ValueChanged<ScoreLibraryEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final itemCount = loading ? (columns == 1 ? 3 : 4) : entries.length;
    Widget itemBuilder(BuildContext context, int index) {
      if (loading) return const _LoadingScoreCard();
      final entry = entries[index];
      return _ScoreCard(
        entry: entry,
        opening: openingPaths.contains(entry.sourcePath),
        onTap: () => onOpen(entry),
      );
    }

    final Widget sliver;
    if (columns > 1) {
      sliver = SliverGrid.builder(
        itemCount: itemCount,
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          mainAxisExtent: 150,
        ),
        itemBuilder: itemBuilder,
      );
    } else {
      sliver = SliverList.builder(
        itemCount: itemCount,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: itemBuilder(context, index),
        ),
      );
    }
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(horizontalPadding, 0, horizontalPadding, 48),
      sliver: sliver,
    );
  }
}

class _ScoreCard extends StatelessWidget {
  const _ScoreCard({
    required this.entry,
    required this.opening,
    required this.onTap,
  });

  final ScoreLibraryEntry entry;
  final bool opening;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final format = entry.format == ScoreFormat.mscz ? 'MSCZ' : 'MSCX';
    final composer = entry.composer.isEmpty ? entry.fileName : entry.composer;
    final semantics = [
      opening ? '正在打开谱面 ${entry.title}' : '打开谱面 ${entry.title}',
      if (composer.isNotEmpty) composer,
      format,
      if (entry.pageCount != null) '${entry.pageCount} 页',
      if (entry.durationUs != null) formatScoreDuration(entry.durationUs!),
    ].join('，');
    return Semantics(
      button: true,
      label: semantics,
      onTap: opening ? null : onTap,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: opening ? null : onTap,
          excludeFromSemantics: true,
          child: ExcludeSemantics(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final previewWidth = constraints.maxWidth < 320 ? 72.0 : 88.0;
                final showChevron = constraints.maxWidth >= 320;
                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _ScorePreview(entry: entry, width: previewWidth),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              composer,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                _FormatBadge(text: format),
                                if (entry.pageCount != null)
                                  _MetaLabel(
                                    icon: Icons.menu_book_outlined,
                                    text: '${entry.pageCount} 页',
                                  ),
                                if (entry.durationUs != null)
                                  _MetaLabel(
                                    icon: Icons.schedule_outlined,
                                    text: formatScoreDuration(
                                      entry.durationUs!,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (showChevron) ...[
                        const SizedBox(width: 4),
                        SizedBox(
                          height: previewWidth * 1.4,
                          child: Center(
                            child: opening
                                ? const SizedBox.square(
                                    dimension: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Icon(
                                    Icons.chevron_right_rounded,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _ScorePreview extends StatelessWidget {
  const _ScorePreview({required this.entry, required this.width});

  final ScoreLibraryEntry entry;
  final double width;

  @override
  Widget build(BuildContext context) {
    final document = entry.document;
    final page = document == null || document.pages.isEmpty
        ? null
        : document.pages.first;
    final height = width * 1.4;
    final fallback = page == null
        ? Center(
            child: Icon(
              Icons.music_note_rounded,
              color: Theme.of(context).colorScheme.primary,
              size: 28,
            ),
          )
        : FittedBox(
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: page.width,
              height: page.height,
              child: CustomPaint(
                painter: ScorePagePainter(
                  page: page,
                  activeEventIndexes: const {},
                  inkColor: museScoreInkColor,
                  accentColor: museScorePlaybackColor,
                ),
              ),
            ),
          );
    final imageBytes = entry.coverBytes ?? page?.imageBytes;
    final content = imageBytes == null
        ? fallback
        : Image.memory(
            imageBytes,
            fit: BoxFit.cover,
            alignment: Alignment.topCenter,
            filterQuality: FilterQuality.medium,
            cacheWidth: 240,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) => fallback,
          );
    return RepaintBoundary(
      child: Container(
        width: width,
        height: height,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: museScorePaperColor,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: content,
      ),
    );
  }
}

class _FormatBadge extends StatelessWidget {
  const _FormatBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          text,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSecondaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _MetaLabel extends StatelessWidget {
  const _MetaLabel({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(text, style: theme.textTheme.labelMedium?.copyWith(color: color)),
      ],
    );
  }
}

class _ErrorStrip extends StatelessWidget {
  const _ErrorStrip({
    required this.message,
    required this.onRetry,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Material(
        color: colors.errorContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: ExcludeSemantics(
                      child: Icon(
                        Icons.error_outline_rounded,
                        size: 20,
                        color: colors.onErrorContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        message,
                        style: TextStyle(color: colors.onErrorContainer),
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onDismiss,
                    icon: const Icon(Icons.close_rounded),
                    color: colors.onErrorContainer,
                    tooltip: '关闭错误提示',
                  ),
                ],
              ),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('重试'),
                  style: TextButton.styleFrom(
                    foregroundColor: colors.onErrorContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingScoreCard extends StatelessWidget {
  const _LoadingScoreCard();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    Widget block({required double width, required double height}) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
      );
    }

    return Semantics(
      label: '正在载入谱面',
      child: ExcludeSemantics(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                block(width: 88, height: 124),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FractionallySizedBox(
                          widthFactor: 0.72,
                          child: block(width: double.infinity, height: 18),
                        ),
                        const SizedBox(height: 12),
                        FractionallySizedBox(
                          widthFactor: 0.48,
                          child: block(width: double.infinity, height: 12),
                        ),
                        const SizedBox(height: 24),
                        FractionallySizedBox(
                          widthFactor: 0.64,
                          child: block(width: double.infinity, height: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onImport, required this.onOpenFolder});

  final VoidCallback onImport;
  final VoidCallback onOpenFolder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.library_music_outlined,
              size: 52,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: 16),
            Text('未找到本地谱面', style: theme.textTheme.titleLarge),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('导入谱面'),
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: onOpenFolder,
              icon: const Icon(Icons.add_rounded),
              label: const Text('打开目录'),
            ),
          ],
        ),
      ),
    );
  }
}
