import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:budgetbuddy/widgets/two_decimal_input_formatter.dart';
import 'package:budgetbuddy/widgets/money_field_utils.dart';
import 'package:image_picker/image_picker.dart';
import 'package:budgetbuddy/widgets/app_gradient_background.dart';
import 'package:budgetbuddy/widgets/pressable_neumorphic.dart';
import 'package:budgetbuddy/features/expenses/receipt_gallery_page.dart';
import 'package:hive/hive.dart';
import 'package:budgetbuddy/services/local_receipt_service.dart';
import 'dart:ui';

class OrTab extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>>
  expensesRows; // kept for parity if needed later
  final void Function(List<Map<String, dynamic>> newRows) onRowsChanged;

  const OrTab({
    super.key,
    required this.rows,
    required this.expensesRows,
    required this.onRowsChanged,
  });

  @override
  State<OrTab> createState() => _OrTabState();
}

class _OrTabState extends State<OrTab> {
  // Match Expenses tab controls/state
  String _sort = 'Date (newest)';
  bool _searchExpanded = false;
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // Period selection removed (no filtering by period in OR tab).

  // Parse a DateTime from common formats used across the app
  DateTime? _parseDateFlexible(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    // Try native ISO-8601
    final d1 = DateTime.tryParse(t);
    if (d1 != null) return d1;
    // Accept 'yyyy-MM-dd HH:mm' by replacing space with 'T'
    final d2 = DateTime.tryParse(t.replaceFirst(' ', 'T'));
    if (d2 != null) return d2;
    // If only date part is present
    final parts = t.split(' ');
    if (parts.isNotEmpty) {
      final d3 = DateTime.tryParse(parts.first);
      if (d3 != null) return d3;
    }
    return null;
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
          (a, b) =>
              cmpDate((a['Date'] ?? '') as String, (b['Date'] ?? '') as String),
        );
        break;
      case 'Date (newest)':
      default:
        copy.sort(
          (a, b) =>
              cmpDate((b['Date'] ?? '') as String, (a['Date'] ?? '') as String),
        );
    }
    return copy;
  }

  // Period range computation removed.

  // Total computation removed.

  List<Map<String, dynamic>> _filteredAndSorted(
    List<Map<String, dynamic>> list,
  ) {
    Iterable<Map<String, dynamic>> it = list;
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      it = it.where((r) {
        final name = (r['Category'] ?? r['Name'] ?? '')
            .toString()
            .toLowerCase();
        final note = (r['Note'] ?? '').toString().toLowerCase();
        final valid = (r['ValidUntil'] ?? '').toString().toLowerCase();
        final amt = ((r['Amount'] ?? 0) as num).toString();
        final ds = (r['Date'] ?? '').toString().toLowerCase();
        return name.contains(q) ||
            note.contains(q) ||
            valid.contains(q) ||
            amt.contains(q) ||
            ds.contains(q);
      });
    }
    return _sorted(it.toList());
  }

  void _add() async {
    final res = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => OrEditPage(
          record: {
            'id': '',
            'Category': '',
            'Name': '', // legacy alias for title
            'Amount': 0.0,
            'Date': '',
            'ValidUntil': '',
            'Note': '',
            'Receipt': null,
          },
        ),
      ),
    );
    if (res != null) {
      // Ensure has a temporary id if still empty so edits map correctly before Firestore assigns
      if ((res['id'] ?? '').toString().isEmpty) {
        res['id'] = 'temp_${DateTime.now().microsecondsSinceEpoch}';
      }
      final rows = List<Map<String, dynamic>>.from(widget.rows);
      rows.add(res);
      widget.onRowsChanged(rows);
    }
  }

  // (obsolete) _edit replaced by view-first OrDetailsPage

  // end _OrTabState helpers

  @override
  Widget build(BuildContext context) {
    final allRows = widget.rows;
    final rows = _filteredAndSorted(allRows);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppGradientBackground(
        child: CustomScrollView(
          slivers: [
            // Removed summary header (period + amount) per design; keep search/sort below.
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
                              key: const ValueKey('or-search-expanded'),
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
                                          hintText: 'Search receipts…',
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
                              key: ValueKey('or-search-collapsed'),
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
                    "No OR records yet. Tap '+' to add.",
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                ),
              )
            else
              SliverList.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  return _buildOrCard(context, row, index);
                },
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'or-fab',
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        elevation: 6,
        extendedPadding: const EdgeInsets.symmetric(horizontal: 20),
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text("Add Official Receipt"),
      ),
    );
  }

  Widget _buildOrCard(
    BuildContext context,
    Map<String, dynamic> row,
    int index,
  ) {
    final currency = NumberFormat.currency(symbol: '₱', decimalDigits: 2);
    final pillowColor = Color.alphaBlend(
      Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.08),
      Colors.white,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
      child: PressableNeumorphic(
        backgroundColor: pillowColor,
        borderRadius: 18,
        padding: const EdgeInsets.all(16),
        onTap: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => OrDetailsPage(
                record: row,
                onEdit: (updated) {
                  final current = List<Map<String, dynamic>>.from(widget.rows);
                  final id = (row['id'] ?? '').toString();
                  int targetIndex = -1;
                  if (id.isNotEmpty) {
                    targetIndex = current.indexWhere(
                      (r) => (r['id'] ?? '') == id,
                    );
                  }
                  if (targetIndex < 0) {
                    targetIndex = current.indexOf(row);
                  }
                  if (targetIndex < 0) targetIndex = index;
                  current[targetIndex] = {
                    ...current[targetIndex],
                    ...updated,
                    'id': current[targetIndex]['id'] ?? updated['id'],
                  };
                  widget.onRowsChanged(current);
                },
                onDelete: () {
                  final current = List<Map<String, dynamic>>.from(widget.rows);
                  final id = (row['id'] ?? '').toString();
                  int removeIndex = -1;
                  if (id.isNotEmpty) {
                    removeIndex = current.indexWhere(
                      (r) => (r['id'] ?? '') == id,
                    );
                  }
                  if (removeIndex < 0) {
                    removeIndex = current.indexOf(row);
                  }
                  if (removeIndex >= 0) {
                    current.removeAt(removeIndex);
                    widget.onRowsChanged(current);
                  }
                  Navigator.of(context).maybePop();
                },
              ),
            ),
          );
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.receipt_long_outlined),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (row['Category'] ?? row['Name'] ?? 'Official Receipt')
                        .toString(),
                    style: Theme.of(context).textTheme.titleMedium!.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        currency.format(_toAmount(row['Amount'])),
                        style: Theme.of(context).textTheme.bodyLarge!.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          (row['Note'] ?? '').toString(),
                          style: Theme.of(context).textTheme.bodyMedium,
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    (row['Date'] ?? '').toString(),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall!.copyWith(color: Colors.grey),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _orReceiptThumb(row),
            ),
          ],
        ),
      ),
    );
  }
}

