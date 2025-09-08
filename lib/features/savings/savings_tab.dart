import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'dart:io';

class SavingsTab extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>> expensesRows;
  final double? goal;
  final void Function(List<Map<String, dynamic>> newRows) onRowsChanged;
  final VoidCallback? onSetGoal;

  const SavingsTab({
    super.key,
    required this.rows,
    required this.expensesRows,
    required this.goal,
    required this.onRowsChanged,
    required this.onSetGoal,
  });

  @override
  State<SavingsTab> createState() => _SavingsTabState();
}

class _SavingsTabState extends State<SavingsTab> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  String _sort = 'Date (newest)';
  bool _showAllAgg = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _filteredAndSorted() {
    final q = _query.trim().toLowerCase();
    List<Map<String, dynamic>> list = widget.rows.where((r) {
      if (q.isEmpty) return true;
      final cat = (r['Category'] ?? '').toString().toLowerCase();
      final sub = (r['Subcategory'] ?? '').toString().toLowerCase();
      final note = (r['Note'] ?? '').toString().toLowerCase();
      final date = (r['Date'] ?? '').toString().toLowerCase();
      return cat.contains(q) ||
          sub.contains(q) ||
          note.contains(q) ||
          date.contains(q);
    }).toList();

    int cmpNum(num a, num b) => a.compareTo(b);
    int cmpDate(String a, String b) {
      final da = DateTime.tryParse(a);
      final db = DateTime.tryParse(b);
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    }

    switch (_sort) {
      case 'Amount (high → low)':
        list.sort(
          (a, b) =>
              cmpNum((b['Amount'] ?? 0) as num, (a['Amount'] ?? 0) as num),
        );
        break;
      case 'Amount (low → high)':
        list.sort(
          (a, b) =>
              cmpNum((a['Amount'] ?? 0) as num, (b['Amount'] ?? 0) as num),
        );
        break;
      case 'Category (A → Z)':
        list.sort(
          (a, b) => ((a['Category'] ?? '') as String).compareTo(
            (b['Category'] ?? '') as String,
          ),
        );
        break;
      case 'Date (oldest)':
        list.sort(
          (a, b) =>
              cmpDate((a['Date'] ?? '') as String, (b['Date'] ?? '') as String),
        );
        break;
      case 'Date (newest)':
      default:
        list.sort(
          (a, b) =>
              cmpDate((b['Date'] ?? '') as String, (a['Date'] ?? '') as String),
        );
    }
    return list;
  }

  // Finalized thresholds:
  // Goal bar colors: green >=100%, amber 50–99%, red <50%.
  Color _goalColor(double progress) {
    if (progress >= 1.0) return Colors.green;
    if (progress >= 0.5) return Colors.amber;
    return Colors.red;
  }

  // Net savings colors: green >= 0; amber between -10% and 0 of goal; red < -10% of goal.
  Color _netColor({required double net, required double goal}) {
    if (net >= 0) return Colors.green;
    if (goal > 0) {
      final threshold = -0.1 * goal;
      if (net >= threshold) return Colors.amber;
      return Colors.red;
    }
    // No goal set: use red for negatives
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: '₱', decimalDigits: 2);
    final rows = widget.rows;
    final expensesRows = widget.expensesRows;
    final totalSaved = rows.fold<double>(
      0.0,
      (sum, row) =>
          sum + (row['Amount'] is num ? (row['Amount'] as num).toDouble() : 0),
    );
    final totalExpenses = expensesRows.fold<double>(
      0.0,
      (sum, row) =>
          sum + (row['Amount'] is num ? (row['Amount'] as num).toDouble() : 0),
    );
    final netSavedRaw = (totalSaved - totalExpenses);
    final goalVal = widget.goal ?? 0.0;
    final progressGoal = goalVal > 0
        ? (totalSaved / goalVal).clamp(0.0, 1.0)
        : 0.0;
    final remainingGoalRatio = goalVal > 0
        ? ((goalVal - totalSaved).clamp(0.0, goalVal) / goalVal)
        : 1.0;
    // Represent net savings progress relative to goal when available; clamp to [0,1] for progress bar.
    final progressNet = goalVal > 0
        ? (netSavedRaw / goalVal).clamp(0.0, 1.0)
        : (totalSaved > 0 ? (netSavedRaw / totalSaved).clamp(0.0, 1.0) : 0.0);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // Goal section
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: _GoalSection(
                goalLabel: widget.goal != null
                    ? currency.format(goalVal)
                    : null,
                progress: progressGoal,
                remainingRatio: remainingGoalRatio,
                onSetGoal: widget.onSetGoal,
                color: _goalColor(progressGoal),
              ),
            ),
          ),
          // Net savings section
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: _NetSavingsSection(
                netLabel: currency.format(netSavedRaw),
                totalLabel: currency.format(totalSaved),
                expensesLabel: currency.format(totalExpenses),
                progress: progressNet,
                color: _netColor(net: netSavedRaw, goal: goalVal),
              ),
            ),
          ),
          // Aggregation (Savings by subcategory)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _AggregationSection(
                rows: rows,
                showAll: _showAllAgg,
                onToggle: () => setState(() => _showAllAgg = !_showAllAgg),
                currency: currency,
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
          // Search + sort controls
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Search savings…',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    ),
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
                      PopupMenuItem(
                        value: 'Category (A → Z)',
                        child: Text('Category (A → Z)'),
                      ),
                    ],
                    child: OutlinedButton.icon(
                      onPressed: null,
                      icon: const Icon(Icons.sort),
                      label: Text(_sort),
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
                  "No savings yet. Tap '+' to add.",
                  style: TextStyle(fontSize: 16, color: Colors.grey),
                ),
              ),
            )
          else
            SliverList.builder(
              itemCount: _filteredAndSorted().length,
              itemBuilder: (context, index) {
                final displayRows = _filteredAndSorted();
                final row = displayRows[index];
                final originalIndex = _findOriginalIndex(rows, row);
                return _SavingCard(
                  row: row,
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SavingsDetailsPage(
                          saving: row,
                          onEdit: (updatedSaving) {
                            final newRows = List<Map<String, dynamic>>.from(
                              rows,
                            );
                            if (originalIndex >= 0) {
                              newRows[originalIndex] = {
                                ...rows[originalIndex],
                                ...updatedSaving,
                                'id':
                                    rows[originalIndex]['id'] ??
                                    updatedSaving['id'],
                              };
                            }
                            widget.onRowsChanged(newRows);
                            Navigator.pop(context);
                          },
                          onDelete: () {
                            final newRows = List<Map<String, dynamic>>.from(
                              rows,
                            );
                            if (originalIndex >= 0)
                              newRows.removeAt(originalIndex);
                            widget.onRowsChanged(newRows);
                            Navigator.pop(context);
                          },
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'savings-fab',
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        elevation: 6,
        extendedPadding: const EdgeInsets.symmetric(horizontal: 20),
        onPressed: () async {
          final newSaving = await Navigator.push<Map<String, dynamic>>(
            context,
            MaterialPageRoute(
              builder: (_) => SavingsEditPage(
                saving: {
                  'Category': '',
                  'Subcategory': '',
                  'Amount': 0.0,
                  'Date': '',
                  'Note': '',
                  'Receipt': null,
                },
              ),
            ),
          );
          if (newSaving != null) {
            final newRows = List<Map<String, dynamic>>.from(rows);
            newRows.add(newSaving);
            widget.onRowsChanged(newRows);
          }
        },
        icon: const Icon(Icons.add),
        label: const Text("Add Saving"),
      ),
    );
  }

  int _findOriginalIndex(
    List<Map<String, dynamic>> rows,
    Map<String, dynamic> row,
  ) {
    final id = row['id'];
    if (id != null) {
      final idx = rows.indexWhere((r) => r['id'] == id);
      if (idx >= 0) return idx;
    }
    // fallback by identity or content
    final idx2 = rows.indexOf(row);
    if (idx2 >= 0) return idx2;
    return rows.indexWhere(
      (r) =>
          r['Category'] == row['Category'] &&
          r['Subcategory'] == row['Subcategory'] &&
          r['Amount'] == row['Amount'] &&
          r['Date'] == row['Date'] &&
          r['Note'] == row['Note'],
    );
  }
}

