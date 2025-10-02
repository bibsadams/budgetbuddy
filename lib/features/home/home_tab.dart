import 'package:flutter/material.dart';
import 'package:budgetbuddy/widgets/pressable_neumorphic.dart';
import 'package:intl/intl.dart';
import 'package:budgetbuddy/widgets/app_gradient_background.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:hive/hive.dart';

enum ChartMode { bar, details, pie }

Color _colorForKey(BuildContext context, String key) {
  final cs = Theme.of(context).colorScheme;
  final palette = <Color>[
    cs.primary,
    cs.secondary,
    cs.tertiary,
    cs.primaryContainer,
    cs.secondaryContainer,
    cs.tertiaryContainer,
  ];
  int idx = key.hashCode;
  if (idx < 0) idx = -idx;
  return palette[idx % palette.length];
}

class HomeTab extends StatefulWidget {
  final Map<String, List<Map<String, dynamic>>> tableData;
  final Map<String, double> tabLimits;
  final Map<String, double> savingsGoals;

  const HomeTab({
    super.key,
    required this.tableData,
    required this.tabLimits,
    required this.savingsGoals,
  });

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  DateTime _selectedMonth = DateTime(DateTime.now().year, DateTime.now().month);
  ChartMode _chartMode = ChartMode.bar;

