import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:image/image.dart' as img;
import 'package:budgetbuddy/widgets/money_field_utils.dart';
import 'package:budgetbuddy/widgets/two_decimal_input_formatter.dart';
import 'package:budgetbuddy/widgets/pressable_neumorphic.dart';
import 'package:budgetbuddy/widgets/app_gradient_background.dart';

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
  bool _searchExpanded = false; // animated, collapsible search field
  // Period options for header: this_week | this_month | last_week | last_month
  String _period = 'this_month';

  @override
  void initState() {
    super.initState();
    final saved = Hive.box('budgetBox').get('savingsSummaryPeriod');
    if (saved is String &&
        [
          'this_week',
          'this_month',
          'last_week',
          'last_month',
          'all_savings',
        ].contains(saved)) {
      _period = saved;
    }
  }

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

    // Apply period date filtering unless showing all_savings
    if (_period != 'all_savings') {
      final (start, end) = _getPeriodRange(_period);
      list = list.where((r) {
        final ds = (r['Date'] ?? '').toString();
        if (ds.isEmpty) return false;
        final dt = DateTime.tryParse(ds);
        if (dt == null) return false;
        return !dt.isBefore(start) && dt.isBefore(end);
      }).toList();
    }

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

  // Period helpers
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

  double _sumForPeriod(List<Map<String, dynamic>> rows) {
    double sum = 0.0;
    // If showing all savings, ignore date filtering
    if (_period == 'all_savings') {
      for (final row in rows) {
        final a = row['Amount'];
        if (a is num) sum += a.toDouble();
      }
      return sum;
    }
    final (start, end) = _getPeriodRange(_period);
    for (final row in rows) {
      final ds = (row['Date'] ?? '').toString();
      if (ds.isEmpty) continue;
      final dt = DateTime.tryParse(ds);
      if (dt == null) continue;
      final include = !dt.isBefore(start) && dt.isBefore(end);
      if (!include) continue;
      final a = row['Amount'];
      if (a is num) sum += a.toDouble();
    }
    return sum;
  }

  String _goalPercentKeyForPeriod(String period) {
    switch (period) {
      case 'today':
        return 'savingsGoalPercent_today';
      case 'yesterday':
        return 'savingsGoalPercent_yesterday';
      case 'this_week':
        return 'savingsGoalPercent_this_week';
      case 'last_week':
        return 'savingsGoalPercent_last_week';
      case 'last_month':
        return 'savingsGoalPercent_last_month';
      case 'all_savings':
        return 'savingsGoalPercent_all_savings';
      case 'this_month':
      default:
        return 'savingsGoalPercent_this_month';
    }
  }

  void _setPeriod(String p) {
    setState(() => _period = p);
    Hive.box('budgetBox').put('savingsSummaryPeriod', p);
  }

  // Net/Goal sections combined back to original summary header.

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: '₱', decimalDigits: 2);
    final rows = widget.rows;
    final expensesRows = widget.expensesRows;
    // Period-based totals
    final periodSavings = _sumForPeriod(rows);
    final periodExpenses = _sumForPeriod(expensesRows);
    final periodNet = periodSavings - periodExpenses;
    final periodLabel = switch (_period) {
      'today' => 'Today',
      'yesterday' => 'Yesterday',
      'this_week' => 'This Week',
      'last_week' => 'Last Week',
      'last_month' => 'Last Month',
      'all_savings' => 'All Savings',
      _ => 'This Month',
    };
    // Goal based on percent of period savings
    final box = Hive.box('budgetBox');
    double goalPercent =
        ((box.get(_goalPercentKeyForPeriod(_period)) as num?) ?? 0).toDouble();
    // Fallback to This Month's goal percent when period-specific value is missing
    if (goalPercent <= 0) {
      goalPercent = ((box.get('savingsGoalPercent_this_month') as num?) ?? 0)
          .toDouble();
    }
    final goalVal = (periodSavings * (goalPercent.clamp(0, 100) / 100.0));
    final rawRatioGoal = goalVal > 0 ? (periodNet / goalVal) : 0.0;
    final progressGoal = rawRatioGoal.clamp(0.0, 1.0);
    final depositsText =
        'Total Deposit $periodLabel: ${currency.format(periodSavings)}';

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppGradientBackground(
        child: CustomScrollView(
          slivers: [
            // Summary header with period dropdown and net amount
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: _SavingsSummaryHeader(
                  periodLabel: periodLabel,
                  currentPeriodKey: _period,
                  onChangePeriod: _setPeriod,
                  netLabel: currency.format(periodNet),
                  progress: progressGoal,
                  rawProgress: rawRatioGoal,
                  goalLabel: goalVal > 0 ? currency.format(goalVal) : null,
                  goalPercent: goalPercent,
                  onSetGoal: widget.onSetGoal,
                  depositsText: depositsText,
                ),
              ),
            ),
            // Aggregation removed per request
            // Search + Filter retained
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
                          ? Container(
                              key: const ValueKey('search-expanded'),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.surface.withValues(alpha: 0.6),
                                borderRadius: BorderRadius.circular(12),
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
                                        hintText: 'Search savings…',
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
                            )
                          : const SizedBox.shrink(
                              key: ValueKey('search-collapsed'),
                            ),
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Search icon (expands field above)
                          PressableNeumorphic(
                            borderRadius: 24,
                            padding: const EdgeInsets.all(8),
                            onTap: () => setState(() {
                              _searchExpanded = true;
                            }),
                            child: const Icon(Icons.search),
                          ),
                          const SizedBox(width: 8),
                          // Filter/Sort icon (popup menu)
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
                              if (originalIndex >= 0) {
                                newRows.removeAt(originalIndex);
                              }
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
      child: PressableNeumorphic(
        borderRadius: 16,
        padding: const EdgeInsets.all(16),
        onTap: onTap,
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
            _savingsReceiptThumb(row),
          ],
        ),
      ),
    );
  }
}