class _SavingCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onTap;

  const _SavingCard({required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: '₱', decimalDigits: 2);
    return Card(
      color: Theme.of(context).colorScheme.surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _savingsCategoryColor(
                    context,
                    (row['Category'] ?? row['Name'] ?? '') as String?,
                  ),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  _savingsCategoryIcon(
                    (row['Category'] ?? row['Name'] ?? '') as String?,
                  ),
                  size: 22,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        (row['Category'] ?? row['Name'] ?? 'No Category')
                            .toString(),
                        if (((row['Subcategory'] ?? '') as String)
                            .toString()
                            .trim()
                            .isNotEmpty)
                          (row['Subcategory']).toString(),
                      ].join(' • '),
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
                          currency.format((row['Amount'] ?? 0) as num),
                          style: Theme.of(context).textTheme.bodyLarge!
                              .copyWith(
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
                child:
                    (row['LocalReceiptPath'] != null &&
                        (row['LocalReceiptPath'] as String).isNotEmpty)
                    ? Image.file(
                        File(row['LocalReceiptPath'] as String),
                        width: 64,
                        height: 64,
                        fit: BoxFit.cover,
                        errorBuilder: (c, e, s) => Container(
                          width: 64,
                          height: 64,
                          color: Colors.grey[200],
                          child: const Icon(Icons.broken_image, size: 28),
                        ),
                      )
                    : (row['ReceiptUrl'] != null &&
                          (row['ReceiptUrl'] as String).isNotEmpty)
                    ? Image.network(
                        row['ReceiptUrl'] as String,
                        width: 64,
                        height: 64,
                        fit: BoxFit.cover,
                        errorBuilder: (c, e, s) => Container(
                          width: 64,
                          height: 64,
                          color: Colors.grey[200],
                          child: const Icon(Icons.broken_image, size: 28),
                        ),
                      )
                    : (row['Receipt'] != null
                          ? Image.memory(
                              row['Receipt'] as Uint8List,
                              width: 64,
                              height: 64,
                              fit: BoxFit.cover,
                              errorBuilder: (c, e, s) => Container(
                                width: 64,
                                height: 64,
                                color: Colors.grey[200],
                                child: const Icon(Icons.broken_image, size: 28),
                              ),
                            )
                          : Container(
                              width: 64,
                              height: 64,
                              color: Colors.grey[200],
                              child: const Icon(Icons.receipt_long, size: 28),
                            )),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoalSection extends StatelessWidget {
  final String? goalLabel;
  final double progress;
  final double remainingRatio; // 0..1
  final VoidCallback? onSetGoal;
  final Color color;

  const _GoalSection({
    required this.goalLabel,
    required this.progress,
    required this.remainingRatio,
    required this.onSetGoal,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (progress * 100).clamp(0, 100).toStringAsFixed(0);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Goal',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: onSetGoal,
                icon: const Icon(Icons.tune),
                label: const Text('Set goal'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (goalLabel != null) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [Text('Goal: $goalLabel'), Text('$pct%')],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 10,
                backgroundColor: Colors.grey.shade300,
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NetSavingsSection extends StatelessWidget {
  final String netLabel;
  final String totalLabel;
  final String expensesLabel;
  final double progress;
  final Color color;
  const _NetSavingsSection({
    required this.netLabel,
    required this.totalLabel,
    required this.expensesLabel,
    required this.progress,
    required this.color,
  });
  @override
  Widget build(BuildContext context) {
    final hint = 'Total Savings = $totalLabel – $expensesLabel = $netLabel';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Savings', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 10,
              backgroundColor: Colors.grey.shade300,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          const SizedBox(height: 8),
          Text(hint, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 6),
          Text(
            'Total of all savings records: $totalLabel',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _AggregationSection extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final bool showAll;
  final VoidCallback onToggle;
  final NumberFormat currency;
  const _AggregationSection({
    required this.rows,
    required this.showAll,
    required this.onToggle,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final bySub = <String, double>{};
    for (final r in rows) {
      final cat = (r['Category'] ?? 'Uncategorized').toString();
      final sub = (r['Subcategory'] ?? 'Unspecified').toString();
      final key = '$cat • $sub';
      final amt = (r['Amount'] is num) ? (r['Amount'] as num).toDouble() : 0.0;
      bySub[key] = (bySub[key] ?? 0) + amt;
    }
    final entries = bySub.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final visible = showAll ? entries : entries.take(3).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Savings by sub category',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onToggle,
                  child: Text(showAll ? 'Show less' : 'Show more'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (visible.isEmpty)
              const Text('No data yet')
            else
              Column(
                children: [
                  for (final e in visible)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6.0),
                      child: Row(
                        children: [
                          Expanded(child: Text(e.key)),
                          Text(
                            currency.format(e.value),
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class SavingsDetailsPage extends StatelessWidget {
  final Map<String, dynamic> saving;
  final void Function(Map<String, dynamic> updatedSaving) onEdit;
  final VoidCallback onDelete;

  const SavingsDetailsPage({
    super.key,
    required this.saving,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Saving Details'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit, size: 32),
            tooltip: 'Edit',
            onPressed: () async {
              final updatedSaving = await Navigator.push<Map<String, dynamic>>(
                context,
                MaterialPageRoute(
                  builder: (_) => SavingsEditPage(saving: saving),
                ),
              );
              if (updatedSaving != null) {
                onEdit(updatedSaving);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete, size: 32),
            tooltip: 'Delete',
            onPressed: () {
              showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Confirm Delete'),
                  content: const Text(
                    'Are you sure you want to delete this saving?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () {
                        onDelete();
                        Navigator.pop(context);
                      },
                      child: const Text(
                        'Delete',
                        style: TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Saving Details',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            _buildDetailRow(
              'Category',
              [
                (saving['Category'] ?? '').toString(),
                if (((saving['Subcategory'] ?? '') as String)
                    .toString()
                    .trim()
                    .isNotEmpty)
                  (saving['Subcategory']).toString(),
              ].where((e) => e.isNotEmpty).join(' • '),
            ),
            _buildDetailRow(
              'Amount',
              '₱${(saving['Amount'] ?? 0.0).toStringAsFixed(2)}',
            ),
            _buildDetailRow('Date', saving['Date'] ?? ''),
            _buildDetailRow('Note', saving['Note'] ?? ''),
            const SizedBox(height: 32),
            Center(
              child: Builder(
                builder: (context) {
                  final localPath =
                      (saving['LocalReceiptPath'] ?? '') as String;
                  final url = (saving['ReceiptUrl'] ?? '') as String;
                  if (localPath.isNotEmpty) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.file(
                        File(localPath),
                        width: MediaQuery.of(context).size.width * 0.9,
                        height: MediaQuery.of(context).size.height * 0.5,
                        fit: BoxFit.contain,
                      ),
                    );
                  } else if (url.isNotEmpty) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(
                        url,
                        width: MediaQuery.of(context).size.width * 0.9,
                        height: MediaQuery.of(context).size.height * 0.5,
                        fit: BoxFit.contain,
                      ),
                    );
                  } else if (saving['Receipt'] != null) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.memory(
                        saving['Receipt'],
                        width: MediaQuery.of(context).size.width * 0.9,
                        height: MediaQuery.of(context).size.height * 0.5,
                        fit: BoxFit.contain,
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ),
          ],
        ),
      ),
    );
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
              value,
              style: const TextStyle(fontSize: 20),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class SavingsEditPage extends StatefulWidget {
  final Map<String, dynamic> saving;

  const SavingsEditPage({super.key, required this.saving});

  @override
  State<SavingsEditPage> createState() => _SavingsEditPageState();
}

class _SavingsEditPageState extends State<SavingsEditPage> {
  late TextEditingController amountController;
  late TextEditingController dateController;
  late TextEditingController noteController;
  Uint8List? receipt;

  String? selectedCategory;
  String? selectedSubcategory;

  Map<String, List<String>> categoriesMap = {};

  final box = Hive.box('budgetBox');
  final NumberFormat _decimalFmt = NumberFormat.decimalPattern();

  // Validation handled in _handleSaveTap to show SnackBar reasons

  @override
  void initState() {
    super.initState();
    final rawMap =
        box.get('savingsCategories') as Map? ??
        {
          'Education': ['Tuition', 'Books', 'Supplies'],
          'Kids': ['Allowance', 'School', 'Toys'],
          'Travel': ['Flights', 'Hotel', 'Activities'],
          'Emergency Fund': ['Contribution'],
          'Home': ['Down Payment', 'Renovation'],
          'Personal': ['Gadgets', 'Hobby'],
        };

    categoriesMap = rawMap.map<String, List<String>>((key, value) {
      final list = (value as List).map((e) => e.toString()).toList();
      return MapEntry(key.toString(), list);
    });

    // Merge helpful defaults without overwriting user data
    final Map<String, List<String>> defaults = {
      'Education': ['Tuition', 'Books', 'Supplies'],
      'Kids': ['Allowance', 'School', 'Toys'],
      'Travel': ['Flights', 'Hotel', 'Activities'],
      'Emergency Fund': ['Contribution'],
      'Home': ['Down Payment', 'Renovation'],
      'Car': ['Down Payment', 'Upgrade'],
      'Personal': ['Gadgets', 'Hobby'],
    };

    bool changed = false;
    defaults.forEach((cat, subs) {
      if (!categoriesMap.containsKey(cat)) {
        categoriesMap[cat] = List<String>.from(subs);
        changed = true;
      } else {
        final current = categoriesMap[cat]!;
        if (current.isEmpty) {
          categoriesMap[cat] = List<String>.from(subs);
          changed = true;
        } else {
          for (final s in subs) {
            if (!current.contains(s)) {
              current.add(s);
              changed = true;
            }
          }
        }
      }
    });

    if (changed) {
      box.put('savingsCategories', categoriesMap);
    }

    selectedCategory = widget.saving['Category'] ?? '';
    selectedSubcategory = widget.saving['Subcategory'] ?? '';

    String amtText = '';
    final amt = widget.saving['Amount'];
    if (amt is num && amt > 0) {
      amtText = _decimalFmt.format(amt);
    }
    amountController = TextEditingController(text: amtText);
    dateController = TextEditingController(text: widget.saving['Date'] ?? '');
    noteController = TextEditingController(text: widget.saving['Note'] ?? '');
    receipt = widget.saving['Receipt'];
    if (!categoriesMap.containsKey(selectedCategory)) {
      selectedCategory = null;
      selectedSubcategory = null;
    }
    if (dateController.text.trim().isEmpty) {
      final now = DateTime.now();
      dateController.text =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
    }
  }

  @override
  void dispose() {
    amountController.dispose();
    dateController.dispose();
    noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(dateController.text) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        dateController.text =
            "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}";
      });
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: source);
    if (pickedFile != null) {
      final bytes = await pickedFile.readAsBytes();
      setState(() {
        receipt = bytes;
      });
    }
  }

  Future<void> _showImageSourceSheet() async {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Pick from Gallery'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _pickImage(ImageSource.gallery);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Take a Photo'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await _pickImage(ImageSource.camera);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _addNewCategory() async {
    String? newCat = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text("Add New Category"),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: "Category name"),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  Navigator.pop(context, controller.text.trim());
                }
              },
              child: const Text("Add"),
            ),
          ],
        );
      },
    );
    if (newCat != null && !categoriesMap.containsKey(newCat)) {
      setState(() {
        categoriesMap[newCat] = [];
        selectedCategory = newCat;
        selectedSubcategory = null;
      });
      box.put('savingsCategories', categoriesMap);
    }
  }

  Future<void> _addNewSubcategory() async {
    if (selectedCategory == null) return;
    String? newSub = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text("Add New Subcategory"),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: "Subcategory name"),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  Navigator.pop(context, controller.text.trim());
                }
              },
              child: const Text("Add"),
            ),
          ],
        );
      },
    );
    if (newSub != null) {
      final subs = categoriesMap[selectedCategory]!;
      if (!subs.contains(newSub)) {
        setState(() {
          subs.add(newSub);
          selectedSubcategory = newSub;
        });
        box.put('savingsCategories', categoriesMap);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final subcategories = selectedCategory != null
        ? categoriesMap[selectedCategory]!
        : [];

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Text(
          widget.saving['Category'] == '' ? 'Add Saving' : 'Edit Saving',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: 'Save',
            onPressed: _handleSaveTap,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    value: selectedCategory,
                    decoration: const InputDecoration(
                      labelText: 'Category',
                      prefixIcon: Icon(Icons.category_outlined),
                      border: OutlineInputBorder(),
                    ),
                    items: categoriesMap.keys
                        .map<DropdownMenuItem<String>>(
                          (cat) =>
                              DropdownMenuItem(value: cat, child: Text(cat)),
                        )
                        .toList(),
                    onChanged: (val) {
                      setState(() {
                        selectedCategory = val;
                        selectedSubcategory = null;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Add category',
                  onPressed: _addNewCategory,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (selectedCategory != null) ...[
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      isExpanded: true,
                      value: subcategories.contains(selectedSubcategory)
                          ? selectedSubcategory
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Subcategory',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        border: OutlineInputBorder(),
                      ),
                      items: subcategories
                          .map<DropdownMenuItem<String>>(
                            (sub) =>
                                DropdownMenuItem(value: sub, child: Text(sub)),
                          )
                          .toList(),
                      onChanged: (val) {
                        setState(() {
                          selectedSubcategory = val;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  IconButton.filledTonal(
                    tooltip: 'Add subcategory',
                    onPressed: _addNewSubcategory,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
              if (selectedSubcategory == null ||
                  (selectedSubcategory?.trim().isEmpty ?? true))
                const Padding(
                  padding: EdgeInsets.only(top: 8.0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Subcategory is required',
                      style: TextStyle(color: Colors.red),
                    ),
                  ),
                ),
              const SizedBox(height: 20),
            ],
            TextField(
              controller: amountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [CurrencyInputFormatter()],
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 20),
              decoration: const InputDecoration(
                labelText: 'Amount',
                prefixText: '₱ ',
                border: OutlineInputBorder(),
              ),
            ),
            if ((double.tryParse(amountController.text.replaceAll(',', '')) ??
                    0.0) <=
                0.0)
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
              onTap: _pickDate,
              style: const TextStyle(fontSize: 20),
              decoration: InputDecoration(
                labelText: 'Date',
                prefixIcon: const Icon(Icons.event_outlined),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Pick date',
                  icon: const Icon(Icons.calendar_today_outlined),
                  onPressed: _pickDate,
                ),
              ),
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
            if (receipt != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  receipt!,
                  width: MediaQuery.of(context).size.width * 0.9,
                  height: MediaQuery.of(context).size.height * 0.4,
                  fit: BoxFit.cover,
                  errorBuilder: (c, e, s) => Container(
                    width: MediaQuery.of(context).size.width * 0.9,
                    height: MediaQuery.of(context).size.height * 0.4,
                    color: Colors.grey[200],
                    child: const Icon(Icons.broken_image, size: 48),
                  ),
                ),
              ),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: _showImageSourceSheet,
                  icon: const Icon(Icons.attachment_outlined),
                  label: Text(
                    receipt == null ? 'Attach Image' : 'Change Image',
                  ),
                ),
                if (receipt != null)
                  OutlinedButton.icon(
                    onPressed: () => setState(() => receipt = null),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove'),
                  ),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16),
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            minimumSize: const Size.fromHeight(56),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          onPressed: _handleSaveTap,
          icon: const Icon(Icons.save),
          label: const Text("Save Saving"),
        ),
      ),
    );
  }

  void _handleSaveTap() {
    final raw = amountController.text.replaceAll(',', '').trim();
    final amountVal = double.tryParse(raw) ?? 0.0;
    final missing = <String>[];
    if (selectedCategory == null) missing.add('Category');
    if (selectedSubcategory == null ||
        (selectedSubcategory?.trim().isEmpty ?? true)) {
      missing.add('Subcategory');
    }
    if (amountVal <= 0) missing.add('Amount > 0');

    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Please complete: ${missing.join(' • ')}')),
      );
      return;
    }

    final updatedSaving = {
      'Category': selectedCategory ?? '',
      'Subcategory': selectedSubcategory ?? '',
      'Amount': amountVal,
      'Date': dateController.text,
      'Note': noteController.text,
      'Receipt': receipt,
      'id': widget.saving['id'],
    };
    Navigator.pop(context, updatedSaving);
  }
}

