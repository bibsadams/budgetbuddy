import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

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

  Color getRandomColor() {
    final random = DateTime.now().millisecondsSinceEpoch;
    return Color(
      (0xFF000000 + (random ^ widget.categoryColors.length * 997) % 0xFFFFFF),
    ).withOpacity(1.0);
  }

  @override
  Widget build(BuildContext context) {
    Map<String, double> categoryTotals = {};
    final expenses = widget.tableData['Expenses'] ?? [];

    for (var row in expenses) {
      String category = row['Name'] ?? 'Uncategorized';
      double amount = row['Amount'] ?? 0.0;
      categoryTotals[category] = (categoryTotals[category] ?? 0) + amount;
      widget.categoryColors.putIfAbsent(category, () => getRandomColor());
    }

    final entries = categoryTotals.entries.toList();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            "Spending Insights",
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: entries.isEmpty
                ? const Center(child: Text("No expense data available."))
                : Card(
                    elevation: 4,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: PieChart(
                        PieChartData(
                          sectionsSpace: 4,
                          centerSpaceRadius: 60,
                          pieTouchData: PieTouchData(
                            touchCallback: (event, response) {
                              setState(() {
                                touchedIndex =
                                    response
                                        ?.touchedSection
                                        ?.touchedSectionIndex ??
                                    -1;
                              });
                            },
                          ),
                          sections: List.generate(entries.length, (i) {
                            final entry = entries[i];
                            final isTouched = i == touchedIndex;
                            final double fontSize = isTouched ? 16 : 12;
                            final double radius = isTouched ? 90 : 70;

                            return PieChartSectionData(
                              value: entry.value,
                              title: isTouched
                                  ? "${entry.key}\n₱${entry.value.toStringAsFixed(0)}"
                                  : '',
                              color: widget.categoryColors[entry.key],
                              radius: radius,
                              titleStyle: TextStyle(
                                fontSize: fontSize,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            );
                          }),
                        ),
                      ),
                    ),
                  ),
          ),
          if (touchedIndex != -1)
            Padding(
              padding: const EdgeInsets.only(top: 16.0),
              child: Center(
                child: Text(
                  "${entries[touchedIndex].key}: ₱${entries[touchedIndex].value.toStringAsFixed(2)}",
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
