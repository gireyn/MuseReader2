import 'package:flutter/material.dart';

import '../services/file_picker_service.dart';

/// In-app directory browser for the "打开目录" library action.
///
/// The first grant comes from the system Storage Access Framework picker
/// (android side persists the read permission); afterwards this page browses
/// the granted tree in-app. The bottom bar holds 确认目录/取消: confirming
/// imports every valid score found directly in the current folder (never
/// recursively) and returns the copied file paths to the library page.
class FolderPickerPage extends StatefulWidget {
  const FolderPickerPage({super.key, required this.picker});

  final FilePickerService picker;

  @override
  State<FolderPickerPage> createState() => _FolderPickerPageState();
}

class _FolderPickerPageState extends State<FolderPickerPage> {
  String? _treeUri;
  bool _initializing = true;
  bool _loading = false;
  bool _importing = false;
  String? _error;
  FolderContents? _contents;

  /// Stack of the folders visited from the tree root, root first.
  final _pathIds = <String>[''];
  final _pathNames = <String>[];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  String get _currentId => _pathIds.last;

  Future<void> _bootstrap() async {
    setState(() {
      _initializing = true;
      _error = null;
    });
    var treeUri = await widget.picker.storedScoreFolderTree();
    if (treeUri == null) {
      treeUri = await widget.picker.pickScoreFolder();
      if (treeUri == null) {
        // The user cancelled the system picker: nothing to browse.
        if (mounted) Navigator.of(context).pop();
        return;
      }
    }
    if (!mounted) return;
    setState(() {
      _treeUri = treeUri;
      _pathIds
        ..clear()
        ..add('');
      _pathNames.clear();
      _initializing = false;
    });
    await _reloadContents();
  }

  /// Start over with a freshly granted tree (更换目录).
  Future<void> _grantFolder() async {
    final treeUri = await widget.picker.pickScoreFolder();
    if (!mounted || treeUri == null) return;
    setState(() {
      _treeUri = treeUri;
      _pathIds
        ..clear()
        ..add('');
      _pathNames.clear();
      _error = null;
    });
    await _reloadContents();
  }