// Decimal currency formatter (no symbol, adds grouping, 2 decimals)
class CurrencyInputFormatter extends TextInputFormatter {
  final NumberFormat _fmt = NumberFormat.decimalPattern();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (text.isEmpty) return newValue.copyWith(text: '');

    final buffer = StringBuffer();
    int dotCount = 0;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == '.') {
        if (dotCount == 0) {
          buffer.write('.');
          dotCount++;
        }
      } else if (RegExp(r'\d').hasMatch(ch)) {
        buffer.write(ch);
      }
    }
    var sanitized = buffer.toString();

    if (sanitized.contains('.')) {
      final parts = sanitized.split('.');
      final decimals = parts[1];
      sanitized =
          parts[0] +
          '.' +
          (decimals.length > 2 ? decimals.substring(0, 2) : decimals);
    }

    String intPart = sanitized;
    String decPart = '';
    if (sanitized.contains('.')) {
      final parts = sanitized.split('.');
      intPart = parts[0];
      decPart = parts[1];
    }

    intPart = intPart.isEmpty ? '0' : int.parse(intPart).toString();
    String grouped = _fmt.format(int.parse(intPart));
    if (decPart.isNotEmpty) {
      grouped = '$grouped.$decPart';
    }

    return TextEditingValue(
      text: grouped,
      selection: TextSelection.collapsed(offset: grouped.length),
    );
  }
}

