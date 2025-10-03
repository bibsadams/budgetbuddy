import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../../services/shared_account_repository.dart';

// Helper to reliably retrieve the page's accountId from within nested list items
String _getAccountId(BuildContext context) {
  final state = context.findAncestorStateOfType<_CategoriesManagerPageState>();
  return state?.widget.accountId ?? '';
}

Future<void> _showErrorPopup(
  BuildContext context,
  String message, {
  String title = 'Notice',
}) async {
  // Show a blocking popup error per request instead of a bottom SnackBar
  await showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(d).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

class CategoriesManagerPage extends StatefulWidget {
  final String accountId;
  const CategoriesManagerPage({super.key, required this.accountId});

  @override
  State<CategoriesManagerPage> createState() => _CategoriesManagerPageState();
}

class _CategoriesManagerPageState extends State<CategoriesManagerPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Categories'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: 'Expenses'),
            Tab(text: 'Savings'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [_ExpensesCategoriesList(), _SavingsCategoriesList()],
      ),
    );
  }
}

class _ExpensesCategoriesList extends StatefulWidget {
  const _ExpensesCategoriesList();

  @override
  State<_ExpensesCategoriesList> createState() =>
      _ExpensesCategoriesListState();
}

class _ExpensesCategoriesListState extends State<_ExpensesCategoriesList> {
  Map<String, List<String>> _loadExpensesCategories(Box box) {
    // Load from Hive; if empty, seed once with defaults. Do NOT merge defaults on every build
    // to ensure deletions made in manager persist.
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
      'Health': ['Medicine', 'Checkup', 'Dental', 'Insurance'],
      'Food': [
        'Restaurant',
        'Food Stall',
        'Street Food',
        'Coffee Shop',
        'Palengke',
      ],
    };
    final raw = box.get('categories');
    if (raw is Map && raw.isNotEmpty) {
      return raw.map<String, List<String>>(
        (key, value) => MapEntry(
          key.toString(),
          (value as List).map((e) => e.toString()).toList(),
        ),
      );
    }
    // Seed defaults (first-time)
    final seeded = defaults.map((k, v) => MapEntry(k, List<String>.from(v)));
    box.put('categories', seeded);
    return seeded;
  }

  @override
  Widget build(BuildContext context) {
    final box = Hive.box('budgetBox');
    final categoriesMap = _loadExpensesCategories(box);
    final cats = categoriesMap.keys.toList()..sort();
    return ListView.separated(
      itemCount: cats.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final cat = cats[i];
        final subs = List<String>.from(categoriesMap[cat] ?? [])..sort();
        return ExpansionTile(
          leading: const Icon(Icons.category_outlined),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  cat,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                onPressed: () async {
                  // Check usage in cloud
                  final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                  final accountId = _getAccountId(context);
                  if (accountId.isEmpty) {
                    if (!context.mounted) return;
                    await _showErrorPopup(context, 'Missing account context.');
                    return;
                  }
                  final repo = SharedAccountRepository(
                    accountId: accountId,
                    uid: uid,
                  );
                  int usage = 0;
                  try {
                    usage = await repo.countCategoryUsage(
                      kind: 'expenses',
                      name: cat,
                    );
                  } catch (e) {
                    if (!context.mounted) return;
                    await _showErrorPopup(
                      context,
                      'Could not verify usage: $e',
                    );
                    return;
                  }
                  if (usage > 0) {
                    if (!context.mounted) return;
                    await _showErrorPopup(
                      context,
                      'Cannot delete. Category is used in records.',
                      title: 'Cannot delete',
                    );
                    return;
                  }
                  if (!context.mounted) return;
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: const Text('Delete Category'),
                      content: Text('Delete "$cat" and all its subcategories?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(d).pop(false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(d).pop(true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirm != true) return;
                  // Update Hive: remove the category
                  final box = Hive.box('budgetBox');
                  final map = Map<String, List>.from(
                    box.get('categories') as Map? ?? {},
                  );
                  map.remove(cat);
                  await box.put(
                    'categories',
                    map.map((k, v) => MapEntry(k, List<String>.from(v))),
                  );
                  if (!context.mounted) return;
                  setState(() {});
                },
              ),
              IconButton(
                tooltip: 'Rename',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final ctrl = TextEditingController(text: cat);
                  String? error;
                  final newName = await showDialog<String>(
                    context: context,
                    builder: (d) => StatefulBuilder(
                      builder: (dctx, setM) => AlertDialog(
                        title: const Text('Rename Category (Expenses)'),
                        content: TextField(
                          controller: ctrl,
                          decoration: InputDecoration(
                            hintText: 'New name',
                            errorText: error,
                          ),
                          autofocus: true,
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(d).pop(),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () {
                              final v = ctrl.text.trim();
                              if (v.isEmpty) {
                                setM(() => error = 'Name cannot be empty');
                                return;
                              }
                              Navigator.of(d).pop(v);
                            },
                            child: const Text('Save'),
                          ),
                        ],
                      ),
                    ),
                  );
                  if (newName == null || newName == cat) return;
                  // Update Hive map
                  final box = Hive.box('budgetBox');
                  final map = Map<String, List>.from(
                    box.get('categories') as Map? ?? {},
                  );
                  // Prevent accidental overwrite by merging
                  final existingSubs = List<String>.from(map[newName] ?? []);
                  final oldSubs = List<String>.from(map[cat] ?? []);
                  final merged = {
                    for (final s in [...existingSubs, ...oldSubs]) s,
                  }.toList();
                  map.remove(cat);
                  map[newName] = merged;
                  await box.put(
                    'categories',
                    map.map((k, v) => MapEntry(k, List<String>.from(v))),
                  );
                  // Update Firestore records
                  final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                  final accountId = _getAccountId(context);
                  final repo2 = SharedAccountRepository(
                    accountId: accountId,
                    uid: uid,
                  );
                  int updated = 0;
                  try {
                    updated = await repo2.renameCategory(
                      kind: 'expenses',
                      oldName: cat,
                      newName: newName,
                    );
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Cloud rename failed: $e')),
                    );
                  }
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        updated > 0
                            ? 'Renamed to "$newName" ($updated records)'
                            : 'Renamed to "$newName"',
                      ),
                    ),
                  );
                  setState(() {});
                },
              ),
            ],
          ),
          subtitle: Text('${subs.length} subcategories'),
          children: [
            if (subs.isEmpty)
              const ListTile(dense: true, title: Text('No subcategories'))
            else
              ...subs.map(
                (s) => ListTile(
                  dense: true,
                  leading: const SizedBox(width: 24),
                  title: Text(s),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Delete subcategory',
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.redAccent,
                        ),
                        onPressed: () async {
                          // Check usage
                          final uid =
                              FirebaseAuth.instance.currentUser?.uid ?? '';
                          final accountId = _getAccountId(context);
                          final repo = SharedAccountRepository(
                            accountId: accountId,
                            uid: uid,
                          );
                          int usage = 0;
                          try {
                            usage = await repo.countSubcategoryUsage(
                              kind: 'expenses',
                              category: cat,
                              name: s,
                            );
                          } catch (_) {}
                          if (usage > 0) {
                            if (!context.mounted) return;
                            await _showErrorPopup(
                              context,
                              'Cannot delete. Subcategory is used in records.',
                              title: 'Cannot delete',
                            );
                            return;
                          }
                          if (!context.mounted) return;
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: const Text('Delete Subcategory'),
                              content: Text('Delete "$s" under "$cat"?'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(d).pop(false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.of(d).pop(true),
                                  child: const Text('Delete'),
                                ),
                              ],
                            ),
                          );
                          if (confirm != true) return;
                          final box = Hive.box('budgetBox');
                          final map = Map<String, List>.from(
                            box.get('categories') as Map? ?? {},
                          );
                          final list = List<String>.from(map[cat] ?? []);
                          list.remove(s);
                          map[cat] = list;
                          await box.put(
                            'categories',
                            map.map(
                              (k, v) => MapEntry(k, List<String>.from(v)),
                            ),
                          );
                          if (!context.mounted) return;
                          setState(() {});
                        },
                      ),
                      IconButton(
                        tooltip: 'Rename subcategory',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () async {
                          final ctrl = TextEditingController(text: s);
                          String? error;
                          final newName = await showDialog<String>(
                            context: context,
                            builder: (d) => StatefulBuilder(
                              builder: (dctx, setM) => AlertDialog(
                                title: Text(
                                  'Rename Subcategory (Expenses)\n$cat',
                                ),
                                content: TextField(
                                  controller: ctrl,
                                  decoration: InputDecoration(
                                    hintText: 'New name',
                                    errorText: error,
                                  ),
                                  autofocus: true,
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.of(d).pop(),
                                    child: const Text('Cancel'),
                                  ),
                                  TextButton(
                                    onPressed: () {
                                      final v = ctrl.text.trim();
                                      if (v.isEmpty) {
                                        setM(
                                          () => error = 'Name cannot be empty',
                                        );
                                        return;
                                      }
                                      Navigator.of(d).pop(v);
                                    },
                                    child: const Text('Save'),
                                  ),
                                ],
                              ),
                            ),
                          );
                          if (newName == null || newName == s) return;
                          // Update Hive map
                          final box = Hive.box('budgetBox');
                          final map = Map<String, List>.from(
                            box.get('categories') as Map? ?? {},
                          );
                          final list = List<String>.from(map[cat] ?? []);
                          final idx = list.indexOf(s);
                          if (idx >= 0) {
                            if (list.contains(newName)) {
                              list.removeAt(idx);
                            } else {
                              list[idx] = newName;
                            }
                            map[cat] = list;
                            await box.put(
                              'categories',
                              map.map(
                                (k, v) => MapEntry(k, List<String>.from(v)),
                              ),
                            );
                          }
                          // Update Firestore records
                          final uid =
                              FirebaseAuth.instance.currentUser?.uid ?? '';
                          final parentId = _getAccountId(context);
                          final repo = SharedAccountRepository(
                            accountId: parentId,
                            uid: uid,
                          );
                          int updated = 0;
                          try {
                            updated = await repo.renameSubcategory(
                              kind: 'expenses',
                              category: cat,
                              oldName: s,
                              newName: newName,
                            );
                          } catch (e) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Cloud rename failed: $e'),
                              ),
                            );
                          }
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                updated > 0
                                    ? 'Renamed to "$newName" ($updated records)'
                                    : 'Renamed to "$newName"',
                              ),
                            ),
                          );
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}

