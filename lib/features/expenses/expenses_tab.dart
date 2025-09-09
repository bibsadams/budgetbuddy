import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:hive/hive.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'dart:io';
// import 'dart:typed_data'; // unnecessary
import 'dart:ui';
import 'package:image/image.dart' as img;
import 'package:budgetbuddy/widgets/pressable_neumorphic.dart';
import 'package:budgetbuddy/widgets/app_gradient_background.dart';
import 'package:budgetbuddy/services/notification_service.dart';

class ExpensesTab extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final double? limit;
  // Savings rows are needed to support percentage-based limits of period savings
  final List<Map<String, dynamic>>? savingsRows;
  final void Function(List<Map<String, dynamic>> newRows) onRowsChanged;
  final void Function()? onSetLimit;

  const ExpensesTab({
    super.key,
    required this.rows,
    required this.limit,
    this.savingsRows,
    required this.onRowsChanged,
    required this.onSetLimit,
  });

  @override
  State<ExpensesTab> createState() => _ExpensesTabState();
}

class _ExpensesTabState extends State<ExpensesTab> {
  late final Box _box;
  // Period options: this_week | this_month | last_week | last_month
  String _period = 'this_month';
  // Search/sort state (mirrors Savings tab)
  bool _searchExpanded = false;
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  String _sort = 'Date (newest)';

  @override
  void initState() {
    super.initState();
    _box = Hive.box('budgetBox');
    final saved = _box.get('expensesSummaryPeriod');
    if (saved is String &&
        [
          'this_week',
          'this_month',
          'last_week',
          'last_month',
          'all_expenses',
        ].contains(saved)) {
      _period = saved;
    }
  }