class _SavingsSummaryHeader extends StatelessWidget {
  final String periodLabel;
  final String currentPeriodKey;
  final ValueChanged<String> onChangePeriod;
  final String netLabel;
  final String? goalLabel;
  final double progress; // 0..1
  final double rawProgress; // unclamped progress, may exceed 1
  final double goalPercent; // e.g., 60.0
  final VoidCallback? onSetGoal;
  final String? depositsText;

  const _SavingsSummaryHeader({
    required this.periodLabel,
    required this.currentPeriodKey,
    required this.onChangePeriod,
    required this.netLabel,
    required this.goalLabel,
    required this.progress,
    required this.rawProgress,
    required this.goalPercent,
    required this.onSetGoal,
    this.depositsText,
  });

  @override
  Widget build(BuildContext context) {
    Color goalColor(double p) {
      if (p >= 1.0) return Colors.green;
      if (p >= 0.5) return Colors.amber;
      return Colors.red;
    }

    return PressableNeumorphic(
      borderRadius: 16,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PopupMenuButton<String>(
                      tooltip: 'Change period',
                      onSelected: onChangePeriod,
                      itemBuilder: (ctx) => const [
                        PopupMenuItem(value: 'today', child: Text('Today')),
                        PopupMenuItem(
                          value: 'yesterday',
                          child: Text('Yesterday'),
                        ),
                        PopupMenuItem(
                          value: 'this_week',
                          child: Text('This Week'),
                        ),
                        PopupMenuItem(
                          value: 'this_month',
                          child: Text('This Month'),
                        ),
                        PopupMenuItem(
                          value: 'last_week',
                          child: Text('Last Week'),
                        ),
                        PopupMenuItem(
                          value: 'last_month',
                          child: Text('Last Month'),
                        ),
                        PopupMenuItem(
                          value: 'all_savings',
                          child: Text('All Savings'),
                        ),
                      ],
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            periodLabel,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(width: 4),
                          const Icon(Icons.keyboard_arrow_down, size: 18),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    Builder(
                      builder: (context) {
                        // Derive sign from text parsing; if it contains '-' assume negative
                        final isNegative = netLabel.contains('-');
                        return Text(
                          netLabel,
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: isNegative ? Colors.red : Colors.green,
                              ),
                        );
                      },
                    ),
                    if (depositsText != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        depositsText!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: onSetGoal,
                icon: const Icon(Icons.tune),
                label: const Text('Set Goal'),
              ),
            ],
          ),
          if (goalLabel != null) ...[
            const SizedBox(height: 12),
            // Move goal text above the progress bar
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Goal: ${goalLabel!}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message:
                          '${goalPercent.toStringAsFixed(0)}% of $periodLabel Savings',
                      child: IconButton(
                        constraints: const BoxConstraints(minWidth: 32),
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.help_outline, size: 18),
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('Goal Calculation'),
                              content: Text(
                                '${goalPercent.toStringAsFixed(0)}% of $periodLabel Savings',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('OK'),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox.shrink(),
              ],
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () {
                final rpct = (rawProgress * 100);
                final remaining = 100 - rpct;
                final msg = remaining >= 0
                    ? '${remaining.clamp(0, 100).toStringAsFixed(0)}% remaining'
                    : '${(-remaining).toStringAsFixed(0)}% over';
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(msg),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
              child: Tooltip(
                message: () {
                  final rpct = (rawProgress * 100);
                  final remaining = 100 - rpct;
                  return remaining >= 0
                      ? '${remaining.clamp(0, 100).toStringAsFixed(0)}% remaining'
                      : '${(-remaining).toStringAsFixed(0)}% over';
                }(),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 8,
                    backgroundColor: Colors.grey.shade300,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      goalColor(progress),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// Small helper to render the savings receipt thumbnail safely.
Widget _savingsReceiptThumb(Map<String, dynamic> row) {
  final local = (row['LocalReceiptPath'] ?? '') as String;
  final url = (row['ReceiptUrl'] ?? '') as String;
  final mem = row['Receipt'];
  Widget child;
  // 1. In-memory (fresh)
  if (mem is Uint8List) {
    child = Image.memory(
      mem,
      key: ValueKey('mem-${row['id']}-${mem.length}'),
      width: 64,
      height: 64,
      fit: BoxFit.cover,
      errorBuilder: (c, e, s) => _brokenThumb(),
    );
  } else if (url.isNotEmpty) {
    final bustUrl = '$url?v=${DateTime.now().millisecondsSinceEpoch}';
    child = Image.network(
      bustUrl,
      key: ValueKey('net-${row['id']}-${row['ReceiptUid'] ?? ''}'),
      width: 64,
      height: 64,
      fit: BoxFit.cover,
      errorBuilder: (c, e, s) => _brokenThumb(),
    );
  } else if (local.isNotEmpty && File(local).existsSync()) {
    final f = File(local);
    final stat = f.statSync();
    PaintingBinding.instance.imageCache.evict(FileImage(f));
    child = Image.file(
      f,
      key: ValueKey(
        'file-${row['id']}-${stat.modified.millisecondsSinceEpoch}',
      ),
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

// Aggregation section removed

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
          title: const Text('Saving Details'),
          actions: [
            IconButton(
              icon: const Icon(Icons.edit, size: 32),
              tooltip: 'Edit',
              onPressed: () async {
                final updatedSaving =
                    await Navigator.push<Map<String, dynamic>>(
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
                currency.format((saving['Amount'] ?? 0) as num),
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
  final FocusNode _amountFocus = FocusNode();
  late TextEditingController dateController;
  late TextEditingController noteController;
  Uint8List? receipt;
  String? localPath;
  String? receiptUrl;

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
      // Newly requested Compensation category
      'Compensation': ['Salary', 'Bonus', 'Incentive', 'Reimbursement'],
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
    // If new saving (empty category) default to Compensation
    if ((selectedCategory == null || selectedCategory!.isEmpty) &&
        categoriesMap.containsKey('Compensation')) {
      selectedCategory = 'Compensation';
      selectedSubcategory = null; // force user to pick specific subcategory
    }

    String amtText = '';
    final amt = widget.saving['Amount'];
    if (amt is num && amt > 0) {
      amtText = _decimalFmt.format(amt);
    }
    amountController = TextEditingController(text: amtText);
    dateController = TextEditingController(text: widget.saving['Date'] ?? '');
    noteController = TextEditingController(text: widget.saving['Note'] ?? '');
    receipt = widget.saving['Receipt'];
    final lp = (widget.saving['LocalReceiptPath'] ?? '') as String;
    localPath = lp.isNotEmpty ? lp : null;
    final ru = (widget.saving['ReceiptUrl'] ?? '') as String;
    receiptUrl = ru.isNotEmpty ? ru : null;
    if (!categoriesMap.containsKey(selectedCategory)) {
      selectedCategory = null;
      selectedSubcategory = null;
    }
    if (dateController.text.trim().isEmpty) {
      final now = DateTime.now();
      dateController.text =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    }
  }

  @override
  void dispose() {
    amountController.dispose();
    _amountFocus.dispose();
    dateController.dispose();
    noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final current = DateTime.tryParse(dateController.text) ?? DateTime.now();
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
        dateController.text =
            "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
      });
    }
  }

  Future<void> _pickTime() async {
    final current = DateTime.tryParse(dateController.text) ?? DateTime.now();
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
        dateController.text =
            "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
      });
    }
  }

  Future<void> _pickDateAndTime() async {
    final current = DateTime.tryParse(dateController.text) ?? DateTime.now();
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
      dateController.text =
          "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: source, imageQuality: 85);
    if (pickedFile == null) return;
    final raw = await pickedFile.readAsBytes();
    Uint8List bytes = raw;
    try {
      final decoded = img.decodeImage(raw);
      if (decoded != null) {
        final normalized = img.bakeOrientation(decoded);
        const maxDim = 1600;
        final w = normalized.width, h = normalized.height;
        img.Image finalImg = normalized;
        if (w > maxDim || h > maxDim) {
          final scale = w >= h ? maxDim / w : maxDim / h;
          final newW = (w * scale).round();
          final newH = (h * scale).round();
          finalImg = img.copyResize(normalized, width: newW, height: newH);
        }
        bytes = Uint8List.fromList(img.encodeJpg(finalImg, quality: 85));
      }
    } catch (_) {}
    setState(() {
      receipt = bytes;
      // Clear other references when a new image is attached
      localPath = null;
      receiptUrl = null;
    });
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

    return AppGradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        resizeToAvoidBottomInset: true,
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
            MediaQuery.of(context).padding.top + kToolbarHeight + 16,
            24,
            24 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: PressableNeumorphic(
            borderRadius: 16,
            padding: const EdgeInsets.all(16),
            useSurfaceBase: true,
            // Form panels look cleaner on plain surface
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
                        items: () {
                          final keys = categoriesMap.keys.toList();
                          // Move Compensation to top if present
                          keys.sort((a, b) {
                            if (a == 'Compensation') return -1;
                            if (b == 'Compensation') return 1;
                            return a.toLowerCase().compareTo(b.toLowerCase());
                          });
                          return keys
                              .map<DropdownMenuItem<String>>(
                                (cat) => DropdownMenuItem(
                                  value: cat,
                                  child: Text(cat),
                                ),
                              )
                              .toList();
                        }(),
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
                                (sub) => DropdownMenuItem(
                                  value: sub,
                                  child: Text(sub),
                                ),
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
                  onTap: _pickDateAndTime,
                  style: const TextStyle(fontSize: 20),
                  decoration: InputDecoration(
                    labelText: 'Date & time',
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
                            onPressed: _pickDate,
                          ),
                          IconButton(
                            tooltip: 'Pick time',
                            icon: const Icon(Icons.access_time),
                            onPressed: _pickTime,
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
                    Widget? imgWidget;
                    if (receipt != null) {
                      imgWidget = Image.memory(
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
                      );
                    } else if ((localPath ?? '').isNotEmpty) {
                      imgWidget = Image.file(
                        File(localPath!),
                        width: MediaQuery.of(context).size.width * 0.9,
                        height: MediaQuery.of(context).size.height * 0.4,
                        fit: BoxFit.cover,
                      );
                    } else if ((receiptUrl ?? '').isNotEmpty) {
                      imgWidget = Image.network(
                        receiptUrl!,
                        width: MediaQuery.of(context).size.width * 0.9,
                        height: MediaQuery.of(context).size.height * 0.4,
                        fit: BoxFit.cover,
                      );
                    }
                    if (imgWidget == null) return const SizedBox.shrink();
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: imgWidget,
                    );
                  },
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: _showImageSourceSheet,
                      icon: const Icon(Icons.attachment_outlined),
                      label: Text(
                        (receipt == null &&
                                (localPath ?? '').isEmpty &&
                                (receiptUrl ?? '').isEmpty)
                            ? 'Attach Image'
                            : 'Change Image',
                      ),
                    ),
                    if (receipt != null ||
                        (localPath ?? '').isNotEmpty ||
                        (receiptUrl ?? '').isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () => setState(() {
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
          child: PressableNeumorphic(
            borderRadius: 16,
            useSurfaceBase: true,
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
        ),
      ),
    );
  }

  void _handleSaveTap() {
    if (_amountFocus.hasFocus) _amountFocus.unfocus();
    final amountVal = parseLooseAmount(amountController.text);
    amountController.text = formatTwoDecimalsGrouped(amountVal);
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
      if (receipt != null) 'LocalReceiptPath': null,
      if (receipt != null) 'ReceiptUrl': '',
      if (receipt == null &&
          (localPath ?? '').isEmpty &&
          (receiptUrl ?? '').isEmpty) ...{
        'LocalReceiptPath': null,
        'ReceiptUrl': '',
      },
      'id': widget.saving['id'],
    };
    Navigator.pop(context, updatedSaving);
  }
}

// (Formatter moved to widgets/two_decimal_input_formatter.dart)

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