  Future<void> _reloadContents() async {
    final treeUri = _treeUri;
    if (treeUri == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final contents = await widget.picker.listScoreFolderContents(
      treeUri,
      _currentId,
    );
    if (!mounted || treeUri != _treeUri) return;
    setState(() {
      _loading = false;
      if (contents == null) {
        // The grant is gone or the provider refused to answer. The in-app
        // tree cannot be listed without it.
        _error = '无法读取所选目录，可能需要重新授权。';
        _contents = null;
      } else {
        _contents = contents;
      }
    });
  }

  void _enterFolder(FolderEntry folder) {
    setState(() {
      _pathIds.add(folder.documentId);
      _pathNames.add(folder.name);
      _contents = null;
    });
    _reloadContents();
  }

  void _jumpToCrumb(int index) {
    if (index >= _pathIds.length - 1) return;
    setState(() {
      _pathIds.removeRange(index + 1, _pathIds.length);
      _pathNames.removeRange(index, _pathNames.length);
      _contents = null;
    });
    _reloadContents();
  }

  Future<void> _confirmFolder() async {
    final treeUri = _treeUri;
    if (treeUri == null || _importing || _loading) return;
    final hasScores = (_contents?.scores.isNotEmpty ?? false);
    if (!hasScores) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认导入'),
          content: const Text('当前目录中没有 MSCX/MSCZ 谱面文件。确认后谱面库将被清空，是否继续？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('继续'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
    }
    setState(() => _importing = true);
    try {
      final paths = await widget.picker.importScoreFolder(treeUri, _currentId);
      if (!mounted) return;
      Navigator.of(context).pop(paths);
    } on Object {
      if (!mounted) return;
      setState(() => _importing = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('导入目录失败，请重试')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: _importing ? null : () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
          tooltip: '关闭',
        ),
        title: const Text('打开目录', maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            onPressed: _importing ? null : _grantFolder,
            icon: const Icon(Icons.folder_open_rounded),
            tooltip: '更换目录',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (_initializing)
              const Expanded(child: Center(child: CircularProgressIndicator()))
            else if (_treeUri == null)
              const Expanded(child: SizedBox.shrink())
            else ...[
              _Breadcrumbs(pathNames: _pathNames, onJump: _jumpToCrumb),
              if (_error != null)
                _FolderErrorStrip(message: _error!, onGrant: _grantFolder),
              if (_loading)
                const LinearProgressIndicator(minHeight: 2)
              else
                const SizedBox(height: 2),
              Expanded(
                child: _FolderContentsList(
                  contents: _contents,
                  loading: _loading,
                  onEnterFolder: _enterFolder,
                  hint: _error == null ? '此目录下没有可直接导入的内容。' : null,
                ),
              ),
            ],
          ],
        ),
      ),
      bottomNavigationBar: _treeUri == null || _initializing
          ? null
          : _FolderActionsBar(
              importing: _importing,
              canConfirm: !_importing && !_loading,
              onConfirm: _confirmFolder,
              onCancel: _importing ? null : () => Navigator.of(context).pop(),
            ),
    );
  }
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.pathNames, required this.onJump});

  final List<String> pathNames;
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chips = <Widget>[
      ActionChip(
        label: const Text('已选目录'),
        avatar: const Icon(Icons.folder_rounded, size: 18),
        onPressed: () => onJump(0),
      ),
    ];
    for (var index = 0; index < pathNames.length; index++) {
      chips.add(const Padding(padding: EdgeInsets.symmetric(horizontal: 2)));
      chips.add(
        ActionChip(
          label: Text(
            pathNames[index],
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onPressed: () => onJump(index + 1),
        ),
      );
    }
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SizedBox(
        width: double.infinity,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(children: chips),
        ),
      ),
    );
  }
}

class _FolderErrorStrip extends StatelessWidget {
  const _FolderErrorStrip({required this.message, required this.onGrant});

  final String message;
  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            Icon(Icons.error_outline_rounded, color: colors.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: onGrant,
              child: Text(
                '重新授权',
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderContentsList extends StatelessWidget {
  const _FolderContentsList({
    required this.contents,
    required this.loading,
    required this.onEnterFolder,
    required this.hint,
  });

  final FolderContents? contents;
  final bool loading;
  final ValueChanged<FolderEntry> onEnterFolder;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = contents;
    if (current == null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (hint != null) Text(hint!, style: theme.textTheme.bodyMedium),
        ],
      );
    }
    final folderTiles = <Widget>[
      for (final folder in current.folders)
        ListTile(
          leading: Icon(Icons.folder_rounded, color: theme.colorScheme.primary),
          title: Text(
            folder.name.isEmpty ? '未命名目录' : folder.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => onEnterFolder(folder),
        ),
    ];
    if (current.folders.isNotEmpty) {
      folderTiles.insert(
        0,
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            '子目录（${current.folders.length}）',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    if (current.scores.isNotEmpty) {
      folderTiles.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            '本目录内的谱面（${current.scores.length}）',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
      for (final name in current.scores) {
        folderTiles.add(
          ListTile(
            dense: true,
            leading: const Icon(Icons.music_note_rounded),
            title: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        );
      }
    }
    if (folderTiles.isEmpty) {
      folderTiles.add(
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            hint ?? '此目录为空。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return ListView(children: folderTiles);
  }
}

class _FolderActionsBar extends StatelessWidget {
  const _FolderActionsBar({
    required this.importing,
    required this.canConfirm,
    required this.onConfirm,
    required this.onCancel,
  });

  final bool importing;
  final bool canConfirm;
  final VoidCallback onConfirm;
  final VoidCallback? onCancel;

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
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onCancel,
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: canConfirm ? onConfirm : null,
                    icon: importing
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text(importing ? '正在导入' : '确认目录'),
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