  void _setPeriod(String p) {
    setState(() => _period = p);
    _box.put('expensesSummaryPeriod', p);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  (DateTime, DateTime) _getPeriodRange(String period) {
    final now = DateTime.now();
    // Week starts on Sunday to match prior logic
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
    if (_period == 'all_expenses') {
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

  String _limitPercentKeyForPeriod(String period) {
    switch (period) {
      case 'this_week':
        return 'expensesLimitPercent_this_week';
      case 'last_week':
        return 'expensesLimitPercent_last_week';
      case 'last_month':
        return 'expensesLimitPercent_last_month';
      case 'all_expenses':
        return 'expensesLimitPercent_all_expenses';
      case 'this_month':
      default:
        return 'expensesLimitPercent_this_month';
    }
  }

  // _sumFor helper removed (no longer used)

  List<Map<String, dynamic>> _filteredAndSorted() {
    final list = List<Map<String, dynamic>>.from(widget.rows);
    final q = _query.trim().toLowerCase();
    Iterable<Map<String, dynamic>> it = list;
    if (q.isNotEmpty) {
      it = it.where((r) {
        final cat = (r['Category'] ?? '').toString().toLowerCase();
        final sub = (r['Subcategory'] ?? '').toString().toLowerCase();
        final note = (r['Note'] ?? '').toString().toLowerCase();
        final amt = ((r['Amount'] ?? 0) as num).toString();
        final ds = (r['Date'] ?? '').toString().toLowerCase();
        return cat.contains(q) ||
            sub.contains(q) ||
            note.contains(q) ||
            amt.contains(q) ||
            ds.contains(q);
      });
    }
    final list2 = it.toList();
    int cmpNumDesc(num a, num b) => (b - a).sign.toInt();
    int cmpNumAsc(num a, num b) => (a - b).sign.toInt();
    DateTime parseDate(Object? v) => v is DateTime
        ? v
        : (DateTime.tryParse((v ?? '').toString()) ?? DateTime(1900));
    switch (_sort) {
      case 'Date (oldest)':
        list2.sort(
          (a, b) => parseDate(a['Date']).compareTo(parseDate(b['Date'])),
        );
        break;
      case 'Amount (high → low)':
        list2.sort(
          (a, b) => cmpNumDesc(
            ((a['Amount'] ?? 0) as num),
            ((b['Amount'] ?? 0) as num),
          ),
        );
        break;
      case 'Amount (low → high)':
        list2.sort(
          (a, b) => cmpNumAsc(
            ((a['Amount'] ?? 0) as num),
            ((b['Amount'] ?? 0) as num),
          ),
        );
        break;
      case 'Category (A → Z)':
        list2.sort(
          (a, b) => ((a['Category'] ?? '') as String)
              .toString()
              .toLowerCase()
              .compareTo(
                ((b['Category'] ?? '') as String).toString().toLowerCase(),
              ),
        );
        break;
      default:
        // Date (newest)
        list2.sort(
          (a, b) => parseDate(b['Date']).compareTo(parseDate(a['Date'])),
        );
    }
    return list2;
  }

  int _findOriginalIndex(
    List<Map<String, dynamic>> rows,
    Map<String, dynamic> row,
  ) {
    // rows and filtered rows share the same map references, so indexOf works
    final idx = rows.indexOf(row);
    if (idx != -1) return idx;
    // fallback by id if present
    final id = row['id'];
    if (id != null) {
      return rows.indexWhere((r) => r['id'] == id);
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: '₱', decimalDigits: 2);
    final rows = widget.rows;
    final total = _sumForPeriod(rows);
    String periodLabel = switch (_period) {
      'this_week' => 'This Week',
      'last_week' => 'Last Week',
      'last_month' => 'Last Month',
      'all_expenses' => 'All Expenses',
      _ => 'This Month',
    };
  // Dynamic effective limit: percentage of selected-period savings when configured
  final box = Hive.box('budgetBox');
  double percent =
    (box.get(_limitPercentKeyForPeriod(_period)) as num?)?.toDouble() ??
      0.0;
  // Fallback to This Month if current period has no saved value
  if (percent <= 0) {
    percent = (box.get('expensesLimitPercent_this_month') as num?)
        ?.toDouble() ??
      0.0;
  }
    double? effectiveLimit;
    if (percent > 0 && widget.savingsRows != null) {
      final periodSavings = _sumForPeriod(widget.savingsRows!);
      effectiveLimit = (percent / 100.0) * periodSavings;
    }
    if (effectiveLimit != null && effectiveLimit <= 0) {
      effectiveLimit = null; // hide bar/label when zero or negative
    }
    final rawRatio = (effectiveLimit != null && effectiveLimit > 0)
        ? (total / effectiveLimit)
        : 0.0;
    final progress = rawRatio.clamp(0.0, 1.0);

    // Notify when reaching 25% of limit for the active period (once per period window)
    if (effectiveLimit != null && effectiveLimit > 0) {
      final threshold = 0.25;
      if (rawRatio >= threshold) {
        final (start, _) = _getPeriodRange(_period);
        final marker = '${start.year.toString().padLeft(4, '0')}-${start.month.toString().padLeft(2, '0')}-${start.day.toString().padLeft(2, '0')}';
        final flagKey = 'notif_expenses_25_${_period}_$marker';
        final notified = box.get(flagKey) == true;
        if (!notified) {
          final spent = currency.format(total);
          final limitStr = currency.format(effectiveLimit);
          final pct = (rawRatio * 100).toStringAsFixed(1);
          // Stable-ish id per period
          int pid;
          switch (_period) {
            case 'this_week':
              pid = 1;
              break;
            case 'this_month':
              pid = 2;
              break;
            case 'all_expenses':
              pid = 3;
              break;
            case 'last_week':
              pid = 4;
              break;
            case 'last_month':
              pid = 5;
              break;
            default:
              pid = 9;
          }
          // Fire-and-forget immediate notification
          NotificationService().showNow(
            3000 + pid,
            title: 'Expenses hit 25% of limit',
            body: '$periodLabel: $spent of $limitStr ($pct%)',
          );
          box.put(flagKey, true);
        }
      }
    }
    // trio totals removed from header UI
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppGradientBackground(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: _SummaryHeader(
                  periodLabel: periodLabel,
                  currentPeriodKey: _period,
                  onChangePeriod: (p) => _setPeriod(p),
                  totalLabel: currency.format(total),
                  limitLabel: effectiveLimit != null
                      ? currency.format(effectiveLimit)
                      : null,
                  progress: progress,
                  rawProgress: rawRatio,
                  overLimit:
                      (effectiveLimit != null) && total > (effectiveLimit),
                  onSetLimit: widget.onSetLimit,
                  limitPercent: percent,
                ),
              ),
            ),
            // Search & Sort controls (same design as Savings tab)
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
                              key: const ValueKey('search-expanded'),
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
                                          hintText: 'Search expenses…',
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
                              key: ValueKey('search-collapsed'),
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
                    "No expenses yet. Tap '+' to add.",
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
                  return _buildExpenseCard(
                    context,
                    row,
                    originalIndex >= 0 ? originalIndex : index,
                  );
                },
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'expenses-fab',
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        elevation: 6,
        extendedPadding: const EdgeInsets.symmetric(horizontal: 20),
        onPressed: () async {
          final newExpense = await Navigator.push<Map<String, dynamic>>(
            context,
            MaterialPageRoute(
              builder: (_) => ExpenseEditPage(
                expense: {
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
          if (newExpense != null) {
            final newRows = List<Map<String, dynamic>>.from(rows);
            newRows.add(newExpense);
            widget.onRowsChanged(newRows);
          }
        },
        icon: const Icon(Icons.add),
        label: const Text("Add Expense"),
      ),
    );
  }

  Widget _buildExpenseCard(
    BuildContext context,
    Map<String, dynamic> row,
    int index,
  ) {
    final currency = NumberFormat.currency(symbol: '₱', decimalDigits: 2);
    final base = _categoryColor(context, (row['Category'] ?? '') as String?);
    final pillowColor = Color.alphaBlend(
      base.withValues(alpha: 0.08),
      Colors.white,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
      child: PressableNeumorphic(
        backgroundColor: pillowColor,
        borderRadius: 18,
        padding: const EdgeInsets.all(16),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ExpenseDetailsPage(
                expense: row,
                onEdit: (updatedExpense) {
                  final newRows = List<Map<String, dynamic>>.from(widget.rows);
                  newRows[index] = {
                    ...row,
                    ...updatedExpense,
                    'id': row['id'] ?? updatedExpense['id'],
                  };
                  widget.onRowsChanged(newRows);
                  Navigator.pop(context);
                },
                onDelete: () {
                  final newRows = List<Map<String, dynamic>>.from(widget.rows);
                  newRows.removeAt(index);
                  widget.onRowsChanged(newRows);
                  Navigator.pop(context);
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
                color: base,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                _categoryIcon((row['Category'] ?? '') as String?),
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
                      (row['Category'] ?? 'No Category').toString(),
                      if (((row['Subcategory'] ?? '') as String)
                          .trim()
                          .isNotEmpty)
                        (row['Subcategory'] as String),
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
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _buildReceiptThumb(row),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReceiptThumb(Map<String, dynamic> row) {
    final local = (row['LocalReceiptPath'] ?? '') as String;
    final url = (row['ReceiptUrl'] ?? '') as String;
    if (local.isNotEmpty) {
      return Image.file(
        File(local),
        width: 64,
        height: 64,
        fit: BoxFit.cover,
        errorBuilder: (c, e, s) => _brokenThumb(),
      );
    }
    if (url.isNotEmpty) {
      return Image.network(
        url,
        width: 64,
        height: 64,
        fit: BoxFit.cover,
        errorBuilder: (c, e, s) => _brokenThumb(),
      );
    }
    final mem = row['Receipt'];
    if (mem != null && mem is Uint8List) {
      return Image.memory(
        mem,
        width: 64,
        height: 64,
        fit: BoxFit.cover,
        errorBuilder: (c, e, s) => _brokenThumb(),
      );
    }
    return Container(
      width: 64,
      height: 64,
      color: Colors.grey[200],
      child: const Icon(Icons.receipt_long, size: 28),
    );
  }

  Widget _brokenThumb() => Container(
    width: 64,
    height: 64,
    color: Colors.grey[200],
    child: const Icon(Icons.broken_image, size: 28),
  );
}

class _SummaryHeader extends StatelessWidget {
  final String periodLabel;
  final String totalLabel;
  final String? limitLabel;
  final double progress;
  final double rawProgress; // unclamped ratio
  final bool overLimit;
  final VoidCallback? onSetLimit;
  final String
  currentPeriodKey; // 'this_week' | 'this_month' | 'last_week' | 'last_month'
  final ValueChanged<String> onChangePeriod;
  final double limitPercent; // e.g., 30.0

  const _SummaryHeader({
    required this.periodLabel,
    required this.totalLabel,
    required this.limitLabel,
    required this.progress,
    required this.rawProgress,
    required this.overLimit,
    required this.onSetLimit,
    required this.currentPeriodKey,
    required this.onChangePeriod,
    required this.limitPercent,
  });

  @override
  Widget build(BuildContext context) {
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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PopupMenuButton<String>(
                      tooltip: 'Change period',
                      onSelected: onChangePeriod,
                      itemBuilder: (ctx) => [
                        _periodItem('This Week', 'this_week'),
                        _periodItem('This Month', 'this_month'),
                        _periodItem('Last Week', 'last_week'),
                        _periodItem('Last Month', 'last_month'),
                        _periodItem('All Expenses', 'all_expenses'),
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
                    Text(
                      totalLabel,
                      style: Theme.of(context).textTheme.headlineSmall!
                          .copyWith(fontWeight: FontWeight.w800, color: Colors.red),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: onSetLimit,
                icon: const Icon(Icons.tune),
                label: const Text('Set limit'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (limitLabel != null) ...[
            // Move limit above the progress bar
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Limit: $limitLabel',
                      style: TextStyle(
                        color: overLimit ? Colors.red : Colors.grey[700],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tooltip(
                      message:
                          'Limit = ${limitPercent.toStringAsFixed(0)}% of $periodLabel savings.',
                      child: IconButton(
                        constraints: const BoxConstraints(minWidth: 32),
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.help_outline, size: 18),
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('How is the limit calculated?'),
                              content: Text(
                                'Limit = ${limitPercent.toStringAsFixed(0)}% of $periodLabel savings.',
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
                Text(
                  overLimit ? 'Over limit' : 'On track',
                  style: TextStyle(
                    color: overLimit ? Colors.red : Colors.green,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () {
                if (limitLabel == null || progress.isNaN) return;
                final rpct = rawProgress * 100;
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
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 10,
                  backgroundColor: Colors.grey.shade300,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    overLimit
                        ? Colors.red
                        : (progress > 0.75 ? Colors.orange : Colors.green),
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

PopupMenuItem<String> _periodItem(String label, String key) {
  return PopupMenuItem<String>(value: key, child: Text(label));
}

// Simple press scale wrapper to add microinteraction on glass cards
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  const PressableScale({super.key, required this.child, this.onTap});
  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;
  void _set(bool v) => setState(() => _down = v);
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapCancel: () => _set(false),
      onTapUp: (_) => _set(false),
      onTap: widget.onTap,
      child: AnimatedScale(
        duration: const Duration(milliseconds: 120),
        scale: _down ? 0.98 : 1.0,
        child: widget.child,
      ),
    );
  }
}

// Glassmorphism container: frosted glass look with blur + translucent gradient
// Local glass/pillow duplicates removed; using shared widgets instead.

class ExpenseDetailsPage extends StatelessWidget {
  final Map<String, dynamic> expense;
  final void Function(Map<String, dynamic> updatedExpense) onEdit;
  final VoidCallback onDelete;

  const ExpenseDetailsPage({
    super.key,
    required this.expense,
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
          title: const Text('Expense Details'),
          actions: [
            IconButton(
              icon: const Icon(Icons.edit, size: 32),
              tooltip: 'Edit',
              onPressed: () async {
                final updatedExpense =
                    await Navigator.push<Map<String, dynamic>>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ExpenseEditPage(expense: expense),
                      ),
                    );
                if (updatedExpense != null) {
                  onEdit(updatedExpense);
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
                      'Are you sure you want to delete this expense?',
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
                'Expense Details',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 24),
              _buildDetailRow(
                'Category',
                [
                  (expense['Category'] ?? '').toString(),
                  if (((expense['Subcategory'] ?? '') as String)
                      .toString()
                      .trim()
                      .isNotEmpty)
                    (expense['Subcategory']).toString(),
                ].where((e) => e.isNotEmpty).join(' • '),
              ),
              _buildDetailRow(
                'Amount',
                currency.format((expense['Amount'] ?? 0) as num),
              ),
              _buildDetailRow('Date', expense['Date'] ?? ''),
              _buildDetailRow('Note', expense['Note'] ?? ''),
              const SizedBox(height: 32),
              Center(
                child: Builder(
                  builder: (context) {
                    final localPath =
                        (expense['LocalReceiptPath'] ?? '') as String;
                    final url = (expense['ReceiptUrl'] ?? '') as String;
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
                    } else if (expense['Receipt'] != null) {
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(
                          expense['Receipt'],
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

class ExpenseEditPage extends StatefulWidget {
  final Map<String, dynamic> expense;

  const ExpenseEditPage({super.key, required this.expense});

  @override
  State<ExpenseEditPage> createState() => _ExpenseEditPageState();
}

class _ExpenseEditPageState extends State<ExpenseEditPage> {
  late TextEditingController amountController;
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

  // Validation is handled in _handleSaveTap to also show SnackBar reasons.

  @override
  void initState() {
    super.initState();
    final rawMap =
        box.get('categories') as Map? ??
        {
          'Grocery': [],
          'House': ['Electricity Bill', 'Water Bill'],
          'Car': [],
        };

    categoriesMap = rawMap.map<String, List<String>>((key, value) {
      final list = (value as List).map((e) => e.toString()).toList();
      return MapEntry(key.toString(), list);
    });

    // Merge in sensible defaults without overwriting user data
    final Map<String, List<String>> defaults = {
      'Grocery': [
        'Supermarket',
        'Produce',
        'Meat & Seafood',
        'Snacks',
        'Beverages',
        'Household Supplies',
      ],
      'Car': ['Fuel', 'Maintenance', 'Parking', 'Insurance', 'Registration'],
      // Extra helpful category
      'Health': ['Medicine', 'Checkup', 'Dental', 'Insurance'],
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
      box.put('categories', categoriesMap);
    }

    selectedCategory = widget.expense['Category'] ?? '';
    selectedSubcategory = widget.expense['Subcategory'] ?? '';
    // Pre-format amount if present
    String amtText = '';
    final amt = widget.expense['Amount'];
    if (amt is num && amt > 0) {
      amtText = _decimalFmt.format(amt);
    }
    amountController = TextEditingController(text: amtText);
    dateController = TextEditingController(text: widget.expense['Date'] ?? '');
    noteController = TextEditingController(text: widget.expense['Note'] ?? '');
  // Initialize possible receipt sources
  receipt = widget.expense['Receipt'];
  final lp = (widget.expense['LocalReceiptPath'] ?? '') as String;
  localPath = lp.isNotEmpty ? lp : null;
  final ru = (widget.expense['ReceiptUrl'] ?? '') as String;
  receiptUrl = ru.isNotEmpty ? ru : null;
    if (!categoriesMap.containsKey(selectedCategory)) {
      selectedCategory = null;
      selectedSubcategory = null;
    }
    // Default date-time to now if empty
    if (dateController.text.trim().isEmpty) {
      final now = DateTime.now();
      dateController.text =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
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
    final bytes = await pickedFile.readAsBytes();
    try {
      // Downscale large images to save space/perf
      final decoded = img.decodeImage(bytes);
      if (decoded != null) {
        const maxW = 1600;
        if (decoded.width > maxW) {
          final resized = img.copyResize(decoded, width: maxW);
          final jpg = img.encodeJpg(resized, quality: 85);
          setState(() {
            receipt = Uint8List.fromList(jpg);
            // If user attaches a new image, clear path/url references
            localPath = null;
            receiptUrl = null;
          });
          return;
        }
      }
    } catch (_) {}
    setState(() {
      receipt = bytes;
      localPath = null;
      receiptUrl = null;
    });
  }

  Future<void> _showImageSourceSheet() async {
    final src = await showModalBottomSheet<ImageSource>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Pick from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (src != null) {
      await _pickImage(src);
    }
  }

  Future<void> _addNewCategory() async {
    final controller = TextEditingController();
    final newCat = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Category'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Category name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.isNotEmpty) Navigator.pop(ctx, v);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (newCat != null && newCat.trim().isNotEmpty) {
      setState(() {
        categoriesMap.putIfAbsent(newCat, () => <String>[]);
        selectedCategory = newCat;
        selectedSubcategory = null;
      });
      box.put('categories', categoriesMap);
    }
  }

  Future<void> _addNewSubcategory() async {
    if (selectedCategory == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Select a category first')));
      return;
    }
    final controller = TextEditingController();
    final newSub = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Subcategory'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Subcategory name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final v = controller.text.trim();
              if (v.isNotEmpty) Navigator.pop(ctx, v);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (newSub != null && newSub.trim().isNotEmpty) {
      final subs = categoriesMap[selectedCategory] ?? <String>[];
      if (!subs.contains(newSub)) {
        setState(() {
          subs.add(newSub);
          categoriesMap[selectedCategory!] = subs;
          selectedSubcategory = newSub;
        });
        box.put('categories', categoriesMap);
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
            widget.expense['Category'] == '' ? 'Add Expense' : 'Edit Expense',
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
                              (cat) => DropdownMenuItem(
                                value: cat,
                                child: Text(cat),
                              ),
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
                    const SizedBox(width: 12),
                    ElevatedButton.icon(
                      onPressed: _addNewCategory,
                      icon: const Icon(Icons.add),
                      label: const Text("Add Category"),
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
                  inputFormatters: [CurrencyInputFormatter()],
                  onChanged: (_) => setState(() {}),
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
                        (receipt == null && (localPath ?? '').isEmpty && (receiptUrl ?? '').isEmpty)
                            ? 'Attach Receipt'
                            : 'Change Receipt',
                      ),
                    ),
                    if (receipt != null || (localPath ?? '').isNotEmpty || (receiptUrl ?? '').isNotEmpty)
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
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: _handleSaveTap,
            icon: const Icon(Icons.save),
            label: const Text("Save Expense"),
          ),
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

    final updatedExpense = {
      'Category': selectedCategory ?? '',
      'Subcategory': selectedSubcategory ?? '',
      'Amount': amountVal,
      'Date': dateController.text,
      'Note': noteController.text,
      'Receipt': receipt,
      // If user picked a new image (in-memory), clear path/url so details uses new bytes
      if (receipt != null) 'LocalReceiptPath': null,
      if (receipt != null) 'ReceiptUrl': '',
      // If user removed all sources, ensure all fields are cleared
      if (receipt == null && (localPath ?? '').isEmpty && (receiptUrl ?? '').isEmpty) ...{
        'LocalReceiptPath': null,
        'ReceiptUrl': '',
      },
      // Bubble through any existing id so the caller updates in place
      'id': widget.expense['id'],
    };
    Navigator.pop(context, updatedExpense);
  }
}

// Lightweight decimal currency formatter (no symbol, adds grouping and limits to 2 decimals)
class CurrencyInputFormatter extends TextInputFormatter {
  final NumberFormat _fmt = NumberFormat.decimalPattern();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (text.isEmpty) return newValue.copyWith(text: '');

    // Keep digits and at most one decimal point
    final buffer = StringBuffer();
    int dotCount = 0;
    for (final ch in text.characters) {
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

    // Limit to two decimal places if any
    if (sanitized.contains('.')) {
      final parts = sanitized.split('.');
      final decimals = parts[1];
      sanitized =
          '${parts[0]}.${decimals.length > 2 ? decimals.substring(0, 2) : decimals}';
    }

    // Split into int/decimals for grouping
    String intPart = sanitized;
    String decPart = '';
    if (sanitized.contains('.')) {
      final parts = sanitized.split('.');
      intPart = parts[0];
      decPart = parts[1];
    }

    // Avoid leading zeroes like 0001
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

// Category helpers for quick visual grouping
Color _categoryColor(BuildContext context, String? cat) {
  final cs = Theme.of(context).colorScheme;
  final key = (cat ?? '').toLowerCase();
  if (key.contains('grocery') || key.contains('food') || key.contains('meal')) {
    return cs.tertiaryContainer;
  }
  if (key.contains('house') || key.contains('rent') || key.contains('home')) {
    return cs.primaryContainer;
  }
  if (key.contains('car') || key.contains('transport')) {
    return cs.secondaryContainer;
  }
  if (key.contains('health') || key.contains('medical')) {
    return cs.errorContainer;
  }
  if (key.contains('utility') || key.contains('bill')) {
    return cs.surfaceContainerHigh;
  }
  return cs.surfaceContainerHighest;
}

IconData _categoryIcon(String? cat) {
  final key = (cat ?? '').toLowerCase();
  if (key.contains('grocery') || key.contains('food') || key.contains('meal')) {
    return Icons.local_grocery_store;
  }
  if (key.contains('house') || key.contains('rent') || key.contains('home')) {
    return Icons.home_outlined;
  }
  if (key.contains('car') || key.contains('transport')) {
    return Icons.directions_car_outlined;
  }
  if (key.contains('health') || key.contains('medical')) {
    return Icons.health_and_safety_outlined;
  }
  if (key.contains('utility') || key.contains('bill')) {
    return Icons.receipt_long;
  }
  return Icons.shopping_bag;
}
