import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:budgetbuddy/widgets/two_decimal_input_formatter.dart';
import 'package:budgetbuddy/widgets/money_field_utils.dart';
import 'package:image_picker/image_picker.dart';
import 'package:budgetbuddy/widgets/app_gradient_background.dart';
import 'package:budgetbuddy/widgets/pressable_neumorphic.dart';

class OrTab extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final List<Map<String, dynamic>>
  expensesRows; // kept for parity if needed later
  final void Function(List<Map<String, dynamic>> newRows) onRowsChanged;

  const OrTab({
    super.key,
    required this.rows,
    required this.expensesRows,
    required this.onRowsChanged,
  });

  @override
  State<OrTab> createState() => _OrTabState();
}

class _OrTabState extends State<OrTab> {
  String _sort = 'Date (newest)';

  List<Map<String, dynamic>> _sorted(List<Map<String, dynamic>> list) {
    int cmpDate(String a, String b) {
      final da = DateTime.tryParse(a);
      final db = DateTime.tryParse(b);
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return da.compareTo(db);
    }

    final copy = List<Map<String, dynamic>>.from(list);
    switch (_sort) {
      case 'Amount (high → low)':
        copy.sort(
          (a, b) =>
              ((b['Amount'] ?? 0) as num).compareTo((a['Amount'] ?? 0) as num),
        );
        break;
      case 'Amount (low → high)':
        copy.sort(
          (a, b) =>
              ((a['Amount'] ?? 0) as num).compareTo((b['Amount'] ?? 0) as num),
        );
        break;
      case 'Date (oldest)':
        copy.sort(
          (a, b) =>
              cmpDate((a['Date'] ?? '') as String, (b['Date'] ?? '') as String),
        );
        break;
      case 'Date (newest)':
      default:
        copy.sort(
          (a, b) =>
              cmpDate((b['Date'] ?? '') as String, (a['Date'] ?? '') as String),
        );
    }
    return copy;
  }

