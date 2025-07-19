import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'dart:async';
import 'features/report/report_tab.dart';
import 'features/expenses/expenses_tab.dart';
import 'features/savings/savings_tab.dart';
import 'features/bills/bills_tab.dart';

class HomeTabsPage extends StatefulWidget {
  const HomeTabsPage({super.key});

  @override
  State<HomeTabsPage> createState() => _HomeTabsPageState();
}

class _HomeTabsPageState extends State<HomeTabsPage> {
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();
  final Box box = Hive.box('budgetBox');
  List<String> tabs = [];
  Map<String, List<Map<String, dynamic>>> tableData = {};
  Map<String, double> tabLimits = {};
  Map<String, double> savingsGoals = {};
  Map<String, List<String>> billReminders = {};
  final Map<String, Color> _categoryColors = {};
  Timer? _billCheckTimer;

  void initializeNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    final InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);
    await flutterLocalNotificationsPlugin.initialize(initializationSettings);
  }

  Future<void> checkExpenseThresholdNotification() async {
    final expenses = tableData['Expenses'] ?? [];
    double totalExpense = expenses.fold(
      0.0,
      (sum, row) => sum + (row['Amount'] ?? 0.0),
    );
    final limit = tabLimits['Expenses'] ?? 0.0;
    if (limit > 0 && totalExpense >= limit * 0.75) {
      await flutterLocalNotificationsPlugin.show(
        10000,
        'Expense Limit Alert',
        'You have reached 75% or more of your expense limit!',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'expense_alert_channel',
            'Expense Alerts',
            channelDescription: 'Notification when expense limit is near',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    }
  }

  void checkBillDueNotifications() async {
    final today = DateTime.now();
    final rows = tableData['Bills'] ?? [];
    for (var row in rows) {
      final dueDateStr = row['Due Date'];
      if (dueDateStr == null || dueDateStr.isEmpty) continue;
      final dueDate = DateTime.tryParse(dueDateStr);
      if (dueDate == null) continue;
      final daysUntilDue = dueDate.difference(today).inDays;
      if (daysUntilDue <= 7) {
        await flutterLocalNotificationsPlugin.show(
          dueDate.hashCode,
          'Bill Due Soon',
          '${row['Name']} is due on ${row['Due Date']}',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'bill_reminder_channel',
              'Bill Reminders',
              channelDescription: 'Notification for due bills',
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _billCheckTimer?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    tabs =
        (box.get('tabs') as List?)?.cast<String>() ??
        ['Expenses', 'Savings', 'Bills', 'Report'];
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
    if (rawTabLimits != null) {
      rawTabLimits.forEach((key, value) {
        tabLimits[key.toString()] = value is num ? value.toDouble() : 0.0;
      });
    }
    final rawSavingsGoals = box.get('savingsGoals') as Map?;
    savingsGoals = {};
    if (rawSavingsGoals != null) {
      rawSavingsGoals.forEach((key, value) {
        savingsGoals[key.toString()] = value is num ? value.toDouble() : 0.0;
      });
    }
    final rawBillReminders = box.get('billReminders') as Map?;
    billReminders = {};
    if (rawBillReminders != null) {
      rawBillReminders.forEach((key, value) {
        billReminders[key.toString()] = (value as List?)?.cast<String>() ?? [];
      });
    }
    for (var tab in tabs) {
      tableData.putIfAbsent(tab, () => []);
    }
    saveData();
    initializeNotifications();
    checkBillDueNotifications();
    _billCheckTimer = Timer.periodic(
      const Duration(minutes: 3),
      (_) => checkBillDueNotifications(),
    );
    checkExpenseThresholdNotification();
  }

  void saveData() {
    box.put('tabs', tabs);
    box.put('tableData', tableData);
    box.put('tabLimits', tabLimits);
    box.put('savingsGoals', savingsGoals);
    box.put('billReminders', billReminders);
    checkExpenseThresholdNotification();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: tabs.length + 1,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('BudgetBuddy'),
          elevation: 4,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(bottom: Radius.circular(16)),
          ),
          bottom: TabBar(
            isScrollable: true,
            indicatorColor: Colors.white,
            tabs: [
              ...tabs.map(
                (tab) => GestureDetector(
                  onLongPress: () => showEditTabDialog(tab),
                  child: Tab(text: tab),
                ),
              ),
              const Tab(icon: Icon(Icons.add)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            ...tabs.map((tab) {
              if (tab == 'Report') {
                return ReportTab(
                  tableData: tableData,
                  categoryColors: _categoryColors,
                );
              }
              if (tab == 'Savings') {
                return SavingsTab(
                  rows: tableData['Savings'] ?? [],
                  goal: savingsGoals['Savings'],
                  onAddNewRow: (columns) => addNewRow('Savings', columns),
                  onSetGoal: () {
                    final ctrl = TextEditingController(
                      text: savingsGoals['Savings']?.toString() ?? '',
                    );
                    showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text("Set Goal"),
                        content: TextField(
                          controller: ctrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            hintText: "Enter savings goal",
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {
                              setState(() {
                                savingsGoals['Savings'] =
                                    double.tryParse(ctrl.text) ?? 0.0;
                                saveData();
                                Navigator.pop(context);
                              });
                            },
                            child: const Text("Save"),
                          ),
                        ],
                      ),
                    );
                  },
                  onAddColumn: () async {
                    final newColName = await showAddColumnDialog();
                    if (newColName != null &&
                        newColName.isNotEmpty &&
                        !(tableData['Savings']?[0].containsKey(newColName) ??
                            false)) {
                      setState(() {
                        for (var row in tableData['Savings']!) {
                          row[newColName] = "";
                        }
                        saveData();
                      });
                    }
                    return null;
                  },
                  onDeleteRow: (rowIndex) {
                    setState(() {
                      tableData['Savings']!.removeAt(rowIndex);
                      saveData();
                    });
                  },
                  onEditValue: (currentValue) =>
                      showEditValueDialog(currentValue),
                );
              }
              if (tab == 'Expenses') {
                return ExpensesTab(
                  rows: tableData['Expenses'] ?? [],
                  limit: tabLimits['Expenses'],
                  onAddNewRow: (columns) => addNewRow('Expenses', columns),
                  onSetLimit: () {
                    final ctrl = TextEditingController(
                      text: tabLimits['Expenses']?.toString() ?? '',
                    );
                    showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text("Set Limit"),
                        content: TextField(
                          controller: ctrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            hintText: "Enter limit amount",
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {
                              setState(() {
                                tabLimits['Expenses'] =
                                    double.tryParse(ctrl.text) ?? 0.0;
                                saveData();
                                Navigator.pop(context);
                              });
                            },
                            child: const Text("Save"),
                          ),
                        ],
                      ),
                    );
                  },
                  onAddColumn: () async {
                    final newColName = await showAddColumnDialog();
                    if (newColName != null &&
                        newColName.isNotEmpty &&
                        !(tableData['Expenses']?[0].containsKey(newColName) ??
                            false)) {
                      setState(() {
                        for (var row in tableData['Expenses']!) {
                          row[newColName] = "";
                        }
                        saveData();
                      });
                    }
                  },
                  onDeleteRow: (rowIndex) {
                    setState(() {
                      tableData['Expenses']!.removeAt(rowIndex);
                      saveData();
                    });
                  },
                  onEditValue: (currentValue) =>
                      showEditValueDialog(currentValue),
                );
              }
              if (tab == 'Bills') {
                return BillsTab(
                  rows: tableData['Bills'] ?? [],
                  onAddNewRow: (columns) => addNewRow('Bills', columns),
                  onDeleteRow: (rowIndex) {
                    setState(() {
                      tableData['Bills']!.removeAt(rowIndex);
                      saveData();
                    });
                  },
                  onEditRow: null,
                );
              }
              return buildTabContent(tab);
            }),
            Center(
              child: ElevatedButton.icon(
                onPressed: addTab,
                icon: const Icon(Icons.add),
                label: const Text("Add Tab"),
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(
                    vertical: 14,
                    horizontal: 24,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color getRandomColor() {
    final random = DateTime.now().millisecondsSinceEpoch;
    return Color(
      (0xFF000000 + (random ^ _categoryColors.length * 997) % 0xFFFFFF),
    ).withOpacity(1.0);
  }

  int touchedIndex = -1;

  Widget buildBillsTab() {
    final rows = tableData['Bills'] ?? [];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: ElevatedButton.icon(
            onPressed: () => addNewRow('Bills', [
              'Name',
              'Amount',
              'Due Date',
              'Recurrence',
            ]),
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
          child: ListView(
            children: rows.map((row) {
              return ListTile(
                title: Text(row['Name'] ?? ''),
                subtitle: Text(
                  "₱${row['Amount']?.toStringAsFixed(2) ?? ''} - Due: ${row['Due Date'] ?? ''}",
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () => addNewRow('Bills', [
                    'Name',
                    'Amount',
                    'Due Date',
                    'Recurrence',
                  ]),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  void addTab() async {
    final nameController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("New Tab Name"),
        content: TextField(controller: nameController),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, nameController.text.trim()),
            child: const Text("Add"),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty && !tabs.contains(result)) {
      setState(() {
        tabs.add(result);
        tableData[result] = [];
        saveData();
      });
    }
  }

  void showEditTabDialog(String tab) async {
    final nameController = TextEditingController(text: tab);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Edit or Delete Tab"),
        content: TextField(controller: nameController),
        actions: [
          if (!['Expenses', 'Savings', 'Bills', 'Report'].contains(tab))
            TextButton(
              onPressed: () {
                setState(() {
                  tabs.remove(tab);
                  tableData.remove(tab);
                  saveData();
                });
                Navigator.pop(context);
              },
              child: const Text("Delete"),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context, nameController.text.trim()),
            child: const Text("Rename"),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty && result != tab) {
      setState(() {
        final data = tableData.remove(tab);
        tabs[tabs.indexOf(tab)] = result;
        tableData[result] = data ?? [];
        saveData();
      });
    }
  }

  Widget buildTabContent(String tab) {
    List<Map<String, dynamic>> rows = tableData[tab] ?? [];
    bool isEmpty = rows.isEmpty;
    List<String> columns = ['Name', 'Amount', 'Date'];
    if (tab == 'Bills' && !columns.contains('Recurrence')) {
      columns.add('Recurrence');
    }
    if (rows.isNotEmpty) {
      final existingCols = rows.expand((row) => row.keys).toSet();
      for (var col in existingCols) {
        if (!columns.contains(col)) columns.add(col);
      }
    }
    double total = rows.fold(0.0, (sum, row) => sum + (row['Amount'] ?? 0.0));
    double? limit = tabLimits[tab];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              if (tab == 'Expenses')
                TextButton(
                  onPressed: () {
                    final ctrl = TextEditingController(
                      text: limit?.toString() ?? '',
                    );
                    showDialog(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text("Set Limit"),
                        content: TextField(
                          controller: ctrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            hintText: "Enter limit amount",
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {
                              setState(() {
                                tabLimits[tab] =
                                    double.tryParse(ctrl.text) ?? 0.0;
                                saveData();
                                Navigator.pop(context);
                              });
                            },
                            child: const Text("Save"),
                          ),
                        ],
                      ),
                    );
                  },
                  child: const Text("Set Limit"),
                ),
              Padding(
                padding: const EdgeInsets.only(right: 12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (limit != null)
                      Text(
                        "Limit: ₱${limit.toStringAsFixed(2)}",
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    Text(
                      "Total: ₱${total.toStringAsFixed(2)}",
                      style: TextStyle(
                        color: limit != null && total > limit
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
          onPressed: () => addNewRow(tab, columns),
          icon: const Icon(Icons.add),
          label: const Text('Add Record'),
          style: ElevatedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        Expanded(
          child: isEmpty
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
                              final newColName = await showAddColumnDialog();
                              if (newColName != null &&
                                  newColName.isNotEmpty &&
                                  !columns.contains(newColName)) {
                                setState(() {
                                  for (var row in tableData[tab]!) {
                                    row[newColName] = "";
                                  }
                                  saveData();
                                });
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
                                    if (col == 'Date') {
                                      final picked = await showDatePicker(
                                        context: context,
                                        initialDate:
                                            DateTime.tryParse(row[col] ?? '') ??
                                            DateTime.now(),
                                        firstDate: DateTime(2000),
                                        lastDate: DateTime(2100),
                                      );
                                      if (picked != null) {
                                        setState(() {
                                          row[col] =
                                              "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}";
                                          saveData();
                                        });
                                      }
                                    } else if (col == 'Recurrence') {
                                      final val = await showDialog<String>(
                                        context: context,
                                        builder: (_) {
                                          String selected = row[col] ?? 'None';
                                          return AlertDialog(
                                            title: const Text(
                                              'Select Recurrence',
                                            ),
                                            content: StatefulBuilder(
                                              builder: (context, setStateDropdown) {
                                                return DropdownButton<String>(
                                                  value: selected,
                                                  isExpanded: true,
                                                  items:
                                                      [
                                                            'None',
                                                            'Monthly',
                                                            'Yearly',
                                                          ]
                                                          .map(
                                                            (option) =>
                                                                DropdownMenuItem(
                                                                  value: option,
                                                                  child: Text(
                                                                    option,
                                                                  ),
                                                                ),
                                                          )
                                                          .toList(),
                                                  onChanged: (value) {
                                                    if (value != null) {
                                                      setStateDropdown(
                                                        () => selected = value,
                                                      );
                                                    }
                                                  },
                                                );
                                              },
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.pop(
                                                  context,
                                                  null,
                                                ),
                                                child: const Text("Cancel"),
                                              ),
                                              ElevatedButton(
                                                onPressed: () => Navigator.pop(
                                                  context,
                                                  selected,
                                                ),
                                                child: const Text("OK"),
                                              ),
                                            ],
                                          );
                                        },
                                      );
                                      if (val != null) {
                                        setState(() {
                                          row[col] = val;
                                          saveData();
                                        });
                                      }
                                    } else {
                                      final val = await showEditValueDialog(
                                        row[col],
                                      );
                                      if (val != null) {
                                        setState(() {
                                          row[col] = col == 'Amount'
                                              ? double.tryParse(val) ?? 0.0
                                              : val;
                                          saveData();
                                        });
                                      }
                                    }
                                  },
                                );
                              }),
                              const DataCell(SizedBox()),
                              DataCell(
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete,
                                    color: Colors.redAccent,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      tableData[tab]!.removeAt(rowIndex);
                                      saveData();
                                    });
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

  Future<String?> showEditValueDialog(dynamic currentValue) {
    final controller = TextEditingController(text: currentValue.toString());
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Edit Value"),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.text,
        ),
        actions: [
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            icon: const Icon(Icons.save),
            label: const Text("Save"),
            style: ElevatedButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<String?> showAddColumnDialog() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Add Column"),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: "Enter new column name"),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text("Cancel"),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            icon: const Icon(Icons.add),
            label: const Text("Add"),
            style: ElevatedButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void addNewRow(String tab, List<String> columns) async {
    final controllers = <String, TextEditingController>{
      for (var col in columns) col: TextEditingController(),
    };
    final now = DateTime.now();
    if (columns.contains('Date')) {
      controllers['Date']?.text =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
    }
    if (columns.contains('Due Date')) {
      controllers['Due Date']?.text =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
    }
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text("Add New Record"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: columns.map((col) {
              if (tab == 'Bills' && col == 'Recurrence') {
                final recurrenceOptions = [
                  'None',
                  'Daily',
                  'Weekly',
                  'Monthly',
                  'Yearly',
                ];
                String selectedValue = controllers[col]?.text.isNotEmpty == true
                    ? controllers[col]!.text
                    : 'None';
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: 'Recurrence',
                      border: OutlineInputBorder(),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: selectedValue,
                        isDense: true,
                        onChanged: (value) {
                          setState(() {
                            controllers[col]?.text = value ?? 'None';
                          });
                        },
                        items: recurrenceOptions
                            .map(
                              (option) => DropdownMenuItem(
                                value: option,
                                child: Text(option),
                              ),
                            )
                            .toList(),
                      ),
                    ),
                  ),
                );
              } else {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: TextField(
                    controller: controllers[col],
                    keyboardType: col == 'Amount'
                        ? TextInputType.numberWithOptions(decimal: true)
                        : TextInputType.text,
                    readOnly: col == 'Date' || col == 'Due Date',
                    onTap: (col == 'Date' || col == 'Due Date')
                        ? () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: DateTime.now(),
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2100),
                            );
                            if (picked != null) {
                              controllers[col]?.text =
                                  "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}";
                            }
                          }
                        : null,
                    decoration: InputDecoration(
                      labelText: col,
                      border: OutlineInputBorder(),
                    ),
                  ),
                );
              }
            }).toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.check),
            label: const Text("Add"),
            style: ElevatedButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
    if (result == true) {
      final newRow = <String, dynamic>{};
      for (var col in columns) {
        final value = controllers[col]?.text.trim();
        newRow[col] = col == 'Amount'
            ? double.tryParse(value ?? '') ?? 0.0
            : value;
      }
      setState(() {
        tableData[tab]!.add(newRow);
        saveData();
      });
    }
  }
}
