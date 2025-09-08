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

  // Save bytes to a deterministic local file and return its path.
  Future<String> saveReceipt({
    required String accountId,
    required String collection,
    required String docId,
    required Uint8List bytes,
  }) async {
    final path = await _receiptPath(
      accountId: accountId,
      collection: collection,
      docId: docId,
    );
    // Try to decode and re-encode as JPEG to improve compatibility and size.
    Uint8List out = bytes;
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded != null) {
        final jpg = img.encodeJpg(decoded, quality: 85);
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
  }) async {
    // Try common extensions to avoid orphan files if encoding policy changes.
    final base = await _baseDir();
    final dir = Directory('$base/$accountId/$collection');
    final candidates = <String>[
      '${dir.path}/$docId.jpg',
      '${dir.path}/$docId.jpeg',
      '${dir.path}/$docId.png',
      '${dir.path}/$docId.webp',
    ];
    for (final p in candidates) {
      final f = File(p);
      if (await f.exists()) {
        await f.delete();
      }
    }
  }
}
