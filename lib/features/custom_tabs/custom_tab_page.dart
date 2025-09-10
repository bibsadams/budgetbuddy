import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:budgetbuddy/widgets/money_field_utils.dart';
import 'package:budgetbuddy/widgets/pressable_neumorphic.dart';
import 'package:budgetbuddy/widgets/app_gradient_background.dart';
import 'custom_tab_record_edit_page.dart';
import '../../services/local_receipt_service.dart';
import '../../services/shared_account_repository.dart';

class CustomTabPageHost extends StatefulWidget {
  final String accountId;
  final String tabId;
  final String title;
  const CustomTabPageHost({
    super.key,
    required this.accountId,
    required this.tabId,
    required this.title,
  });

  @override
  State<CustomTabPageHost> createState() => _CustomTabPageHostState();
}

class _CustomTabPageHostState extends State<CustomTabPageHost> {
  SharedAccountRepository? _repo;
  StreamSubscription? _sub;
  List<Map<String, dynamic>> _rows = [];
  // Cache of receiptUid -> local file path (if exists)
  final Map<String, String?> _receiptPaths = {};
  bool _resolvingReceipts = false;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      _repo = SharedAccountRepository(
        accountId: widget.accountId,
        uid: user.uid,
      );
      _sub = _repo!
          .customTabRecordsStream(widget.tabId)
          .listen((data) => setState(() => _rows = data));
    }
  }

  Future<void> _resolveReceiptPaths() async {
    if (_resolvingReceipts) return;
    final receiptUids = _rows
        .map((r) => (r['ReceiptUid'] ?? '').toString())
        .where((e) => e.isNotEmpty)
        .toSet();
    final missing = receiptUids
        .where((u) => !_receiptPaths.containsKey(u))
        .toList();
    if (missing.isEmpty) return;
    setState(() => _resolvingReceipts = true);
    try {
      for (final uid in missing) {
        try {
          final path = await LocalReceiptService().pathForReceiptUid(
            accountId: widget.accountId,
            collection: 'custom_${widget.tabId}',
            receiptUid: uid,
          );
          final file = File(path);
          _receiptPaths[uid] = await file.exists() ? path : null;
        } catch (_) {
          _receiptPaths[uid] = null;
        }
      }
    } finally {
      if (mounted) setState(() => _resolvingReceipts = false);
    }
  }

  Color _recordColor(BuildContext context, String? title) {
    final cs = Theme.of(context).colorScheme;
    final t = (title ?? '').toLowerCase();
    Color adjust(Color c) => c;
    if (t.contains('food') || t.contains('meal')) {
      return adjust(cs.primaryContainer);
    }
    if (t.contains('travel') || t.contains('trip') || t.contains('flight')) {
      return adjust(cs.tertiaryContainer);
    }
    if (t.contains('save') || t.contains('deposit')) {
      return adjust(cs.secondaryContainer);
    }
    if (t.contains('gift')) {
      return adjust(cs.surfaceContainerHigh);
    }
    if (t.contains('tax')) {
      return adjust(cs.errorContainer);
    }
    // Hash fallback for variety
    final hash = t.hashCode;
    final variants = [
      cs.surfaceContainerLow,
      cs.surfaceContainer,
      cs.surfaceContainerHigh,
      cs.surfaceContainerHighest,
    ];
    return adjust(variants[hash.abs() % variants.length]);
  }

  IconData _recordIcon(String? title) {
    final t = (title ?? '').toLowerCase();
    if (t.contains('food') || t.contains('meal')) {
      return Icons.fastfood_outlined;
    }
    if (t.contains('travel') || t.contains('trip') || t.contains('flight')) {
      return Icons.flight_takeoff_outlined;
    }
    if (t.contains('save') || t.contains('deposit')) {
      return Icons.savings_outlined;
    }
    if (t.contains('gift')) {
      return Icons.card_giftcard_outlined;
    }
    if (t.contains('tax')) {
      return Icons.receipt_long_outlined;
    }
    if (t.contains('rent')) {
      return Icons.home_outlined;
    }
    if (t.contains('car')) {
      return Icons.directions_car_outlined;
    }
    return Icons.label_outline;
  }

  Future<void> _addNewRecord() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => CustomTabRecordEditPage(
          accountId: widget.accountId,
          tabId: widget.tabId,
          record: {'Title': '', 'Amount': 0.0, 'Date': '', 'Note': ''},
          repo: _repo,
        ),
      ),
    );
    if (result != null) {
      // If the edit page already persisted (_persisted flag), rely on stream update.
      if (result['_persisted'] == true) return;
      try {
        if (_repo != null) {
          await _repo!.addCustomTabRecord(widget.tabId, result);
        } else {
          setState(
            () => _rows = [
              ..._rows,
              {...result, 'id': 'row_${DateTime.now().microsecondsSinceEpoch}'},
            ],
          );
        }
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save: $e')));
      }
    }
  }

  // Build one record tile (used for both grouped and ungrouped lists)
  Widget _buildRecordTile(Map<String, dynamic> r) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveReceiptPaths());
    final receiptUid = (r['ReceiptUid'] ?? '').toString();
    final localPath = receiptUid.isNotEmpty ? _receiptPaths[receiptUid] : null;
    final hasReceipt =
        receiptUid.isNotEmpty || (r['ReceiptUrl'] ?? '').toString().isNotEmpty;

    Widget leading;
    if (hasReceipt) {
      final radius = BorderRadius.circular(12);
      if (localPath == null && _resolvingReceipts) {
        leading = _shimmerBox(context);
      } else if (localPath != null && File(localPath).existsSync()) {
        leading = ClipRRect(
          borderRadius: radius,
          child: Image.file(
            File(localPath),
            width: 48,
            height: 48,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _thumbFallback(context),
          ),
        );
      } else {
        leading = _thumbFallback(context);
      }
    } else {
      leading = Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: _recordColor(context, r['Title']?.toString()),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(_recordIcon(r['Title']?.toString()), size: 24),
      );
    }

    final handleEdit = () async {
      final updated = await Navigator.push<Map<String, dynamic>>(
        context,
        MaterialPageRoute(
          builder: (_) => CustomTabRecordEditPage(
            accountId: widget.accountId,
            tabId: widget.tabId,
            record: r,
            repo: _repo,
          ),
        ),
      );
      if (updated != null) {
        if (updated['_deleted'] == true) {
          setState(
            () =>
                _rows = List.of(_rows)..removeWhere((e) => e['id'] == r['id']),
          );
          return;
        }
        try {
          if (updated['_persisted'] == true) {
            // Already saved; rely on stream
          } else if (_repo != null && (r['id'] as String?) != null) {
            await _repo!.updateCustomTabRecord(
              widget.tabId,
              r['id'] as String,
              updated,
            );
          } else {
            setState(() {
              final idx = _rows.indexWhere((e) => e['id'] == r['id']);
              if (idx >= 0) _rows[idx] = {..._rows[idx], ...updated};
            });
          }
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Failed to update: $e')));
        }
      }
    };

    final content = PressableNeumorphic(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      onTap: handleEdit,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r['Title']?.toString() ?? 'Untitled',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      formatTwoDecimalsGrouped(
                        (r['Amount'] is num)
                            ? (r['Amount'] as num)
                            : (double.tryParse(
                                    r['Amount']?.toString() ?? '0',
                                  ) ??
                                  0),
                      ),
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        (r['Note'] ?? '').toString(),
                        style: Theme.of(context).textTheme.bodyMedium,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  (r['Date'] ?? '').toString().substring(0, 10),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: Colors.grey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final padded = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
      child: content,
    );

    return Dismissible(
      key: ValueKey(r['id'] ?? r.hashCode),
      background: _swipeBg(
        context,
        Icons.edit,
        Colors.blue,
        Alignment.centerLeft,
      ),
      secondaryBackground: _swipeBg(
        context,
        Icons.delete,
        Colors.red,
        Alignment.centerRight,
      ),
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          await handleEdit();
          return false;
        } else {
          final ok = await showDialog<bool>(
            context: context,
            builder: (d) => AlertDialog(
              title: const Text('Delete record?'),
              content: const Text('This will remove the record from this tab.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(d).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(d).pop(true),
                  child: const Text('Delete'),
                ),
              ],
            ),
          );
          if (ok == true) {
            try {
              if (_repo != null && (r['id'] as String?)?.isNotEmpty == true) {
                await _repo!.deleteCustomTabRecord(
                  widget.tabId,
                  r['id'] as String,
                );
              } else {
                setState(
                  () =>
                      _rows = List.of(_rows)
                        ..removeWhere((e) => e['id'] == r['id']),
                );
              }
              return true;
            } catch (e) {
              if (!mounted) return false;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
            }
          }
          return false;
        }
      },
      child: padded,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppGradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(widget.title),
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
        ),
        body: _rows.isEmpty
            ? const Center(
                child: Text(
                  'No records yet',
                  style: TextStyle(fontSize: 16, color: Colors.grey),
                ),
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 96),
                itemCount: _rows.length,
                itemBuilder: (ctx, i) => _buildRecordTile(_rows[i]),
              ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _addNewRecord,
          icon: const Icon(Icons.add),
          label: const Text('New'),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

