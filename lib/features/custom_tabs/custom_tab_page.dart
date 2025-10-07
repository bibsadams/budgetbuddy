import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:budgetbuddy/widgets/money_field_utils.dart';
import 'package:budgetbuddy/widgets/pressable_neumorphic.dart';
import 'package:budgetbuddy/widgets/app_gradient_background.dart';
import 'custom_tab_record_edit_page.dart';
import 'custom_tab_record_details_page.dart';
import '../../services/local_receipt_service.dart';
import '../../services/shared_account_repository.dart';
// Hive not required on this screen after removing summary persistence
// Removed intl as summary header (amount/period) is not used here

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

  // OR-like UI state
  // Removed summary persistence; Hive box not needed here.
  String _period = 'all';
  String _sort = 'Date (newest)';
  bool _searchExpanded = false;
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    // Summary period selector removed from UI; default to 'all'.
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
    // Collect all receipt UIDs present in current rows (single and plural)
    final Set<String> receiptUids = {};
    for (final r in _rows) {
      final single = (r['ReceiptUid'] ?? '').toString();
      if (single.isNotEmpty) receiptUids.add(single);
      if (r['ReceiptUids'] is List) {
        for (final u in (r['ReceiptUids'] as List)) {
          if (u is String && u.isNotEmpty) receiptUids.add(u);
        }
      }
    }

    // Re-fetch for any uid we have never seen OR whose cached path is null (previously missing)
    final toFetch = receiptUids
        .where((u) => !_receiptPaths.containsKey(u) || _receiptPaths[u] == null)
        .toList();
    if (toFetch.isEmpty) return;
    setState(() => _resolvingReceipts = true);
    try {
      for (final uid in toFetch) {
        try {
          final path = await LocalReceiptService().pathForReceiptUid(
            accountId: widget.accountId,
            collection: 'custom_${widget.tabId}',
            receiptUid: uid,
          );
          final file = File(path);
          _receiptPaths[uid] = await file.exists() ? path : null;
        } catch (_) {
          // Keep null so we'll retry on next refresh attempt
          _receiptPaths[uid] = null;
        }
      }
    } finally {
      if (mounted) setState(() => _resolvingReceipts = false);
    }
  }

  // Period selector removed from UI; keep _period='all' for unfiltered view.

  DateTime? _parseDateFlexible(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final d1 = DateTime.tryParse(t);
    if (d1 != null) return d1;
    final d2 = DateTime.tryParse(t.replaceFirst(' ', 'T'));
    if (d2 != null) return d2;
    final parts = t.split(' ');
    if (parts.isNotEmpty) {
      final d3 = DateTime.tryParse(parts.first);
      if (d3 != null) return d3;
    }
    return null;
  }

  (DateTime, DateTime) _getPeriodRange(String period) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final tomorrowStart = todayStart.add(const Duration(days: 1));
    final yesterdayStart = todayStart.subtract(const Duration(days: 1));
    final startOfThisWeek = now
        .subtract(Duration(days: now.weekday % 7))
        .copyWith(
          hour: 0,
          minute: 0,
          second: 0,
          millisecond: 0,
          microsecond: 0,
        );
    final startOfNextWeek = startOfThisWeek.add(const Duration(days: 7));
    final startOfThisMonth = DateTime(now.year, now.month, 1);
    final startOfNextMonth = DateTime(now.year, now.month + 1, 1);
    final startOfLastMonth = DateTime(now.year, now.month - 1, 1);
    final startOfThisWeekPrev = startOfThisWeek.subtract(
      const Duration(days: 7),
    );
    switch (period) {
      case 'today':
        return (todayStart, tomorrowStart);
      case 'yesterday':
        return (yesterdayStart, todayStart);
      case 'this_week':
        return (startOfThisWeek, startOfNextWeek);
      case 'last_week':
        return (startOfThisWeekPrev, startOfThisWeek);
      case 'last_month':
        return (startOfLastMonth, startOfThisMonth);
      case 'this_month':
      default:
        return (startOfThisMonth, startOfNextMonth);
    }
  }

  double _toAmount(Object? v) {
    if (v is num) return v.toDouble();
    final s = v?.toString();
    final n = double.tryParse((s ?? '').replaceAll(',', ''));
    return n ?? 0.0;
  }

  List<Map<String, dynamic>> _sorted(List<Map<String, dynamic>> list) {
    int cmpDate(String a, String b) {
      final da = _parseDateFlexible(a);
      final db = _parseDateFlexible(b);
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    }

    final copy = List<Map<String, dynamic>>.from(list);
    switch (_sort) {
      case 'Amount (high → low)':
        copy.sort(
          (a, b) => _toAmount(b['Amount']).compareTo(_toAmount(a['Amount'])),
        );
        break;
      case 'Amount (low → high)':
        copy.sort(
          (a, b) => _toAmount(a['Amount']).compareTo(_toAmount(b['Amount'])),
        );
        break;
      case 'Date (oldest)':
        copy.sort(
          (a, b) => cmpDate(
            (a['Date'] ?? '').toString(),
            (b['Date'] ?? '').toString(),
          ),
        );
        break;
      case 'Date (newest)':
      default:
        copy.sort(
          (a, b) => cmpDate(
            (b['Date'] ?? '').toString(),
            (a['Date'] ?? '').toString(),
          ),
        );
    }
    return copy;
  }

  List<Map<String, dynamic>> _filteredAndSorted(
    List<Map<String, dynamic>> list,
  ) {
    Iterable<Map<String, dynamic>> it = list;
    if (_period != 'all') {
      final (start, end) = _getPeriodRange(_period);
      it = it.where((r) {
        final ds = (r['Date'] ?? '').toString();
        if (ds.isEmpty) return false;
        final dt = DateTime.tryParse(ds);
        if (dt == null) return false;
        return !dt.isBefore(start) && dt.isBefore(end);
      });
    }
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      it = it.where((r) {
        final title = (r['Title'] ?? r['Category'] ?? '')
            .toString()
            .toLowerCase();
        final note = (r['Note'] ?? '').toString().toLowerCase();
        final amt = ((r['Amount'] ?? 0) as num).toString();
        final ds = (r['Date'] ?? '').toString().toLowerCase();
        return title.contains(q) ||
            note.contains(q) ||
            amt.contains(q) ||
            ds.contains(q);
      });
    }
    return _sorted(it.toList());
  }

  // Removed period total computation since summary header is gone.

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
        // Suppress save error SnackBar per requirements; avoid blocking UX
      }
    }
  }

  // Build one record tile (used for both grouped and ungrouped lists)
  Widget _buildRecordTile(Map<String, dynamic> r) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolveReceiptPaths());
    final singleUid = (r['ReceiptUid'] ?? '').toString();
    final receiptUrls = (r['ReceiptUrls'] is List)
        ? (r['ReceiptUrls'] as List).whereType<String>().toList()
        : <String>[];
    final receiptUids = (r['ReceiptUids'] is List)
        ? (r['ReceiptUids'] as List).whereType<String>().toList()
        : <String>[];
    final firstUid = receiptUids.isNotEmpty
        ? receiptUids.first
        : (singleUid.isNotEmpty ? singleUid : null);
    final localPath = (firstUid != null) ? _receiptPaths[firstUid] : null;
    final receiptUrl = (r['ReceiptUrl'] ?? '').toString();
    final memBytes = r['Receipt'];
    final memList = (r['ReceiptBytes'] is List)
        ? (r['ReceiptBytes'] as List).whereType<Uint8List>().toList()
        : const <Uint8List>[];
    final hasReceipt =
        firstUid != null ||
        receiptUrl.isNotEmpty ||
        receiptUrls.isNotEmpty ||
        memBytes != null ||
        memList.isNotEmpty ||
        ((r['LocalReceiptPath'] ?? '').toString().isNotEmpty);

    Widget leading;
    if (hasReceipt) {
      final radius = BorderRadius.circular(12);
      if (memList.isNotEmpty) {
        final fb = memList.first;
        leading = ClipRRect(
          borderRadius: radius,
          child: Image.memory(
            fb,
            key: ValueKey('memlist-${r['id']}-${fb.length}'),
            width: 48,
            height: 48,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _thumbFallback(context),
          ),
        );
      } else if (memBytes is Uint8List) {
        leading = ClipRRect(
          borderRadius: radius,
          child: Image.memory(
            memBytes,
            key: ValueKey('mem-${r['id']}-${memBytes.length}'),
            width: 48,
            height: 48,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _thumbFallback(context),
          ),
        );
      } else if (receiptUrls.isNotEmpty) {
        final bustUrl =
            '${receiptUrls.first}?v=${DateTime.now().millisecondsSinceEpoch}';
        leading = ClipRRect(
          borderRadius: radius,
          child: Image.network(
            bustUrl,
            key: ValueKey('netlist-${r['id']}-${receiptUrls.length}'),
            width: 48,
            height: 48,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _thumbFallback(context),
          ),
        );
      } else if (receiptUrl.isNotEmpty) {
        final bustUrl =
            '$receiptUrl?v=${DateTime.now().millisecondsSinceEpoch}';
        leading = ClipRRect(
          borderRadius: radius,
          child: Image.network(
            bustUrl,
            key: ValueKey('net-${r['id']}-$singleUid'),
            width: 48,
            height: 48,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _thumbFallback(context),
          ),
        );
      } else if (localPath == null && _resolvingReceipts) {
        leading = _shimmerBox(context);
      } else if (localPath != null && File(localPath).existsSync()) {
        final stat = File(localPath).statSync();
        // Evict any stale cached image for this file path (helps hot reload after overwrite)
        PaintingBinding.instance.imageCache.evict(FileImage(File(localPath)));
        leading = ClipRRect(
          borderRadius: radius,
          child: Image.file(
            File(localPath),
            key: ValueKey(
              'file-${r['id']}-${stat.modified.millisecondsSinceEpoch}',
            ),
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

    Future<void> handleEdit() async {
      // Details-first flow, mirrors Expenses/OR UX
      final updated = await Navigator.push<Map<String, dynamic>>(
        context,
        MaterialPageRoute(
          builder: (_) => CustomTabRecordDetailsPage(
            accountId: widget.accountId,
            tabId: widget.tabId,
            record: r,
            onUpdate: (updated) async {
              // Persist via repo when available; else update local state
              try {
                if (_repo != null && (r['id'] as String?)?.isNotEmpty == true) {
                  await _repo!.updateCustomTabRecord(
                    widget.tabId,
                    r['id'] as String,
                    updated,
                  );
                } else {
                  final idx = _rows.indexWhere((e) => e['id'] == r['id']);
                  if (idx >= 0) {
                    setState(() => _rows[idx] = {..._rows[idx], ...updated});
                  }
                }
              } catch (_) {}
            },
          ),
        ),
      );
      if (updated != null) {
        if (updated['_deleted'] == true) {
          // If persisted, delete via repo so it doesn't come back via stream
          final id = r['id'] as String?;
          if (id != null && _repo != null) {
            try {
              await _repo!.deleteCustomTabRecord(widget.tabId, id);
            } catch (e) {
              // Suppress delete error SnackBar per requirements
            }
          }
          if (mounted) {
            setState(
              () =>
                  _rows = List.of(_rows)
                    ..removeWhere((e) => e['id'] == r['id']),
            );
          }
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
          // Suppress update error SnackBar per requirements
        }
      }
    }

    final content = PressableNeumorphic(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      onTap: handleEdit,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Stack(
            alignment: Alignment.bottomRight,
            children: [
              leading,
              Builder(
                builder: (_) {
                  // Show a small "+N" badge if there are multiple attachments
                  int count = 0;
                  if (r['ReceiptBytes'] is List) {
                    count += (r['ReceiptBytes'] as List)
                        .whereType<Uint8List>()
                        .length;
                  }
                  final uids = (r['ReceiptUids'] is List)
                      ? (r['ReceiptUids'] as List).whereType<String>().toList()
                      : <String>[];
                  count = count > 0 ? count : uids.length;
                  if (count > 1) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      margin: const EdgeInsets.all(2),
                      decoration: BoxDecoration(
                        color: Colors.black87,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '+${count - 1}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                        ),
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r['Title']?.toString() ??
                      r['Category']?.toString() ??
                      'Untitled',
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
                  () {
                    final s = (r['Date'] ?? '').toString();
                    if (s.length >= 10) return s.substring(0, 10);
                    return s; // show as-is if shorter or empty
                  }(),
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
          if (!mounted) return false;
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
    final all = _rows;
    final rows = _filteredAndSorted(all);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppGradientBackground(
        child: CustomScrollView(
          slivers: [
            SliverAppBar(
              backgroundColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              floating: true,
              snap: true,
              title: Text(widget.title),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: ScaleTransition(
                          scale: Tween<double>(
                            begin: 0.95,
                            end: 1.0,
                          ).animate(anim),
                          child: child,
                        ),
                      ),
                      child: _searchExpanded
                          ? Padding(
                              key: const ValueKey('custom-search-expanded'),
                              padding: const EdgeInsets.only(bottom: 8),
                              child: PressableNeumorphic(
                                borderRadius: 16,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.search, size: 20),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: TextField(
                                        controller: _searchCtrl,
                                        autofocus: true,
                                        decoration: const InputDecoration(
                                          hintText: 'Search records…',
                                          isDense: true,
                                          border: InputBorder.none,
                                        ),
                                        onChanged: (v) =>
                                            setState(() => _query = v),
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Clear',
                                      icon: const Icon(Icons.close, size: 20),
                                      onPressed: () {
                                        setState(() {
                                          _searchCtrl.clear();
                                          _query = '';
                                          _searchExpanded = false;
                                        });
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : const SizedBox.shrink(
                              key: ValueKey('custom-search-collapsed'),
                            ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PressableNeumorphic(
                            borderRadius: 24,
                            padding: const EdgeInsets.all(8),
                            onTap: () => setState(() => _searchExpanded = true),
                            child: const Icon(Icons.search),
                          ),
                          const SizedBox(width: 8),
                          PopupMenuButton<String>(
                            tooltip: 'Sort',
                            onSelected: (v) => setState(() => _sort = v),
                            itemBuilder: (ctx) => const [
                              PopupMenuItem(
                                value: 'Date (newest)',
                                child: Text('Date (newest)'),
                              ),
                              PopupMenuItem(
                                value: 'Date (oldest)',
                                child: Text('Date (oldest)'),
                              ),
                              PopupMenuItem(
                                value: 'Amount (high → low)',
                                child: Text('Amount (high → low)'),
                              ),
                              PopupMenuItem(
                                value: 'Amount (low → high)',
                                child: Text('Amount (low → high)'),
                              ),
                            ],
                            child: PressableNeumorphic(
                              borderRadius: 24,
                              padding: const EdgeInsets.all(8),
                              child: const Icon(Icons.filter_list),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (rows.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    'No records yet',
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                ),
              )
            else
              SliverList.builder(
                itemCount: rows.length,
                itemBuilder: (ctx, i) => Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  child: _buildRecordTile(rows[i]),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addNewRecord,
        icon: const Icon(Icons.add),
        label: const Text('New'),
      ),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }
}

// Summary header widget removed per design request.

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
  // Avoid deprecated withOpacity; use withAlpha to preserve precision
  color: color.withAlpha((0.85 * 255).round()),
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
