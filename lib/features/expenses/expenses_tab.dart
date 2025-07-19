import 'package:flutter/material.dart';

class ExpensesTab extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final double? limit;
  final void Function(List<String> columns) onAddNewRow;
  final void Function()? onSetLimit;
  final Future<void> Function()? onAddColumn;
  final void Function(int rowIndex) onDeleteRow;
  final Future<String?> Function(dynamic currentValue) onEditValue;

  const ExpensesTab({
    super.key,
    required this.rows,
    required this.limit,
    required this.onAddNewRow,
    required this.onSetLimit,
    required this.onAddColumn,
    required this.onDeleteRow,
    required this.onEditValue,
  });

  @override
  Widget build(BuildContext context) {
    final columns = ['Name', 'Amount', 'Date'];
    double total = rows.fold(0.0, (sum, row) => sum + (row['Amount'] ?? 0.0));

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(onPressed: onSetLimit, child: const Text("Set Limit")),
              Padding(
                padding: const EdgeInsets.only(right: 12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (limit != null)
                      Text(
                        "Limit: ₱${limit!.toStringAsFixed(2)}",
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    Text(
                      "Total: ₱${total.toStringAsFixed(2)}",
                      style: TextStyle(
                        color: limit != null && total > limit!
                            ? Colors.red
                            : Colors.black,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ElevatedButton.icon(
          onPressed: () => onAddNewRow(columns),
          icon: const Icon(Icons.add),
          label: const Text('Add Expense'),
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
                    "No expenses yet. Tap 'Add Expense' to begin.",
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
                            onPressed: onAddColumn,
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
                          for (var col in columns) {
                            row.putIfAbsent(col, () => '');
                          }
                          return DataRow(
                            cells: [
                              ...columns.map((col) {
                                return DataCell(
                                  GestureDetector(
                                    child: Container(
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
                                      if (col == 'Date') {
                                        final picked = await showDatePicker(
                                          context: context,
                                          initialDate:
                                              DateTime.tryParse(
                                                row[col] ?? '',
                                              ) ??
                                              DateTime.now(),
                                          firstDate: DateTime(2000),
                                          lastDate: DateTime(2100),
                                        );
                                        if (picked != null) {
                                          row[col] =
                                              "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}";
                                        }
                                      } else {
                                        final val = await onEditValue(row[col]);
                                        if (val != null) {
                                          row[col] = col == 'Amount'
                                              ? double.tryParse(val) ?? 0.0
                                              : val;
                                        }
                                      }
                                    },
                                  ),
                                );
                              }),
                              const DataCell(SizedBox()),
                              DataCell(
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete,
                                    color: Colors.redAccent,
                                  ),
                                  onPressed: () => onDeleteRow(rowIndex),
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
