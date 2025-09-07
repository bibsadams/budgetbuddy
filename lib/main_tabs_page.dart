import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'features/home/home_tab.dart';
import 'features/expenses/expenses_tab.dart';
import 'features/savings/savings_tab.dart';
import 'features/bills/bills_tab.dart';
import 'features/report/report_tab.dart';

class MainTabsPage extends StatefulWidget {
  const MainTabsPage({super.key});

  @override
  State<MainTabsPage> createState() => _MainTabsPageState();
}

class _MainTabsPageState extends State<MainTabsPage> {
  final Box box = Hive.box('budgetBox');
  int _index = 0;

  Map<String, List<Map<String, dynamic>>> tableData = {};
  Map<String, double> tabLimits = {}; // For Expenses
  Map<String, double> savingsGoals = {}; // For Savings
  final Map<String, Color> _reportCategoryColors = {}; // For Report coloring

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  void _loadData() {
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
    for (final tab in ['Expenses', 'Savings', 'Bills', 'Report']) {
      tableData.putIfAbsent(tab, () => []);
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

    setState(() {});
  }

  void _saveData() {
    box.put('tableData', tableData);
    box.put('tabLimits', tabLimits);
    box.put('savingsGoals', savingsGoals);
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      const HomeTab(),
      _buildExpensesPage(),
      _buildSavingsPage(),
      _buildBillsPage(),
      _buildReportPage(),
      const _SettingsPlaceholder(),
    ];

    final destinations = const <NavigationDestination>[
      NavigationDestination(
        icon: Icon(Icons.home_outlined),
        selectedIcon: Icon(Icons.home),
        label: 'Home',
      ),
      NavigationDestination(
        icon: Icon(Icons.payments_outlined),
        selectedIcon: Icon(Icons.payments),
        label: 'Expenses',
      ),
      NavigationDestination(
        icon: Icon(Icons.savings_outlined),
        selectedIcon: Icon(Icons.savings),
        label: 'Savings',
      ),
      NavigationDestination(
        icon: Icon(Icons.receipt_long_outlined),
        selectedIcon: Icon(Icons.receipt_long),
        label: 'Bills',
      ),
      NavigationDestination(
        icon: Icon(Icons.pie_chart_outline),
        selectedIcon: Icon(Icons.pie_chart),
        label: 'Report',
      ),
      NavigationDestination(
        icon: Icon(Icons.settings_outlined),
        selectedIcon: Icon(Icons.settings),
        label: 'Settings',
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('BudgetBuddy')),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: destinations,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
    );
  }

  // Expenses
  Widget _buildExpensesPage() {
    final rows = tableData['Expenses'] ?? [];
    final limit = tabLimits['Expenses'];
    return ExpensesTab(
      rows: rows,
      limit: limit,
      onRowsChanged: (newRows) {
        setState(() {
          tableData['Expenses'] = newRows;
          _saveData();
        });
      },
      onSetLimit: () {
        final ctrl = TextEditingController(
          text: (tabLimits['Expenses'] ?? 0.0).toString(),
        );
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Set Monthly Limit'),
            content: TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(hintText: 'Enter limit amount'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    tabLimits['Expenses'] = double.tryParse(ctrl.text) ?? 0.0;
                    _saveData();
                    Navigator.pop(context);
                  });
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
  }

  // Savings
  Widget _buildSavingsPage() {
    final rows = tableData['Savings'] ?? [];
    final goal = savingsGoals['Savings'];
    return SavingsTab(
      rows: rows,
      goal: goal,
      onRowsChanged: (newRows) {
        setState(() {
          tableData['Savings'] = newRows;
          _saveData();
        });
      },
      onSetGoal: () {
        final ctrl = TextEditingController(
          text: (savingsGoals['Savings'] ?? 0.0).toString(),
        );
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Set Savings Goal'),
            content: TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(hintText: 'Enter goal amount'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  setState(() {
                    savingsGoals['Savings'] = double.tryParse(ctrl.text) ?? 0.0;
                    _saveData();
                    Navigator.pop(context);
                  });
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
  }

  // Bills
  Widget _buildBillsPage() {
    final rows = tableData['Bills'] ?? [];
    return BillsTab(
      rows: rows,
      onRowsChanged: (newRows) {
        setState(() {
          tableData['Bills'] = newRows;
          _saveData();
        });
      },
    );
  }

  // Report
  Widget _buildReportPage() {
    return ReportTab(
      tableData: tableData,
      categoryColors: _reportCategoryColors,
    );
  }
}

class _SettingsPlaceholder extends StatelessWidget {
  const _SettingsPlaceholder();
  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('Settings (coming soon)'));
}