Color _savingsCategoryColor(BuildContext context, String? cat) {
  final cs = Theme.of(context).colorScheme;
  final key = (cat ?? '').toLowerCase();
  if (key.contains('education') || key.contains('school')) {
    return cs.primaryContainer;
  }
  if (key.contains('kid')) {
    return cs.secondaryContainer;
  }
  if (key.contains('travel') || key.contains('trip')) {
    return cs.tertiaryContainer;
  }
  if (key.contains('emergency')) {
    return cs.errorContainer;
  }
  if (key.contains('home') || key.contains('house')) {
    return cs.surfaceContainerHigh;
  }
  if (key.contains('car')) {
    return cs.surfaceContainerHighest;
  }
  return cs.surfaceContainerLow;
}

IconData _savingsCategoryIcon(String? cat) {
  final key = (cat ?? '').toLowerCase();
  if (key.contains('education') || key.contains('school')) {
    return Icons.school_outlined;
  }
  if (key.contains('kid')) {
    return Icons.child_care_outlined;
  }
  if (key.contains('travel') || key.contains('trip')) {
    return Icons.flight_takeoff_outlined;
  }
  if (key.contains('emergency')) {
    return Icons.health_and_safety_outlined;
  }
  if (key.contains('home') || key.contains('house')) {
    return Icons.home_outlined;
  }
  if (key.contains('car')) {
    return Icons.directions_car_outlined;
  }
  return Icons.savings_outlined;
}
