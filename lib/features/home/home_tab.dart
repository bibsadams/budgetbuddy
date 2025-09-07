import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';

enum ChartMode { bar, pie }

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
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  final Box box = Hive.box('budgetBox');
  DateTime _selectedMonth = DateTime(DateTime.now().year, DateTime.now().month);
  ChartMode _chartMode = ChartMode.bar;

  Map<String, List<Map<String, dynamic>>> tableData = {};
  Map<String, double> tabLimits = {};
  Map<String, double> savingsGoals = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    final rawTableData = box.get('tableData') as Map?;
    tableData = {};
    if (rawTableData != null) {
      rawTableData.forEach((key, value) {
        final list = (value as List?)?.map<Map<String, dynamic>>((item) {
          if (item is Map) {
            return item.map((k, v) => MapEntry(k.toString(), v));
          }
          return {};
        }).toList();
        tableData[key.toString()] = list ?? [];
      });
    }
    final rawTabLimits = box.get('tabLimits') as Map?;
    tabLimits = {};
    rawTabLimits?.forEach(
      (k, v) => tabLimits[k.toString()] = (v as num).toDouble(),
    );
    final rawSavingsGoals = box.get('savingsGoals') as Map?;
    savingsGoals = {};
    rawSavingsGoals?.forEach(
      (k, v) => savingsGoals[k.toString()] = (v as num).toDouble(),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final monthLabel = DateFormat.yMMM().format(_selectedMonth);
    final expenses = (tableData['Expenses'] ?? []).where((row) {
      final d = DateTime.tryParse((row['Date'] ?? '').toString());
      return d != null &&
          d.year == _selectedMonth.year &&
          d.month == _selectedMonth.month;
    }).toList();
    final savings = tableData['Savings'] ?? [];
    final bills = tableData['Bills'] ?? [];

    final totalExpense = expenses.fold<double>(
      0.0,
      (s, r) => s + ((r['Amount'] ?? 0.0) as num).toDouble(),
    );
    final expenseLimit = tabLimits['Expenses'] ?? 0.0;
    final goal = savingsGoals['Savings'] ?? 0.0;
    final savedTotal = savings.fold<double>(
      0.0,
      (s, r) => s + ((r['Amount'] ?? 0.0) as num).toDouble(),
    );

    final dueSoon = bills.where((b) {
      final d = DateTime.tryParse((b['Due Date'] ?? '').toString());
      if (d == null) return false;
      return d.difference(DateTime.now()).inDays <= 7;
    }).toList();

    final byCategory = <String, double>{};
    for (final r in expenses) {
      final cat = (r['Category'] ?? r['Name'] ?? 'Uncategorized').toString();
      final amt = ((r['Amount'] ?? 0.0) as num).toDouble();
      byCategory[cat] = (byCategory[cat] ?? 0) + amt;
    }
    final entries = byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return CustomScrollView(
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
                  title: 'This Month Expense',
                  value: '₱${totalExpense.toStringAsFixed(2)}',
                  secondary: expenseLimit > 0
                      ? 'Limit: ₱${expenseLimit.toStringAsFixed(0)}'
                      : null,
                  progress: expenseLimit > 0
                      ? (totalExpense / expenseLimit).clamp(0.0, 1.0)
                      : null,
                ),
                _StatCard(
                  title: 'Savings',
                  value: '₱${savedTotal.toStringAsFixed(2)}',
                  secondary: goal > 0
                      ? 'Goal: ₱${goal.toStringAsFixed(0)}'
                      : null,
                  progress: goal > 0
                      ? (savedTotal / goal).clamp(0.0, 1.0)
                      : null,
                ),
                _StatCard(
                  title: 'Bills Due Soon',
                  value: '${dueSoon.length}',
                  secondary: 'within 7 days',
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(child: SizedBox(height: 16)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Card(
              elevation: 1,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Top Categories — $monthLabel',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        SegmentedButton<ChartMode>(
                          segments: const [
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
                    SizedBox(
                      height: 220,
                      child: entries.isEmpty
                          ? const Center(child: Text('No data for this month'))
                          : (_chartMode == ChartMode.bar
                                ? BarChart(
                                    BarChartData(
                                      borderData: FlBorderData(show: false),
                                      gridData: const FlGridData(show: false),
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
                                                  idx >= entries.length)
                                                return const SizedBox();
                                              final label = entries[idx].key;
                                              return Padding(
                                                padding: const EdgeInsets.only(
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
                                        for (int i = 0; i < entries.length; i++)
                                          BarChartGroupData(
                                            x: i,
                                            barRods: [
                                              BarChartRodData(
                                                toY: entries[i].value,
                                                width: 14,
                                                borderRadius:
                                                    BorderRadius.circular(6),
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.primary,
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
                                            color: _colorForKey(context, e.key),
                                            radius: 70,
                                          ),
                                      ],
                                    ),
                                  )),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
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
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [cs.primaryContainer, cs.surfaceContainerHighest],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          IconButton(onPressed: onPrev, icon: const Icon(Icons.chevron_left)),
          Expanded(
            child: Center(
              child: Text(
                monthLabel,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
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
  const _StatCard({
    required this.title,
    required this.value,
    this.secondary,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: 260,
      child: Card(
        child: Padding(
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
              Text(
                value,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
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
                  child: LinearProgressIndicator(value: progress, minHeight: 8),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
