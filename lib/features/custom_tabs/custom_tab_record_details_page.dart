import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:budgetbuddy/widgets/app_gradient_background.dart';
import 'package:budgetbuddy/widgets/pressable_neumorphic.dart';
import 'package:budgetbuddy/features/expenses/receipt_gallery_page.dart';
import 'package:budgetbuddy/services/local_receipt_service.dart';
import 'custom_tab_record_edit_page.dart';

class CustomTabRecordDetailsPage extends StatelessWidget {
  final String accountId;
  final String tabId;
  final Map<String, dynamic> record;
  final Future<void> Function(Map<String, dynamic> updated)? onUpdate;
  const CustomTabRecordDetailsPage({
    super.key,
    required this.accountId,
    required this.tabId,
    required this.record,
    this.onUpdate,
  });

  String _fmtAmount(num? v) {
    if (v == null) return '₱ 0.00';
    final d = NumberFormat.currency(locale: 'en_PH', symbol: '₱ ').format(v);
    return d;
  }

  List<Map<String, dynamic>> _rowsForGallery(Map<String, dynamic> r) {
    // Build rows compatible with ReceiptGalleryPage: support multi and single sources
    final List<Map<String, dynamic>> rows = [];
    // Multi bytes
    if (r['ReceiptBytes'] is List && (r['ReceiptBytes'] as List).isNotEmpty) {
      for (final b in (r['ReceiptBytes'] as List)) {
        if (b is Uint8List)
          rows.add({
            'ReceiptBytes': [b],
            'id': r['id'],
          });
      }
    } else if (r['Receipt'] is Uint8List) {
      rows.add({'Receipt': r['Receipt'], 'id': r['id']});
    }
    // Local file preview
    final lp = (r['LocalReceiptPath'] ?? '').toString();
    if (lp.isNotEmpty) rows.add({'LocalReceiptPath': lp, 'id': r['id']});
    // ReceiptUids (resolved by gallery)
    final uids = (r['ReceiptUids'] is List)
        ? (r['ReceiptUids'] as List).whereType<String>().toList()
        : <String>[];
    if (uids.isNotEmpty) rows.add({'ReceiptUids': uids, 'id': r['id']});
    // URLs
    final urls = (r['ReceiptUrls'] is List)
        ? (r['ReceiptUrls'] as List).whereType<String>().toList()
        : <String>[];
    if (urls.isNotEmpty) rows.add({'ReceiptUrls': urls, 'id': r['id']});
    final url = (r['ReceiptUrl'] ?? '').toString();
    if (url.isNotEmpty) rows.add({'ReceiptUrl': url, 'id': r['id']});
    if (rows.isEmpty) rows.add(r);
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final r = Map<String, dynamic>.from(record);
    final title = (r['Title'] ?? r['Category'] ?? 'Untitled').toString();
    final amount = (r['Amount'] as num?) ?? 0.0;
    final date = (r['Date'] ?? '').toString();
    final note = (r['Note'] ?? '').toString();

    final hasAnyAttachment = () {
      if (r['Receipt'] is Uint8List) return true;
      if (r['ReceiptBytes'] is List && (r['ReceiptBytes'] as List).isNotEmpty) {
        return true;
      }
      if ((r['LocalReceiptPath'] ?? '').toString().isNotEmpty) return true;
      if (r['ReceiptUids'] is List && (r['ReceiptUids'] as List).isNotEmpty) {
        return true;
      }
      if ((r['ReceiptUrl'] ?? '').toString().isNotEmpty) return true;
      if (r['ReceiptUrls'] is List && (r['ReceiptUrls'] as List).isNotEmpty) {
        return true;
      }
      return false;
    }();

    return AppGradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          title: const Text('Record Details'),
          actions: [
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () async {
                final updated = await Navigator.push<Map<String, dynamic>>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CustomTabRecordEditPage(
                      accountId: accountId,
                      tabId: tabId,
                      record: r,
                      repo: null, // host will handle stream updates if needed
                    ),
                  ),
                );
                if (updated != null && context.mounted) {
                  Navigator.pop(context, updated);
                }
              },
            ),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: const Text('Delete record?'),
                    content: const Text(
                      'This will permanently remove the record from this tab.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(d).pop(false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(d).pop(true),
                        child: const Text(
                          'Delete',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  Navigator.pop(context, {'_deleted': true, 'id': r['id']});
                }
              },
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            24,
            MediaQuery.of(context).padding.top + kToolbarHeight + 16,
            24,
            24,
          ),
          child: PressableNeumorphic(
            borderRadius: 16,
            padding: const EdgeInsets.all(16),
            useSurfaceBase: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Title styled similarly to OR details header
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                // Amount row matches OR details row typography (no special color)
                _row(context, 'Amount', _fmtAmount(amount)),
                _row(context, 'Date', date),
                if (note.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _row(context, 'Note', note),
                ],
                const SizedBox(height: 16),
                // Inline receipt preview (matches OR details behavior)
                Center(child: _inlineReceiptPreview(context, r)),
                const SizedBox(height: 12),
                if (hasAnyAttachment)
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        final rows = _rowsForGallery(r);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ReceiptGalleryPage(
                              rows: rows,
                              resolveRows: rows,
                              collection: 'custom_$tabId',
                              initialIndex: 0,
                              onEdit: onUpdate,
                              onReplace: onUpdate,
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('View Receipts'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _inlineReceiptPreview(BuildContext context, Map<String, dynamic> rec) {
    final localPath = (rec['LocalReceiptPath'] ?? '').toString();
    final singleUrl = (rec['ReceiptUrl'] ?? '').toString();
    final urls = (rec['ReceiptUrls'] is List)
        ? (rec['ReceiptUrls'] as List).whereType<String>().toList()
        : <String>[];
    final bytesList = (rec['ReceiptBytes'] is List)
        ? (rec['ReceiptBytes'] as List).whereType<Uint8List>().toList()
        : <Uint8List>[];
    final hasMemSingle = rec['Receipt'] is Uint8List;

    Widget? immediate;
    if (bytesList.isNotEmpty) {
      immediate = Image.memory(
        bytesList.first,
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.4,
        fit: BoxFit.contain,
      );
    } else if (localPath.isNotEmpty) {
      immediate = Image.file(
        File(localPath),
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.4,
        fit: BoxFit.contain,
      );
    } else if (singleUrl.isNotEmpty) {
      immediate = Image.network(
        singleUrl,
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.4,
        fit: BoxFit.contain,
      );
    } else if (urls.isNotEmpty) {
      immediate = Image.network(
        urls.first,
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.4,
        fit: BoxFit.contain,
      );
    } else if (hasMemSingle) {
      immediate = Image.memory(
        rec['Receipt'] as Uint8List,
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.4,
        fit: BoxFit.contain,
      );
    }

    if (immediate != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: immediate,
      );
    }

    // Fallback: resolve first available ReceiptUid to a local file path
    final uids = (rec['ReceiptUids'] is List)
        ? (rec['ReceiptUids'] as List).whereType<String>().toList()
        : const <String>[];
    if (uids.isEmpty) return const SizedBox.shrink();

    return FutureBuilder<String>(
      future: () async {
        for (final uid in uids) {
          try {
            final path = await LocalReceiptService().pathForReceiptUid(
              accountId: accountId,
              collection: 'custom_$tabId',
              receiptUid: uid,
            );
            if (path.isNotEmpty && await File(path).exists()) {
              return path;
            }
          } catch (_) {}
        }
        return '';
      }(),
      builder: (context, snap) {
        final p = (snap.data ?? '').toString();
        if (p.isEmpty) return const SizedBox.shrink();
        return ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            File(p),
            width: MediaQuery.of(context).size.width * 0.9,
            height: MediaQuery.of(context).size.height * 0.4,
            fit: BoxFit.contain,
          ),
        );
      },
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 20),
          ),
        ),
      ],
    );
  }
}