Widget _thumbFallback(BuildContext context) => Container(
  width: 48,
  height: 48,
  decoration: BoxDecoration(
    color: Theme.of(context).colorScheme.primaryContainer,
    borderRadius: BorderRadius.circular(12),
  ),
  child: const Icon(Icons.receipt_long_outlined, size: 24),
);

Widget _swipeBg(
  BuildContext context,
  IconData icon,
  Color color,
  Alignment alignment,
) => Container(
  alignment: alignment,
  padding: const EdgeInsets.symmetric(horizontal: 20),
  color: color.withOpacity(0.85),
  child: Icon(icon, color: Colors.white, size: 28),
);

Widget _shimmerBox(BuildContext context) {
  return _AnimatedShimmer(
    width: 48,
    height: 48,
    borderRadius: BorderRadius.circular(12),
  );
}

class _AnimatedShimmer extends StatefulWidget {
  final double width;
  final double height;
  final BorderRadius borderRadius;
  const _AnimatedShimmer({
    required this.width,
    required this.height,
    required this.borderRadius,
  });
  @override
  State<_AnimatedShimmer> createState() => _AnimatedShimmerState();
}

class _AnimatedShimmerState extends State<_AnimatedShimmer>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final gradientPosition = _c.value;
        return ClipRRect(
          borderRadius: widget.borderRadius,
          child: Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(-1.0 + gradientPosition * 2, -1),
                end: Alignment(1.0 + gradientPosition * 2, 1),
                colors: [
                  Colors.grey.shade300,
                  Colors.grey.shade100,
                  Colors.grey.shade300,
                ],
                stops: const [0.1, 0.5, 0.9],
              ),
            ),
          ),
        );
      },
    );
  }
}
