import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/intl.dart';
import 'dart:async';
import 'dart:ui' show ImageFilter;
import 'features/expenses/expenses_tab.dart';

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
  Map<String, double> tabLimits = {}; // For Expenses
  Map<String, double> savingsGoals = {}; // For Savings tab
  Map<String, List<String>> billReminders =
      {}; // For Bills tab: [Due Date, Description]
  final Map<String, Color> _categoryColors = {}; // ← Add this line
  Timer? _billCheckTimer;

  void initializeNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    final InitializationSettings initializationSettings =
        InitializationSettings(
          android: initializationSettingsAndroid,
          // You can add iOS initialization here if needed
        );

    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
      // Optional: onSelectNotification handler here
    );
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
        10000, // unique notification id for expense alert
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

    print("Checking for due bills...");

    for (var row in rows) {
      final dueDateStr = row['Due Date'];
      if (dueDateStr == null || dueDateStr.isEmpty) continue;

      final dueDate = DateTime.tryParse(dueDateStr);
      if (dueDate == null) continue;

      // If today is 1 day before or same day as due date or overdue
      final daysUntilDue = dueDate.difference(today).inDays;
      if (daysUntilDue <= 7) {
        await flutterLocalNotificationsPlugin.show(
          dueDate.hashCode, // unique ID
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

  // void checkExpenseThresholdNotification() async {
  //   final totalExpenses =
  //       tableData['Expenses']?.fold<double>(
  //         0.0,
  //         (sum, row) => sum + (row['Amount'] ?? 0.0),
  //       ) ??
  //       0.0;

  //   final limit = tabLimits['Expenses'] ?? 0.0;

  //   if (limit > 0 && totalExpenses >= 0.75 * limit) {
  //     await flutterLocalNotificationsPlugin.show(
  //       9999, // Unique ID for expense alert
  //       'Expenses Alert',
  //       'Your expenses have reached 75% of the set limit (₱${limit.toStringAsFixed(2)}).',
  //       const NotificationDetails(
  //         android: AndroidNotificationDetails(
  //           'expenses_alert_channel',
  //           'Expenses Alert',
  //           channelDescription: 'Notifies when expenses hit 75% of the limit',
  //           importance: Importance.high,
  //           priority: Priority.high,
  //         ),
  //       ),
  //     );
  //   }
  // }

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

    // Ensure tableData contains a list for each tab
    for (var tab in tabs) {
      tableData.putIfAbsent(tab, () => []);
    }

    saveData();

    // Initialize notifications
    initializeNotifications();

    // Check bills and show notifications if due
    checkBillDueNotifications(); // Run immediately on launch
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
    // Check if expense threshold notification needs to be shown after saving
    checkExpenseThresholdNotification();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: tabs.length + 1,
      child: Scaffold(
        extendBodyBehindAppBar: true,
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          flexibleSpace: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
              child: Container(color: Colors.transparent),
            ),
          ),
          title: const Text('BudgetBuddy'),
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
              if (tab == 'Report') return buildReportTab();
              if (tab == 'Savings') return buildSavingsTab();
              if (tab == 'Bills') return buildBillsTab();
              if (tab == 'Expenses') {
                final rows = tableData['Expenses'] ?? [];
                final savingsRows = tableData['Savings'] ?? [];
                final limit = tabLimits['Expenses'];
                return ExpensesTab(
                  rows: rows,
                  limit: limit,
                  savingsRows: savingsRows,
                  onRowsChanged: (newRows) {
                    setState(() {
                      // Preserve any local receipt metadata when replacing the list
                      final existing =
                          Map<String, Map<String, dynamic>>.fromEntries(
                            (tableData['Expenses'] ?? [])
                                .where(
                                  (e) => (e['id'] ?? '').toString().isNotEmpty,
                                )
                                .map(
                                  (e) => MapEntry(
                                    (e['id'] as String).toString(),
                                    Map<String, dynamic>.from(e),
                                  ),
                                ),
                          );
                      // Simple overlay: if a new row lacks ReceiptUids/LocalReceiptPath,
                      // copy from the previous entry with same id.
                      final merged = newRows.map<Map<String, dynamic>>((r) {
                        final id = (r['id'] ?? '').toString();
                        final m = Map<String, dynamic>.from(r);
                        if ((m['LocalReceiptPath'] == null ||
                                (m['LocalReceiptPath'] as String).isEmpty) &&
                            existing.containsKey(id)) {
                          final prev = existing[id]!;
                          final prevPath = (prev['LocalReceiptPath'] ?? '')
                              .toString();
                          if (prevPath.isNotEmpty)
                            m['LocalReceiptPath'] = prevPath;
                        }
                        if ((m['ReceiptUids'] == null ||
                                !(m['ReceiptUids'] is List) ||
                                (m['ReceiptUids'] as List).isEmpty) &&
                            existing.containsKey(id)) {
                          final prev = existing[id]!;
                          if (prev['ReceiptUids'] is List &&
                              (prev['ReceiptUids'] as List).isNotEmpty) {
                            m['ReceiptUids'] = List<String>.from(
                              prev['ReceiptUids'] as List,
                            );
                          } else if ((prev['ReceiptUid'] ?? '')
                              .toString()
                              .isNotEmpty) {
                            m['ReceiptUids'] = [
                              (prev['ReceiptUid'] ?? '').toString(),
                            ];
                          }
                        }
                        return m;
                      }).toList();
                      tableData['Expenses'] = merged;
                      saveData();
                    });
                  },
                  onSetLimit: () {
                    final valueCtrl = TextEditingController(
                      text: (box.get('expensesLimitPercent') ?? '').toString(),
                    );
                    showDialog(
                      context: context,
                      builder: (_) => StatefulBuilder(
                        builder: (ctx, setLocal) {
                          final currentPeriod =
                              (box.get('expensesSummaryPeriod') as String?) ??
                              'month';
                          final periodWord = switch (currentPeriod) {
                            'week' => 'weekly',
                            'quarter' => 'quarterly',
                            _ => 'monthly',
                          };
                          final helper = 'Percent of $periodWord saving';
                          return AlertDialog(
                            title: const Text("Set Limit"),
                            content: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                TextField(
                                  controller: valueCtrl,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Percent',
                                    suffixText: '%',
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    helper,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                ),
                              ],
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text("Cancel"),
                              ),
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    final numVal = double.tryParse(
                                      valueCtrl.text,
                                    );
                                    box.put(
                                      'expensesLimitPercent',
                                      (numVal ?? 0).clamp(0.0, 100.0),
                                    );
                                    saveData();
                                  });
                                  Navigator.pop(context);
                                },
                                child: const Text("Save"),
                              ),
                            ],
                          );
                        },
                      ),
                    );
                  },
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
    ).withValues(alpha: 1.0);
  }

  // Month/Year selection state for Home Report
  int _reportMonth = DateTime.now().month; // 1..12
  int _reportYear = DateTime.now().year;
  bool _showSavingsByCat = true;
  bool _showSavingsBySub = false;
  bool _showExpensesByCat = true;
  bool _showExpensesBySub = false;

  Widget buildReportTab() {
    final expenses = tableData['Expenses'] ?? [];
    final savings = tableData['Savings'] ?? [];

    bool pass(Object? date) {
      DateTime? dt;
      if (date is DateTime) dt = date;
      if (dt == null && date is String) dt = DateTime.tryParse(date);
      if (dt == null) return false;
      return dt.year == _reportYear && dt.month == _reportMonth;
    }

    String monthLabel(int m) => DateFormat.MMM().format(DateTime(2000, m));
    final header = '${monthLabel(_reportMonth)} $_reportYear';

    // Filtered rows
    final expRows = expenses.where((r) => pass(r['Date'])).toList();
    final savRows = savings.where((r) => pass(r['Date'])).toList();

    // Aggregations
    Map<String, double> sumByCat(List<Map<String, dynamic>> rows) {
      final map = <String, double>{};
      for (final r in rows) {
        final cat = (r['Category'] ?? r['Name'] ?? 'Uncategorized').toString();
        final amt = (r['Amount'] is num)
            ? (r['Amount'] as num).toDouble()
            : 0.0;
        map[cat] = (map[cat] ?? 0) + amt;
      }
      return map;
    }

    Map<String, double> sumBySub(List<Map<String, dynamic>> rows) {
      final map = <String, double>{};
      for (final r in rows) {
        final cat = (r['Category'] ?? r['Name'] ?? 'Uncategorized').toString();
        final sub = (r['Subcategory'] ?? 'Unspecified').toString();
        final key = '$cat • $sub';
        final amt = (r['Amount'] is num)
            ? (r['Amount'] as num).toDouble()
            : 0.0;
        map[key] = (map[key] ?? 0) + amt;
      }
      return map;
    }

    final expByCat = sumByCat(expRows);
    final expBySub = sumBySub(expRows);
    final savByCat = sumByCat(savRows);
    final savBySub = sumBySub(savRows);

    List<DropdownMenuItem<int>> yearItems() {
      final years = <int>{_reportYear};
      for (final r in expenses + savings) {
        final d = r['Date'];
        DateTime? dt;
        if (d is DateTime) {
          dt = d;
        } else if (d is String) {
          dt = DateTime.tryParse(d);
        }
        if (dt != null) years.add(dt.year);
      }
      final list = years.toList()..sort();
      return list
          .map((y) => DropdownMenuItem(value: y, child: Text('$y')))
          .toList();
    }

    final currency = NumberFormat.currency(symbol: '₱', decimalDigits: 2);

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header and selectors
          Row(
            children: [
              Expanded(
                child: Text(
                  'Report — $header',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              DropdownButton<int>(
                value: _reportMonth,
                onChanged: (v) =>
                    setState(() => _reportMonth = v ?? _reportMonth),
                items: List.generate(12, (i) {
                  final m = i + 1;
                  return DropdownMenuItem(value: m, child: Text(monthLabel(m)));
                }),
              ),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _reportYear,
                onChanged: (v) =>
                    setState(() => _reportYear = v ?? _reportYear),
                items: yearItems(),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Toggles
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilterChip(
                label: const Text('Savings by Category'),
                selected: _showSavingsByCat,
                onSelected: (v) => setState(() => _showSavingsByCat = v),
              ),
              FilterChip(
                label: const Text('Savings by Subcategory'),
                selected: _showSavingsBySub,
                onSelected: (v) => setState(() => _showSavingsBySub = v),
              ),
              FilterChip(
                label: const Text('Expenses by Category'),
                selected: _showExpensesByCat,
                onSelected: (v) => setState(() => _showExpensesByCat = v),
              ),
              FilterChip(
                label: const Text('Expenses by Subcategory'),
                selected: _showExpensesBySub,
                onSelected: (v) => setState(() => _showExpensesBySub = v),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Details lists (no bars/charts)
          Expanded(
            child: ListView(
              children: [
                if (_showSavingsByCat)
                  _buildAggSection('Savings by Category', savByCat, currency),
                if (_showSavingsBySub)
                  _buildAggSection(
                    'Savings by Subcategory',
                    savBySub,
                    currency,
                  ),
                if (_showExpensesByCat)
                  _buildAggSection('Expenses by Category', expByCat, currency),
                if (_showExpensesBySub)
                  _buildAggSection(
                    'Expenses by Subcategory',
                    expBySub,
                    currency,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAggSection(
    String title,
    Map<String, double> data,
    NumberFormat currency,
  ) {
    final entries = data.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: ExpansionTile(
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          '${entries.length} ${(entries.length == 1) ? 'item' : 'items'}',
        ),
        children: entries.isEmpty
            ? [const ListTile(title: Text('No data for selection'))]
            : entries
                  .map(
                    (e) => ListTile(
                      title: Text(e.key),
                      trailing: Text(
                        currency.format(e.value),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  )
                  .toList(),
      ),
    );
  }

  Widget buildSavingsTab() {
    final rows = tableData['Savings'] ?? [];
    double savedTotal = rows.fold(
      0.0,
      (sum, row) => sum + (row['Amount'] ?? 0.0),
    );
    double goal = savingsGoals['Savings'] ?? 0.0;
    double progress = goal > 0 ? (savedTotal / goal).clamp(0.0, 1.0) : 0.0;

    // Declare progressColor only once here:
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
                    onPressed: () {
                      final ctrl = TextEditingController(text: goal.toString());
                      showDialog(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text("Set Savings Goal"),
                          content: TextField(
                            controller: ctrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              hintText: "Enter goal amount",
                            ),
                          ),
                          actions: [
                            ElevatedButton.icon(
                              onPressed: () {
                                setState(() {
                                  savingsGoals['Savings'] =
                                      double.tryParse(ctrl.text) ?? 0.0;
                                  saveData();
                                  Navigator.pop(context);
                                });
                              },
                              icon: const Icon(Icons.check),
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
                    },
                    child: const Text("Set Goal"),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Use progressColor here - no re-declaration
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
                "Saved: ${NumberFormat.currency(symbol: '₱', decimalDigits: 2).format(savedTotal)} / ${NumberFormat.currency(symbol: '₱', decimalDigits: 2).format(goal)}",
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        Expanded(child: buildTabContent('Savings')),
      ],
    );
  }

  Widget buildBillsTab() {
    final rows = tableData['Bills'] ?? [];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: ElevatedButton.icon(
            onPressed: () => addNewRow('Bills', ['Name', 'Amount', 'Due Date']),
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
                  "${row['Amount'] == null ? '' : NumberFormat.currency(symbol: '₱', decimalDigits: 2).format(row['Amount'])} - Due: ${row['Due Date'] ?? ''}",
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.edit),
                  onPressed: () =>
                      addNewRow('Bills', ['Name', 'Amount', 'Due Date']),
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
      builder: (d) => AlertDialog(
        title: const Text("New Tab Name"),
        content: TextField(controller: nameController),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).pop(),
            child: const Text("Cancel"),
          ),
          TextButton(
            onPressed: () => Navigator.of(d).pop(nameController.text.trim()),
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
      builder: (d) => AlertDialog(
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
                Navigator.of(d).pop();
              },
              child: const Text("Delete"),
            ),
          TextButton(
            onPressed: () => Navigator.of(d).pop(nameController.text.trim()),
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
                        "Limit: ${NumberFormat.currency(symbol: '₱', decimalDigits: 2).format(limit)}",
                        style: const TextStyle(color: Colors.redAccent),
                      ),
                    Text(
                      "Total: ${NumberFormat.currency(symbol: '₱', decimalDigits: 2).format(total)}",
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

        // ✅ "Add Record" button hidden for Expenses (use ExpensesTab FAB)
        if (tab != 'Expenses')
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

        // ✅ Show message if table is empty
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
                        // ➕ Add Column Button
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
                              const DataCell(
                                SizedBox(),
                              ), // <-- This empty cell for the Add Column button
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

    // Autofill both 'Date' and 'Due Date' if present
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
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: TextField(
                  controller: controllers[col],
                  keyboardType: col == 'Amount'
                      ? const TextInputType.numberWithOptions(decimal: true)
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
                    border: const OutlineInputBorder(),
                  ),
                ),
              );
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

// Deprecated: Removed top-tab UI. This file is intentionally left empty.