// OR Details page (view-first), modeled after ExpenseDetailsPage
class OrDetailsPage extends StatefulWidget {
  final Map<String, dynamic> record;
  final void Function(Map<String, dynamic> updated) onEdit;
  final VoidCallback onDelete;

  const OrDetailsPage({
    super.key,
    required this.record,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  State<OrDetailsPage> createState() => _OrDetailsPageState();
}

class _OrDetailsPageState extends State<OrDetailsPage> {
  late Map<String, dynamic> _record;
  String? _resolvedPreviewPath; // fallback path resolved from ReceiptUids

  @override
  void initState() {
    super.initState();
    _record = Map<String, dynamic>.from(widget.record);
    _resolvePreviewIfNeeded();
  }

  Future<void> _resolvePreviewIfNeeded() async {
    try {
      final r = _record;
      final localPath = (r['LocalReceiptPath'] ?? '') as String;
      final hasBytes =
          r['ReceiptBytes'] is List &&
          (r['ReceiptBytes'] as List).whereType<Uint8List>().isNotEmpty;
      final hasUrl =
          ((r['ReceiptUrl'] ?? '') as String).isNotEmpty ||
          ((r['ReceiptUrls'] is List) &&
              (r['ReceiptUrls'] as List).whereType<String>().isNotEmpty);
      final hasMem = r['Receipt'] is Uint8List;
      if (localPath.isNotEmpty || hasBytes || hasUrl || hasMem) return;

      final uids = (r['ReceiptUids'] is List)
          ? (r['ReceiptUids'] as List).whereType<String>().toList()
          : const <String>[];
      if (uids.isEmpty) return;

      final box = Hive.box('budgetBox');
      final accountId = (box.get('accountId') ?? '') as String;
      if (accountId.isEmpty) return;

      for (final uid in uids) {
        try {
          final path = await LocalReceiptService().pathForReceiptUid(
            accountId: accountId,
            collection: 'or',
            receiptUid: uid,
          );
          if (path.isNotEmpty) {
            if (await File(path).exists()) {
              if (!mounted) return;
              setState(() => _resolvedPreviewPath = path);
              break;
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final r = _record;
    final currency = NumberFormat.currency(symbol: '₱', decimalDigits: 2);
    return AppGradientBackground(
      child: Scaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          flexibleSpace: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(color: Colors.transparent),
            ),
          ),
          title: const Text('Official Receipt Details'),
          actions: [
            IconButton(
              icon: const Icon(Icons.edit, size: 28),
              tooltip: 'Edit',
              onPressed: () async {
                final updated = await Navigator.push<Map<String, dynamic>>(
                  context,
                  MaterialPageRoute(builder: (_) => OrEditPage(record: r)),
                );
                if (updated != null) {
                  setState(() {
                    _record = {
                      ..._record,
                      ...updated,
                      'id': _record['id'] ?? updated['id'],
                    };
                  });
                  widget.onEdit(_record);
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.delete, size: 28),
              tooltip: 'Delete',
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Delete OR'),
                    content: const Text(
                      'Are you sure you want to delete this record?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text(
                          'Delete',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                );
                if (confirm == true) {
                  widget.onDelete();
                }
              },
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + kToolbarHeight + 12,
            left: 24,
            right: 24,
            bottom: 24,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Official Receipt Details',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              _buildDetailRow(
                'Name',
                (r['Category'] ?? r['Name'] ?? '').toString(),
              ),
              _buildDetailRow(
                'Amount',
                currency.format(((r['Amount'] ?? 0) as num)),
              ),
              _buildDetailRow('Date Purchase', (r['Date'] ?? '').toString()),
              _buildDetailRow(
                'Valid Until',
                (r['ValidUntil'] ?? '').toString(),
              ),
              _buildDetailRow('Note', (r['Note'] ?? '').toString()),
              const SizedBox(height: 32),
              Center(
                child: Column(
                  children: [
                    _receiptPreview(r),
                    const SizedBox(height: 12),
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ReceiptGalleryPage(
                              rows: [r],
                              collection: 'or',
                              resolveRows: [r],
                              onEdit: (updated) async {
                                final merged = {
                                  ..._record,
                                  ...updated,
                                  'id': _record['id'] ?? updated['id'],
                                };
                                setState(() => _record = merged);
                                widget.onEdit(merged);
                              },
                              onReplace: (updated) async {
                                final merged = {
                                  ..._record,
                                  ...updated,
                                  'id': _record['id'] ?? updated['id'],
                                };
                                setState(() => _record = merged);
                                widget.onEdit(merged);
                              },
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('View receipt(s)'),
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

  Widget _receiptPreview(Map<String, dynamic> rec) {
    final localPath = (rec['LocalReceiptPath'] ?? '') as String;
    final resolvedPath = _resolvedPreviewPath ?? '';
    final singleUrl = (rec['ReceiptUrl'] ?? '') as String;
    final urls = (rec['ReceiptUrls'] is List)
        ? (rec['ReceiptUrls'] as List).whereType<String>().toList()
        : <String>[];
    final bytesList = (rec['ReceiptBytes'] is List)
        ? (rec['ReceiptBytes'] as List).whereType<Uint8List>().toList()
        : <Uint8List>[];
    final hasMemSingle = rec['Receipt'] is Uint8List;

    Widget? w;
    if (bytesList.isNotEmpty) {
      w = Image.memory(
        bytesList.first,
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.4,
        fit: BoxFit.contain,
      );
    } else if (localPath.isNotEmpty || resolvedPath.isNotEmpty) {
      try {
        final p = localPath.isNotEmpty ? localPath : resolvedPath;
        PaintingBinding.instance.imageCache.evict(FileImage(File(p)));
      } catch (_) {}
      w = Image.file(
        File(localPath.isNotEmpty ? localPath : resolvedPath),
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.4,
        fit: BoxFit.contain,
      );
    } else if (singleUrl.isNotEmpty) {
      w = Image.network(
        singleUrl,
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.4,
        fit: BoxFit.contain,
      );
    } else if (urls.isNotEmpty) {
      w = Image.network(
        urls.first,
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.4,
        fit: BoxFit.contain,
      );
    } else if (hasMemSingle) {
      w = Image.memory(
        rec['Receipt'] as Uint8List,
        width: MediaQuery.of(context).size.width * 0.9,
        height: MediaQuery.of(context).size.height * 0.4,
        fit: BoxFit.contain,
      );
    }
    return w != null
        ? ClipRRect(borderRadius: BorderRadius.circular(12), child: w)
        : const SizedBox.shrink();
  }
}

Widget _buildDetailRow(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 12.0),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
          ),
        ),
        Expanded(
          child: Text(
            value.isEmpty ? '—' : value,
            style: const TextStyle(fontSize: 20),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    ),
  );
}

class OrEditPage extends StatefulWidget {
  final Map<String, dynamic> record;
  const OrEditPage({super.key, required this.record});

  @override
  State<OrEditPage> createState() => _OrEditPageState();
}

class _OrEditPageState extends State<OrEditPage> {
  late TextEditingController nameController;
  late TextEditingController amountController;
  late TextEditingController dateController; // Date Purchase
  late TextEditingController validUntilController; // Valid Until
  late TextEditingController noteController;
  // Multi-image model following Expenses: prefer ReceiptBytes list for local edits.
  List<Uint8List> receipts = [];
  List<String> receiptUrls = [];
  List<String> receiptUids = [];
  Uint8List? receipt; // legacy single memory
  String? localPath; // legacy single file path
  String? receiptUrl; // legacy single url

  final NumberFormat _decimalFmt = NumberFormat.decimalPattern();
  final FocusNode _amountFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(
      text: (widget.record['Category'] ?? widget.record['Name'] ?? '')
          .toString(),
    );
    String amtText = '';
    final amt = widget.record['Amount'];
    if (amt is num && amt > 0) amtText = _decimalFmt.format(amt);
    amountController = TextEditingController(text: amtText);
    dateController = TextEditingController(text: widget.record['Date'] ?? '');
    validUntilController = TextEditingController(
      text: widget.record['ValidUntil'] ?? '',
    );
    noteController = TextEditingController(text: widget.record['Note'] ?? '');
    // Load attachments from record (support legacy and new forms)
    receipt = widget.record['Receipt'];
    final lp = (widget.record['LocalReceiptPath'] ?? '') as String;
    localPath = lp.isNotEmpty ? lp : null;
    final ru = (widget.record['ReceiptUrl'] ?? '') as String;
    receiptUrl = ru.isNotEmpty ? ru : null;
    if (widget.record['ReceiptBytes'] is List) {
      receipts = (widget.record['ReceiptBytes'] as List)
          .whereType<Uint8List>()
          .toList();
    } else if (receipt != null) {
      // Migrate single receipt to list in-memory to enable gallery actions
      receipts = [receipt!];
      receipt = null;
    }
    if (widget.record['ReceiptUrls'] is List) {
      receiptUrls = (widget.record['ReceiptUrls'] as List)
          .whereType<String>()
          .toList();
    }
    if (widget.record['ReceiptUids'] is List) {
      receiptUids = (widget.record['ReceiptUids'] as List)
          .whereType<String>()
          .toList();
    }

    if (dateController.text.trim().isEmpty) {
      final now = DateTime.now();
      dateController.text =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    }
  }

  @override
  void dispose() {
    nameController.dispose();
    amountController.dispose();
    _amountFocus.dispose();
    dateController.dispose();
    validUntilController.dispose();
    noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate(TextEditingController target) async {
    final current = DateTime.tryParse(target.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        final dt = DateTime(
          picked.year,
          picked.month,
          picked.day,
          current.hour,
          current.minute,
        );
        target.text =
            "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
      });
    }
  }

  Future<void> _pickTime(TextEditingController target) async {
    final current = DateTime.tryParse(target.text) ?? DateTime.now();
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: false),
        child: child!,
      ),
    );
    if (t != null) {
      setState(() {
        final dt = DateTime(
          current.year,
          current.month,
          current.day,
          t.hour,
          t.minute,
        );
        target.text =
            "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
      });
    }
  }

  Future<void> _pickDateAndTime(TextEditingController target) async {
    final current = DateTime.tryParse(target.text) ?? DateTime.now();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (pickedDate == null) return;
    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: false),
        child: child!,
      ),
    );
    final dt = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime?.hour ?? current.hour,
      pickedTime?.minute ?? current.minute,
    );
    setState(() {
      target.text =
          "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: source, imageQuality: 85);
    if (pickedFile == null) return;
    final raw = await pickedFile.readAsBytes();
    setState(() {
      // Append as another receipt to enable multi-image
      receipts.add(raw);
      // Clear legacy single holders
      receipt = null;
      localPath = null;
      receiptUrl = null;
    });
  }

  Future<void> _pickMultiple() async {
    final picker = ImagePicker();
    final files = await picker.pickMultiImage(imageQuality: 85);
    if (files.isEmpty) return;
    final list = <Uint8List>[];
    for (final f in files) {
      try {
        list.add(await f.readAsBytes());
      } catch (_) {}
    }
    if (list.isEmpty) return;
    setState(() {
      receipts.addAll(list);
      // Clear legacy single holders
      receipt = null;
      localPath = null;
      receiptUrl = null;
    });
  }

  // (Removed legacy single-image bottom sheet; replaced with multi-image attach UI)

  void _handleSave() {
    if (_amountFocus.hasFocus) _amountFocus.unfocus();
    final amountVal = parseLooseAmount(amountController.text);
    amountController.text = formatTwoDecimalsGrouped(amountVal);
    final missing = <String>[];
    if (nameController.text.trim().isEmpty) missing.add('Name');
    if (amountVal <= 0) missing.add('Amount > 0');
    if (dateController.text.trim().isEmpty) missing.add('Date Purchase');

    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Please complete: ${missing.join(' • ')}')),
      );
      return;
    }

    final updated = {
      'Category': nameController.text.trim(),
      'Name': nameController.text.trim(), // keep legacy alias
      'Amount': amountVal,
      'Date': dateController.text.trim(),
      'ValidUntil': validUntilController.text.trim(),
      'Note': noteController.text.trim(),
      // Prefer plural ReceiptBytes for multi-image edits
      if (receipts.isNotEmpty) 'ReceiptBytes': receipts,
      if (receiptUrls.isNotEmpty) 'ReceiptUrls': receiptUrls,
      if (receiptUids.isNotEmpty) 'ReceiptUids': receiptUids,
      // Legacy single fields maintained only when list is empty
      if (receipts.isEmpty) 'Receipt': receipt,
      if (receipts.isEmpty && receipt != null) 'LocalReceiptPath': null,
      if (receipts.isEmpty && receipt != null) 'ReceiptUrl': '',
      if (receipts.isEmpty &&
          receipt == null &&
          (localPath ?? '').isEmpty &&
          (receiptUrl ?? '').isEmpty) ...{
        'LocalReceiptPath': null,
        'ReceiptUrl': '',
      },
      // Ensure an id exists so the list can render and update deterministically
      'id': (widget.record['id'] ?? '').toString().isNotEmpty
          ? widget.record['id']
          : 'local_${DateTime.now().millisecondsSinceEpoch}',
    };
    Navigator.pop(context, updated);
  }

