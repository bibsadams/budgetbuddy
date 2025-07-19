import 'package:flutter/material.dart';

class SavingsTab extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final double? goal;
  final Function(List<String>) onAddNewRow;
  final Function() onSetGoal;
  final Future<String?> Function()? onAddColumn;
  final void Function(int rowIndex)? onDeleteRow;
  final Future<String?> Function(dynamic currentValue)? onEditValue;

  const SavingsTab({
    super.key,
    required this.rows,
    required this.goal,
    required this.onAddNewRow,
    required this.onSetGoal,
    this.onAddColumn,
    this.onDeleteRow,
    this.onEditValue,
  });

  @override
  Widget build(BuildContext context) {
    double total = rows.fold(0.0, (sum, row) => sum + (row['Amount'] ?? 0.0));
    List<String> columns = ['Name', 'Amount', 'Date'];

    // Dynamically add columns if present in rows
    if (rows.isNotEmpty) {
      final existingCols = rows.expand((row) => row.keys).toSet();
      for (var col in existingCols) {
        if (!columns.contains(col)) columns.add(col);
      }
    }

    double progress = (goal ?? 0) > 0
        ? (total / (goal ?? 1)).clamp(0.0, 1.0)
        : 0.0;
    final Color progressColor = progress >= 1.0
        ? Colors.green
        : (progress > 0.75 ? Colors.yellow.shade700 : Colors.orange.shade300);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text("Goal Amount:"),
                  ElevatedButton(
                    onPressed: onSetGoal,
                    child: const Text("Set Goal"),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 24,
                  backgroundColor: Colors.grey.shade300,
                  valueColor: AlwaysStoppedAnimation<Color>(progressColor),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "Saved: ₱${total.toStringAsFixed(2)} / ₱${(goal ?? 0).toStringAsFixed(2)}",
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        ElevatedButton.icon(
          onPressed: () => onAddNewRow(columns),
          icon: const Icon(Icons.add),
          label: const Text('Add Record'),
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? const Center(
                  child: Text(
                    "No records yet. Tap 'Add Record' to begin.",
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                )
              : Card(
                  elevation: 4,
                  margin: const EdgeInsets.all(8),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columns: [
                        ...columns.map(
                          (c) => DataColumn(
                            label: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: Text(c),
                            ),
                          ),
                        ),
                        DataColumn(
                          label: IconButton(
                            icon: const Icon(
                              Icons.add,
                              color: Colors.blueAccent,
                            ),
                            tooltip: "Add new column",
                            onPressed: () async {
                              if (onAddColumn != null) {
                                await onAddColumn!();
                              }
                            },
                          ),
                        ),
                        const DataColumn(
                          label: Icon(Icons.delete, color: Colors.redAccent),
                        ),
                      ],
                      rows: [
                        ...rows.asMap().entries.map((entry) {
                          final rowIndex = entry.key;
                          final row = entry.value;

                          // Ensure all expected columns are present in the row
                          for (var col in columns) {
                            row.putIfAbsent(col, () => '');
                          }

                          return DataRow(
                            cells: [
                              ...columns.map((col) {
                                return DataCell(
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                      horizontal: 12,
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Expanded(
                                          child: Text(
                                            row[col]?.toString() ?? '',
                                            textAlign: col == 'Amount'
                                                ? TextAlign.right
                                                : TextAlign.left,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                        const Icon(
                                          Icons.edit,
                                          size: 14,
                                          color: Colors.grey,
                                        ),
                                      ],
                                    ),
                                  ),
                                  onTap: () async {
                                    if (onEditValue != null) {
                                      final val = await onEditValue!(row[col]);
                                      // You can handle updating the value in parent if needed
                                    }
                                  },
                                );
                              }),
                              const DataCell(
                                SizedBox(),
                              ), // For Add Column button
                              DataCell(
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete,
                                    color: Colors.redAccent,
                                  ),
                                  onPressed: () {
                                    if (onDeleteRow != null) {
                                      onDeleteRow!(rowIndex);
                                    }
                                  },
                                ),
                              ),
                            ],
                          );
                        }),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}
