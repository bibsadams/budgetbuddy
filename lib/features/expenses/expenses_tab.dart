import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:hive/hive.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

class ExpensesTab extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final double? limit;
  final void Function(List<Map<String, dynamic>> newRows) onRowsChanged;
  final void Function()? onSetLimit;

  const ExpensesTab({
    super.key,
    required this.rows,
    required this.limit,
    required this.onRowsChanged,
    required this.onSetLimit,
  });

  @override
  Widget build(BuildContext context) {
    final currency = NumberFormat.currency(symbol: '₱', decimalDigits: 2);
    final total = rows.fold<double>(
      0.0,
      (sum, row) =>
          sum + (row['Amount'] is num ? row['Amount'] as num : 0).toDouble(),
    );
    final limitVal = limit ?? 0.0;
    final progress = limitVal > 0 ? (total / limitVal).clamp(0.0, 1.0) : 0.0;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: _SummaryHeader(
                totalLabel: currency.format(total),
                limitLabel: limit != null ? currency.format(limitVal) : null,
                progress: progress,
                overLimit: limit != null && total > limitVal,
                onSetLimit: onSetLimit,
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
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                return _buildExpenseCard(context, row, index);
              },
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
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
            onRowsChanged(newRows);
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
    return Card(
      color: Theme.of(context).colorScheme.surface,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ExpenseDetailsPage(
                expense: row,
                onEdit: (updatedExpense) {
                  final newRows = List<Map<String, dynamic>>.from(rows);
                  newRows[index] = updatedExpense;
                  onRowsChanged(newRows);
                  Navigator.pop(context);
                },
                onDelete: () {
                  final newRows = List<Map<String, dynamic>>.from(rows);
                  newRows.removeAt(index);
                  onRowsChanged(newRows);
                  Navigator.pop(context);
                },
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: _categoryColor(
                    context,
                    (row['Category'] ?? '') as String?,
                  ),
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
                      (row['Category'] ?? 'No Category').toString(),
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
                          style: Theme.of(context).textTheme.bodyLarge!
                              .copyWith(
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
                child: row['Receipt'] != null
                    ? Image.memory(
                        row['Receipt'] as Uint8List,
                        width: 64,
                        height: 64,
                        fit: BoxFit.cover,
                      )
                    : Container(
                        width: 64,
                        height: 64,
                        color: Colors.grey[200],
                        child: const Icon(Icons.receipt_long, size: 28),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryHeader extends StatelessWidget {
  final String totalLabel;
  final String? limitLabel;
  final double progress;
  final bool overLimit;
  final VoidCallback? onSetLimit;

  const _SummaryHeader({
    required this.totalLabel,
    required this.limitLabel,
    required this.progress,
    required this.overLimit,
    required this.onSetLimit,
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
                    const Text(
                      'This Month',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      totalLabel,
                      style: Theme.of(context).textTheme.headlineSmall!
                          .copyWith(fontWeight: FontWeight.w800),
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Limit: $limitLabel',
                  style: TextStyle(
                    color: overLimit ? Colors.red : Colors.grey[700],
                    fontWeight: FontWeight.w600,
                  ),
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
            ClipRRect(
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
          ],
        ],
      ),
    );
  }
}

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Expense Details'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit, size: 32),
            tooltip: 'Edit',
            onPressed: () async {
              final updatedExpense = await Navigator.push<Map<String, dynamic>>(
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
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Expense Details',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            _buildDetailRow('Category', expense['Category'] ?? ''),
            _buildDetailRow(
              'Amount',
              '₱${(expense['Amount'] ?? 0.0).toStringAsFixed(2)}',
            ),
            _buildDetailRow('Date', expense['Date'] ?? ''),
            _buildDetailRow('Note', expense['Note'] ?? ''),
            const SizedBox(height: 32),
            if (expense['Receipt'] != null)
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    expense['Receipt'],
                    width: MediaQuery.of(context).size.width * 0.9,
                    height: MediaQuery.of(context).size.height * 0.5,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
          ],
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

  String? selectedCategory;
  String? selectedSubcategory;

  Map<String, List<String>> categoriesMap = {};

  final box = Hive.box('budgetBox');
  final NumberFormat _decimalFmt = NumberFormat.decimalPattern();

  bool get _canSave {
    final raw = amountController.text.replaceAll(',', '').trim();
    final val = double.tryParse(raw) ?? 0.0;
    return (selectedCategory != null && val > 0);
  }

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
    receipt = widget.expense['Receipt'];
    if (!categoriesMap.containsKey(selectedCategory)) {
      selectedCategory = null;
      selectedSubcategory = null;
    }
    // Default date to today if empty
    if (dateController.text.trim().isEmpty) {
      final now = DateTime.now();
      dateController.text =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
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
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(dateController.text) ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        dateController.text =
            "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}";
      });
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: source);
    if (pickedFile != null) {
      final bytes = await pickedFile.readAsBytes();
      setState(() {
        receipt = bytes;
      });
    }
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

  Future<void> _addNewCategory() async {
    String? newCat = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text("Add New Category"),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: "Category name"),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  Navigator.pop(context, controller.text.trim());
                }
              },
              child: const Text("Add"),
            ),
          ],
        );
      },
    );
    if (newCat != null && !categoriesMap.containsKey(newCat)) {
      setState(() {
        categoriesMap[newCat] = [];
        selectedCategory = newCat;
        selectedSubcategory = null;
      });
      box.put('categories', categoriesMap);
    }
  }

  Future<void> _addNewSubcategory() async {
    if (selectedCategory == null) return;
    String? newSub = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text("Add New Subcategory"),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: "Subcategory name"),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  Navigator.pop(context, controller.text.trim());
                }
              },
              child: const Text("Add"),
            ),
          ],
        );
      },
    );
    if (newSub != null) {
      final subs = categoriesMap[selectedCategory]!;
      if (!subs.contains(newSub)) {
        setState(() {
          subs.add(newSub);
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

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.expense['Category'] == '' ? 'Add Expense' : 'Edit Expense',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: 'Save',
            onPressed: _canSave
                ? () {
                    final updatedExpense = {
                      'Category': selectedCategory ?? '',
                      'Subcategory': selectedSubcategory ?? '',
                      'Amount':
                          double.tryParse(
                            amountController.text.replaceAll(',', ''),
                          ) ??
                          0.0,
                      'Date': dateController.text,
                      'Note': noteController.text,
                      'Receipt': receipt,
                    };
                    Navigator.pop(context, updatedExpense);
                  }
                : null,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: selectedCategory,
                    decoration: const InputDecoration(
                      labelText: 'Category',
                      prefixIcon: Icon(Icons.category_outlined),
                      border: OutlineInputBorder(),
                    ),
                    items: categoriesMap.keys
                        .map<DropdownMenuItem<String>>(
                          (cat) =>
                              DropdownMenuItem(value: cat, child: Text(cat)),
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
                            (sub) =>
                                DropdownMenuItem(value: sub, child: Text(sub)),
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

            const SizedBox(height: 20),
            TextField(
              controller: dateController,
              readOnly: true,
              onTap: _pickDate,
              style: const TextStyle(fontSize: 20),
              decoration: InputDecoration(
                labelText: 'Date',
                prefixIcon: const Icon(Icons.event_outlined),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Pick date',
                  icon: const Icon(Icons.calendar_today_outlined),
                  onPressed: _pickDate,
                ),
              ),
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
            if (receipt != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  receipt!,
                  width: MediaQuery.of(context).size.width * 0.9,
                  height: MediaQuery.of(context).size.height * 0.4,
                  fit: BoxFit.cover,
                ),
              ),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _showImageSourceSheet,
                  icon: const Icon(Icons.attachment_outlined),
                  label: Text(
                    receipt == null ? 'Attach Receipt' : 'Change Receipt',
                  ),
                ),
                const SizedBox(width: 12),
                if (receipt != null)
                  OutlinedButton.icon(
                    onPressed: () => setState(() => receipt = null),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove'),
                  ),
              ],
            ),
          ],
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
          onPressed: _canSave
              ? () {
                  final updatedExpense = {
                    'Category': selectedCategory ?? '',
                    'Subcategory': selectedSubcategory ?? '',
                    'Amount':
                        double.tryParse(
                          amountController.text.replaceAll(',', ''),
                        ) ??
                        0.0,
                    'Date': dateController.text,
                    'Note': noteController.text,
                    'Receipt': receipt,
                  };
                  Navigator.pop(context, updatedExpense);
                }
              : null,
          icon: const Icon(Icons.save),
          label: const Text("Save Expense"),
        ),
      ),
    );
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
          parts[0] +
          '.' +
          (decimals.length > 2 ? decimals.substring(0, 2) : decimals);
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
