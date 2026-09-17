import 'dart:io';

import 'package:flutter/services.dart';

import '../model/score_library_entry.dart';

/// One directory or score file inside a granted (SAF) directory tree.
class FolderEntry {
  const FolderEntry({
    required this.documentId,
    required this.name,
    required this.isDirectory,
  });

  /// Document id relative to the tree root; empty for the tree root itself.
  final String documentId;
  final String name;
  final bool isDirectory;
}

/// One level of a granted directory tree: sub-folders plus the direct score
/// files of the current folder.
class FolderContents {
  const FolderContents({required this.folders, required this.scores});

  final List<FolderEntry> folders;
  final List<String> scores;
}

class FilePickerService {
  static const _channel = MethodChannel('com.musereader/files');

  Future<String?> pickScoreFile() async {
    try {
      final path = await _channel.invokeMethod<String>('pickScoreFile');
      return path;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Returns score files copied into the app's persistent import directory.
  ///
  /// The mobile implementations own that directory because a path supplied by
  /// the system picker is not guaranteed to remain readable after the process
  /// is restarted. Other platforms may not expose the optional method; in that
  /// case an empty list keeps the compatibility UI usable.
  Future<List<String>> listImportedScoreFiles() async {
    try {
      final invocation = _channel.invokeMethod<List<dynamic>>(
        'listImportedScoreFiles',
      );
      // Desktop/widget embedders do not register this mobile-only channel.
      // Their test messengers can leave an unhandled call pending, so use a
      // short optional-capability timeout there. Mobile I/O gets a more
      // generous bound for slower devices while still preventing a broken
      // channel from blocking library startup forever.
      final timeout = Platform.isAndroid || Platform.isIOS
          ? const Duration(seconds: 5)
          : const Duration(milliseconds: 250);
      final paths = await invocation.timeout(timeout, onTimeout: () => null);
      if (paths == null) return const [];
      return paths.whereType<String>().where(_isSupportedScorePath).toList();
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    } on Object {
      // A malformed platform response must not leave the library in its
      // startup loading state. The next explicit import can still surface its
      // own error to the user.
      return const [];
    }
  }

  /// The tree [Uri] string of the last folder granted by the user, when the
  /// platform was able to persist the read permission across launches.
  Future<String?> storedScoreFolderTree() async {
    try {
      final uri = await _channel.invokeMethod<String>('storedScoreFolderTree');
      return uri == null || uri.isEmpty ? null : uri;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } on Object {
      return null;
    }
  }

  /// Ask the system folder picker (SAF) for a directory tree grant and return
  /// its tree [Uri] string, or null when the user cancels. The platform side
  /// persists the read grant so later launches can keep browsing the tree.
  Future<String?> pickScoreFolder() async {
    try {
      final uri = await _channel.invokeMethod<String>('pickScoreFolder');
      return uri == null || uri.isEmpty ? null : uri;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// List the direct children (folders and supported score files) of one
  /// folder inside a granted tree. [documentId] is relative to the tree root
  /// (empty string lists the root). Returns null when the grant is missing,
  /// revoked, or unsupported on this platform.
  Future<FolderContents?> listScoreFolderContents(
    String treeUri,
    String documentId,
  ) async {
    try {
      final invocation = _channel.invokeMethod<Map<dynamic, dynamic>>(
        'listScoreFolderContents',
        <String, Object>{'treeUri': treeUri, 'documentId': documentId},
      );
      final timeout = Platform.isAndroid || Platform.isIOS
          ? const Duration(seconds: 8)
          : const Duration(milliseconds: 250);
      final raw = await invocation.timeout(timeout, onTimeout: () => null);
      if (raw == null) return null;
      final folders = <FolderEntry>[
        for (final item in (raw['folders'] as List<dynamic>? ?? const []))
          FolderEntry(
            documentId: (item as Map<dynamic, dynamic>)['documentId'] as String,
            name: (item['name'] as String?) ?? '',
            isDirectory: true,
          ),
      ];
      final scores = <String>[
        for (final item in (raw['scores'] as List<dynamic>? ?? const []))
          item as String,
      ];
      return FolderContents(folders: folders, scores: scores);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    } on Object {
      return null;
    }
  }

  /// Import every valid score file found DIRECTLY inside [documentId] of the
  /// granted tree (non-recursive). The platform side clears the app's import
  /// directory first, so the library collection is replaced by the folder's
  /// scores. Returns the absolute paths of the imported files in display
  /// order; an empty list means the folder contained no supported score.
  /// Platform failures are rethrown so the caller can tell them apart from an
  /// empty folder.
  Future<List<String>> importScoreFolder(
    String treeUri,
    String documentId,
  ) async {
    try {
      final invocation = _channel.invokeMethod<List<dynamic>>(
        'importScoreFolder',
        <String, Object>{'treeUri': treeUri, 'documentId': documentId},
      );
      final timeout = Platform.isAndroid || Platform.isIOS
          ? const Duration(seconds: 20)
          : const Duration(milliseconds: 250);
      final paths = await invocation.timeout(timeout, onTimeout: () => null);
      if (paths == null) return const [];
      return paths.whereType<String>().where(_isSupportedScorePath).toList();
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      rethrow;
    } on Object {
      rethrow;
    }
  }

  /// Boolean display preference persisted by the platform side (for example
  /// the 内部标题 toggle). Falls back to [fallback] when unavailable.
  Future<bool> readBooleanPreference(
    String key, {
    bool fallback = false,
  }) async {
    try {
      final value = await _channel.invokeMethod<bool>('getBooleanPreference', {
        'key': key,
      });
      return value ?? fallback;
    } on MissingPluginException {
      return fallback;
    } on PlatformException {
      return fallback;
    } on Object {
      return fallback;
    }
  }

  Future<void> writeBooleanPreference(String key, bool value) async {
    try {
      await _channel.invokeMethod<void>('setBooleanPreference', {
        'key': key,
        'value': value,
      });
    } on MissingPluginException {
      // Desktop/test embedders have no preference store.
    } on PlatformException {
      // A failed write must never break the UI.
    } on Object {
      // Same as above.
    }
  }

  /// Reads embedded audio tags (title/artist) and the duration of [paths] with
  /// Android's MediaMetadataRetriever. Off-thread on the platform side; returns
  /// one map per readable path with `path`, `title`, `artist`, `durationMs`.
  Future<List<Map<dynamic, dynamic>>> readAudioMetadata(
    List<String> paths,
  ) async {
    if (paths.isEmpty) return const [];
    try {
      // No artificial timeout here: an embedder without the method raises
      // MissingPluginException, which is handled below. (A short timeout would
      // race slow tag reads on large folders.)
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'readAudioMetadata',
        <String, Object>{'paths': paths},
      );
      if (raw == null) return const [];
      return [
        for (final item in raw)
          if (item is Map) item,
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    } on Object {
      return const [];
    }
  }

  static bool _isSupportedScorePath(String path) => isSupportedMediaPath(path);
}
