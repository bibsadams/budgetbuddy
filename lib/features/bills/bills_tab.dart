import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../services/notification_service.dart';

class BillsTab extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final void Function(List<Map<String, dynamic>> newRows) onRowsChanged;

  const BillsTab({super.key, required this.rows, required this.onRowsChanged});

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: '₱', decimalDigits: 2);
    return Scaffold(
      body: rows.isEmpty
          ? const Center(child: Text("No bills yet. Tap '+' to add."))
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final bill = rows[index];
                final enabled = bill['Enabled'] == true;
                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: ListTile(
                    leading: Icon(
                      Icons.receipt_long_outlined,
                      color: enabled
                          ? Theme.of(context).colorScheme.primary
                          : Colors.grey,
                    ),
                    title: Text(bill['Name'] ?? 'Untitled'),
                    subtitle: Text(
                      "${currency.format((bill['Amount'] ?? 0) as num)}  •  ${bill['Due Date'] ?? ''}  ${bill['Time'] ?? ''}",
                    ),
                    trailing: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(
                            value: enabled,
                            onChanged: (v) async {
                              final updated = Map<String, dynamic>.from(bill);
                              updated['Enabled'] = v;
                              final newRows = List<Map<String, dynamic>>.from(
                                rows,
                              );
                              newRows[index] = updated;
                              onRowsChanged(newRows);
                              await _scheduleIfNeeded(index, updated);
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit),
                            onPressed: () async {
                              final edited =
                                  await Navigator.push<Map<String, dynamic>>(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          _BillEditPage(initial: bill),
                                    ),
                                  );
                              if (edited != null) {
                                final newRows = List<Map<String, dynamic>>.from(
                                  rows,
                                );
                                newRows[index] = edited;
                                onRowsChanged(newRows);
                                await _scheduleIfNeeded(index, edited);
                              }
                            },
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.delete,
                              color: Colors.redAccent,
                            ),
                            onPressed: () async {
                              final confirm = await showDialog<bool>(
                                context: context,
                                builder: (_) => AlertDialog(
                                  title: const Text('Delete Bill'),
                                  content: const Text(
                                    'Delete this bill and its reminder?',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('Cancel'),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
                                      child: const Text('Delete'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirm == true) {
                                final newRows = List<Map<String, dynamic>>.from(
                                  rows,
                                );
                                newRows.removeAt(index);
                                onRowsChanged(newRows);
                                await NotificationService().cancel(
                                  _notifIdFromIndex(index),
                                );
                              }
                            },
                          ),
                        ],
                      ),
                    ),
                    onTap: () async {
                      final edited = await Navigator.push<Map<String, dynamic>>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => _BillEditPage(initial: bill),
                        ),
                      );
                      if (edited != null) {
                        final newRows = List<Map<String, dynamic>>.from(rows);
                        newRows[index] = edited;
                        onRowsChanged(newRows);
                        await _scheduleIfNeeded(index, edited);
                      }
                    },
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'bills-fab',
        icon: const Icon(Icons.add_alert),
        label: const Text('Add Bill Reminder'),
        onPressed: () async {
          final created = await Navigator.push<Map<String, dynamic>>(
            context,
            MaterialPageRoute(builder: (_) => const _BillEditPage()),
          );
          if (created != null) {
            final newRows = List<Map<String, dynamic>>.from(rows)..add(created);
            onRowsChanged(newRows);
            await _scheduleIfNeeded(newRows.length - 1, created);
          }
        },
      ),
    );
  }

  static int _notifIdFromIndex(int index) =>
      5000 + index; // Stable-ish ID per row

  static Future<void> _scheduleIfNeeded(
    int index,
    Map<String, dynamic> bill,
  ) async {
    final enabled = bill['Enabled'] == true;
    if (!enabled) {
      await NotificationService().cancel(_notifIdFromIndex(index));
      return;
    }

    final name = (bill['Name'] ?? 'Bill') as String;
    final amount = bill['Amount'] is num
        ? (bill['Amount'] as num).toDouble()
        : 0.0;
    final dateStr = (bill['Due Date'] ?? '') as String; // yyyy-MM-dd
    final timeStrRaw = (bill['Time'] ?? '') as String; // may be blank
    final timeStr = timeStrRaw.trim().isEmpty ? '09:00' : timeStrRaw; // HH:mm
    final repeatStr = (bill['Repeat'] ?? 'None') as String;
    final repeat = _parseRepeat(repeatStr);

    if (dateStr.isEmpty) return;
    final parts = dateStr.split('-');
    if (parts.length != 3) return;
    final year = int.tryParse(parts[0]) ?? DateTime.now().year;
    final month = int.tryParse(parts[1]) ?? DateTime.now().month;
    final day = int.tryParse(parts[2]) ?? DateTime.now().day;
    final hm = timeStr.split(':');
    final hour = (hm.isNotEmpty ? int.tryParse(hm[0]) : null) ?? 9;
    final minute = (hm.length > 1 ? int.tryParse(hm[1]) : null) ?? 0;

    final dt = DateTime(year, month, day, hour, minute);
    final title = 'Bill due: $name';
    final body = '₱${amount.toStringAsFixed(2)} due on $dateStr at $timeStr';
    await NotificationService().schedule(
      _notifIdFromIndex(index),
      title: title,
      body: body,
      firstDateTime: dt,
      repeat: repeat,
    );
  }

  static RepeatIntervalMode _parseRepeat(String s) {
    switch (s.toLowerCase()) {
      case 'weekly':
        return RepeatIntervalMode.weekly;
      case 'monthly':
        return RepeatIntervalMode.monthly;
      case 'yearly':
        return RepeatIntervalMode.yearly;
      default:
        return RepeatIntervalMode.none;
    }
  }
}

