import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;

class LocalReceiptService {
  Future<String> _baseDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final base = Directory('${dir.path}/receipts');
    if (!await base.exists()) {
      await base.create(recursive: true);
    }
    return base.path;
  }

  Future<String> _receiptPath({
    required String accountId,
    required String collection,
    required String docId,
  }) async {
    final base = await _baseDir();
    final dir = Directory('$base/$accountId/$collection');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return '${dir.path}/$docId.jpg';
  }

  // Optional: a stable path keyed by a durable receipt uid instead of doc id.
  Future<String> _receiptPathByUid({
    required String accountId,
    required String collection,
    required String receiptUid,
  }) async {
    final base = await _baseDir();
    final dir = Directory('$base/$accountId/$collection');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  return '${dir.path}/$receiptUid.jpg';
  }

  // Public helper: compute the expected local file path for a given receipt UID.
  Future<String> pathForReceiptUid({
    required String accountId,
    required String collection,
    required String receiptUid,
  }) async {
    return _receiptPathByUid(
      accountId: accountId,
      collection: collection,
      receiptUid: receiptUid,
    );
  }

  // Save bytes to a deterministic local file and return its path.
  Future<String> saveReceipt({
    required String accountId,
    required String collection,
    required String docId,
    required Uint8List bytes,
    String? receiptUid,
  }) async {
    final path = receiptUid != null && receiptUid.isNotEmpty
        ? await _receiptPathByUid(
            accountId: accountId,
            collection: collection,
            receiptUid: receiptUid,
          )
        : await _receiptPath(
            accountId: accountId,
            collection: collection,
            docId: docId,
          );
    // Try to decode, normalize orientation, optionally resize, and re-encode JPEG.
    Uint8List out = bytes;
    try {
      final decodedRaw = img.decodeImage(bytes);
      if (decodedRaw != null) {
        // Normalize orientation and downscale if very large
        img.Image normalized;
        try {
          normalized = img.bakeOrientation(decodedRaw);
        } catch (_) {
          normalized = decodedRaw;
        }
        const int maxDim = 1600; // cap longer side to 1600px
        final int w = normalized.width;
        final int h = normalized.height;
        img.Image finalImg = normalized;
        if (w > maxDim || h > maxDim) {
          final scale = w >= h ? maxDim / w : maxDim / h;
          final newW = (w * scale).round();
          final newH = (h * scale).round();
          finalImg = img.copyResize(normalized, width: newW, height: newH);
        }
        final jpg = img.encodeJpg(finalImg, quality: 85);
        out = Uint8List.fromList(jpg);
      }
    } catch (_) {
      // Fall back to raw bytes if decode fails.
    }
    final f = File(path);
    await f.writeAsBytes(out, flush: true);
    return path;
  }

  Future<void> deleteReceipt({
    required String accountId,
    required String collection,
    required String docId,
    String? receiptUid,
  }) async {
    // Try common extensions to avoid orphan files if encoding policy changes.
    final base = await _baseDir();
    final dir = Directory('$base/$accountId/$collection');
    final candidates = <String>[
      '${dir.path}/$docId.jpg',
      '${dir.path}/$docId.jpeg',
      '${dir.path}/$docId.png',
      '${dir.path}/$docId.webp',
      if (receiptUid != null && receiptUid.isNotEmpty) ...[
        '${dir.path}/$receiptUid.jpg',
        '${dir.path}/$receiptUid.jpeg',
        '${dir.path}/$receiptUid.png',
        '${dir.path}/$receiptUid.webp',
      ]
    ];
    for (final p in candidates) {
      final f = File(p);
      if (await f.exists()) {
        await f.delete();
      }
    }
  }
}
