import 'dart:typed_data';

import 'package:firebase_storage/firebase_storage.dart';

class StorageService {
  final FirebaseStorage _storage = FirebaseStorage.instance;

  Future<String> uploadReceipt({
    required String accountId,
    required String collection, // 'expenses' or 'savings'
    required String docId, // provisional or Firestore-generated id
    required Uint8List bytes,
    String contentType = 'image/jpeg',
  }) async {
    final ref = _storage.ref().child(
      'receipts/$accountId/$collection/$docId.jpg',
    );
    final task = await ref.putData(
      bytes,
      SettableMetadata(contentType: contentType),
    );
    return await task.ref.getDownloadURL();
  }
}
