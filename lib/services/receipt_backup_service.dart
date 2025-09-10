import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

import 'local_receipt_service.dart';
import 'shared_account_repository.dart';

class ReceiptBackupService {
  final String accountId;
  final SharedAccountRepository repo;
  ReceiptBackupService({required this.accountId, required this.repo});

  // Export: create a receipts manifest and ensure local files exist, returning the folder used
  Future<Directory> exportAll({
    String subfolderName = 'bb_receipts_backup',
  }) async {
    final docs = await getApplicationDocumentsDirectory();
    final outDir = Directory('${docs.path}/$subfolderName/$accountId');
    await outDir.create(recursive: true);

    final local = LocalReceiptService();

    final expenses = await repo.fetchAllExpensesOnce();
    final savings = await repo.fetchAllSavingsOnce();
    List<Map<String, dynamic>> orRows = const [];
    try {
      orRows = await repo.fetchAllOrOnce();
    } catch (_) {
      // ignore if rules missing yet
    }

  final manifest = <String, Map<String, dynamic>>{}; // uid -> meta

    Future<void> addRow(String collection, Map<String, dynamic> row) async {
      final uid = (row['ReceiptUid'] ?? row['receiptUid'] ?? '').toString();
      if (uid.isEmpty) return;
      // Copy/ensure local file exists using uid path
      final src = await local.pathForReceiptUid(
        accountId: accountId,
        collection: collection,
        receiptUid: uid,
      );
      final srcFile = File(src);
      if (await srcFile.exists()) {
        final dest = File('${outDir.path}/$collection/$uid.jpg');
        await dest.parent.create(recursive: true);
        await srcFile.copy(dest.path);
      }
      manifest[uid] = {
        'collection': collection,
        'docId': (row['id'] ?? '').toString(),
        'category': row['Category'],
        'subcategory': row['Subcategory'],
        'amount': row['Amount'],
        'date': row['Date'],
            'validUntil': row['ValidUntil'],
        'note': row['Note'],
      };
    }

    for (final r in expenses) {
      await addRow('expenses', r);
    }
  for (final r in savings) { await addRow('savings', r); }
  for (final r in orRows) { await addRow('or', r); }

    // Custom tabs: iterate tabs and include records
    try {
      final tabs = await repo.fetchAllCustomTabsOnce();
      for (final t in tabs) {
        final tabId = (t['id'] ?? '').toString();
        if (tabId.isEmpty) continue;
        final records = await repo.fetchAllCustomTabRecordsOnce(tabId);
        for (final r in records) {
          final uid = (r['ReceiptUid'] ?? '').toString();
          if (uid.isEmpty) continue;
          final src = await local.pathForReceiptUid(
            accountId: accountId,
            collection: 'custom_$tabId',
            receiptUid: uid,
          );
          final srcFile = File(src);
          if (await srcFile.exists()) {
            final dest = File('${outDir.path}/custom_$tabId/$uid.jpg');
            await dest.parent.create(recursive: true);
            await srcFile.copy(dest.path);
          }
          manifest[uid] = {
            'collection': 'custom_$tabId',
            'docId': (r['id'] ?? '').toString(),
            'title': r['Title'],
            'amount': r['Amount'],
            'date': r['Date'],
            'note': r['Note'],
          };
        }
      }
    } catch (_) {
      // best-effort; ignore if rules disallow listing or offline
    }

    final manifestFile = File('${outDir.path}/manifest.json');
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
    );
    return outDir;
  }

  // Import: read manifest and place any found files into the expected local cache paths
  // Returns a list of reconciled entries for optional UI logs.
  Future<List<Map<String, dynamic>>> importAll(Directory sourceDir) async {
    final manifestFile = File('${sourceDir.path}/manifest.json');
    if (!await manifestFile.exists()) return [];
    final manifestRaw =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    final results = <Map<String, dynamic>>[];
    final local = LocalReceiptService();

    for (final entry in manifestRaw.entries) {
      final uid = entry.key;
      final meta = entry.value as Map<String, dynamic>;
      final collection = (meta['collection'] ?? '').toString();
  final isStd = collection == 'expenses' || collection == 'savings' || collection == 'or';
  final isCustom = collection.startsWith('custom_');
  if (!isStd && !isCustom) continue;

  final file = File('${sourceDir.path}/$collection/$uid.jpg');
      if (!await file.exists()) {
        results.add({'receiptUid': uid, 'status': 'skipped_no_file'});
        continue;
      }

      // Place into the cache path keyed by receiptUid
      final destPath = await local.pathForReceiptUid(
        accountId: accountId,
        collection: collection,
        receiptUid: uid,
      );
      await File(destPath).parent.create(recursive: true);
      await file.copy(destPath);

      // Try to map to an existing Firestore doc id by uid
      final foundDocId = await repo.findDocIdByReceiptUid(
        collection: collection,
        receiptUid: uid,
      );
      results.add({
        'receiptUid': uid,
        'collection': collection,
        'docId': foundDocId,
        'localPath': destPath,
        'status': foundDocId == null ? 'cached_only' : 'attached_by_uid',
      });
    }

    return results;
  }
}