class _SavingsCategoriesList extends StatefulWidget {
  const _SavingsCategoriesList();

  @override
  State<_SavingsCategoriesList> createState() => _SavingsCategoriesListState();
}

class _SavingsCategoriesListState extends State<_SavingsCategoriesList> {
  Map<String, List<String>> _loadSavingsCategories(Box box) {
    // Load from Hive; seed defaults only if empty. Avoid merging defaults on every load
    final Map<String, List<String>> defaults = {
      'Education': ['Tuition', 'Books', 'Supplies'],
      'Kids': ['Allowance', 'School', 'Toys'],
      'Travel': ['Flights', 'Hotel', 'Activities'],
      'Emergency Fund': ['Contribution'],
      'Home': ['Down Payment', 'Renovation'],
      'Car': ['Down Payment', 'Upgrade'],
      'Personal': ['Gadgets', 'Hobby'],
      'Compensation': ['Salary', 'Bonus', 'Incentive', 'Reimbursement'],
    };
    final raw = box.get('savingsCategories');
    if (raw is Map && raw.isNotEmpty) {
      return raw.map<String, List<String>>(
        (key, value) => MapEntry(
          key.toString(),
          (value as List).map((e) => e.toString()).toList(),
        ),
      );
    }
    // Seed defaults first-time
    final seeded = defaults.map((k, v) => MapEntry(k, List<String>.from(v)));
    box.put('savingsCategories', seeded);
    return seeded;
  }