class _BillEditPage extends StatefulWidget {
  final Map<String, dynamic>? initial;
  const _BillEditPage({this.initial});

  @override
  State<_BillEditPage> createState() => _BillEditPageState();
}

class _BillEditPageState extends State<_BillEditPage> {
  late TextEditingController _name;
  late TextEditingController _amount;
  late TextEditingController _date; // yyyy-MM-dd
  late TextEditingController _time; // HH:mm
  String _repeat = 'None';
  bool _enabled = true;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _name = TextEditingController(text: widget.initial?['Name'] ?? '');
    _amount = TextEditingController(
      text: widget.initial?['Amount'] is num
          ? (widget.initial!['Amount'] as num).toString()
          : '',
    );
    _date = TextEditingController(
      text:
          widget.initial?['Due Date'] ??
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}",
    );
    _time = TextEditingController(text: widget.initial?['Time'] ?? '');
    _repeat = widget.initial?['Repeat'] ?? 'None';
    _enabled = widget.initial?['Enabled'] ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _date.dispose();
    _time.dispose();
    super.dispose();
  }

  bool get _canSave {
    final amt = double.tryParse(_amount.text.replaceAll(',', '')) ?? 0.0;
    return _name.text.trim().isNotEmpty && amt > 0 && _date.text.isNotEmpty;
  }

  Future<void> _pickDate() async {
    final init = DateTime.tryParse(_date.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _date.text =
            "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}";
      });
    }
  }

  Future<void> _pickTime() async {
    final parts = _time.text.split(':');
    final hourStr = parts.isNotEmpty ? parts[0] : '9';
    final minuteStr = parts.length > 1 ? parts[1] : '0';
    final init = TimeOfDay(
      hour: int.tryParse(hourStr) ?? 9,
      minute: int.tryParse(minuteStr) ?? 0,
    );
    final picked = await showTimePicker(context: context, initialTime: init);
    if (picked != null) {
      setState(() {
        _time.text =
            "${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.initial == null ? 'Add Bill' : 'Edit Bill'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _canSave
                ? () {
                    final data = <String, dynamic>{
                      'Name': _name.text.trim(),
                      'Amount':
                          double.tryParse(_amount.text.replaceAll(',', '')) ??
                          0.0,
                      'Due Date': _date.text,
                      'Time': _time.text,
                      'Repeat': _repeat,
                      'Enabled': _enabled,
                    };
                    Navigator.pop(context, data);
                  }
                : null,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                labelText: 'Bill name',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Amount',
                prefixIcon: Icon(Icons.payments_outlined),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _date,
                    readOnly: true,
                    onTap: _pickDate,
                    decoration: const InputDecoration(
                      labelText: 'Due date',
                      prefixIcon: Icon(Icons.event_outlined),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _time,
                    readOnly: true,
                    onTap: _pickTime,
                    decoration: const InputDecoration(
                      labelText: 'Time',
                      prefixIcon: Icon(Icons.access_time),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _repeat,
                    decoration: const InputDecoration(
                      labelText: 'Repeat',
                      prefixIcon: Icon(Icons.repeat),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'None', child: Text('One time')),
                      DropdownMenuItem(value: 'Weekly', child: Text('Weekly')),
                      DropdownMenuItem(
                        value: 'Monthly',
                        child: Text('Monthly'),
                      ),
                      DropdownMenuItem(value: 'Yearly', child: Text('Yearly')),
                    ],
                    onChanged: (v) => setState(() => _repeat = v ?? 'None'),
                  ),
                ),
                const SizedBox(width: 12),
                Row(
                  children: [
                    const Text('Reminder'),
                    const SizedBox(width: 8),
                    Switch(
                      value: _enabled,
                      onChanged: (v) => setState(() => _enabled = v),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: Padding(
        padding: const EdgeInsets.all(16),
        child: ElevatedButton.icon(
          onPressed: _canSave
              ? () {
                  final data = <String, dynamic>{
                    'Name': _name.text.trim(),
                    'Amount':
                        double.tryParse(_amount.text.replaceAll(',', '')) ??
                        0.0,
                    'Due Date': _date.text,
                    'Time': _time.text,
                    'Repeat': _repeat,
                    'Enabled': _enabled,
                  };
                  Navigator.pop(context, data);
                }
              : null,
          icon: const Icon(Icons.save),
          label: const Text('Save Bill'),
        ),
      ),
    );
  }
}
