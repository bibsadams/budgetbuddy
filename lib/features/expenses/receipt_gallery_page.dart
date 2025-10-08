import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:hive/hive.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:convert';
import 'package:budgetbuddy/services/local_receipt_service.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ReceiptGalleryPage extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final int initialIndex;
  final Future<void> Function(Map<String, dynamic> updated)? onEdit;
  final Future<void> Function(Map<String, dynamic> updated)? onReplace;
  final List<Map<String, dynamic>>? resolveRows;
  // Target collection for receipts (e.g., 'expenses', 'savings', 'or'). Defaults to 'expenses'.
  final String collection;

  const ReceiptGalleryPage({
    super.key,
    required this.rows,
    this.initialIndex = 0,
    this.onEdit,
    this.onReplace,
    this.resolveRows,
    this.collection = 'expenses',
  });

  @override
  State<ReceiptGalleryPage> createState() => _ReceiptGalleryPageState();
}

class _ReceiptGalleryPageState extends State<ReceiptGalleryPage> {
  static const _mediaStoreChannel = MethodChannel('budgetbuddy/media_store');
  late final List<_ImgSrc> _images;
  late int _curIndex;
  late final PageController _pageController;
  Map<String, dynamic>? _pendingUndo; // holds last undo payload

  bool _bytesEqual(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.lengthInBytes != b.lengthInBytes) return false;
    return listEquals(a, b);
  }

  @override
  void initState() {
    super.initState();
    _curIndex = widget.initialIndex;
    _images = [];
    _pageController = PageController(initialPage: _curIndex);
    // DEBUG: log incoming rows for gallery
    try {
      final summary = widget.rows.map((r) {
        final id = (r['id'] ?? '').toString();
        final uids = (r['ReceiptUids'] is List)
            ? (r['ReceiptUids'] as List).whereType<String>().toList()
            : <String>[];
        final lp = (r['LocalReceiptPath'] ?? '').toString();
        final bytesCount = (r['ReceiptBytes'] is List)
            ? (r['ReceiptBytes'] as List).length
            : ((r['Receipt'] is Uint8List) ? 1 : 0);
        return 'id=$id uids=${uids.length} lp=${lp.isNotEmpty} bytes=$bytesCount';
      }).toList();
      debugPrint(
        'receipt gallery: opened initialIndex=$_curIndex, rows summary=$summary',
      );
    } catch (_) {}

    // Kick off a quick synchronous-style uid -> path logger so we see computed
    // paths and existence checks immediately when the gallery opens. This is
    // fire-and-forget (we don't await) so logs appear even if the UI is slow.
    _syncLogUidPaths(widget.resolveRows ?? widget.rows);

    for (final r in widget.rows) {
      // Prefer plural ReceiptBytes if present
      if (r['ReceiptBytes'] is List) {
        for (final b in (r['ReceiptBytes'] as List)) {
          if (b is Uint8List) _images.add(_ImgSrc.memory(b));
        }
        try {
          debugPrint(
            'receipt gallery: added ${(r['ReceiptBytes'] as List).length} memory images from row id=${(r['id'] ?? '').toString()}',
          );
        } catch (_) {}
        continue;
      }
      if (r['Receipt'] is Uint8List) {
        _images.add(_ImgSrc.memory(r['Receipt'] as Uint8List));
        try {
          debugPrint(
            'receipt gallery: added single memory image from row id=${(r['id'] ?? '').toString()}',
          );
        } catch (_) {}
        continue;
      }
      final local = (r['LocalReceiptPath'] ?? '').toString();
      // If the row has explicit ReceiptUids, prefer resolving each uid to a file
      // instead of immediately adding the single LocalReceiptPath (which commonly
      // points to the first uid). The async resolver will append all uid paths.
      final hasUids =
          r['ReceiptUids'] is List && (r['ReceiptUids'] as List).isNotEmpty;
      if (local.isNotEmpty && !hasUids) {
        _images.add(_ImgSrc.file(local));
        try {
          debugPrint(
            'receipt gallery: added file image path=$local from row id=${(r['id'] ?? '').toString()}',
          );
        } catch (_) {}
        continue;
      }
      if (r['ReceiptUrls'] is List) {
        for (final u in (r['ReceiptUrls'] as List)) {
          if (u is String && u.isNotEmpty) _images.add(_ImgSrc.network(u));
        }
        try {
          debugPrint(
            'receipt gallery: added ${(r['ReceiptUrls'] as List).length} network images from row id=${(r['id'] ?? '').toString()}',
          );
        } catch (_) {}
        continue;
      }
      final url = (r['ReceiptUrl'] ?? '').toString();
      if (url.isNotEmpty) {
        _images.add(_ImgSrc.network(url));
        try {
          debugPrint(
            'receipt gallery: added single network image from row id=${(r['id'] ?? '').toString()} url=$url',
          );
        } catch (_) {}
      }
    }

    // Resolve any ReceiptUids to local file paths asynchronously and append them.
    _resolveReceiptUids(widget.resolveRows ?? widget.rows);
  }

  @override
  void dispose() {
    try {
      _pageController.dispose();
    } catch (_) {}
    super.dispose();
  }

  // Returns true when running on Android API < 29 (Q) where WRITE_EXTERNAL_STORAGE
  // runtime permission is required for writing to public external directories.
  Future<bool> _needsLegacyStoragePermission() async {
    try {
      if (!Platform.isAndroid) return false;
      final sdk =
          (await MethodChannel(
            'flutter/platform',
          ).invokeMethod<int>('getSystemVersion')) ??
          0;
      // If we couldn't get a version, be conservative and assume permission needed.
      return sdk > 0 && sdk < 29;
    } catch (_) {
      return true;
    }
  }

  // Request WRITE_EXTERNAL_STORAGE (Permission.storage) and return whether granted.
  Future<bool> _requestLegacyStoragePermission() async {
    try {
      final status = await Permission.storage.status;
      if (status.isGranted) return true;
      final res = await Permission.storage.request();
      return res.isGranted;
    } catch (e) {
      debugPrint('permission request failed: $e');
      return false;
    }
  }

  // Append a small JSON debug entry to receipts_debug.log for replace actions.
  Future<void> _appendReplaceDebugLog(Map<String, dynamic> entry) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final base = Directory('${dir.path}/receipts');
      if (!await base.exists()) await base.create(recursive: true);
      final debugFile = File('${base.path}/receipts_debug.log');
      final e = {...entry, 'ts': DateTime.now().toIso8601String()};
      await debugFile.writeAsString(
        '${jsonEncode(e)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (e) {
      try {
        debugPrint('receipt gallery: failed to append replace debug log: $e');
      } catch (_) {}
    }
  }

  void _queueUndo(Map<String, dynamic> payload, String message) {
    _pendingUndo = payload;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            // fire and forget
            _performUndo();
          },
        ),
      ),
    );
  }

  Future<void> _performUndo() async {
    final payload = _pendingUndo;
    _pendingUndo = null;
    if (payload == null) return;
    try {
      final type = payload['type'] as String?;
      final rowIndex = payload['rowIndex'] as int?;
      if (rowIndex == null || rowIndex < 0 || rowIndex >= widget.rows.length)
        return;
      final r = widget.rows[rowIndex];
      final galleryIndex =
          (payload['galleryIndex'] as int?) ??
          (_images.isEmpty ? 0 : _curIndex);

      if (type == 'delete') {
        final srcKind = payload['srcKind'] as String?;
        if (srcKind == 'memoryList') {
          final idx = (payload['listIndex'] as int?) ?? -1;
          final bytes = payload['bytesOld'] as Uint8List?;
          if (bytes != null && idx >= 0) {
            final list = List<Uint8List>.from(
              r['ReceiptBytes'] as List? ?? const [],
            );
            if (idx <= list.length) {
              list.insert(idx, bytes);
            } else {
              list.add(bytes);
            }
            r['ReceiptBytes'] = list;
            if (widget.onEdit != null) await widget.onEdit!(r);
            setState(() {
              final insertAt = (galleryIndex <= _images.length)
                  ? galleryIndex
                  : _images.length;
              _images.insert(insertAt, _ImgSrc.memory(bytes));
              _curIndex = insertAt;
            });
          }
          return;
        }
        if (srcKind == 'memorySingle') {
          final bytes = payload['bytesOld'] as Uint8List?;
          if (bytes != null) {
            r['Receipt'] = bytes;
            if (widget.onEdit != null) await widget.onEdit!(r);
            setState(() {
              final insertAt = (galleryIndex <= _images.length)
                  ? galleryIndex
                  : _images.length;
              _images.insert(insertAt, _ImgSrc.memory(bytes));
              _curIndex = insertAt;
            });
          }
          return;
        }
        if (srcKind == 'urlList' || srcKind == 'urlSingle') {
          final url = payload['url'] as String?;
          final idx = payload['urlIndex'] as int?;
          if (url != null) {
            if (srcKind == 'urlList') {
              final urls = List<String>.from(
                r['ReceiptUrls'] as List? ?? const [],
              );
              if (idx != null && idx >= 0 && idx <= urls.length) {
                urls.insert(idx, url);
              } else {
                urls.add(url);
              }
              r['ReceiptUrls'] = urls;
            } else {
              r['ReceiptUrl'] = url;
            }
            if (widget.onEdit != null) await widget.onEdit!(r);
            setState(() {
              final insertAt = (galleryIndex <= _images.length)
                  ? galleryIndex
                  : _images.length;
              _images.insert(insertAt, _ImgSrc.network(url));
              _curIndex = insertAt;
            });
          }
          return;
        }
        if (srcKind == 'fileUid' || srcKind == 'fileDoc') {
          final docId = (r['id'] ?? r['Id'] ?? r['docId'] ?? '').toString();
          final accountId =
              (Hive.isBoxOpen('budgetBox')
                          ? Hive.box('budgetBox')
                          : await Hive.openBox('budgetBox'))
                      .get('accountId')
                  as String? ??
              '';
          final bytes = payload['bytesOld'] as Uint8List?;
          final receiptUid = payload['receiptUid'] as String?;
          if (bytes != null && accountId.isNotEmpty) {
            String restoredPath;
            if (srcKind == 'fileUid' &&
                receiptUid != null &&
                receiptUid.isNotEmpty) {
              restoredPath = await LocalReceiptService().saveReceipt(
                accountId: accountId,
                collection: widget.collection,
                docId: docId,
                bytes: bytes,
                receiptUid: receiptUid,
              );
              final prev = List<String>.from(
                payload['prevReceiptUids'] as List? ?? const [],
              );
              if (!prev.contains(receiptUid)) prev.add(receiptUid);
              r['ReceiptUids'] = prev;
              r['LocalReceiptPath'] = restoredPath;
            } else {
              restoredPath = await LocalReceiptService().saveReceipt(
                accountId: accountId,
                collection: widget.collection,
                docId: docId,
                bytes: bytes,
              );
              r['LocalReceiptPath'] = restoredPath;
            }
            if (widget.onEdit != null) await widget.onEdit!(r);
            try {
              PaintingBinding.instance.imageCache.evict(
                FileImage(File(restoredPath)),
              );
            } catch (_) {}
            setState(() {
              final insertAt = (galleryIndex <= _images.length)
                  ? galleryIndex
                  : _images.length;
              _images.insert(insertAt, _ImgSrc.file(restoredPath));
              _curIndex = insertAt;
            });
          }
          return;
        }
      }
      if (type == 'replace') {
        final srcKind = payload['srcKind'] as String?;
        if (srcKind == 'memoryList') {
          final idx = payload['listIndex'] as int?;
          final oldBytes = payload['bytesOld'] as Uint8List?;
          if (idx != null && idx >= 0 && oldBytes != null) {
            final list = List<Uint8List>.from(
              r['ReceiptBytes'] as List? ?? const [],
            );
            if (idx < list.length) list[idx] = oldBytes;
            r['ReceiptBytes'] = list;
            if (widget.onEdit != null) await widget.onEdit!(r);
            setState(() => _images[_curIndex] = _ImgSrc.memory(oldBytes));
          }
          return;
        }
        if (srcKind == 'memorySingle') {
          final oldBytes = payload['bytesOld'] as Uint8List?;
          if (oldBytes != null) {
            r['Receipt'] = oldBytes;
            if (widget.onEdit != null) await widget.onEdit!(r);
            setState(() => _images[_curIndex] = _ImgSrc.memory(oldBytes));
          }
          return;
        }
        if (srcKind == 'file') {
          final accountId =
              (Hive.isBoxOpen('budgetBox')
                          ? Hive.box('budgetBox')
                          : await Hive.openBox('budgetBox'))
                      .get('accountId')
                  as String? ??
              '';
          final docId = (r['id'] ?? r['Id'] ?? r['docId'] ?? '').toString();
          final oldBytes = payload['bytesOld'] as Uint8List?;
          final matchedUid = payload['matchedUid'] as String?;
          if (oldBytes != null && accountId.isNotEmpty) {
            final restoredPath = await LocalReceiptService().saveReceipt(
              accountId: accountId,
              collection: widget.collection,
              docId: docId,
              bytes: oldBytes,
              receiptUid: matchedUid,
            );
            r['LocalReceiptPath'] = restoredPath;
            r['Receipt'] = oldBytes;
            if (widget.onEdit != null) await widget.onEdit!(r);
            try {
              PaintingBinding.instance.imageCache.evict(
                FileImage(File(restoredPath)),
              );
            } catch (_) {}
            setState(() => _images[_curIndex] = _ImgSrc.file(restoredPath));
          }
          return;
        }
      }
    } catch (e) {
      debugPrint('undo failed: $e');
    }
  }

  // Fire-and-forget helper: compute deterministic paths for ReceiptUids and
  // log whether the files exist. This provides immediate, easy-to-copy logs
  // for debugging (called from initState without awaiting).
  Future<void> _syncLogUidPaths(List<Map<String, dynamic>> rowsToCheck) async {
    try {
      final box = Hive.isBoxOpen('budgetBox')
          ? Hive.box('budgetBox')
          : await Hive.openBox('budgetBox');
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final perUserKey = uid != null ? 'accountId_$uid' : 'accountId';
      final accountId =
          (box.get(perUserKey) ?? box.get('accountId') ?? '') as String;
      if (accountId.isEmpty) {
        try {
          debugPrint(
            'receipt gallery sync: accountId empty; cannot compute uid paths from accountId',
          );
        } catch (_) {}
        // As a fallback, list the receipts directory so we can see existing files
        await _logReceiptsDirectoryContents();
        return;
      }
      try {
        debugPrint(
          'receipt gallery: sync uid path logging start for accountId=$accountId',
        );
      } catch (_) {}
      for (final r in rowsToCheck) {
        if (r['ReceiptUids'] is List) {
          for (final uid in (r['ReceiptUids'] as List)) {
            if (uid is! String || uid.isEmpty) continue;
            try {
              final path = await LocalReceiptService().pathForReceiptUid(
                accountId: accountId,
                collection: widget.collection,
                receiptUid: uid,
              );
              try {
                debugPrint('receipt gallery sync: uid=$uid computedPath=$path');
              } catch (_) {}
              try {
                final exists = await File(path).exists();
                try {
                  debugPrint('receipt gallery sync: uid=$uid exists=$exists');
                } catch (_) {}
              } catch (e) {
                try {
                  debugPrint(
                    'receipt gallery sync: uid=$uid exists check failed: $e',
                  );
                } catch (_) {}
              }
            } catch (e) {
              try {
                debugPrint('receipt gallery sync: uid=$uid compute failed: $e');
              } catch (_) {}
            }
          }
        }
      }
      try {
        debugPrint('receipt gallery: sync uid path logging finished');
      } catch (_) {}
    } catch (_) {
      // ignore failures of the logging helper
    }
  }

  // Helper: list receipts directory contents (recursive) for quick debugging.
  Future<void> _logReceiptsDirectoryContents() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final base = Directory('${dir.path}/receipts');
      if (!await base.exists()) {
        try {
          debugPrint(
            'receipt gallery sync: receipts base dir does not exist: ${base.path}',
          );
        } catch (_) {}
        return;
      }
      final List<String> entries = [];
      await for (final e in base.list(recursive: true)) {
        entries.add(e.path);
      }
      try {
        debugPrint(
          'receipt gallery sync: receipts dir entries (${entries.length}): $entries',
        );
      } catch (_) {}
    } catch (e) {
      try {
        debugPrint('receipt gallery sync: failed listing receipts dir: $e');
      } catch (_) {}
    }
  }

  Future<void> _resolveReceiptUids(
    List<Map<String, dynamic>> rowsToResolve,
  ) async {
    try {
      final box = Hive.isBoxOpen('budgetBox')
          ? Hive.box('budgetBox')
          : await Hive.openBox('budgetBox');
      final uid2 = FirebaseAuth.instance.currentUser?.uid;
      final k2 = uid2 != null ? 'accountId_$uid2' : 'accountId';
      final accountId = (box.get(k2) ?? box.get('accountId') ?? '') as String;
      final haveAccountId = accountId.isNotEmpty;
      // Debug: collect all uids we'll attempt to resolve and log them
      try {
        final allUids = <String>[];
        for (final r in rowsToResolve) {
          if (r['ReceiptUids'] is List) {
            for (final uid in (r['ReceiptUids'] as List)) {
              if (uid is String && uid.isNotEmpty) allUids.add(uid);
            }
          }
        }
        debugPrint(
          'receipt gallery: starting uid resolution for accountId=$accountId totalUids=${allUids.length} uids=$allUids',
        );
      } catch (_) {}
      for (final r in rowsToResolve) {
        // Debug: log which row we are resolving
        try {
          debugPrint(
            'receipt gallery: resolving row id=${(r['id'] ?? '').toString()} ReceiptUids=${r['ReceiptUids']}',
          );
        } catch (_) {}

        if (r['ReceiptUids'] is List) {
          for (final uid in (r['ReceiptUids'] as List)) {
            if (uid is String && uid.isNotEmpty) {
              try {
                String? path;
                if (haveAccountId) {
                  path = await LocalReceiptService().pathForReceiptUid(
                    accountId: accountId,
                    collection: widget.collection,
                    receiptUid: uid,
                  );
                  try {
                    debugPrint(
                      'receipt gallery: computed path for uid=$uid -> $path',
                    );
                  } catch (_) {}
                  final f = File(path);
                  if (await f.exists()) {
                    debugPrint(
                      'receipt gallery: resolved uid=$uid -> path exists',
                    );
                  } else {
                    // computed path missing; fall back to scanning receipts dir for matching file
                    debugPrint(
                      'receipt gallery: uid=$uid computed path does not exist; scanning receipts dir as fallback',
                    );
                    path = await _findPathForUidInReceiptsDir(uid);
                  }
                } else {
                  // No accountId available: scan receipts dir for matching uid file(s)
                  path = await _findPathForUidInReceiptsDir(uid);
                  try {
                    debugPrint(
                      'receipt gallery: accountId empty - scanned for uid=$uid -> found=$path',
                    );
                  } catch (_) {}
                }

                if (path != null) {
                  if (!_images.any((img) => img.filePath == path)) {
                    try {
                      // Evict any cached image for this file so the gallery will
                      // display the latest bytes after replacements.
                      PaintingBinding.instance.imageCache.evict(
                        FileImage(File(path)),
                      );
                    } catch (_) {}
                    if (mounted)
                      setState(() => _images.add(_ImgSrc.file(path)));
                  }
                }
              } catch (e) {
                debugPrint(
                  'receipt gallery: failed to resolve uid=$uid error=$e',
                );
                // ignore individual resolution failures
              }
            }
          }
        }
      }
      try {
        debugPrint('receipt gallery: uid resolution finished');
      } catch (_) {}
    } catch (_) {}
  }

  // Helper: look for a file whose basename contains or starts with the uid
  // by scanning the receipts directory recursively. Returns the first match
  // or null if none found.
  Future<String?> _findPathForUidInReceiptsDir(String uid) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final base = Directory('${dir.path}/receipts');
      if (!await base.exists()) return null;
      await for (final e in base.list(recursive: true, followLinks: false)) {
        try {
          if (e is File) {
            final name = p.basename(e.path);
            if (name == uid || name.startsWith('$uid') || name.contains(uid)) {
              return e.path;
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_images.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Receipts')),
        body: const Center(child: Text('No receipt images available.')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('Receipts (${_images.length})'),
        actions: [
          IconButton(
            tooltip: 'Debug receipts',
            icon: const Icon(Icons.bug_report_outlined),
            onPressed: () => _showDebugInfo(),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        onPageChanged: (i) => setState(() => _curIndex = i),
        itemCount: _images.length,
        itemBuilder: (context, idx) {
          final s = _images[idx];
          return InteractiveViewer(
            child: Center(
              child: s.when(
                file: (path) => Image.file(File(path), fit: BoxFit.contain),
                network: (u) => Image.network(u, fit: BoxFit.contain),
                memory: (b) => Image.memory(b, fit: BoxFit.contain),
              ),
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${_curIndex + 1} / ${_images.length}'),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 100),
                      child: ElevatedButton.icon(
                        onPressed: () => _downloadCurrent(context),
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('Download'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 80),
                      child: ElevatedButton.icon(
                        onPressed: () => _editCurrent(context),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Edit'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 80),
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                        ),
                        onPressed: () => _deleteCurrent(context),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Delete'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // TEMP DEBUG: show receipts_debug.log tail, receipts dir listing, and Hive box info
  Future<void> _showDebugInfo() async {
    try {
      final box = Hive.isBoxOpen('budgetBox')
          ? Hive.box('budgetBox')
          : await Hive.openBox('budgetBox');
      final uid3 = FirebaseAuth.instance.currentUser?.uid;
      final k3 = uid3 != null ? 'accountId_$uid3' : 'accountId';
      final accountId = (box.get(k3) ?? box.get('accountId') ?? '') as String;
      debugPrint('receipt debug: budgetBox.accountId=$accountId');
      debugPrint('receipt debug: budgetBox.keys=${box.keys}');

      final dir = await getApplicationDocumentsDirectory();
      final base = Directory('${dir.path}/receipts');
      if (!await base.exists()) {
        debugPrint(
          'receipt debug: receipts base dir does not exist: ${base.path}',
        );
      } else {
        final entries = <String>[];
        await for (final e in base.list(recursive: true)) entries.add(e.path);
        debugPrint(
          'receipt debug: receipts dir entries (${entries.length}): $entries',
        );
      }

      // Print tail of receipts_debug.log if present
      try {
        final debugFile = File('${base.path}/receipts_debug.log');
        if (await debugFile.exists()) {
          final lines = await debugFile.readAsLines();
          final tail = lines.length <= 50
              ? lines
              : lines.sublist(lines.length - 50);
          debugPrint(
            'receipt debug: receipts_debug.log tail (${tail.length} lines):',
          );
          for (final l in tail) debugPrint('receipt debug: $l');
        } else {
          debugPrint(
            'receipt debug: receipts_debug.log not found at ${debugFile.path}',
          );
        }
      } catch (e) {
        debugPrint('receipt debug: failed reading receipts_debug.log: $e');
      }

      // Also show a simple dialog so you know the action completed
      if (mounted) {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Debug info printed'),
            content: Text(
              'Printed receipts_debug.log tail, receipts dir listing, and budgetBox.accountId to console.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      try {
        debugPrint('receipt debug: _showDebugInfo failed: $e');
      } catch (_) {}
    }
  }

  Future<void> _downloadCurrent(BuildContext context) async {
    final src = _images[_curIndex];
    try {
      // Prefer a Downloads folder on Android; fall back to app documents or temp.
      String targetDirPath = Directory.systemTemp.path;
      try {
        if (Platform.isAndroid) {
          final dirs = await getExternalStorageDirectories(
            type: StorageDirectory.downloads,
          );
          if (dirs != null && dirs.isNotEmpty) {
            targetDirPath = dirs.first.path;
          } else {
            final ext = await getExternalStorageDirectory();
            if (ext != null) targetDirPath = ext.path;
          }
        } else if (Platform.isIOS) {
          final docs = await getApplicationDocumentsDirectory();
          targetDirPath = docs.path;
        } else {
          try {
            final docs = await getApplicationDocumentsDirectory();
            targetDirPath = docs.path;
          } catch (_) {}
        }
      } catch (_) {
        // ignore and fall back to temp
      }

      final filename = 'receipt_${DateTime.now().millisecondsSinceEpoch}.jpg';

      // Consolidate all sources to bytes and then call the Android MediaStore
      // bridge when available so saved images appear in system Downloads/Gallery.
      Uint8List? bytes;
      String mime = 'image/jpeg';
      if (src.bytes != null) {
        bytes = src.bytes;
      } else if (src.filePath != null) {
        final srcf = File(src.filePath!);
        bytes = await srcf.readAsBytes();
      } else if (src.url != null) {
        final uri = Uri.parse(src.url!);
        final client = HttpClient();
        final req = await client.getUrl(uri);
        final res = await req.close();
        bytes = await consolidateHttpClientResponseBytes(res);
        // Try to detect mime from response headers
        try {
          final ct = res.headers.contentType;
          if (ct != null) mime = ct.mimeType;
        } catch (_) {}
      }

      if (bytes == null) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No image bytes available to save')),
          );
        return;
      }
      // Present location choices to the user: Pictures (Gallery), Downloads, Choose folder
      final chosen = await showDialog<String?>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Save to'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.photo),
                title: const Text('Pictures (Gallery)'),
                onTap: () => Navigator.of(context).pop('pictures'),
              ),
              ListTile(
                leading: const Icon(Icons.download),
                title: const Text('Downloads'),
                onTap: () => Navigator.of(context).pop('downloads'),
              ),
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: const Text('Choose folder...'),
                onTap: () => Navigator.of(context).pop('choose'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );

      if (chosen == null) return; // user cancelled

      if (Platform.isAndroid &&
          (chosen == 'pictures' || chosen == 'downloads')) {
        try {
          final savedUri = await _mediaStoreChannel.invokeMethod<String>(
            'saveImageToMediaStore',
            {
              'filename': filename,
              'bytes': bytes,
              'mime': mime,
              'target':
                  chosen, // MainActivity will default to Pictures if not provided
            },
          );
          if (savedUri != null && savedUri.isNotEmpty) {
            if (mounted)
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('Saved to $savedUri')));
            return;
          }
        } catch (e) {
          debugPrint('receipt gallery: media store save failed: $e');
          // fall back to file write
        }
      }

      if (chosen == 'choose') {
        try {
          // Use file_picker to pick a directory and write there
          final dir = await FilePicker.platform.getDirectoryPath();
          if (dir == null) return; // user cancelled
          // On older Android versions we must request WRITE_EXTERNAL_STORAGE before writing to external folders
          if (Platform.isAndroid && (await _needsLegacyStoragePermission())) {
            final ok = await _requestLegacyStoragePermission();
            if (!ok) {
              if (mounted)
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Storage permission required to save to chosen folder',
                    ),
                  ),
                );
              return;
            }
          }
          final dst = File('$dir/$filename');
          await dst.create(recursive: true);
          await dst.writeAsBytes(bytes);
          if (mounted)
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text('Saved to ${dst.path}')));
          return;
        } catch (e) {
          debugPrint('receipt gallery: choose folder save failed: $e');
        }
      }

      // Fallback: write to target directory (Downloads/Documents) and show path
      if (Platform.isAndroid && (await _needsLegacyStoragePermission())) {
        final ok = await _requestLegacyStoragePermission();
        if (!ok) {
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Storage permission required to save file'),
              ),
            );
          return;
        }
      }
      final dst = File('${targetDirPath}/${filename}');
      await dst.create(recursive: true);
      await dst.writeAsBytes(bytes);
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Saved to ${dst.path}')));
      return;
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  Future<void> _editCurrent(BuildContext context) async {
    // Let the user pick a replacement image and replace the currently-shown
    // image in the underlying expense row. We find the parent row as before
    // and then save the bytes using LocalReceiptService (preserving a
    // ReceiptUid when possible) and update the row metadata and UI.
    final src = _images[_curIndex];
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return; // user cancelled
    final newBytes = await picked.readAsBytes();

    // Determine which row this image belongs to. Prefer exact LocalReceiptPath
    // equality, but fall back to matching any ReceiptUids whose basename is
    // contained in the file path (useful when gallery scanned uid files but
    // the row's LocalReceiptPath wasn't populated).
    Map<String, dynamic>? targetRow;
    int? targetIndex;
    if (src.filePath != null) {
      final basename = p.basename(src.filePath!);
      for (int i = 0; i < widget.rows.length; i++) {
        final r = widget.rows[i];
        final lp = (r['LocalReceiptPath'] ?? '').toString();
        if (lp.isNotEmpty && lp == src.filePath) {
          targetRow = r;
          targetIndex = i;
          break;
        }
      }
      if (targetRow == null) {
        // Try matching by ReceiptUids substring in basename
        for (int i = 0; i < widget.rows.length; i++) {
          final r = widget.rows[i];
          if (r['ReceiptUids'] is List) {
            final ulist = List<String>.from(
              (r['ReceiptUids'] as List).whereType<String>(),
            );
            for (final uid in ulist) {
              if (uid.isNotEmpty &&
                  (basename == uid ||
                      basename.startsWith(uid) ||
                      basename.contains(uid))) {
                targetRow = r;
                targetIndex = i;
                break;
              }
            }
            if (targetRow != null) break;
          }
        }
      }
    }

    // If we didn't find a row via file matching, fall back to legacy per-row checks
    if (targetRow == null) {
      for (int i = 0; i < widget.rows.length; i++) {
        final r = widget.rows[i];
        // Match same ways as deletion/edit lookup
        try {
          if (src.bytes != null && r['ReceiptBytes'] is List) {
            final list = List<Uint8List>.from(r['ReceiptBytes'] as List);
            // Use content-equality for Uint8List, not reference equality
            final idx = list.indexWhere((b) => _bytesEqual(b, src.bytes!));
            if (idx >= 0) {
              final oldPath = (r['LocalReceiptPath'] ?? '').toString();
              list[idx] = newBytes;
              r['ReceiptBytes'] = list;
              await _appendReplaceDebugLog({
                'action': 'replace_memory',
                'docId': (r['id'] ?? r['docId'] ?? '').toString(),
                'oldPath': oldPath,
                'bytesNew': newBytes.length,
              });
              if (widget.onReplace != null) {
                await widget.onReplace!(r);
              } else if (widget.onEdit != null) {
                await widget.onEdit!(r);
              }
              setState(() => _images[_curIndex] = _ImgSrc.memory(newBytes));
              return;
            }
          }
          if (src.bytes != null &&
              r['Receipt'] is Uint8List &&
              r['Receipt'] == src.bytes) {
            r['Receipt'] = newBytes;
            await _appendReplaceDebugLog({
              'action': 'replace_single_memory',
              'docId': (r['id'] ?? r['docId'] ?? '').toString(),
              'bytesNew': newBytes.length,
            });
            _queueUndo({
              'type': 'replace',
              'srcKind': 'memorySingle',
              'rowIndex': i,
              'bytesOld': src.bytes,
              'galleryIndex': _curIndex,
            }, 'Replaced image');
            if (widget.onReplace != null) {
              await widget.onReplace!(r);
            } else if (widget.onEdit != null) {
              await widget.onEdit!(r);
            }
            setState(() => _images[_curIndex] = _ImgSrc.memory(newBytes));
            return;
          }
        } catch (e) {
          debugPrint(
            'receipt gallery: edit attempt failed in fallback matching: $e',
          );
        }
      }
    }

    // If we found a target row via path/uid matching, perform the appropriate replacement
    if (targetRow != null && targetIndex != null) {
      final r = targetRow;
      try {
        // Preserve accountId
        final box = Hive.isBoxOpen('budgetBox')
            ? Hive.box('budgetBox')
            : await Hive.openBox('budgetBox');
        final uid4 = FirebaseAuth.instance.currentUser?.uid;
        final k4 = uid4 != null ? 'accountId_$uid4' : 'accountId';
        final accountIdRaw =
            (box.get(k4) ?? box.get('accountId') ?? '') as String;
        final accountId = accountIdRaw.isNotEmpty
            ? accountIdRaw
            : 'unknown_account';

        // Try to find a matchedUid from the row's ReceiptUids
        String? matchedUid;
        final hasUidsList =
            r['ReceiptUids'] is List &&
            (r['ReceiptUids'] as List).whereType<String>().isNotEmpty;
        if (hasUidsList && accountIdRaw.isNotEmpty) {
          final ulist = List<String>.from(
            (r['ReceiptUids'] as List).whereType<String>(),
          );
          final basename = p.basename(src.filePath!);
          for (final uid in ulist) {
            if (basename == uid ||
                basename.startsWith(uid) ||
                basename.contains(uid)) {
              matchedUid = uid;
              break;
            }
            try {
              final expected = await LocalReceiptService().pathForReceiptUid(
                accountId: accountId,
                collection: widget.collection,
                receiptUid: uid,
              );
              if (expected == src.filePath) {
                matchedUid = uid;
                break;
              }
            } catch (_) {}
          }
        }

        // If still not matched, attempt to derive uid from the filename stem.
        // Do not require the computed expected path to exactly equal the current
        // file path (extensions/normalization may differ). We'll accept the stem
        // as the UID and migrate the row to use this UID moving forward.
        if (matchedUid == null && src.filePath != null) {
          final stem = p.basenameWithoutExtension(src.filePath!);
          if (stem.isNotEmpty) {
            matchedUid = stem;
            // Ensure the row lists this uid so future operations are consistent
            final uids = List<String>.from(
              (r['ReceiptUids'] as List?)?.whereType<String>() ??
                  const <String>[],
            );
            if (!uids.contains(stem)) {
              uids.add(stem);
              r['ReceiptUids'] = uids;
            }
          }
        }

        final docId = (r['id'] ?? r['Id'] ?? r['docId'] ?? '').toString();
        // If still not matched, allow a safe fallback only when there are no
        // ReceiptUids and the current file equals the preview path. Otherwise require uid.
        final previewPath = (r['LocalReceiptPath'] ?? '').toString();
        final allowDocFallback =
            matchedUid == null && !hasUidsList && src.filePath == previewPath;

        String savedPath;
        final oldFilePath = src.filePath; // used for cache eviction and cleanup
        if (matchedUid != null) {
          savedPath = await LocalReceiptService().saveReceipt(
            accountId: accountId,
            collection: widget.collection,
            docId: docId,
            bytes: newBytes,
            receiptUid: matchedUid,
          );
        } else if (allowDocFallback) {
          savedPath = await LocalReceiptService().saveReceipt(
            accountId: accountId,
            collection: widget.collection,
            docId: docId,
            bytes: newBytes,
          );
        } else {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  'Could not resolve this image to the record. Replace aborted.',
                ),
              ),
            );
          }
          return;
        }

        // Update metadata on the resolved row
        // Only move preview path if we replaced the same file the preview refers to
        final curPreview = (r['LocalReceiptPath'] ?? '').toString();
        if (curPreview == src.filePath) {
          r['LocalReceiptPath'] = savedPath;
        }
        // Do not touch in-memory fields for multi-image records
        // r['Receipt'] is left unchanged for multi-image flows
        // If we did not preserve a matchedUid, clear ReceiptUids so the
        // gallery will prefer the LocalReceiptPath instead of resolving
        // stale uid-based files that may still point to old images.
        // (Not applicable here since we require matchedUid)

        await _appendReplaceDebugLog({
          'action': 'replace_file',
          'docId': docId,
          'matchedUid': matchedUid,
          'newPath': savedPath,
          'bytesNew': newBytes.length,
        });

        // Prepare Undo using old file bytes
        try {
          Uint8List? oldBytes;
          if (src.bytes != null) {
            oldBytes = src.bytes;
          } else if (src.filePath != null) {
            oldBytes = await File(src.filePath!).readAsBytes();
          }
          if (oldBytes != null) {
            _queueUndo({
              'type': 'replace',
              'srcKind': 'file',
              'rowIndex': targetIndex,
              'bytesOld': oldBytes,
              'matchedUid': matchedUid,
              'galleryIndex': _curIndex,
            }, 'Replaced image');
          }
        } catch (_) {}

        if (widget.onReplace != null) {
          await widget.onReplace!(r);
        } else if (widget.onEdit != null) {
          await widget.onEdit!(r);
        }

        try {
          // Evict both new and old paths to ensure fresh render
          PaintingBinding.instance.imageCache.evict(FileImage(File(savedPath)));
          if (oldFilePath != null && oldFilePath != savedPath) {
            PaintingBinding.instance.imageCache.evict(
              FileImage(File(oldFilePath)),
            );
          }
        } catch (_) {}
        // If we migrated from a different on-disk path (e.g., jpeg -> jpg),
        // remove the old file to avoid duplicates appearing later.
        if (oldFilePath != null && oldFilePath != savedPath) {
          try {
            final f = File(oldFilePath);
            if (await f.exists()) {
              await f.delete();
            }
          } catch (_) {}
        }
        setState(() => _images[_curIndex] = _ImgSrc.file(savedPath));
        return;
      } catch (e) {
        debugPrint('receipt gallery: edit failed for resolved target row: $e');
      }
    }
  }

  Future<void> _deleteCurrent(BuildContext context) async {
    final src = _images[_curIndex];
    for (int i = 0; i < widget.rows.length; i++) {
      final r = widget.rows[i];
      bool changed = false;
      // Remove from plural ReceiptBytes
      if (src.bytes != null && r['ReceiptBytes'] is List) {
        final list = (r['ReceiptBytes'] as List)
            .whereType<Uint8List>()
            .toList();
        final idx = list.indexWhere((e) => _bytesEqual(e, src.bytes!));
        if (idx != -1) {
          list.removeAt(idx);
          r['ReceiptBytes'] = list;
          changed = true;
          try {
            debugPrint(
              'gallery delete: removed from memory list at index=$idx for row=${(r['id'] ?? '').toString()}',
            );
          } catch (_) {}
        }
      }
      // Remove single Receipt
      if (!changed && src.bytes != null && r['Receipt'] is Uint8List) {
        final single = r['Receipt'] as Uint8List;
        if (_bytesEqual(single, src.bytes!)) {
          r['Receipt'] = null;
          changed = true;
          try {
            debugPrint(
              'gallery delete: removed single in-memory receipt for row=${(r['id'] ?? '').toString()}',
            );
          } catch (_) {}
        }
      }
      // Remove file path
      final lp = (r['LocalReceiptPath'] ?? '').toString();
      if (!changed && src.filePath != null && lp == src.filePath) {
        // Try to delete the underlying file if it corresponds to a ReceiptUid.
        try {
          final box = Hive.isBoxOpen('budgetBox')
              ? Hive.box('budgetBox')
              : await Hive.openBox('budgetBox');
          final uid5 = FirebaseAuth.instance.currentUser?.uid;
          final k5 = uid5 != null ? 'accountId_$uid5' : 'accountId';
          final accountId =
              (box.get(k5) ?? box.get('accountId') ?? '') as String;
          if (accountId.isNotEmpty) {
            // If the row has ReceiptUids, try to find which uid maps to this path and delete it.
            if (r['ReceiptUids'] is List) {
              final ulist = List<String>.from(
                (r['ReceiptUids'] as List).whereType<String>(),
              );
              String? matchedUid;
              for (final uid in ulist) {
                try {
                  final expected = await LocalReceiptService()
                      .pathForReceiptUid(
                        accountId: accountId,
                        collection: widget.collection,
                        receiptUid: uid,
                      );
                  if (expected == src.filePath) {
                    matchedUid = uid;
                    break;
                  }
                } catch (_) {}
              }
              // Fallback: also try matching by basename containing the uid
              if (matchedUid == null && src.filePath != null) {
                final base = p.basename(src.filePath!);
                for (final uid in ulist) {
                  if (base == uid ||
                      base.startsWith(uid) ||
                      base.contains(uid)) {
                    matchedUid = uid;
                    break;
                  }
                }
              }
              if (matchedUid != null) {
                // delete the file
                try {
                  final docId = (r['id'] ?? r['Id'] ?? r['docId'] ?? '')
                      .toString();
                  await LocalReceiptService().deleteReceipt(
                    accountId: accountId,
                    collection: widget.collection,
                    docId: docId,
                    receiptUid: matchedUid,
                  );
                } catch (_) {}

                // remove the uid from the row
                final newUlist = List.from(ulist);
                newUlist.remove(matchedUid);
                r['ReceiptUids'] = newUlist;
                // update LocalReceiptPath: if no uids left, clear path, otherwise set to first remaining uid path
                if (newUlist.isEmpty) {
                  r['LocalReceiptPath'] = null;
                } else {
                  try {
                    final firstPath = await LocalReceiptService()
                        .pathForReceiptUid(
                          accountId: accountId,
                          collection: widget.collection,
                          receiptUid: newUlist.first,
                        );
                    r['LocalReceiptPath'] = firstPath;
                  } catch (_) {
                    r['LocalReceiptPath'] = null;
                  }
                }
                changed = true;
                try {
                  debugPrint(
                    'gallery delete: deleted file by matched uid=$matchedUid (by LocalReceiptPath equality or basename) for row=${(r['id'] ?? '').toString()}',
                  );
                } catch (_) {}
              } else {
                // We have ReceiptUids but none matched the current file path.
                // To be safe, DO NOT delete by docId (it may remove other images).
                // If the preview path equals current, clear preview only; keep uids intact.
                if (lp == src.filePath) {
                  r['LocalReceiptPath'] = null;
                  changed = true;
                  try {
                    debugPrint(
                      'gallery delete: no uid matched current file; cleared preview only for row=${(r['id'] ?? '').toString()}',
                    );
                  } catch (_) {}
                }
              }
            } else {
              // No ReceiptUids - attempt delete by docId path
              try {
                final docId = (r['id'] ?? r['Id'] ?? r['docId'] ?? '')
                    .toString();
                await LocalReceiptService().deleteReceipt(
                  accountId: accountId,
                  collection: widget.collection,
                  docId: docId,
                );
              } catch (_) {}
              r['LocalReceiptPath'] = null;
              changed = true;
              try {
                debugPrint(
                  'gallery delete: deleted by docId (no ReceiptUids present) for row=${(r['id'] ?? '').toString()}',
                );
              } catch (_) {}
            }
          } else {
            // accountId empty: just clear the LocalReceiptPath metadata
            r['LocalReceiptPath'] = null;
            changed = true;
            try {
              debugPrint(
                'gallery delete: accountId empty; cleared LocalReceiptPath only for row=${(r['id'] ?? '').toString()}',
              );
            } catch (_) {}
          }
        } catch (_) {
          // On any failure just clear metadata so UI reflects deletion
          r['LocalReceiptPath'] = null;
          changed = true;
          try {
            debugPrint(
              'gallery delete: exception clearing file-backed image; cleared LocalReceiptPath for row=${(r['id'] ?? '').toString()}',
            );
          } catch (_) {}
        }
      }
      // If the file-backed image is not equal to LocalReceiptPath, attempt matching by ReceiptUids
      if (!changed &&
          src.filePath != null &&
          lp != src.filePath &&
          r['ReceiptUids'] is List) {
        try {
          final box = Hive.isBoxOpen('budgetBox')
              ? Hive.box('budgetBox')
              : await Hive.openBox('budgetBox');
          final uid6 = FirebaseAuth.instance.currentUser?.uid;
          final k6 = uid6 != null ? 'accountId_$uid6' : 'accountId';
          final accountId =
              (box.get(k6) ?? box.get('accountId') ?? '') as String;
          final ulist = List<String>.from(
            (r['ReceiptUids'] as List).whereType<String>(),
          );
          String? matchedUid;
          // Prefer exact path match when accountId available
          if (accountId.isNotEmpty) {
            for (final uid in ulist) {
              try {
                final expected = await LocalReceiptService().pathForReceiptUid(
                  accountId: accountId,
                  collection: widget.collection,
                  receiptUid: uid,
                );
                if (expected == src.filePath) {
                  matchedUid = uid;
                  break;
                }
              } catch (_) {}
            }
          }
          // Fallback: match by basename containing uid regardless of accountId
          if (matchedUid == null) {
            final base = p.basename(src.filePath!);
            for (final uid in ulist) {
              if (base == uid || base.startsWith(uid) || base.contains(uid)) {
                matchedUid = uid;
                break;
              }
            }
          }
          if (matchedUid != null) {
            // Delete the file: prefer LocalReceiptService when accountId known, else delete directly
            try {
              final docId = (r['id'] ?? r['Id'] ?? r['docId'] ?? '').toString();
              if (accountId.isNotEmpty) {
                await LocalReceiptService().deleteReceipt(
                  accountId: accountId,
                  collection: widget.collection,
                  docId: docId,
                  receiptUid: matchedUid,
                );
              } else {
                // Best-effort direct deletion when we can't compute expected path
                final f = File(src.filePath!);
                if (await f.exists()) {
                  await f.delete();
                }
              }
            } catch (_) {}
            final newUlist = List.from(ulist);
            newUlist.remove(matchedUid);
            r['ReceiptUids'] = newUlist;
            // If LocalReceiptPath also pointed to this file (rare in this branch), update it
            if (lp == src.filePath) {
              if (newUlist.isEmpty) {
                r['LocalReceiptPath'] = null;
              } else if (accountId.isNotEmpty) {
                try {
                  final firstPath = await LocalReceiptService()
                      .pathForReceiptUid(
                        accountId: accountId,
                        collection: widget.collection,
                        receiptUid: newUlist.first,
                      );
                  r['LocalReceiptPath'] = firstPath;
                } catch (_) {
                  r['LocalReceiptPath'] = null;
                }
              }
            }
            changed = true;
            try {
              debugPrint(
                'gallery delete: deleted uid=$matchedUid by uid-path/basename match (path != preview) for row=${(r['id'] ?? '').toString()}',
              );
            } catch (_) {}
          }
        } catch (_) {}
      }
      // Remove from ReceiptUrls/ReceiptUrl
      if (!changed && src.url != null && r['ReceiptUrls'] is List) {
        final urls = List.from(r['ReceiptUrls'] as List);
        if (urls.remove(src.url)) {
          r['ReceiptUrls'] = urls;
          changed = true;
          try {
            debugPrint(
              'gallery delete: removed from url list for row=${(r['id'] ?? '').toString()}',
            );
          } catch (_) {}
        }
      }
      if (!changed && src.url != null && (r['ReceiptUrl'] ?? '') == src.url) {
        r['ReceiptUrl'] = '';
        changed = true;
        try {
          debugPrint(
            'gallery delete: cleared single url for row=${(r['id'] ?? '').toString()}',
          );
        } catch (_) {}
      }
      if (changed) {
        // Prepare undo payloads based on source kind
        if (src.bytes != null && r['ReceiptBytes'] is List) {
          _queueUndo({
            'type': 'delete',
            'srcKind': 'memoryList',
            'rowIndex': i,
            // We do not track exact original index here; re-insert near current
            'listIndex': (r['ReceiptBytes'] as List).length,
            'bytesOld': src.bytes,
            'galleryIndex': _curIndex,
          }, 'Image deleted');
        } else if (src.bytes != null) {
          _queueUndo({
            'type': 'delete',
            'srcKind': 'memorySingle',
            'rowIndex': i,
            'bytesOld': src.bytes,
            'galleryIndex': _curIndex,
          }, 'Image deleted');
        } else if (src.url != null) {
          final urls = (r['ReceiptUrls'] as List?)?.cast<String>();
          final urlIndex = urls?.indexOf(src.url!);
          _queueUndo({
            'type': 'delete',
            'srcKind': (urls != null) ? 'urlList' : 'urlSingle',
            'rowIndex': i,
            'url': src.url,
            'urlIndex': urlIndex,
            'galleryIndex': _curIndex,
          }, 'Image deleted');
        } else if (src.filePath != null) {
          Uint8List? bytes;
          try {
            bytes = await File(src.filePath!).readAsBytes();
          } catch (_) {}
          List<String> prevUids = [];
          if (r['ReceiptUids'] is List) {
            prevUids = List<String>.from(
              (r['ReceiptUids'] as List).whereType<String>(),
            );
          }
          String? matchedUid;
          try {
            final box = Hive.isBoxOpen('budgetBox')
                ? Hive.box('budgetBox')
                : await Hive.openBox('budgetBox');
            final uid7 = FirebaseAuth.instance.currentUser?.uid;
            final k7 = uid7 != null ? 'accountId_$uid7' : 'accountId';
            final accountId =
                (box.get(k7) ?? box.get('accountId') ?? '') as String;
            if (accountId.isNotEmpty) {
              for (final uid in prevUids) {
                final expected = await LocalReceiptService().pathForReceiptUid(
                  accountId: accountId,
                  collection: widget.collection,
                  receiptUid: uid,
                );
                if (expected == src.filePath) {
                  matchedUid = uid;
                  break;
                }
                // Also allow fallback by basename for undo accuracy
                if (matchedUid == null && src.filePath != null) {
                  final base = p.basename(src.filePath!);
                  if (base == uid ||
                      base.startsWith(uid) ||
                      base.contains(uid)) {
                    matchedUid = uid;
                    break;
                  }
                }
              }
            }
          } catch (_) {}
          _queueUndo({
            'type': 'delete',
            'srcKind': matchedUid != null ? 'fileUid' : 'fileDoc',
            'rowIndex': i,
            'bytesOld': bytes,
            'receiptUid': matchedUid,
            'prevReceiptUids': prevUids,
            'galleryIndex': _curIndex,
          }, 'Image deleted');
        }
        // Evict any cached image for the deleted file to refresh UI immediately
        if (src.filePath != null) {
          try {
            PaintingBinding.instance.imageCache.evict(
              FileImage(File(src.filePath!)),
            );
          } catch (_) {}
        }
        // Notify via onEdit if provided
        if (widget.onEdit != null) await widget.onEdit!(r);
        // Update UI list and images
        setState(() {
          _images.removeAt(_curIndex);
          if (_images.isEmpty) {
            // Close the gallery when no images remain
            Navigator.of(context).pop();
            return;
          }
          if (_curIndex >= _images.length) _curIndex = _images.length - 1;
        });
        return;
      }
    }
  }
}

class _ImgSrc {
  final String? filePath;
  final String? url;
  final Uint8List? bytes;

  _ImgSrc.file(this.filePath) : url = null, bytes = null;
  _ImgSrc.network(this.url) : filePath = null, bytes = null;
  _ImgSrc.memory(this.bytes) : filePath = null, url = null;

  T when<T>({
    required T Function(String path) file,
    required T Function(String url) network,
    required T Function(Uint8List bytes) memory,
  }) {
    if (bytes != null) return memory(bytes!);
    if (filePath != null) return file(filePath!);
    return network(url!);
  }
}