  @override
  Widget build(BuildContext context) {
    final box = Hive.box('budgetBox');
    final categoriesMap = _loadSavingsCategories(box);
    final cats = categoriesMap.keys.toList()..sort();
    return ListView.separated(
      itemCount: cats.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final cat = cats[i];
        final subs = List<String>.from(categoriesMap[cat] ?? [])..sort();
        return ExpansionTile(
          leading: const Icon(Icons.category_outlined),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  cat,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                onPressed: () async {
                  final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                  final accountId = _getAccountId(context);
                  if (accountId.isEmpty) {
                    if (!context.mounted) return;
                    await _showErrorPopup(context, 'Missing account context.');
                    return;
                  }
                  final repo = SharedAccountRepository(
                    accountId: accountId,
                    uid: uid,
                  );
                  int usage = 0;
                  try {
                    usage = await repo.countCategoryUsage(
                      kind: 'savings',
                      name: cat,
                    );
                  } catch (e) {
                    if (!context.mounted) return;
                    await _showErrorPopup(
                      context,
                      'Could not verify usage: $e',
                    );
                    return;
                  }
                  if (usage > 0) {
                    if (!context.mounted) return;
                    await _showErrorPopup(
                      context,
                      'Cannot delete. Category is used in records.',
                      title: 'Cannot delete',
                    );
                    return;
                  }
                  if (!context.mounted) return;
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: const Text('Delete Category'),
                      content: Text('Delete "$cat" and all its subcategories?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(d).pop(false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(d).pop(true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirm != true) return;
                  final box = Hive.box('budgetBox');
                  final map = Map<String, List>.from(
                    box.get('savingsCategories') as Map? ?? {},
                  );
                  map.remove(cat);
                  await box.put(
                    'savingsCategories',
                    map.map((k, v) => MapEntry(k, List<String>.from(v))),
                  );
                  if (!context.mounted) return;
                  setState(() {});
                },
              ),
              IconButton(
                tooltip: 'Rename',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final ctrl = TextEditingController(text: cat);
                  String? error;
                  final newName = await showDialog<String>(
                    context: context,
                    builder: (d) => StatefulBuilder(
                      builder: (dctx, setM) => AlertDialog(
                        title: const Text('Rename Category (Savings)'),
                        content: TextField(
                          controller: ctrl,
                          decoration: InputDecoration(
                            hintText: 'New name',
                            errorText: error,
                          ),
                          autofocus: true,
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(d).pop(),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () {
                              final v = ctrl.text.trim();
                              if (v.isEmpty) {
                                setM(() => error = 'Name cannot be empty');
                                return;
                              }
                              Navigator.of(d).pop(v);
                            },
                            child: const Text('Save'),
                          ),
                        ],
                      ),
                    ),
                  );
                  if (newName == null || newName == cat) return;
                  // Update Hive map
                  final box = Hive.box('budgetBox');
                  final map = Map<String, List>.from(
                    box.get('savingsCategories') as Map? ?? {},
                  );
                  final existingSubs = List<String>.from(map[newName] ?? []);
                  final oldSubs = List<String>.from(map[cat] ?? []);
                  final merged = {
                    for (final s in [...existingSubs, ...oldSubs]) s,
                  }.toList();
                  map.remove(cat);
                  map[newName] = merged;
                  await box.put(
                    'savingsCategories',
                    map.map((k, v) => MapEntry(k, List<String>.from(v))),
                  );
                  // Update Firestore records
                  final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
                  final accountId = _getAccountId(context);
                  final repo = SharedAccountRepository(
                    accountId: accountId,
                    uid: uid,
                  );
                  int updated = 0;
                  try {
                    updated = await repo.renameCategory(
                      kind: 'savings',
                      oldName: cat,
                      newName: newName,
                    );
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Cloud rename failed: $e')),
                    );
                  }
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        updated > 0
                            ? 'Renamed to "$newName" ($updated records)'
                            : 'Renamed to "$newName"',
                      ),
                    ),
                  );
                  setState(() {});
                },
              ),
            ],
          ),
          subtitle: Text('${subs.length} subcategories'),
          children: [
            if (subs.isEmpty)
              const ListTile(dense: true, title: Text('No subcategories'))
            else
              ...subs.map(
                (s) => ListTile(
                  dense: true,
                  leading: const SizedBox(width: 24),
                  title: Text(s),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Delete subcategory',
                        icon: const Icon(
                          Icons.delete_outline,
                          color: Colors.redAccent,
                        ),
                        onPressed: () async {
                          final uid =
                              FirebaseAuth.instance.currentUser?.uid ?? '';
                          final accountId = _getAccountId(context);
                          final repo = SharedAccountRepository(
                            accountId: accountId,
                            uid: uid,
                          );
                          int usage = 0;
                          try {
                            usage = await repo.countSubcategoryUsage(
                              kind: 'savings',
                              category: cat,
                              name: s,
                            );
                          } catch (e) {
                            if (!context.mounted) return;
                            await _showErrorPopup(
                              context,
                              'Could not verify usage: $e',
                            );
                            return;
                          }
                          if (usage > 0) {
                            if (!context.mounted) return;
                            await _showErrorPopup(
                              context,
                              'Cannot delete. Subcategory is used in records.',
                              title: 'Cannot delete',
                            );
                            return;
                          }
                          if (!context.mounted) return;
                          final confirm = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: const Text('Delete Subcategory'),
                              content: Text('Delete "$s" under "$cat"?'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.of(d).pop(false),
                                  child: const Text('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.of(d).pop(true),
                                  child: const Text('Delete'),
                                ),
                              ],
                            ),
                          );
                          if (confirm != true) return;
                          final box = Hive.box('budgetBox');
                          final map = Map<String, List>.from(
                            box.get('savingsCategories') as Map? ?? {},
                          );
                          final list = List<String>.from(map[cat] ?? []);
                          list.remove(s);
                          map[cat] = list;
                          await box.put(
                            'savingsCategories',
                            map.map(
                              (k, v) => MapEntry(k, List<String>.from(v)),
                            ),
                          );
                          if (!context.mounted) return;
                          setState(() {});
                        },
                      ),
                      IconButton(
                        tooltip: 'Rename subcategory',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () async {
                          final ctrl = TextEditingController(text: s);
                          String? error;
                          final newName = await showDialog<String>(
                            context: context,
                            builder: (d) => StatefulBuilder(
                              builder: (dctx, setM) => AlertDialog(
                                title: Text(
                                  'Rename Subcategory (Savings)\n$cat',
                                ),
                                content: TextField(
                                  controller: ctrl,
                                  decoration: InputDecoration(
                                    hintText: 'New name',
                                    errorText: error,
                                  ),
                                  autofocus: true,
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.of(d).pop(),
                                    child: const Text('Cancel'),
                                  ),
                                  TextButton(
                                    onPressed: () {
                                      final v = ctrl.text.trim();
                                      if (v.isEmpty) {
                                        setM(
                                          () => error = 'Name cannot be empty',
                                        );
                                        return;
                                      }
                                      Navigator.of(d).pop(v);
                                    },
                                    child: const Text('Save'),
                                  ),
                                ],
                              ),
                            ),
                          );
                          if (newName == null || newName == s) return;
                          // Update Hive map
                          final box = Hive.box('budgetBox');
                          final map = Map<String, List>.from(
                            box.get('savingsCategories') as Map? ?? {},
                          );
                          final list = List<String>.from(map[cat] ?? []);
                          final idx = list.indexOf(s);
                          if (idx >= 0) {
                            if (list.contains(newName)) {
                              list.removeAt(idx);
                            } else {
                              list[idx] = newName;
                            }
                            map[cat] = list;
                            await box.put(
                              'savingsCategories',
                              map.map(
                                (k, v) => MapEntry(k, List<String>.from(v)),
                              ),
                            );
                          }
                          // Update Firestore records
                          final uid =
                              FirebaseAuth.instance.currentUser?.uid ?? '';
                          final accountId = _getAccountId(context);
                          final repo = SharedAccountRepository(
                            accountId: accountId,
                            uid: uid,
                          );
                          int updated = 0;
                          try {
                            updated = await repo.renameSubcategory(
                              kind: 'savings',
                              category: cat,
                              oldName: s,
                              newName: newName,
                            );
                          } catch (e) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Cloud rename failed: $e'),
                              ),
                            );
                          }
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                updated > 0
                                    ? 'Renamed to "$newName" ($updated records)'
                                    : 'Renamed to "$newName"',
                              ),
                            ),
                          );
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}