  @override
  Widget build(BuildContext context) {
    return AppGradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          flexibleSpace: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Container(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.06),
              ),
            ),
          ),
          title: Text(widget.record['Category'] == '' ? 'Add OR' : 'Edit OR'),
          actions: [
            IconButton(
              icon: const Icon(Icons.save),
              tooltip: 'Save',
              onPressed: _handleSave,
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            24,
            MediaQuery.of(context).padding.top + kToolbarHeight + 16,
            24,
            24 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: PressableNeumorphic(
            borderRadius: 16,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(
                  controller: nameController,
                  style: const TextStyle(fontSize: 20),
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    prefixIcon: Icon(Icons.receipt_long_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                if (nameController.text.trim().isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 8.0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Name is required',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                TextField(
                  controller: amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  focusNode: _amountFocus,
                  inputFormatters: [TwoDecimalInputFormatter()],
                  onChanged: (_) => setState(() {}),
                  onEditingComplete: () => _amountFocus.unfocus(),
                  onTapOutside: (_) {
                    if (_amountFocus.hasFocus) _amountFocus.unfocus();
                  },
                  style: const TextStyle(fontSize: 20),
                  decoration: const InputDecoration(
                    labelText: 'Amount',
                    prefixText: '₱ ',
                    border: OutlineInputBorder(),
                  ),
                ),
                if ((double.tryParse(
                          amountController.text.replaceAll(',', ''),
                        ) ??
                        0) <=
                    0)
                  const Padding(
                    padding: EdgeInsets.only(top: 8.0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Amount must be greater than 0',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                TextField(
                  controller: dateController,
                  readOnly: true,
                  onTap: () => _pickDateAndTime(dateController),
                  style: const TextStyle(fontSize: 20),
                  decoration: InputDecoration(
                    labelText: 'Date Purchase',
                    prefixIcon: const Icon(Icons.event_outlined),
                    border: const OutlineInputBorder(),
                    suffixIconConstraints: const BoxConstraints(minWidth: 96),
                    suffixIcon: SizedBox(
                      width: 96,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Pick date',
                            icon: const Icon(Icons.calendar_today_outlined),
                            onPressed: () => _pickDate(dateController),
                          ),
                          IconButton(
                            tooltip: 'Pick time',
                            icon: const Icon(Icons.access_time),
                            onPressed: () => _pickTime(dateController),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Builder(
                  builder: (_) {
                    final dt = DateTime.tryParse(dateController.text);
                    final friendly = dt != null
                        ? DateFormat('MMM d, y h:mm a').format(dt)
                        : dateController.text;
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        friendly,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),
                // New Valid Until (same style as Date Purchase)
                TextField(
                  controller: validUntilController,
                  readOnly: true,
                  onTap: () => _pickDateAndTime(validUntilController),
                  style: const TextStyle(fontSize: 20),
                  decoration: InputDecoration(
                    labelText: 'Valid Until',
                    prefixIcon: const Icon(Icons.event_available_outlined),
                    border: const OutlineInputBorder(),
                    suffixIconConstraints: const BoxConstraints(minWidth: 96),
                    suffixIcon: SizedBox(
                      width: 96,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Pick date',
                            icon: const Icon(Icons.calendar_today_outlined),
                            onPressed: () => _pickDate(validUntilController),
                          ),
                          IconButton(
                            tooltip: 'Pick time',
                            icon: const Icon(Icons.access_time),
                            onPressed: () => _pickTime(validUntilController),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Builder(
                  builder: (_) {
                    final dt = DateTime.tryParse(validUntilController.text);
                    final friendly = dt != null
                        ? DateFormat('MMM d, y h:mm a').format(dt)
                        : validUntilController.text;
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        friendly,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: noteController,
                  style: const TextStyle(fontSize: 20),
                  decoration: const InputDecoration(
                    labelText: 'Note',
                    prefixIcon: Icon(Icons.notes_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24),
                Builder(
                  builder: (ctx) {
                    final hasAny =
                        receipts.isNotEmpty ||
                        receipt != null ||
                        (localPath ?? '').isNotEmpty ||
                        (receiptUrl ?? '').isNotEmpty ||
                        receiptUrls.isNotEmpty;
                    if (!hasAny) return const SizedBox.shrink();
                    Widget imgWidget;
                    if (receipts.isNotEmpty) {
                      imgWidget = Image.memory(
                        receipts.first,
                        width: MediaQuery.of(context).size.width * 0.9,
                        height: MediaQuery.of(context).size.height * 0.4,
                        fit: BoxFit.cover,
                      );
                    } else if (receipt != null) {
                      imgWidget = Image.memory(
                        receipt!,
                        width: MediaQuery.of(context).size.width * 0.9,
                        height: MediaQuery.of(context).size.height * 0.4,
                        fit: BoxFit.cover,
                      );
                    } else if ((localPath ?? '').isNotEmpty) {
                      imgWidget = Image.file(
                        File(localPath!),
                        width: MediaQuery.of(context).size.width * 0.9,
                        height: MediaQuery.of(context).size.height * 0.4,
                        fit: BoxFit.cover,
                      );
                    } else {
                      // Prefer single URL if present, else first from plural list
                      final firstUrl = (receiptUrl ?? '').isNotEmpty
                          ? receiptUrl!
                          : receiptUrls.first;
                      imgWidget = Image.network(
                        firstUrl,
                        width: MediaQuery.of(context).size.width * 0.9,
                        height: MediaQuery.of(context).size.height * 0.4,
                        fit: BoxFit.cover,
                      );
                    }
                    return Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: imgWidget,
                        ),
                        if (receipts.length > 1)
                          Positioned(
                            right: 8,
                            top: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '+${receipts.length - 1}',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () async {
                        await showModalBottomSheet(
                          context: context,
                          showDragHandle: true,
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.vertical(
                              top: Radius.circular(16),
                            ),
                          ),
                          builder: (ctx) => SafeArea(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  ListTile(
                                    leading: const Icon(
                                      Icons.collections_outlined,
                                    ),
                                    title: const Text(
                                      'Pick from Gallery (multiple)',
                                    ),
                                    onTap: () async {
                                      Navigator.pop(ctx);
                                      await _pickMultiple();
                                    },
                                  ),
                                  ListTile(
                                    leading: const Icon(
                                      Icons.photo_camera_outlined,
                                    ),
                                    title: const Text('Take a Photo'),
                                    onTap: () async {
                                      Navigator.pop(ctx);
                                      await _pickImage(ImageSource.camera);
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.attachment_outlined),
                      label: Text(
                        (receipts.isEmpty &&
                                receipt == null &&
                                (localPath ?? '').isEmpty &&
                                (receiptUrl ?? '').isEmpty &&
                                receiptUrls.isEmpty)
                            ? 'Attach Receipt(s)'
                            : 'Add Receipt(s)',
                      ),
                    ),
                    if (receipts.isNotEmpty ||
                        receipt != null ||
                        (localPath ?? '').isNotEmpty ||
                        (receiptUrl ?? '').isNotEmpty ||
                        receiptUrls.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () => setState(() {
                          receipts.clear();
                          receiptUrls.clear();
                          receiptUids.clear();
                          receipt = null;
                          localPath = null;
                          receiptUrl = null;
                        }),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Remove'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              if ((widget.record['id'] ?? '').toString().isNotEmpty)
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      foregroundColor: Colors.red,
                    ),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (d) => AlertDialog(
                          title: const Text('Delete OR'),
                          content: const Text(
                            'Are you sure you want to delete this record?',
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
                      if (!mounted) return;
                      if (confirm == true) {
                        Navigator.pop(context, {
                          '__delete': true,
                          'id': widget.record['id'],
                        });
                      }
                    },
                  ),
                ),
              if ((widget.record['id'] ?? '').toString().isNotEmpty)
                const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: _handleSave,
                  icon: const Icon(Icons.save),
                  label: const Text('Save OR'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _orReceiptThumb(Map<String, dynamic> row) {
  final local = (row['LocalReceiptPath'] ?? '') as String;
  final url = (row['ReceiptUrl'] ?? '') as String;
  final hasMem = row['Receipt'] != null && row['Receipt'] is Uint8List;
  final list = (row['ReceiptBytes'] is List)
      ? (row['ReceiptBytes'] as List).whereType<Uint8List>().toList()
      : <Uint8List>[];
  final urls = (row['ReceiptUrls'] is List)
      ? (row['ReceiptUrls'] as List).whereType<String>().toList()
      : <String>[];
  Widget child;
  if (list.isNotEmpty) {
    child = Stack(
      children: [
        Positioned.fill(
          child: Image.memory(
            list.first,
            width: 64,
            height: 64,
            fit: BoxFit.cover,
            errorBuilder: (c, e, s) => _brokenThumb(),
          ),
        ),
        if (list.length > 1)
          Positioned(
            right: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${list.length}',
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ),
      ],
    );
  } else if (local.isNotEmpty) {
    child = Image.file(
      File(local),
      width: 64,
      height: 64,
      fit: BoxFit.cover,
      errorBuilder: (c, e, s) => _brokenThumb(),
    );
  } else if (urls.isNotEmpty) {
    child = Stack(
      children: [
        Positioned.fill(
          child: Image.network(
            urls.first,
            width: 64,
            height: 64,
            fit: BoxFit.cover,
            errorBuilder: (c, e, s) => _brokenThumb(),
          ),
        ),
        if (urls.length > 1)
          Positioned(
            right: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '${urls.length}',
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
          ),
      ],
    );
  } else if (url.isNotEmpty) {
    child = Image.network(
      url,
      width: 64,
      height: 64,
      fit: BoxFit.cover,
      errorBuilder: (c, e, s) => _brokenThumb(),
    );
  } else if (hasMem) {
    child = Image.memory(
      row['Receipt'] as Uint8List,
      width: 64,
      height: 64,
      fit: BoxFit.cover,
      errorBuilder: (c, e, s) => _brokenThumb(),
    );
  } else {
    child = _placeholderThumb();
  }
  return ClipRRect(borderRadius: BorderRadius.circular(12), child: child);
}

Widget _brokenThumb() => Container(
  width: 64,
  height: 64,
  color: Colors.grey[200],
  child: const Icon(Icons.broken_image, size: 28),
);
Widget _placeholderThumb() => Container(
  width: 64,
  height: 64,
  color: Colors.grey[200],
  child: const Icon(Icons.receipt_long, size: 28),
);
// End of OR tab implementation