  @override
  Widget build(BuildContext context) {
    final monthLabel = DateFormat.yMMM().format(_selectedMonth);

    // Expenses for selected month
    final expenses = (widget.tableData['Expenses'] ?? []).where((row) {
      final d = DateTime.tryParse((row['Date'] ?? '').toString());
      return d != null &&
          d.year == _selectedMonth.year &&
          d.month == _selectedMonth.month;
    }).toList();
    final totalExpense = expenses.fold<double>(
      0.0,
      (sum, r) => sum + ((r['Amount'] ?? 0) as num).toDouble(),
    );
    // Compute effective limit for the selected month:
    // If a percent is set (per-month), use percent of selected month savings deposits; else use fixed tab limit.
    final box = Hive.box('budgetBox');
    final double percent =
        (box.get('expensesLimitPercent_this_month') as num?)?.toDouble() ?? 0.0;
    double expenseLimit = (widget.tabLimits['Expenses'] ?? 0.0);
    final savingsRowsAll = (widget.tableData['Savings'] ?? []) as List? ?? [];
    final savingsForMonth = savingsRowsAll.where((r) {
      final d = DateTime.tryParse((r['Date'] ?? '').toString());
      return d != null &&
          d.year == _selectedMonth.year &&
          d.month == _selectedMonth.month;
    }).toList();
    final monthlySavings = savingsRowsAll.fold<double>(0.0, (sum, r) {
      final d = DateTime.tryParse((r['Date'] ?? '').toString());
      if (d != null &&
          d.year == _selectedMonth.year &&
          d.month == _selectedMonth.month) {
        final a = (r['Amount'] ?? 0) as num;
        return sum + a.toDouble();
      }
      return sum;
    });
    if (percent > 0) {
      expenseLimit = (percent / 100.0) * monthlySavings;
    }

    // Savings card: Net = Total Deposit savings of selected month - Total Expenses of selected month
    final monthlyNetSavings = (monthlySavings - totalExpense);
    // Goal uses the per-period percent set in Savings tab for this month
    // Removed goal display in Savings card

    // Bills due within next 7 days
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final bills = (widget.tableData['Bills'] ?? []) as List? ?? [];
    DateTime? parseDateFlexible(String v) {
      if (v.isEmpty) return null;
      final iso = DateTime.tryParse(v);
      if (iso != null) return iso;
      try {
        return DateFormat('MM/dd/yyyy').parseStrict(v);
      } catch (_) {}
      try {
        return DateFormat('dd/MM/yyyy').parseStrict(v);
      } catch (_) {}
      try {
        return DateFormat('M/d/yyyy').parseStrict(v);
      } catch (_) {}
      return null;
    }

    final dueSoon = bills.where((row) {
      final ds = (row['Due Date'] ?? row['Date'] ?? '').toString();
      final dt = parseDateFlexible(ds);
      if (dt == null) return false;
      final d0 = DateTime(dt.year, dt.month, dt.day);
      final diff = d0.difference(today).inDays;
      return diff >= 0 && diff <= 7;
    }).toList();

    // Build category totals for chart
    final byCategory = <String, double>{};
    for (final r in expenses) {
      final cat = (r['Category'] ?? r['Name'] ?? 'Uncategorized').toString();
      final amt = ((r['Amount'] ?? 0.0) as num).toDouble();
      byCategory[cat] = (byCategory[cat] ?? 0) + amt;
    }
    final entries = byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return AppGradientBackground(
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: _HeroHeader(
                monthLabel: monthLabel,
                onPrev: () => setState(
                  () => _selectedMonth = DateTime(
                    _selectedMonth.year,
                    _selectedMonth.month - 1,
                  ),
                ),
                onNext: () => setState(
                  () => _selectedMonth = DateTime(
                    _selectedMonth.year,
                    _selectedMonth.month + 1,
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _StatCard(
                    title: 'Expenses',
                    value: NumberFormat.currency(
                      symbol: '₱',
                      decimalDigits: 2,
                    ).format(totalExpense),
                    secondary: expenseLimit > 0
                        ? 'Limit: ${NumberFormat.currency(symbol: '₱', decimalDigits: 0).format(expenseLimit)}'
                        : null,
                    // Remove progress bar for Expenses per request
                    progress: null,
                    // Always show expenses value in red
                    valueColor: Colors.red,
                    tint: const Color(0xFFEF476F),
                  ),
                  _StatCard(
                    title: 'Savings',
                    value: NumberFormat.currency(
                      symbol: '₱',
                      decimalDigits: 2,
                    ).format(monthlyNetSavings),
                    // Remove goal subtitle per request
                    secondary: null,
                    progress: null,
                    // Savings value green if >= 0, else red
                    valueColor: monthlyNetSavings >= 0
                        ? Colors.green
                        : Colors.red,
                    tint: const Color(0xFF06D6A0),
                  ),
                  _StatCard(
                    title: 'Bills Due Soon',
                    value: '${dueSoon.length}',
                    secondary: 'within 7 days',
                    tint: const Color(0xFFF9C74F),
                  ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 16)),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: PressableNeumorphic(
                borderRadius: 20,
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const SizedBox.shrink(),
                        SegmentedButton<ChartMode>(
                          segments: const [
                            ButtonSegment(
                              value: ChartMode.details,
                              icon: Icon(Icons.list_alt),
                              label: Text('Details'),
                            ),
                            ButtonSegment(
                              value: ChartMode.bar,
                              icon: Icon(Icons.bar_chart),
                              label: Text('Bar'),
                            ),
                            ButtonSegment(
                              value: ChartMode.pie,
                              icon: Icon(Icons.pie_chart),
                              label: Text('Pie'),
                            ),
                          ],
                          selected: {_chartMode},
                          onSelectionChanged: (s) =>
                              setState(() => _chartMode = s.first),
                          style: const ButtonStyle(
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: _chartMode == ChartMode.details
                          ? _MonthlyDetails(
                              expenses: expenses,
                              savings: List<Map<String, dynamic>>.from(
                                savingsForMonth,
                              ),
                            )
                          : SizedBox(
                              key: ValueKey(_chartMode),
                              height: 220,
                              child: entries.isEmpty
                                  ? const Center(
                                      child: Text('No data for this month'),
                                    )
                                  : (_chartMode == ChartMode.bar
                                        ? BarChart(
                                            BarChartData(
                                              borderData: FlBorderData(
                                                show: false,
                                              ),
                                              gridData: const FlGridData(
                                                show: false,
                                              ),
                                              titlesData: FlTitlesData(
                                                leftTitles: const AxisTitles(
                                                  sideTitles: SideTitles(
                                                    showTitles: false,
                                                  ),
                                                ),
                                                rightTitles: const AxisTitles(
                                                  sideTitles: SideTitles(
                                                    showTitles: false,
                                                  ),
                                                ),
                                                topTitles: const AxisTitles(
                                                  sideTitles: SideTitles(
                                                    showTitles: false,
                                                  ),
                                                ),
                                                bottomTitles: AxisTitles(
                                                  sideTitles: SideTitles(
                                                    showTitles: true,
                                                    reservedSize: 42,
                                                    getTitlesWidget: (value, meta) {
                                                      final idx = value.toInt();
                                                      if (idx < 0 ||
                                                          idx >=
                                                              entries.length) {
                                                        return const SizedBox();
                                                      }
                                                      final label =
                                                          entries[idx].key;
                                                      return Padding(
                                                        padding:
                                                            const EdgeInsets.only(
                                                              top: 8.0,
                                                            ),
                                                        child: Text(
                                                          label.length > 8
                                                              ? '${label.substring(0, 8)}…'
                                                              : label,
                                                          style: Theme.of(
                                                            context,
                                                          ).textTheme.bodySmall,
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ),
                                              ),
                                              barGroups: [
                                                for (
                                                  int i = 0;
                                                  i < entries.length;
                                                  i++
                                                )
                                                  BarChartGroupData(
                                                    x: i,
                                                    barRods: [
                                                      BarChartRodData(
                                                        toY: entries[i].value,
                                                        width: 14,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              6,
                                                            ),
                                                        color: _colorForKey(
                                                          context,
                                                          entries[i].key,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                              ],
                                            ),
                                          )
                                        : PieChart(
                                            PieChartData(
                                              sectionsSpace: 2,
                                              centerSpaceRadius: 40,
                                              sections: [
                                                for (final e in entries)
                                                  PieChartSectionData(
                                                    value: e.value,
                                                    title: '',
                                                    color: _colorForKey(
                                                      context,
                                                      e.key,
                                                    ),
                                                    radius: 70,
                                                  ),
                                              ],
                                            ),
                                          )),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

class _HeroHeader extends StatelessWidget {
  final String monthLabel;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  const _HeroHeader({
    required this.monthLabel,
    required this.onPrev,
    required this.onNext,
  });
  @override
  Widget build(BuildContext context) {
    return PressableNeumorphic(
      borderRadius: 16,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          IconButton(onPressed: onPrev, icon: const Icon(Icons.chevron_left)),
          Expanded(
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.1, 0),
                      end: Offset.zero,
                    ).animate(anim),
                    child: child,
                  ),
                ),
                child: Text(
                  monthLabel,
                  key: ValueKey(monthLabel),
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ),
          IconButton(onPressed: onNext, icon: const Icon(Icons.chevron_right)),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final String? secondary;
  final double? progress;
  final Color? tint;
  final Color? valueColor;
  const _StatCard({
    required this.title,
    required this.value,
    this.secondary,
    this.progress,
    this.tint,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 260,
      child: PressableNeumorphic(
        borderRadius: 16,
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 200),
              style:
                  (Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: valueColor,
                  )) ??
                  TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: valueColor,
                  ),
              child: Text(value),
            ),
            if (secondary != null) ...[
              const SizedBox(height: 4),
              Text(
                secondary!,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.primary),
              ),
            ],
            if (progress != null) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: TweenAnimationBuilder<double>(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  tween: Tween<double>(
                    begin: 0.0,
                    end: (progress!).clamp(0.0, 1.0),
                  ),
                  builder: (context, v, _) =>
                      LinearProgressIndicator(value: v, minHeight: 8),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// Glassmorphism container: frosted glass look with blur + translucent gradient
// glass container is no longer used here; shared PressableNeumorphic from widgets is used.

class _MonthlyDetails extends StatelessWidget {
  final List<Map<String, dynamic>> expenses;
  final List<Map<String, dynamic>> savings;
  const _MonthlyDetails({required this.expenses, required this.savings});

  Map<String, double> _sumByCat(List<Map<String, dynamic>> rows) {
    final map = <String, double>{};
    for (final r in rows) {
      final cat = (r['Category'] ?? r['Name'] ?? 'Uncategorized').toString();
      final amt = (r['Amount'] is num) ? (r['Amount'] as num).toDouble() : 0.0;
      map[cat] = (map[cat] ?? 0) + amt;
    }
    return map;
  }

  Map<String, double> _sumBySub(List<Map<String, dynamic>> rows) {
    final map = <String, double>{};
    for (final r in rows) {
      final cat = (r['Category'] ?? r['Name'] ?? 'Uncategorized').toString();
      final sub = (r['Subcategory'] ?? 'Unspecified').toString();
      final key = '$cat • $sub';
      final amt = (r['Amount'] is num) ? (r['Amount'] as num).toDouble() : 0.0;
      map[key] = (map[key] ?? 0) + amt;
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: '₱', decimalDigits: 2);

    List<MapEntry<String, double>> sort(Map<String, double> m) {
      final l = m.entries.toList();
      l.sort((a, b) => b.value.compareTo(a.value));
      return l;
    }

    Widget listCard({
      required String title,
      required List<MapEntry<String, double>> entries,
      required bool isExpense,
    }) {
      return Card(
        elevation: 1,
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              if (entries.isEmpty)
                const ListTile(
                  title: Text('No data for selection'),
                  dense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 8),
                )
              else
                ...entries.map(
                  (e) => ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: CircleAvatar(
                      backgroundColor: _colorForKey(
                        context,
                        (isExpense ? 'EXP:' : 'SAV:') + e.key,
                      ),
                      radius: 10,
                    ),
                    title: Text(e.key),
                    trailing: Text(
                      currency.format(e.value),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    final savByCat = sort(_sumByCat(savings));
    final savBySub = sort(_sumBySub(savings));
    final expByCat = sort(_sumByCat(expenses));
    final expBySub = sort(_sumBySub(expenses));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        listCard(
          title: 'Savings by Category',
          entries: savByCat,
          isExpense: false,
        ),
        listCard(
          title: 'Savings by Subcategory',
          entries: savBySub,
          isExpense: false,
        ),
        listCard(
          title: 'Expenses by Category',
          entries: expByCat,
          isExpense: true,
        ),
        listCard(
          title: 'Expenses by Subcategory',
          entries: expBySub,
          isExpense: true,
        ),
      ],
    );
  }
}
