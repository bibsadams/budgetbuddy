import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:fl_chart/fl_chart.dart';
import 'report_export.dart';

class ReportTab extends StatefulWidget {
  final Map<String, List<Map<String, dynamic>>> tableData;
  final Map<String, Color> categoryColors;

  const ReportTab({
    super.key,
    required this.tableData,
    required this.categoryColors,
  });

  @override
  State<ReportTab> createState() => _ReportTabState();
}

class _ReportTabState extends State<ReportTab> {
  int touchedIndex = -1;
  String view = 'Expenses'; // or 'Savings'
  int selectedMonth = 0; // 0 = All months, 1..12
  int selectedYear = 0; // 0 = All years
  late final Box _box;
  String allYearsAgg = 'Yearly'; // or 'Quarterly'
  String savingsMode = 'Details'; // or 'Charts'
  String expensesMode = 'Details'; // or 'Charts'

  @override
  void initState() {
    super.initState();
    _box = Hive.box('budgetBox');
    // Restore filters
    view = (_box.get('report_view') as String?) ?? 'Expenses';
    selectedMonth = (_box.get('report_month') as int?) ?? 0;
    selectedYear = (_box.get('report_year') as int?) ?? 0;
    allYearsAgg = (_box.get('report_allYearsAgg') as String?) ?? 'Yearly';
    savingsMode = (_box.get('report_savingsMode') as String?) ?? 'Details';
    expensesMode = (_box.get('report_expensesMode') as String?) ?? 'Details';
  }

  Color _colorForKey(String key) {
    return widget.categoryColors.putIfAbsent(key, () {
      final seed = key.hashCode & 0xFFFFFF;
      return Color(0xFF000000 | seed).withValues(alpha: 1.0);
    });
  }

