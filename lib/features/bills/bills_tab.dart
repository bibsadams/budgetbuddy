import 'package:flutter/material.dart';

class BillsTab extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final void Function(List<String> columns) onAddNewRow;
  final void Function(int rowIndex) onDeleteRow;
  final Future<void> Function(int rowIndex)? onEditRow;

  const BillsTab({
    super.key,
    required this.rows,
    required this.onAddNewRow,
    required this.onDeleteRow,
    this.onEditRow,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: ElevatedButton.icon(
            onPressed: () =>
                onAddNewRow(['Name', 'Amount', 'Due Date', 'Recurrence']),
            icon: const Icon(Icons.add_alert),
            label: const Text("Add Bill Reminder"),
            style: ElevatedButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
            ),
          ),
        ),
        Expanded(
          child: rows.isEmpty
              ? const Center(
                  child: Text(
                    "No bills yet. Tap 'Add Bill Reminder' to begin.",
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (context, index) {
                    final row = rows[index];
                    return Card(
                      margin: const EdgeInsets.symmetric(
                        vertical: 6,
                        horizontal: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ListTile(
                        title: Text(row['Name'] ?? ''),
                        subtitle: Text(
                          "₱${row['Amount']?.toStringAsFixed(2) ?? ''} - Due: ${row['Due Date'] ?? ''}",
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit),
                              onPressed: onEditRow != null
                                  ? () => onEditRow!(index)
                                  : null,
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.delete,
                                color: Colors.redAccent,
                              ),
                              onPressed: () => onDeleteRow(index),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
