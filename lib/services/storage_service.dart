import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';
import 'dart:io';
import 'package:budgetbuddy/services/local_receipt_service.dart';

class StorageService {
  final FirebaseStorage _storage = FirebaseStorage.instance;

  Future<String> uploadReceipt({
    required String accountId,
    required String collection, // 'expenses' or 'savings'
    required String docId, // provisional or Firestore-generated id
    required Uint8List bytes,
    String contentType = 'image/jpeg',
    String? receiptUid,
  }) async {
    final filename = (receiptUid != null && receiptUid.isNotEmpty)
        ? '$receiptUid.jpg'
        : '$docId.jpg';
    final ref = _storage.ref().child(
      'receipts/$accountId/$collection/$filename',
    );
    final task = await ref.putData(
      bytes,
      SettableMetadata(contentType: contentType),
    );
    return await task.ref.getDownloadURL();
  }

  /// Upload multiple receipts identified by their stable [receiptUids].
  /// Returns a list of maps with keys: 'uid' and 'url'.
  Future<List<Map<String, String>>> uploadReceipts({
    required String accountId,
    required String collection,
    required List<String> receiptUids,
    String contentType = 'image/jpeg',
  }) async {
    final lrs = LocalReceiptService();
    final results = <Map<String, String>>[];
    for (final uid in receiptUids) {
      try {
        final path = await lrs.pathForReceiptUid(
          accountId: accountId,
          collection: collection,
          receiptUid: uid,
        );
        final f = File(path);
        if (!await f.exists()) continue;
        final bytes = await f.readAsBytes();
        final url = await uploadReceipt(
          accountId: accountId,
          collection: collection,
          docId: uid, // docId not used when receiptUid is provided in filename
          bytes: bytes,
          contentType: contentType,
          receiptUid: uid,
        );
        results.add({'uid': uid, 'url': url});
      } catch (_) {
        // Ignore individual failures; caller can decide to retry
      }
    }
    return results;
  }
}