  bool _passesFilter(Object? dateValue) {
    if (selectedMonth == 0 && selectedYear == 0) return true;
    DateTime? dt;
    if (dateValue is DateTime) {
      dt = dateValue;
    } else if (dateValue is String) {
      dt = DateTime.tryParse(dateValue);
    }
    if (dt == null) return false;
    if (selectedYear != 0 && dt.year != selectedYear) return false;
    if (selectedMonth != 0 && dt.month != selectedMonth) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final expenses = widget.tableData['Expenses'] ?? [];
    final savings = widget.tableData['Savings'] ?? [];

    // Compute totals subject to filters
    final expenseTotals = <String, double>{};
    final expensesBySubcategory = <String, double>{};
    for (final r in expenses) {
      if (!_passesFilter(r['Date'])) continue;
      final cat = (r['Category'] ?? r['Name'] ?? 'Uncategorized').toString();
      final amt = (r['Amount'] is num) ? (r['Amount'] as num).toDouble() : 0.0;
      expenseTotals[cat] = (expenseTotals[cat] ?? 0) + amt;
      final sub = (r['Subcategory'] ?? 'Unspecified').toString();
      final subKey = '$cat • $sub';
      expensesBySubcategory[subKey] =
          (expensesBySubcategory[subKey] ?? 0) + amt;
    }

    final savingsByCategory = <String, double>{};
    final savingsBySubcategory = <String, double>{};
    for (final r in savings) {
      if (!_passesFilter(r['Date'])) continue;
      final cat = (r['Category'] ?? 'Uncategorized').toString();
      final sub = (r['Subcategory'] ?? 'Unspecified').toString();
      final amt = (r['Amount'] is num) ? (r['Amount'] as num).toDouble() : 0.0;
      savingsByCategory[cat] = (savingsByCategory[cat] ?? 0) + amt;
      final subKey = '$cat • $sub';
      savingsBySubcategory[subKey] = (savingsBySubcategory[subKey] ?? 0) + amt;
    }

    final entries = expenseTotals.entries.toList();
    entries.sort((a, b) => b.value.compareTo(a.value));
    final catEntries = savingsByCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final subEntries = savingsBySubcategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Controls
          Wrap(
            runSpacing: 8,
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'Expenses',
                    label: Text('Expenses'),
                    icon: Icon(Icons.payments_outlined),
                  ),
                  ButtonSegment(
                    value: 'Savings',
                    label: Text('Savings'),
                    icon: Icon(Icons.savings_outlined),
                  ),
                ],
                selected: {view},
                onSelectionChanged: (s) => setState(() {
                  view = s.first;
                  _box.put('report_view', view);
                }),
              ),
              if (view == 'Expenses')
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'Details',
                      label: Text('Details'),
                      icon: Icon(Icons.view_list),
                    ),
                    ButtonSegment(
                      value: 'Charts',
                      label: Text('Charts'),
                      icon: Icon(Icons.pie_chart_outline),
                    ),
                  ],
                  selected: {expensesMode},
                  onSelectionChanged: (s) => setState(() {
                    expensesMode = s.first;
                    _box.put('report_expensesMode', expensesMode);
                  }),
                ),
              if (view == 'Savings')
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'Details',
                      label: Text('Details'),
                      icon: Icon(Icons.view_list),
                    ),
                    ButtonSegment(
                      value: 'Charts',
                      label: Text('Charts'),
                      icon: Icon(Icons.pie_chart_outline),
                    ),
                  ],
                  selected: {savingsMode},
                  onSelectionChanged: (s) => setState(() {
                    savingsMode = s.first;
                    _box.put('report_savingsMode', savingsMode);
                  }),
                ),
              _MonthDropdown(
                value: selectedMonth,
                onChanged: (v) => setState(() {
                  selectedMonth = v ?? 0;
                  _box.put('report_month', selectedMonth);
                }),
              ),
              _YearDropdown(
                value: selectedYear,
                years: _yearsFromData(expenses + savings),
                onChanged: (v) => setState(() {
                  selectedYear = v ?? 0;
                  _box.put('report_year', selectedYear);
                }),
              ),
              if ((view == 'Savings' || view == 'Expenses') &&
                  selectedYear == 0)
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'Yearly', label: Text('Yearly')),
                    ButtonSegment(value: 'Quarterly', label: Text('Quarterly')),
                  ],
                  selected: {allYearsAgg},
                  onSelectionChanged: (s) => setState(() {
                    allYearsAgg = s.first;
                    _box.put('report_allYearsAgg', allYearsAgg);
                  }),
                ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('Export CSV'),
                onPressed: () async {
                  if (view == 'Expenses') {
                    // Build category totals (already filtered)
                    final rows = [
                      ['Category', 'Amount (₱)'],
                      ...expenseTotals.entries.map(
                        (e) => [e.key, e.value.toStringAsFixed(2)],
                      ),
                      [''],
                      ['Category • Subcategory', 'Amount (₱)'],
                      ...expensesBySubcategory.entries.map(
                        (e) => [e.key, e.value.toStringAsFixed(2)],
                      ),
                    ];
                    final title = _exportTitle('Expenses');
                    await ReportExportService.exportCsv(
                      filename: title,
                      rows: rows,
                    );
                  } else {
                    final rows = [
                      ['Category', 'Amount (₱)'],
                      ...savingsByCategory.entries.map(
                        (e) => [e.key, e.value.toStringAsFixed(2)],
                      ),
                      [''],
                      ['Category • Subcategory', 'Amount (₱)'],
                      ...savingsBySubcategory.entries.map(
                        (e) => [e.key, e.value.toStringAsFixed(2)],
                      ),
                    ];
                    final title = _exportTitle('Savings');
                    await ReportExportService.exportCsv(
                      filename: title,
                      rows: rows,
                    );
                  }
                },
              ),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('Export PDF'),
                onPressed: () async {
                  final title = _exportTitle(view);
                  if (view == 'Expenses') {
                    await ReportExportService.exportPdf(
                      filename: title,
                      title: '$title Report',
                      byCategory: Map.fromEntries(entries),
                      bySubcategory: Map.fromEntries(
                        expensesBySubcategory.entries.toList()
                          ..sort((a, b) => b.value.compareTo(a.value)),
                      ),
                    );
                  } else {
                    await ReportExportService.exportPdf(
                      filename: title,
                      title: '$title Report',
                      byCategory: Map.fromEntries(catEntries),
                      bySubcategory: Map.fromEntries(subEntries),
                    );
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Body
          Expanded(
            child: view == 'Expenses'
                ? (expensesMode == 'Details'
                      ? _buildExpensesDetailsView(expenses)
                      : _buildExpensesCharts(entries, expenses))
                : (savingsMode == 'Details'
                      ? _buildSavingsDetailsView(savings)
                      : _buildSavingsLists(
                          catEntries,
                          subEntries,
                          header: _buildSavingsStackedBarCard(savings),
                        )),
          ),
        ],
      ),
    );
  }

  String _exportTitle(String base) {
    String m = selectedMonth == 0
        ? 'AllMonths'
        : selectedMonth.toString().padLeft(2, '0');
    String y = selectedYear == 0 ? 'AllYears' : selectedYear.toString();
    return '${base}_$y-$m';
  }

  // Detailed Expenses view (mirrors Savings details)
  Widget _buildExpensesDetailsView(List<Map<String, dynamic>> allExpenses) {
    final rows = <Map<String, dynamic>>[];
    for (final r in allExpenses) {
      if (_passesFilter(r['Date'])) rows.add(r);
    }
    if (rows.isEmpty) {
      return const Center(
        child: Text('No expense data for the selected period.'),
      );
    }

    if (selectedYear == 0) {
      final byYear = <int, List<Map<String, dynamic>>>{};
      for (final r in rows) {
        final dt = r['Date'] is DateTime
            ? r['Date'] as DateTime
            : DateTime.tryParse((r['Date'] ?? '').toString());
        if (dt == null) continue;
        byYear.putIfAbsent(dt.year, () => []).add(r);
      }
      final years = byYear.keys.toList()..sort();
      return ListView(
        children: [
          for (final y in years)
            _GroupedTotalsTile(
              title: 'Year $y',
              rows: byYear[y]!,
              colorFor: _colorForKey,
              onOpen: (filtered) => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ExpensesRecordsListPage(rows: filtered),
                ),
              ),
            ),
        ],
      );
    } else if (selectedMonth == 0) {
      final byMonth = List.generate(12, (_) => <Map<String, dynamic>>[]);
      for (final r in rows) {
        final dt = r['Date'] is DateTime
            ? r['Date'] as DateTime
            : DateTime.tryParse((r['Date'] ?? '').toString());
        if (dt == null) continue;
        byMonth[dt.month - 1].add(r);
      }
      return ListView(
        children: [
          for (int m = 0; m < 12; m++)
            if (byMonth[m].isNotEmpty)
              _GroupedTotalsTile(
                title: _monthFull(m + 1),
                rows: byMonth[m],
                colorFor: _colorForKey,
                onOpen: (filtered) => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ExpensesRecordsListPage(rows: filtered),
                  ),
                ),
              ),
        ],
      );
    } else {
      return ListView(
        children: [
          _CategorySection(
            title: '${_monthFull(selectedMonth)} $selectedYear',
            rows: rows,
            colorFor: _colorForKey,
            onOpen: (filtered) => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ExpensesRecordsListPage(rows: filtered),
              ),
            ),
          ),
        ],
      );
    }
  }

  // Detailed Savings view (like in Savings tab but aggregated)
  Widget _buildSavingsDetailsView(List<Map<String, dynamic>> allSavings) {
    // Filter rows by current Month/Year filters
    final rows = <Map<String, dynamic>>[];
    for (final r in allSavings) {
      if (_passesFilter(r['Date'])) rows.add(r);
    }
    if (rows.isEmpty) {
      return const Center(
        child: Text('No savings data for the selected period.'),
      );
    }

    // Grouping strategy
    if (selectedYear == 0) {
      // Group by Year -> Category -> Subcategory
      final byYear = <int, List<Map<String, dynamic>>>{};
      for (final r in rows) {
        final dt = r['Date'] is DateTime
            ? r['Date'] as DateTime
            : DateTime.tryParse((r['Date'] ?? '').toString());
        if (dt == null) continue;
        byYear.putIfAbsent(dt.year, () => []).add(r);
      }
      final years = byYear.keys.toList()..sort();
      return ListView(
        children: [
          for (final y in years)
            _GroupedTotalsTile(
              title: 'Year $y',
              rows: byYear[y]!,
              colorFor: _colorForKey,
              onOpen: (filtered) => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SavingsRecordsListPage(rows: filtered),
                ),
              ),
            ),
        ],
      );
    } else if (selectedMonth == 0) {
      // Group by Month -> Category -> Subcategory
      final byMonth = List.generate(12, (_) => <Map<String, dynamic>>[]);
      for (final r in rows) {
        final dt = r['Date'] is DateTime
            ? r['Date'] as DateTime
            : DateTime.tryParse((r['Date'] ?? '').toString());
        if (dt == null) continue;
        byMonth[dt.month - 1].add(r);
      }
      return ListView(
        children: [
          for (int m = 0; m < 12; m++)
            if (byMonth[m].isNotEmpty)
              _GroupedTotalsTile(
                title: _monthFull(m + 1),
                rows: byMonth[m],
                colorFor: _colorForKey,
                onOpen: (filtered) => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SavingsRecordsListPage(rows: filtered),
                  ),
                ),
              ),
        ],
      );
    } else {
      // Specific Month -> just categories with subcategories
      return ListView(
        children: [
          _CategorySection(
            title: '${_monthFull(selectedMonth)} $selectedYear',
            rows: rows,
            colorFor: _colorForKey,
            onOpen: (filtered) => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => SavingsRecordsListPage(rows: filtered),
              ),
            ),
          ),
        ],
      );
    }
  }

  String _monthFull(int m) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return months[(m - 1).clamp(0, 11)];
  }

  // Expenses pie moved into _buildExpensesCharts

  // Expenses charts mode: header stacked bars + small pie
  Widget _buildExpensesCharts(
    List<MapEntry<String, double>> catEntries,
    List<Map<String, dynamic>> allExpenses,
  ) {
    if (catEntries.isEmpty && allExpenses.isEmpty) {
      return const Center(
        child: Text('No expense data for the selected period.'),
      );
    }
    return ListView(
      children: [
        _buildExpensesStackedBarCard(allExpenses),
        const SizedBox(height: 8),
        if (catEntries.isNotEmpty)
          Card(
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Expenses by Category (Pie)',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 180,
                    child: PieChart(
                      PieChartData(
                        sectionsSpace: 4,
                        centerSpaceRadius: 40,
                        sections: [
                          for (final e in catEntries)
                            PieChartSectionData(
                              value: e.value,
                              title: '',
                              color: _colorForKey('EXP:${e.key}'),
                              radius: 56,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
      ],
    );
  }

  // Build a stacked monthly/annual/quarterly bar chart for Expenses categories
  Widget _buildExpensesStackedBarCard(List<Map<String, dynamic>> allExp) {
    // If a specific year is selected (non-zero), show monthly bars for that year.
    if (selectedYear != 0) {
      final chosenYear = selectedYear;
      final categorySet = <String>{};
      final monthlyCatTotals = List.generate(12, (_) => <String, double>{});
      for (final r in allExp) {
        final dv = r['Date'];
        DateTime? dt;
        if (dv is DateTime) {
          dt = dv;
        } else if (dv is String) {
          dt = DateTime.tryParse(dv);
        }
        if (dt == null || dt.year != chosenYear) continue;
        if (selectedMonth != 0 && dt.month != selectedMonth) continue;
        final cat = (r['Category'] ?? 'Uncategorized').toString();
        final amt = (r['Amount'] is num)
            ? (r['Amount'] as num).toDouble()
            : 0.0;
        if (amt <= 0) continue;
        categorySet.add(cat);
        final mIndex = dt.month - 1;
        final map = monthlyCatTotals[mIndex];
        map[cat] = (map[cat] ?? 0) + amt;
      }
      if (categorySet.isEmpty) return const SizedBox.shrink();
      final categories = categorySet.toList()..sort();
      final groups = <BarChartGroupData>[];
      for (int m = 0; m < 12; m++) {
        double cursor = 0;
        final stacks = <BarChartRodStackItem>[];
        for (final cat in categories) {
          final v = (monthlyCatTotals[m][cat] ?? 0);
          if (v > 0) {
            stacks.add(
              BarChartRodStackItem(
                cursor,
                cursor + v,
                _colorForKey('EXP:$cat'),
              ),
            );
            cursor += v;
          }
        }
        groups.add(
          BarChartGroupData(
            x: m,
            barRods: [
              BarChartRodData(
                toY: cursor,
                width: 14,
                rodStackItems: stacks,
                borderRadius: BorderRadius.circular(2),
                color: Colors.transparent,
              ),
            ],
          ),
        );
      }
      String monthLabel(int m) {
        const months = [
          'J',
          'F',
          'M',
          'A',
          'M',
          'J',
          'J',
          'A',
          'S',
          'O',
          'N',
          'D',
        ];
        return months[m.clamp(0, 11)];
      }

      return _stackedBarCard(
        title: 'Monthly Expenses (Stacked by Category) — $chosenYear',
        groups: groups,
        bottomLabel: (val) => monthLabel(val.toInt()),
        categories: categories,
        colorPrefix: 'EXP:',
      );
    }

    // All years mode
    if (allYearsAgg == 'Yearly') {
      final categorySet = <String>{};
      final annual = <int, Map<String, double>>{};
      for (final r in allExp) {
        final dv = r['Date'];
        DateTime? dt;
        if (dv is DateTime) {
          dt = dv;
        } else if (dv is String) {
          dt = DateTime.tryParse(dv);
        }
        if (dt == null) continue;
        if (selectedMonth != 0 && dt.month != selectedMonth) continue;
        final cat = (r['Category'] ?? 'Uncategorized').toString();
        final amt = (r['Amount'] is num)
            ? (r['Amount'] as num).toDouble()
            : 0.0;
        if (amt <= 0) continue;
        categorySet.add(cat);
        final map = annual.putIfAbsent(dt.year, () => <String, double>{});
        map[cat] = (map[cat] ?? 0) + amt;
      }
      if (categorySet.isEmpty || annual.isEmpty) return const SizedBox.shrink();
      final years = annual.keys.toList()..sort();
      final categories = categorySet.toList()..sort();
      final groups = <BarChartGroupData>[];
      for (int i = 0; i < years.length; i++) {
        final y = years[i];
        double cursor = 0;
        final stacks = <BarChartRodStackItem>[];
        final map = annual[y]!;
        for (final cat in categories) {
          final v = (map[cat] ?? 0);
          if (v > 0) {
            stacks.add(
              BarChartRodStackItem(
                cursor,
                cursor + v,
                _colorForKey('EXP:$cat'),
              ),
            );
            cursor += v;
          }
        }
        groups.add(
          BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: cursor,
                width: 18,
                rodStackItems: stacks,
                borderRadius: BorderRadius.circular(2),
                color: Colors.transparent,
              ),
            ],
          ),
        );
      }
      return _stackedBarCard(
        title: 'Yearly Expenses (Stacked by Category)',
        groups: groups,
        bottomLabel: (val) {
          final idx = val.toInt();
          if (idx < 0 || idx >= years.length) return '';
          return years[idx].toString();
        },
        categories: categories,
        colorPrefix: 'EXP:',
      );
    } else {
      final categorySet = <String>{};
      final quarters = List.generate(4, (_) => <String, double>{});
      for (final r in allExp) {
        final dv = r['Date'];
        DateTime? dt;
        if (dv is DateTime) {
          dt = dv;
        } else if (dv is String) {
          dt = DateTime.tryParse(dv);
        }
        if (dt == null) continue;
        if (selectedMonth != 0 && dt.month != selectedMonth) continue;
        final q = (dt.month - 1) ~/ 3; // 0..3
        final cat = (r['Category'] ?? 'Uncategorized').toString();
        final amt = (r['Amount'] is num)
            ? (r['Amount'] as num).toDouble()
            : 0.0;
        if (amt <= 0) continue;
        categorySet.add(cat);
        final map = quarters[q];
        map[cat] = (map[cat] ?? 0) + amt;
      }
      if (categorySet.isEmpty) return const SizedBox.shrink();
      final categories = categorySet.toList()..sort();
      final groups = <BarChartGroupData>[];
      for (int q = 0; q < 4; q++) {
        double cursor = 0;
        final stacks = <BarChartRodStackItem>[];
        final map = quarters[q];
        for (final cat in categories) {
          final v = (map[cat] ?? 0);
          if (v > 0) {
            stacks.add(
              BarChartRodStackItem(
                cursor,
                cursor + v,
                _colorForKey('EXP:$cat'),
              ),
            );
            cursor += v;
          }
        }
        groups.add(
          BarChartGroupData(
            x: q,
            barRods: [
              BarChartRodData(
                toY: cursor,
                width: 18,
                rodStackItems: stacks,
                borderRadius: BorderRadius.circular(2),
                color: Colors.transparent,
              ),
            ],
          ),
        );
      }
      return _stackedBarCard(
        title: 'Quarterly Expenses (Stacked by Category — All Years)',
        groups: groups,
        bottomLabel: (val) {
          const labels = ['Q1', 'Q2', 'Q3', 'Q4'];
          final idx = val.toInt();
          if (idx < 0 || idx >= labels.length) return '';
          return labels[idx];
        },
        categories: categories,
        colorPrefix: 'EXP:',
      );
    }
  }

  Widget _buildSavingsLists(
    List<MapEntry<String, double>> catEntries,
    List<MapEntry<String, double>> subEntries, {
    Widget? header,
  }) {
    if (catEntries.isEmpty && subEntries.isEmpty) {
      return const Center(
        child: Text('No savings data for the selected period.'),
      );
    }
    return ListView(
      children: [
        if (header != null) header,
        if (header != null) const SizedBox(height: 8),
        if (catEntries.isNotEmpty)
          Card(
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Savings by Category (Pie)',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 180,
                    child: PieChart(
                      PieChartData(
                        sectionsSpace: 4,
                        centerSpaceRadius: 40,
                        sections: [
                          for (final e in catEntries)
                            PieChartSectionData(
                              value: e.value,
                              title: '',
                              color: _colorForKey(e.key),
                              radius: 56,
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        Card(
          elevation: 1,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Savings by Category',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                ...catEntries.map(
                  (e) => ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: CircleAvatar(
                      backgroundColor: _colorForKey(e.key),
                      radius: 10,
                    ),
                    title: Text(e.key),
                    trailing: Text(
                      '₱${e.value.toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          elevation: 1,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Savings by Subcategory',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                ...subEntries.map(
                  (e) => ListTile(
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading: CircleAvatar(
                      backgroundColor: _colorForKey(e.key),
                      radius: 10,
                    ),
                    title: Text(e.key),
                    trailing: Text(
                      '₱${e.value.toStringAsFixed(2)}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  // Build a stacked monthly bar chart for Savings categories
  Widget _buildSavingsStackedBarCard(List<Map<String, dynamic>> allSavings) {
    // If a specific year is selected (non-zero), show monthly bars for that year.
    if (selectedYear != 0) {
      final chosenYear = selectedYear;
      final categorySet = <String>{};
      final monthlyCatTotals = List.generate(12, (_) => <String, double>{});
      for (final r in allSavings) {
        final dv = r['Date'];
        DateTime? dt;
        if (dv is DateTime)
          dt = dv;
        else if (dv is String)
          dt = DateTime.tryParse(dv);
        if (dt == null || dt.year != chosenYear) continue;
        if (selectedMonth != 0 && dt.month != selectedMonth)
          continue; // honor month filter
        final cat = (r['Category'] ?? 'Uncategorized').toString();
        final amt = (r['Amount'] is num)
            ? (r['Amount'] as num).toDouble()
            : 0.0;
        if (amt <= 0) continue;
        categorySet.add(cat);
        final mIndex = dt.month - 1;
        final map = monthlyCatTotals[mIndex];
        map[cat] = (map[cat] ?? 0) + amt;
      }
      if (categorySet.isEmpty) return const SizedBox.shrink();
      final categories = categorySet.toList()..sort();
      final groups = <BarChartGroupData>[];
      for (int m = 0; m < 12; m++) {
        double cursor = 0;
        final stacks = <BarChartRodStackItem>[];
        for (final cat in categories) {
          final v = (monthlyCatTotals[m][cat] ?? 0);
          if (v > 0) {
            stacks.add(
              BarChartRodStackItem(
                cursor,
                cursor + v,
                _colorForKey('SAV:$cat'),
              ),
            );
            cursor += v;
          }
        }
        groups.add(
          BarChartGroupData(
            x: m,
            barRods: [
              BarChartRodData(
                toY: cursor,
                width: 14,
                rodStackItems: stacks,
                borderRadius: BorderRadius.circular(2),
                color: Colors.transparent,
              ),
            ],
          ),
        );
      }
      String monthLabel(int m) {
        const months = [
          'J',
          'F',
          'M',
          'A',
          'M',
          'J',
          'J',
          'A',
          'S',
          'O',
          'N',
          'D',
        ];
        return months[m.clamp(0, 11)];
      }

      return _stackedBarCard(
        title: 'Monthly Savings (Stacked by Category) — $chosenYear',
        groups: groups,
        bottomLabel: (val) => monthLabel(val.toInt()),
        categories: categories,
        colorPrefix: 'SAV:',
      );
    }

    // All years mode
    if (allYearsAgg == 'Yearly') {
      // Aggregate per year
      final categorySet = <String>{};
      final annual = <int, Map<String, double>>{};
      for (final r in allSavings) {
        final dv = r['Date'];
        DateTime? dt;
        if (dv is DateTime)
          dt = dv;
        else if (dv is String)
          dt = DateTime.tryParse(dv);
        if (dt == null) continue;
        if (selectedMonth != 0 && dt.month != selectedMonth)
          continue; // month filter across all years
        final cat = (r['Category'] ?? 'Uncategorized').toString();
        final amt = (r['Amount'] is num)
            ? (r['Amount'] as num).toDouble()
            : 0.0;
        if (amt <= 0) continue;
        categorySet.add(cat);
        final map = annual.putIfAbsent(dt.year, () => <String, double>{});
        map[cat] = (map[cat] ?? 0) + amt;
      }
      if (categorySet.isEmpty || annual.isEmpty) return const SizedBox.shrink();
      final years = annual.keys.toList()..sort();
      final categories = categorySet.toList()..sort();
      final groups = <BarChartGroupData>[];
      for (int i = 0; i < years.length; i++) {
        final y = years[i];
        double cursor = 0;
        final stacks = <BarChartRodStackItem>[];
        final map = annual[y]!;
        for (final cat in categories) {
          final v = (map[cat] ?? 0);
          if (v > 0) {
            stacks.add(
              BarChartRodStackItem(
                cursor,
                cursor + v,
                _colorForKey('SAV:$cat'),
              ),
            );
            cursor += v;
          }
        }
        groups.add(
          BarChartGroupData(
            x: i,
            barRods: [
              BarChartRodData(
                toY: cursor,
                width: 18,
                rodStackItems: stacks,
                borderRadius: BorderRadius.circular(2),
                color: Colors.transparent,
              ),
            ],
          ),
        );
      }
      return _stackedBarCard(
        title: 'Yearly Savings (Stacked by Category)',
        groups: groups,
        bottomLabel: (val) {
          final idx = val.toInt();
          if (idx < 0 || idx >= years.length) return '';
          return years[idx].toString();
        },
        categories: categories,
        colorPrefix: 'SAV:',
      );
    } else {
      // Quarterly across all years
      final categorySet = <String>{};
      final quarters = List.generate(4, (_) => <String, double>{});
      for (final r in allSavings) {
        final dv = r['Date'];
        DateTime? dt;
        if (dv is DateTime)
          dt = dv;
        else if (dv is String)
          dt = DateTime.tryParse(dv);
        if (dt == null) continue;
        if (selectedMonth != 0 && dt.month != selectedMonth)
          continue; // month filter
        final q = (dt.month - 1) ~/ 3; // 0..3
        final cat = (r['Category'] ?? 'Uncategorized').toString();
        final amt = (r['Amount'] is num)
            ? (r['Amount'] as num).toDouble()
            : 0.0;
        if (amt <= 0) continue;
        categorySet.add(cat);
        final map = quarters[q];
        map[cat] = (map[cat] ?? 0) + amt;
      }
      if (categorySet.isEmpty) return const SizedBox.shrink();
      final categories = categorySet.toList()..sort();
      final groups = <BarChartGroupData>[];
      for (int q = 0; q < 4; q++) {
        double cursor = 0;
        final stacks = <BarChartRodStackItem>[];
        final map = quarters[q];
        for (final cat in categories) {
          final v = (map[cat] ?? 0);
          if (v > 0) {
            stacks.add(
              BarChartRodStackItem(
                cursor,
                cursor + v,
                _colorForKey('SAV:$cat'),
              ),
            );
            cursor += v;
          }
        }
        groups.add(
          BarChartGroupData(
            x: q,
            barRods: [
              BarChartRodData(
                toY: cursor,
                width: 18,
                rodStackItems: stacks,
                borderRadius: BorderRadius.circular(2),
                color: Colors.transparent,
              ),
            ],
          ),
        );
      }
      return _stackedBarCard(
        title: 'Quarterly Savings (Stacked by Category — All Years)',
        groups: groups,
        bottomLabel: (val) {
          const labels = ['Q1', 'Q2', 'Q3', 'Q4'];
          final idx = val.toInt();
          if (idx < 0 || idx >= labels.length) return '';
          return labels[idx];
        },
        categories: categories,
        colorPrefix: 'SAV:',
      );
    }
  }

  Widget _stackedBarCard({
    required String title,
    required List<BarChartGroupData> groups,
    required String Function(double) bottomLabel,
    required List<String> categories,
    String colorPrefix = '',
  }) {
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 220,
              child: BarChart(
                BarChartData(
                  barGroups: groups,
                  gridData: FlGridData(show: true, drawVerticalLine: false),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    leftTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 26,
                        getTitlesWidget: (val, meta) => Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            bottomLabel(val),
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final cat in categories)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: _colorForKey('$colorPrefix$cat'),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(cat, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<int> _yearsFromData(List<Map<String, dynamic>> rows) {
    final years = <int>{};
    for (final r in rows) {
      final dv = r['Date'];
      DateTime? dt;
      if (dv is DateTime) {
        dt = dv;
      } else if (dv is String) {
        dt = DateTime.tryParse(dv);
      }
      if (dt != null) years.add(dt.year);
    }
    final list = years.toList()..sort();
    return [0, ...list];
  }
}

class _MonthDropdown extends StatelessWidget {
  final int value; // 0..12
  final ValueChanged<int?> onChanged;
  const _MonthDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    const months = <String>[
      'All months',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return DropdownButton<int>(
      value: value,
      items: List.generate(
        13,
        (i) => DropdownMenuItem(value: i, child: Text(months[i])),
      ),
      onChanged: onChanged,
    );
  }
}

class _YearDropdown extends StatelessWidget {
  final int value; // 0 = All years
  final List<int> years; // includes 0
  final ValueChanged<int?> onChanged;
  const _YearDropdown({
    required this.value,
    required this.years,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Ensure unique, sorted years and that 0 (All years) exists exactly once.
    final uniqueYears = <int>{...years}..removeWhere((e) => e < 0);
    uniqueYears.add(0);
    final finalYears = uniqueYears.toList()..sort();

    // If current value isn't present (e.g., saved year with no data), fallback to 0.
    final effectiveValue = finalYears.contains(value) ? value : 0;

    final labels = {0: 'All years'};
    return DropdownButton<int>(
      value: effectiveValue,
      items: finalYears
          .map(
            (y) => DropdownMenuItem(
              value: y,
              child: Text(labels[y] ?? y.toString()),
            ),
          )
          .toList(),
      onChanged: onChanged,
    );
  }
}

// ========================= DETAILS VIEW WIDGETS =========================

class _GroupedTotalsTile extends StatelessWidget {
  final String title;
  final List<Map<String, dynamic>> rows;
  final Color Function(String) colorFor;
  final void Function(List<Map<String, dynamic>> filtered) onOpen;

  const _GroupedTotalsTile({
    required this.title,
    required this.rows,
    required this.colorFor,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    // Aggregate: Category -> total, and Category -> Subcategory -> total
    final byCategory = <String, double>{};
    final byCatSub = <String, Map<String, double>>{};
    for (final r in rows) {
      final cat = (r['Category'] ?? 'Uncategorized').toString();
      final sub = (r['Subcategory'] ?? 'Unspecified').toString();
      final amt = (r['Amount'] is num) ? (r['Amount'] as num).toDouble() : 0.0;
      byCategory[cat] = (byCategory[cat] ?? 0) + amt;
      final subMap = byCatSub.putIfAbsent(cat, () => <String, double>{});
      subMap[sub] = (subMap[sub] ?? 0) + amt;
    }
    final cats = byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => onOpen(rows),
                  icon: const Icon(Icons.list_alt),
                  label: const Text('View records'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            ...cats.map((c) {
              final subMap = byCatSub[c.key] ?? const <String, double>{};
              final subs = subMap.entries.toList()
                ..sort((a, b) => b.value.compareTo(a.value));
              return ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: CircleAvatar(
                  radius: 10,
                  backgroundColor: colorFor(c.key),
                ),
                title: Text(c.key),
                trailing: Text(
                  '₱${c.value.toStringAsFixed(2)}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(
                      left: 12,
                      right: 8,
                      bottom: 8,
                    ),
                    child: Column(
                      children: [
                        for (final s in subs)
                          ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.only(left: 8),
                            leading: const SizedBox(width: 24),
                            title: Text(s.key),
                            trailing: Text('₱${s.value.toStringAsFixed(2)}'),
                            onTap: () {
                              // Open records filtered by this category/subcategory
                              final filtered = rows
                                  .where(
                                    (r) =>
                                        (r['Category'] ?? '').toString() ==
                                            c.key &&
                                        (r['Subcategory'] ?? '').toString() ==
                                            s.key,
                                  )
                                  .toList();
                              onOpen(filtered);
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _CategorySection extends StatelessWidget {
  final String title;
  final List<Map<String, dynamic>> rows;
  final Color Function(String) colorFor;
  final void Function(List<Map<String, dynamic>> filtered) onOpen;

  const _CategorySection({
    required this.title,
    required this.rows,
    required this.colorFor,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return _GroupedTotalsTile(
      title: title,
      rows: rows,
      colorFor: colorFor,
      onOpen: onOpen,
    );
  }
}

class SavingsRecordsListPage extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  const SavingsRecordsListPage({super.key, required this.rows});

  String _fmtDate(Object? dv) {
    DateTime? dt;
    if (dv is DateTime)
      dt = dv;
    else if (dv is String)
      dt = DateTime.tryParse(dv);
    if (dt == null) return '';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final items = rows.toList();
    items.sort((a, b) {
      final da = a['Date'];
      final db = b['Date'];
      final dta = da is DateTime
          ? da
          : DateTime.tryParse((da ?? '').toString()) ?? DateTime(1900);
      final dtb = db is DateTime
          ? db
          : DateTime.tryParse((db ?? '').toString()) ?? DateTime(1900);
      return dtb.compareTo(dta);
    });
    return Scaffold(
      appBar: AppBar(title: const Text('Savings Records')),
      body: ListView.builder(
        itemCount: items.length,
        itemBuilder: (context, i) {
          final r = items[i];
          final title =
              '${(r['Category'] ?? '').toString()} • ${(r['Subcategory'] ?? '').toString()}';
          final note = (r['Note'] ?? '').toString();
          final date = _fmtDate(r['Date']);
          final amt = (r['Amount'] is num)
              ? (r['Amount'] as num).toDouble()
              : 0.0;
          return ListTile(
            title: Text(title),
            subtitle: Text([date, if (note.isNotEmpty) note].join(' — ')),
            trailing: Text(
              '₱${amt.toStringAsFixed(2)}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          );
        },
      ),
    );
  }
}

class ExpensesRecordsListPage extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  const ExpensesRecordsListPage({super.key, required this.rows});

  String _fmtDate(Object? dv) {
    DateTime? dt;
    if (dv is DateTime)
      dt = dv;
    else if (dv is String)
      dt = DateTime.tryParse(dv);
    if (dt == null) return '';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final items = rows.toList();
    items.sort((a, b) {
      final da = a['Date'];
      final db = b['Date'];
      final dta = da is DateTime
          ? da
          : DateTime.tryParse((da ?? '').toString()) ?? DateTime(1900);
      final dtb = db is DateTime
          ? db
          : DateTime.tryParse((db ?? '').toString()) ?? DateTime(1900);
      return dtb.compareTo(dta);
    });
    return Scaffold(
      appBar: AppBar(title: const Text('Expense Records')),
      body: ListView.builder(
        itemCount: items.length,
        itemBuilder: (context, i) {
          final r = items[i];
          final title =
              '${(r['Category'] ?? '').toString()} • ${(r['Subcategory'] ?? '').toString()}';
          final note = (r['Note'] ?? '').toString();
          final date = _fmtDate(r['Date']);
          final amt = (r['Amount'] is num)
              ? (r['Amount'] as num).toDouble()
              : 0.0;
          return ListTile(
            title: Text(title),
            subtitle: Text([date, if (note.isNotEmpty) note].join(' — ')),
            trailing: Text(
              '₱${amt.toStringAsFixed(2)}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          );
        },
      ),
    );
  }
}