  void _add() async {
    final res = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => OrEditPage(
          record: {
            'id': '',
            'Category':
                '', // store Name in Category field for reuse of persistence
            'Amount': 0.0,
            'Date': '',
            'ValidUntil': '',
            'Note': '',
            'Receipt': null,
          },
        ),
      ),
    );
    if (res != null) {
      // Ensure has a temporary id if still empty so edits map correctly before Firestore assigns
      if ((res['id'] ?? '').toString().isEmpty) {
        res['id'] = 'temp_${DateTime.now().microsecondsSinceEpoch}';
      }
      final rows = List<Map<String, dynamic>>.from(widget.rows);
      rows.add(res);
      widget.onRowsChanged(rows);
    }
  }

  void _edit(int index, Map<String, dynamic> row) async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => OrEditPage(record: row)),
    );
    if (result == null) return;

    final current = List<Map<String, dynamic>>.from(widget.rows);
    final existingId = (row['id'] ?? '').toString();

    // Deletion path
    if (result['__delete'] == true) {
      final delId = (result['id'] ?? existingId).toString();
      int removeIndex = -1;
      if (delId.isNotEmpty) {
        removeIndex = current.indexWhere((r) => (r['id'] ?? '') == delId);
      }
      if (removeIndex < 0) {
        removeIndex = current.indexWhere(
          (r) =>
              r['Category'] == row['Category'] &&
              r['Amount'] == row['Amount'] &&
              r['Date'] == row['Date'] &&
              r['Note'] == row['Note'],
        );
      }
      if (removeIndex >= 0) {
        current.removeAt(removeIndex);
        widget.onRowsChanged(current);
      }
      return;
    }

    // Update path
    int targetIndex = -1;
    if (existingId.isNotEmpty) {
      targetIndex = current.indexWhere((r) => (r['id'] ?? '') == existingId);
    }
    if (targetIndex < 0) {
      targetIndex = current.indexWhere(
        (r) =>
            r['Category'] == row['Category'] &&
            r['Amount'] == row['Amount'] &&
            r['Date'] == row['Date'] &&
            r['Note'] == row['Note'],
      );
    }
    if (targetIndex < 0) targetIndex = index;

    // Preserve id if edit result lacks it
    if ((result['id'] ?? '').toString().isEmpty && existingId.isNotEmpty) {
      result['id'] = existingId;
    }

    current[targetIndex] = {...current[targetIndex], ...result};
    widget.onRowsChanged(current);
  }

  // end _OrTabState helpers

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: '₱', decimalDigits: 2);
    final rows = _sorted(widget.rows);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppGradientBackground(
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Official Receipts',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
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
            ),
            if (rows.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    "No OR records yet. Tap '+' to add.",
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                ),
              )
            else
              SliverList.builder(
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  final amount = currency.format(
                    ((row['Amount'] ?? 0) as num).toDouble(),
                  );
                  return Dismissible(
                    key: ValueKey(row['id'] ?? index),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: const Icon(Icons.delete, color: Colors.white),
                    ),
                    confirmDismiss: (_) async {
                      return await showDialog<bool>(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('Delete OR'),
                              content: const Text(
                                'Are you sure you want to delete this record?',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text(
                                    'Delete',
                                    style: TextStyle(color: Colors.red),
                                  ),
                                ),
                              ],
                            ),
                          ) ??
                          false;
                    },
                    onDismissed: (_) {
                      final original = List<Map<String, dynamic>>.from(
                        widget.rows,
                      );
                      final id = (row['id'] ?? '').toString();
                      int removeIndex = -1;
                      if (id.isNotEmpty) {
                        removeIndex = original.indexWhere(
                          (r) => (r['id'] ?? '') == id,
                        );
                      }
                      if (removeIndex < 0) {
                        removeIndex = original.indexWhere(
                          (r) =>
                              r['Category'] == row['Category'] &&
                              r['Amount'] == row['Amount'] &&
                              r['Date'] == row['Date'] &&
                              r['Note'] == row['Note'],
                        );
                      }
                      if (removeIndex >= 0) {
                        original.removeAt(removeIndex);
                        widget.onRowsChanged(original);
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      child: PressableNeumorphic(
                        borderRadius: 16,
                        padding: const EdgeInsets.all(16),
                        onTap: () => _edit(index, row),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.receipt_long_outlined),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    (row['Category'] ?? 'No Name').toString(),
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium!
                                        .copyWith(fontWeight: FontWeight.w700),
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    children: [
                                      Text(
                                        amount,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyLarge!
                                            .copyWith(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.primary,
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          (row['Note'] ?? '').toString(),
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodyMedium,
                                          overflow: TextOverflow.ellipsis,
                                          maxLines: 1,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    (row['Date'] ?? '').toString(),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall!
                                        .copyWith(color: Colors.grey),
                                    overflow: TextOverflow.ellipsis,
                                    maxLines: 1,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            _orReceiptThumb(row),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'or-fab',
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
        elevation: 6,
        extendedPadding: const EdgeInsets.symmetric(horizontal: 20),
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text("Add OR"),
      ),
    );
  }
}

class OrEditPage extends StatefulWidget {
  final Map<String, dynamic> record;
  const OrEditPage({super.key, required this.record});

  @override
  State<OrEditPage> createState() => _OrEditPageState();
}

class _OrEditPageState extends State<OrEditPage> {
  late TextEditingController nameController;
  late TextEditingController amountController;
  late TextEditingController dateController; // Date Purchase
  late TextEditingController validUntilController; // Valid Until
  late TextEditingController noteController;
  Uint8List? receipt;
  String? localPath;
  String? receiptUrl;

  final NumberFormat _decimalFmt = NumberFormat.decimalPattern();
  final FocusNode _amountFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    nameController = TextEditingController(
      text: widget.record['Category'] ?? '',
    );
    String amtText = '';
    final amt = widget.record['Amount'];
    if (amt is num && amt > 0) amtText = _decimalFmt.format(amt);
    amountController = TextEditingController(text: amtText);
    dateController = TextEditingController(text: widget.record['Date'] ?? '');
    validUntilController = TextEditingController(
      text: widget.record['ValidUntil'] ?? '',
    );
    noteController = TextEditingController(text: widget.record['Note'] ?? '');
    receipt = widget.record['Receipt'];
    final lp = (widget.record['LocalReceiptPath'] ?? '') as String;
    localPath = lp.isNotEmpty ? lp : null;
    final ru = (widget.record['ReceiptUrl'] ?? '') as String;
    receiptUrl = ru.isNotEmpty ? ru : null;

    if (dateController.text.trim().isEmpty) {
      final now = DateTime.now();
      dateController.text =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    }
  }

  @override
  void dispose() {
    nameController.dispose();
    amountController.dispose();
    _amountFocus.dispose();
    dateController.dispose();
    validUntilController.dispose();
    noteController.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime(TextEditingController target) async {
    final current = DateTime.tryParse(target.text) ?? DateTime.now();
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
    );
    final dt = DateTime(
      pickedDate.year,
      pickedDate.month,
      pickedDate.day,
      pickedTime?.hour ?? current.hour,
      pickedTime?.minute ?? current.minute,
    );
    setState(() {
      target.text =
          "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    });
  }

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: source, imageQuality: 85);
    if (pickedFile == null) return;
    final raw = await pickedFile.readAsBytes();
    setState(() {
      receipt = raw;
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

  void _handleSave() {
    if (_amountFocus.hasFocus) _amountFocus.unfocus();
    final amountVal = parseLooseAmount(amountController.text);
    amountController.text = formatTwoDecimalsGrouped(amountVal);
    final missing = <String>[];
    if (nameController.text.trim().isEmpty) missing.add('Name');
    if (amountVal <= 0) missing.add('Amount > 0');
    if (dateController.text.trim().isEmpty) missing.add('Date Purchase');

    if (missing.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Please complete: ${missing.join(' • ')}')),
      );
      return;
    }

    final updated = {
      'Category': nameController.text.trim(),
      'Amount': amountVal,
      'Date': dateController.text.trim(),
      'ValidUntil': validUntilController.text.trim(),
      'Note': noteController.text.trim(),
      'Receipt': receipt,
      if (receipt != null) 'LocalReceiptPath': null,
      if (receipt != null) 'ReceiptUrl': '',
      if (receipt == null &&
          (localPath ?? '').isEmpty &&
          (receiptUrl ?? '').isEmpty) ...{
        'LocalReceiptPath': null,
        'ReceiptUrl': '',
      },
      'id': widget.record['id'],
    };
    Navigator.pop(context, updated);
  }

  @override
  Widget build(BuildContext context) {
    return AppGradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          title: Text(widget.record['Category'] == '' ? 'Add OR' : 'Edit OR'),
          actions: [
            IconButton(
              icon: const Icon(Icons.save),
              tooltip: 'Save',
              onPressed: _handleSave,
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
            child: Column(
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    prefixIcon: Icon(Icons.receipt_long_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
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
                  decoration: const InputDecoration(
                    labelText: 'Amount',
                    prefixText: '₱ ',
                    border: OutlineInputBorder(),
                  ),
                ),
                if ((double.tryParse(
                          amountController.text.replaceAll(',', ''),
                        ) ??
                        0) <=
                    0)
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
                  onTap: () => _pickDateTime(dateController),
                  decoration: const InputDecoration(
                    labelText: 'Date Purchase',
                    prefixIcon: Icon(Icons.event_outlined),
                    border: OutlineInputBorder(),
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
                // New Valid Until (same style as Date Purchase)
                TextField(
                  controller: validUntilController,
                  readOnly: true,
                  onTap: () => _pickDateTime(validUntilController),
                  decoration: const InputDecoration(
                    labelText: 'Valid Until',
                    prefixIcon: Icon(Icons.event_available_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 6),
                Builder(
                  builder: (_) {
                    final dt = DateTime.tryParse(validUntilController.text);
                    final friendly = dt != null
                        ? DateFormat('MMM d, y h:mm a').format(dt)
                        : validUntilController.text;
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
          child: Row(
            children: [
              if ((widget.record['id'] ?? '').toString().isNotEmpty)
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      foregroundColor: Colors.red,
                    ),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('Delete OR'),
                          content: const Text(
                            'Are you sure you want to delete this record?',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: const Text(
                                'Delete',
                                style: TextStyle(color: Colors.red),
                              ),
                            ),
                          ],
                        ),
                      );
                      if (confirm == true) {
                        Navigator.pop(context, {
                          '__delete': true,
                          'id': widget.record['id'],
                        });
                      }
                    },
                  ),
                ),
              if ((widget.record['id'] ?? '').toString().isNotEmpty)
                const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(56),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: _handleSave,
                  icon: const Icon(Icons.save),
                  label: const Text('Save OR'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _orReceiptThumb(Map<String, dynamic> row) {
  final local = (row['LocalReceiptPath'] ?? '') as String;
  final url = (row['ReceiptUrl'] ?? '') as String;
  final hasMem = row['Receipt'] != null && row['Receipt'] is Uint8List;
  Widget child;
  if (local.isNotEmpty) {
    child = Image.file(
      File(local),
      width: 64,
      height: 64,
      fit: BoxFit.cover,
      errorBuilder: (c, e, s) => _brokenThumb(),
    );
  } else if (url.isNotEmpty) {
    child = Image.network(
      url,
      width: 64,
      height: 64,
      fit: BoxFit.cover,
      errorBuilder: (c, e, s) => _brokenThumb(),
    );
  } else if (hasMem) {
    child = Image.memory(
      row['Receipt'] as Uint8List,
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
// End of OR tab implementation
