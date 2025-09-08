import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'services/shared_account_repository.dart';
import 'services/local_receipt_service.dart';
import 'features/home/home_tab.dart';
import 'features/expenses/expenses_tab.dart';
import 'features/savings/savings_tab.dart';
import 'features/bills/bills_tab.dart';
import 'features/report/report_tab.dart';

class MainTabsPage extends StatefulWidget {
  final String accountId;
  final String? initialWarning;
  const MainTabsPage({super.key, required this.accountId, this.initialWarning});

  @override
  State<MainTabsPage> createState() => _MainTabsPageState();
}

class _MainTabsPageState extends State<MainTabsPage> {
  // Data/state
  late final Box box;
  SharedAccountRepository? _repo;

  // Streams
  Stream<List<Map<String, dynamic>>>? _expenses$;
  Stream<List<Map<String, dynamic>>>? _savings$;
  Stream<Map<String, dynamic>>? _meta$;
  Stream<Map<String, dynamic>?>? _account$;

  // In-memory tables and settings
  Map<String, List<Map<String, dynamic>>> tableData = {};
  Map<String, double> tabLimits = {}; // For Expenses
  Map<String, double> savingsGoals = {}; // For Savings
  final Map<String, Color> _reportCategoryColors = {};

  // Local-only receipt maps
  final Map<String, String> _localReceiptPathsExpenses = {};
  final Map<String, String> _localReceiptPathsSavings = {};

  // UI
  int _index = 0;
  Map<String, dynamic>? _accountDoc;

  @override
  void initState() {
    super.initState();
    box = Hive.box('budgetBox');
    _initShared();
  }

  // Stable hash for matching the same record across provisional (local_) and remote ids
  String _clientHash(Map<String, dynamic> r) {
    String normDate(dynamic dv) {
      DateTime? dt;
      if (dv is DateTime) {
        dt = dv;
      } else if (dv is String) {
        dt = DateTime.tryParse(dv);
      }
      if (dt == null) return '';
      return '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    }

    final cat = (r['Category'] ?? '').toString().trim().toLowerCase();
    final sub = (r['Subcategory'] ?? '').toString().trim().toLowerCase();
    final amt = (r['Amount'] is num)
        ? (r['Amount'] as num).toDouble().toStringAsFixed(2)
        : '0.00';
    final dateStr = normDate(r['Date']);
    final note = (r['Note'] ?? '').toString().trim().toLowerCase();
    return [cat, sub, amt, dateStr, note].join('|');
  }

  // Local-only persistence for attachments and row IDs when backend is unavailable
  Future<void> _persistReceiptsLocalOnly({
    required String collection, // 'expenses' | 'savings'
    required List<Map<String, dynamic>> current,
    required List<Map<String, dynamic>> desired,
  }) async {
    String genId() => 'local_${DateTime.now().millisecondsSinceEpoch}';

    // Build maps by id for deletions
    final currentById = {
      for (final r in current)
        if (r['id'] != null && (r['id'] as String).isNotEmpty)
          r['id'] as String: r,
    };
    final desiredById = {
      for (final r in desired)
        if (r['id'] != null && (r['id'] as String).isNotEmpty)
          r['id'] as String: r,
    };

    // Handle local deletions: remove files and mappings
    for (final id in currentById.keys) {
      if (!desiredById.containsKey(id)) {
        if (collection == 'expenses') {
          _localReceiptPathsExpenses.remove(id);
        } else {
          _localReceiptPathsSavings.remove(id);
        }
        // Best-effort remove file
        await LocalReceiptService().deleteReceipt(
          accountId: widget.accountId,
          collection: collection,
          docId: id,
        );
      }
    }

    // Save/assign IDs and persist attachments for desired rows

    for (int i = 0; i < desired.length; i++) {
      final item = Map<String, dynamic>.from(desired[i]);
      String id = (item['id'] as String?) ?? '';
      final hasBytes = item['Receipt'] != null && item['Receipt'] is Uint8List;

      if (id.isEmpty) {
        // Assign a fallback id for purely local usage
        id = genId();
        item['id'] = id;
        desired[i] = item;
      }

      if (hasBytes) {
        final path = await LocalReceiptService().saveReceipt(
          accountId: widget.accountId,
          collection: collection,
          docId: id,
          bytes: item['Receipt'] as Uint8List,
        );
        if (collection == 'expenses') {
          _localReceiptPathsExpenses[id] = path;
        } else {
          _localReceiptPathsSavings[id] = path;
        }
        // Inject LocalReceiptPath into the desired row as well
        item['LocalReceiptPath'] = path;
        desired[i] = item;
      }
    }

    setState(() {
      if (collection == 'expenses') {
        tableData['Expenses'] = desired;
      } else {
        tableData['Savings'] = desired;
      }
    });
    _saveLocalOnly();
  }

  void _loadLocalOnly() {
    // Load base table data except expenses/savings (handled separately)
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

    // Offline rows for Expenses/Savings (device-only persistence)
    final offlineExp = box.get('offline_expenses_${widget.accountId}') as List?;
    if (offlineExp != null) {
      tableData['Expenses'] = offlineExp
          .whereType<Map>()
          .map<Map<String, dynamic>>(
            (m) => m.map((k, v) => MapEntry(k.toString(), v)),
          )
          .toList();
    } else {
      tableData['Expenses'] = [];
    }
    final offlineSav = box.get('offline_savings_${widget.accountId}') as List?;
    if (offlineSav != null) {
      tableData['Savings'] = offlineSav
          .whereType<Map>()
          .map<Map<String, dynamic>>(
            (m) => m.map((k, v) => MapEntry(k.toString(), v)),
          )
          .toList();
    } else {
      tableData['Savings'] = [];
    }

    // Bills stays local
    tableData.putIfAbsent('Bills', () => []);

    // Limits/goals
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

    // Local receipts maps
    final lrExp = box.get('localReceipts_expenses_${widget.accountId}') as Map?;
    _localReceiptPathsExpenses.clear();
    if (lrExp != null) {
      lrExp.forEach(
        (k, v) => _localReceiptPathsExpenses[k.toString()] = v.toString(),
      );
    }
    final lrSav = box.get('localReceipts_savings_${widget.accountId}') as Map?;
    _localReceiptPathsSavings.clear();
    if (lrSav != null) {
      lrSav.forEach(
        (k, v) => _localReceiptPathsSavings[k.toString()] = v.toString(),
      );
    }

    // Overlay LocalReceiptPath into offline rows
    final expList = List<Map<String, dynamic>>.from(
      tableData['Expenses'] ?? [],
    );
    for (int i = 0; i < expList.length; i++) {
      final id = (expList[i]['id'] ?? '').toString();
      final p = _localReceiptPathsExpenses[id];
      if (p != null && p.isNotEmpty)
        expList[i] = {...expList[i], 'LocalReceiptPath': p};
    }
    tableData['Expenses'] = expList;

    final savList = List<Map<String, dynamic>>.from(tableData['Savings'] ?? []);
    for (int i = 0; i < savList.length; i++) {
      final id = (savList[i]['id'] ?? '').toString();
      final p = _localReceiptPathsSavings[id];
      if (p != null && p.isNotEmpty)
        savList[i] = {...savList[i], 'LocalReceiptPath': p};
    }
    tableData['Savings'] = savList;

    setState(() {});
  }

  void _saveLocalOnly() {
    // Only persist local-only sections
    final tb = Map<String, List<Map<String, dynamic>>>.from(tableData);
    tb.remove('Expenses');
    tb.remove('Savings');
    tb.remove('Report');
    box.put('tableData', tb);

    // Persist offline expenses/savings
    box.put(
      'offline_expenses_${widget.accountId}',
      tableData['Expenses'] ?? <Map<String, dynamic>>[],
    );
    box.put(
      'offline_savings_${widget.accountId}',
      tableData['Savings'] ?? <Map<String, dynamic>>[],
    );
    box.put('tabLimits', tabLimits);
    box.put('savingsGoals', savingsGoals);
    box.put(
      'localReceipts_expenses_${widget.accountId}',
      _localReceiptPathsExpenses,
    );
    box.put(
      'localReceipts_savings_${widget.accountId}',
      _localReceiptPathsSavings,
    );
  }

  void _initShared() {
    _loadLocalOnly();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return; // guarded by login flow
    _repo = SharedAccountRepository(accountId: widget.accountId, uid: user.uid);
    _expenses$ = _repo!.expensesStream();
    _savings$ = _repo!.savingsStream();
    _meta$ = _repo!.metaStream();
    _account$ = _repo!.accountStream();
    _account$!.listen((doc) => setState(() => _accountDoc = doc ?? {}));

    // Listen and integrate into tableData in-memory
    _expenses$!.listen((remoteRows) {
      if (remoteRows.isEmpty)
        return; // keep offline data if backend emits nothing
      final local = List<Map<String, dynamic>>.from(
        tableData['Expenses'] ?? [],
      );
      final remoteById = {
        for (final r in remoteRows.where((e) => e['id'] != null))
          (r['id'] as String).toString(): r,
      };
      final merged = <Map<String, dynamic>>[];
      // Build a lookup for local provisional rows to match by clientHash
      final localProvisionalByHash = <String, Map<String, dynamic>>{};
      final consumedLocalIds = <String>{};
      for (final l in local) {
        final lid = (l['id'] ?? '').toString();
        if (lid.isEmpty || lid.startsWith('local_')) {
          final ch = (l['clientHash'] as String?) ?? _clientHash(l);
          localProvisionalByHash[ch] = l;
        }
      }
      // Start with remote, overlay/migrate any local receipt paths
      for (final r in remoteRows) {
        final id = (r['id'] ?? '').toString();
        Map<String, dynamic> out = r;
        // If we already have a path for this remote id, overlay
        final existingPath = _localReceiptPathsExpenses[id];
        if (existingPath != null && existingPath.isNotEmpty) {
          out = {...r, 'LocalReceiptPath': existingPath};
        } else {
          // Otherwise, try to match a provisional local row and migrate its path mapping
          final remoteHash = (r['clientHash'] as String?) ?? _clientHash(r);
          final match = localProvisionalByHash[remoteHash];
          if (match != null) {
            final localId = (match['id'] ?? '').toString();
            final localPath = _localReceiptPathsExpenses[localId];
            if (localPath != null && localPath.isNotEmpty) {
              // Migrate mapping key from provisional -> remote id
              _localReceiptPathsExpenses.remove(localId);
              _localReceiptPathsExpenses[id] = localPath;
              out = {
                ...r,
                'LocalReceiptPath': localPath,
                'clientHash': remoteHash,
              };
              consumedLocalIds.add(localId);
            } else {
              consumedLocalIds.add(localId);
            }
          }
        }
        merged.add(out);
      }
      // Keep any remaining local-only rows that weren't matched/consumed
      for (final l in local) {
        final id = (l['id'] ?? '').toString();
        final isLocalOnly =
            id.isEmpty ||
            id.startsWith('local_') ||
            !remoteById.containsKey(id);
        if (isLocalOnly && !consumedLocalIds.contains(id)) {
          final lp = _localReceiptPathsExpenses[id];
          merged.add(
            lp != null && lp.isNotEmpty ? {...l, 'LocalReceiptPath': lp} : l,
          );
        }
      }
      // Final de-duplication: prefer items with LocalReceiptPath
      Map<String, Map<String, dynamic>> uniq = {};
      for (final r in merged) {
        final id = (r['id'] ?? '').toString();
        final ch = (r['clientHash'] as String?) ?? _clientHash(r);
        final key = id.isNotEmpty ? 'id:$id' : 'ch:$ch';
        if (!uniq.containsKey(key)) {
          uniq[key] = r;
        } else {
          final existing = uniq[key]!;
          final hasPathExisting =
              ((existing['LocalReceiptPath'] as String?) ?? '').isNotEmpty;
          final hasPathNew =
              ((r['LocalReceiptPath'] as String?) ?? '').isNotEmpty;
          if (hasPathNew && !hasPathExisting) {
            uniq[key] = r;
          } else if (id.isNotEmpty && (existing['id'] ?? '') != id) {
            // Prefer the one with the non-local id
            final isLocalExisting = ((existing['id'] ?? '').toString())
                .startsWith('local_');
            final isLocalNew = id.startsWith('local_');
            if (!isLocalNew && isLocalExisting) {
              uniq[key] = r;
            }
          }
        }
      }
      setState(() {
        tableData['Expenses'] = uniq.values.toList();
      });
      _saveLocalOnly();
    });
    _savings$!.listen((remoteRows) {
      if (remoteRows.isEmpty)
        return; // keep offline data if backend emits nothing
      final local = List<Map<String, dynamic>>.from(tableData['Savings'] ?? []);
      final remoteById = {
        for (final r in remoteRows.where((e) => e['id'] != null))
          (r['id'] as String).toString(): r,
      };
      final merged = <Map<String, dynamic>>[];
      final localProvisionalByHash = <String, Map<String, dynamic>>{};
      final consumedLocalIds = <String>{};
      for (final l in local) {
        final lid = (l['id'] ?? '').toString();
        if (lid.isEmpty || lid.startsWith('local_')) {
          final ch = (l['clientHash'] as String?) ?? _clientHash(l);
          localProvisionalByHash[ch] = l;
        }
      }
      for (final r in remoteRows) {
        final id = (r['id'] ?? '').toString();
        Map<String, dynamic> out = r;
        final existingPath = _localReceiptPathsSavings[id];
        if (existingPath != null && existingPath.isNotEmpty) {
          out = {...r, 'LocalReceiptPath': existingPath};
        } else {
          final remoteHash = (r['clientHash'] as String?) ?? _clientHash(r);
          final match = localProvisionalByHash[remoteHash];
          if (match != null) {
            final localId = (match['id'] ?? '').toString();
            final localPath = _localReceiptPathsSavings[localId];
            if (localPath != null && localPath.isNotEmpty) {
              _localReceiptPathsSavings.remove(localId);
              _localReceiptPathsSavings[id] = localPath;
              out = {
                ...r,
                'LocalReceiptPath': localPath,
                'clientHash': remoteHash,
              };
              consumedLocalIds.add(localId);
            } else {
              consumedLocalIds.add(localId);
            }
          }
        }
        merged.add(out);
      }
      for (final l in local) {
        final id = (l['id'] ?? '').toString();
        final isLocalOnly =
            id.isEmpty ||
            id.startsWith('local_') ||
            !remoteById.containsKey(id);
        if (isLocalOnly && !consumedLocalIds.contains(id)) {
          final lp = _localReceiptPathsSavings[id];
          merged.add(
            lp != null && lp.isNotEmpty ? {...l, 'LocalReceiptPath': lp} : l,
          );
        }
      }
      // Final de-duplication: prefer items with LocalReceiptPath
      Map<String, Map<String, dynamic>> uniq = {};
      for (final r in merged) {
        final id = (r['id'] ?? '').toString();
        final ch = (r['clientHash'] as String?) ?? _clientHash(r);
        final key = id.isNotEmpty ? 'id:$id' : 'ch:$ch';
        if (!uniq.containsKey(key)) {
          uniq[key] = r;
        } else {
          final existing = uniq[key]!;
          final hasPathExisting =
              ((existing['LocalReceiptPath'] as String?) ?? '').isNotEmpty;
          final hasPathNew =
              ((r['LocalReceiptPath'] as String?) ?? '').isNotEmpty;
          if (hasPathNew && !hasPathExisting) {
            uniq[key] = r;
          } else if (id.isNotEmpty && (existing['id'] ?? '') != id) {
            final isLocalExisting = ((existing['id'] ?? '').toString())
                .startsWith('local_');
            final isLocalNew = id.startsWith('local_');
            if (!isLocalNew && isLocalExisting) {
              uniq[key] = r;
            }
          }
        }
      }
      setState(() {
        tableData['Savings'] = uniq.values.toList();
      });
      _saveLocalOnly();
    });
    _meta$!.listen((meta) {
      setState(() {
        final limits = (meta['limits'] as Map?) ?? {};
        final goals = (meta['goals'] as Map?) ?? {};
        tabLimits['Expenses'] =
            (limits['Expenses'] as num?)?.toDouble() ??
            (tabLimits['Expenses'] ?? 0.0);
        savingsGoals['Savings'] =
            (goals['Savings'] as num?)?.toDouble() ??
            (savingsGoals['Savings'] ?? 0.0);
      });
    });
  }

  // Immediately persist attachment for a newly added row at a known index.
  Future<Map<String, String>?> _saveNewRowAttachmentImmediately({
    required String collection, // 'expenses' | 'savings'
    required int index,
  }) async {
    final list = List<Map<String, dynamic>>.from(
      tableData[collection == 'expenses' ? 'Expenses' : 'Savings'] ?? [],
    );
    if (index < 0 || index >= list.length) return null;
    final item = Map<String, dynamic>.from(list[index]);
    final hasBytes = item['Receipt'] != null && item['Receipt'] is Uint8List;
    if (!hasBytes) return null;

    // Assign a local id if absent
    String id = (item['id'] as String?) ?? '';
    if (id.isEmpty) {
      id = 'local_${DateTime.now().millisecondsSinceEpoch}';
    }

    try {
      final path = await LocalReceiptService().saveReceipt(
        accountId: widget.accountId,
        collection: collection,
        docId: id,
        bytes: item['Receipt'] as Uint8List,
      );

      // Update maps and row in-place for immediate UI
      if (collection == 'expenses') {
        _localReceiptPathsExpenses[id] = path;
      } else {
        _localReceiptPathsSavings[id] = path;
      }
      final ch = (item['clientHash'] as String?) ?? _clientHash(item);
      list[index] = {
        ...item,
        'id': id,
        'LocalReceiptPath': path,
        'clientHash': ch,
      };
      setState(() {
        if (collection == 'expenses') {
          tableData['Expenses'] = list;
        } else {
          tableData['Savings'] = list;
        }
      });
      _saveLocalOnly();
      return {'id': id, 'path': path};
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save image locally: $e')),
        );
      }
      return null;
    }
  }

  // Fallback: ensure every row with in-memory bytes has a local file + id
  Future<void> _ensureLocalReceiptsForAll({
    required String collection, // 'expenses' | 'savings'
    required List<Map<String, dynamic>> rows,
  }) async {
    final list = List<Map<String, dynamic>>.from(rows);
    bool changed = false;
    for (int i = 0; i < list.length; i++) {
      final item = Map<String, dynamic>.from(list[i]);
      final hasBytes = item['Receipt'] != null && item['Receipt'] is Uint8List;
      final hasLocalPath =
          (item['LocalReceiptPath'] as String?)?.trim().isNotEmpty == true;
      if (!hasBytes || hasLocalPath) {
        if ((item['clientHash'] as String?) == null) {
          item['clientHash'] = _clientHash(item);
          list[i] = item;
          changed = true;
        }
        continue;
      }
      String id = (item['id'] as String?) ?? '';
      if (id.isEmpty) {
        id = 'local_${DateTime.now().millisecondsSinceEpoch}';
        item['id'] = id;
      }
      try {
        final path = await LocalReceiptService().saveReceipt(
          accountId: widget.accountId,
          collection: collection,
          docId: id,
          bytes: item['Receipt'] as Uint8List,
        );
        item['LocalReceiptPath'] = path;
        item['clientHash'] =
            (item['clientHash'] as String?) ?? _clientHash(item);
        if (collection == 'expenses') {
          _localReceiptPathsExpenses[id] = path;
        } else {
          _localReceiptPathsSavings[id] = path;
        }
        list[i] = item;
        changed = true;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to save image locally: $e')),
          );
        }
      }
    }
    if (changed) {
      setState(() {
        if (collection == 'expenses') {
          tableData['Expenses'] = list;
        } else {
          tableData['Savings'] = list;
        }
      });
      _saveLocalOnly();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      Column(
        children: [
          if ((widget.initialWarning ?? '').isNotEmpty)
            Material(
              color: Colors.amber.shade100,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.initialWarning!,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: HomeTab(
              tableData: tableData,
              tabLimits: tabLimits,
              savingsGoals: savingsGoals,
            ),
          ),
        ],
      ),
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

    final isJoint = (_accountDoc?['isJoint'] as bool?) ?? false;
    final createdBy = (_accountDoc?['createdBy'] as String?) ?? '';
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final isOwner = createdBy.isNotEmpty && createdBy == uid;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('BudgetBuddy'),
            const SizedBox(width: 8),
            if (_accountDoc != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isJoint
                      ? Colors.green.withOpacity(0.12)
                      : Colors.blueGrey.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  children: [
                    Icon(
                      isJoint ? Icons.groups_2 : Icons.person_outline,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isJoint ? 'Joint' : 'Single-owner',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
          ],
        ),
        actions: [
          if (isOwner && _accountDoc != null)
            Row(
              children: [
                const Text('Joint'),
                Switch(
                  value: isJoint,
                  onChanged: (v) async {
                    try {
                      await _repo!.setIsJoint(v);
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            v
                                ? 'Joint access enabled'
                                : 'Joint access disabled',
                          ),
                        ),
                      );
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Failed to update: $e')),
                      );
                    }
                  },
                ),
                const SizedBox(width: 8),
              ],
            ),
        ],
      ),
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
    final rawRows = tableData['Expenses'] ?? [];
    // Always overlay local receipt paths to guarantee display
    final rows = rawRows.map<Map<String, dynamic>>((r) {
      final id = (r['id'] ?? '').toString();
      final lp = _localReceiptPathsExpenses[id];
      if (lp != null && lp.isNotEmpty) return {...r, 'LocalReceiptPath': lp};
      return r;
    }).toList();
    final limit = tabLimits['Expenses'];
    return ExpensesTab(
      rows: rows,
      limit: limit,
      onRowsChanged: (newRows) async {
        // Immediate UI + offline persistence
        setState(() {
          tableData['Expenses'] = List<Map<String, dynamic>>.from(newRows);
        });
        _saveLocalOnly();

        // If one or more rows were appended, immediately persist their attachments
        final prevLen = rawRows.length;
        final addedCount = newRows.length - prevLen;
        if (addedCount > 0) {
          for (int i = prevLen; i < newRows.length; i++) {
            final res = await _saveNewRowAttachmentImmediately(
              collection: 'expenses',
              index: i,
            );
            if (res != null) {
              // Keep the same id for later Firestore creation & UI
              newRows[i] = {
                ...newRows[i],
                'id': res['id'],
                if (res['path'] != null) 'LocalReceiptPath': res['path'],
              };
            }
          }
          // Re-sync updated newRows back into state so callers/UI see id/path immediately
          setState(() {
            tableData['Expenses'] = List<Map<String, dynamic>>.from(newRows);
          });
          _saveLocalOnly();
        }
        // Robust fallback: ensure any row with Receipt bytes has a local file/path
        await _ensureLocalReceiptsForAll(
          collection: 'expenses',
          rows: List<Map<String, dynamic>>.from(newRows),
        );
        // If backend unavailable, ensure local attachments are saved and IDs assigned
        if (_repo == null) {
          await _persistReceiptsLocalOnly(
            collection: 'expenses',
            current: rows,
            desired: List<Map<String, dynamic>>.from(newRows),
          );
          return;
        }
        // Determine diffs vs current and apply mutations to Firestore
        // Smarter diff: compare content (category, subcategory, amount, date, note, receiptUrl)
        final current = rows;
        final desired = newRows;

        String fingerprint(Map<String, dynamic> r) => [
          r['Category'] ?? '',
          r['Subcategory'] ?? '',
          (r['Amount'] ?? 0).toString(),
          r['Date'] ?? '',
          r['Note'] ?? '',
          r['ReceiptUrl'] ?? '',
        ].join('|');

        final currentById = {
          for (final r in current.where((e) => e['id'] != null))
            r['id'] as String: r,
        };
        final desiredById = {
          for (final r in desired.where((e) => e['id'] != null))
            r['id'] as String: r,
        };

        // Handle deletions first optimistically
        for (final id in currentById.keys) {
          if (!desiredById.containsKey(id)) {
            // Firestore delete
            _repo!.deleteExpense(id).catchError((e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to delete expense: $e')),
                );
              }
            });
            // Local receipt cleanup
            _localReceiptPathsExpenses.remove(id);
            LocalReceiptService().deleteReceipt(
              accountId: widget.accountId,
              collection: 'expenses',
              docId: id,
            );
            _saveLocalOnly();
          }
        }

        // Updates for retained IDs
        for (final id in desiredById.keys) {
          if (currentById.containsKey(id)) {
            final desiredItem = desiredById[id]!;
            final changed =
                fingerprint(currentById[id]!) != fingerprint(desiredItem) ||
                (desiredItem['Receipt'] != null &&
                    desiredItem['Receipt'] is Uint8List);
            if (changed) {
              await _maybeUploadReceiptAndPersist(
                collection: 'expenses',
                id: id,
                item: desiredItem,
                isUpdate: true,
              );
            }
          }
        }

        // Creations: include rows with null id or provisional local_ ids
        for (final r in desired.where((e) {
          final sid = e['id'] as String?;
          return sid == null || sid.startsWith('local_');
        })) {
          await _maybeUploadReceiptAndPersist(
            collection: 'expenses',
            id: (r['id'] as String?) ?? '',
            item: r,
            isUpdate: false,
          );
        }
      },
      onSetLimit: () {
        final ctrl = TextEditingController(
          text: (tabLimits['Expenses'] ?? 0.0).toString(),
        );
        showDialog(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Set Monthly Limit'),
            content: TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(hintText: 'Enter limit amount'),
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext, rootNavigator: true).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () async {
                  final value = double.tryParse(ctrl.text) ?? 0.0;
                  await _repo?.setExpenseLimit(value);
                  // Also update local cache for immediate/offline UX
                  if (mounted) {
                    setState(() {
                      tabLimits['Expenses'] = value;
                    });
                    _saveLocalOnly();
                  }
                  if (mounted) {
                    Navigator.of(dialogContext, rootNavigator: true).pop();
                  }
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
    final rawRows = tableData['Savings'] ?? [];
    final rows = rawRows.map<Map<String, dynamic>>((r) {
      final id = (r['id'] ?? '').toString();
      final lp = _localReceiptPathsSavings[id];
      if (lp != null && lp.isNotEmpty) return {...r, 'LocalReceiptPath': lp};
      return r;
    }).toList();
    final expensesRows = tableData['Expenses'] ?? [];
    final goal = savingsGoals['Savings'];
    return SavingsTab(
      rows: rows,
      expensesRows: expensesRows,
      goal: goal,
      onRowsChanged: (newRows) async {
        // Immediate UI + offline persistence
        setState(() {
          tableData['Savings'] = List<Map<String, dynamic>>.from(newRows);
        });
        _saveLocalOnly();

        // Immediately persist attachments for appended rows
        final prevLen = rawRows.length;
        final addedCount = newRows.length - prevLen;
        if (addedCount > 0) {
          for (int i = prevLen; i < newRows.length; i++) {
            final res = await _saveNewRowAttachmentImmediately(
              collection: 'savings',
              index: i,
            );
            if (res != null) {
              newRows[i] = {
                ...newRows[i],
                'id': res['id'],
                if (res['path'] != null) 'LocalReceiptPath': res['path'],
              };
            }
          }
          // Re-sync updated newRows back into state so callers/UI see id/path immediately
          setState(() {
            tableData['Savings'] = List<Map<String, dynamic>>.from(newRows);
          });
          _saveLocalOnly();
        }
        // Robust fallback: ensure any row with Receipt bytes has a local file/path
        await _ensureLocalReceiptsForAll(
          collection: 'savings',
          rows: List<Map<String, dynamic>>.from(newRows),
        );
        if (_repo == null) {
          await _persistReceiptsLocalOnly(
            collection: 'savings',
            current: rows,
            desired: List<Map<String, dynamic>>.from(newRows),
          );
          return;
        }
        final current = rows;
        final desired = newRows;
        String fingerprint(Map<String, dynamic> r) => [
          r['Category'] ?? '',
          r['Subcategory'] ?? '',
          (r['Amount'] ?? 0).toString(),
          r['Date'] ?? '',
          r['Note'] ?? '',
          r['ReceiptUrl'] ?? '',
        ].join('|');

        final currentById = {
          for (final r in current.where((e) => e['id'] != null))
            r['id'] as String: r,
        };
        final desiredById = {
          for (final r in desired.where((e) => e['id'] != null))
            r['id'] as String: r,
        };

        for (final id in currentById.keys) {
          if (!desiredById.containsKey(id)) {
            // Firestore delete
            _repo!.deleteSaving(id).catchError((e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to delete saving: $e')),
                );
              }
            });
            // Local receipt cleanup
            _localReceiptPathsSavings.remove(id);
            LocalReceiptService().deleteReceipt(
              accountId: widget.accountId,
              collection: 'savings',
              docId: id,
            );
            _saveLocalOnly();
          }
        }

        for (final id in desiredById.keys) {
          if (currentById.containsKey(id)) {
            final desiredItem = desiredById[id]!;
            final changed =
                fingerprint(currentById[id]!) != fingerprint(desiredItem) ||
                (desiredItem['Receipt'] != null &&
                    desiredItem['Receipt'] is Uint8List);
            if (changed) {
              await _maybeUploadReceiptAndPersist(
                collection: 'savings',
                id: id,
                item: desiredItem,
                isUpdate: true,
              );
            }
          }
        }

        for (final r in desired.where((e) {
          final sid = e['id'] as String?;
          return sid == null || sid.startsWith('local_');
        })) {
          await _maybeUploadReceiptAndPersist(
            collection: 'savings',
            id: (r['id'] as String?) ?? '',
            item: r,
            isUpdate: false,
          );
        }
      },
      onSetGoal: () {
        final ctrl = TextEditingController(
          text: (savingsGoals['Savings'] ?? 0.0).toString(),
        );
        showDialog(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Set Savings Goal'),
            content: TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(hintText: 'Enter goal amount'),
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext, rootNavigator: true).pop(),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () async {
                  final value = double.tryParse(ctrl.text) ?? 0.0;
                  await _repo?.setSavingsGoal(value);
                  // Also update local cache for immediate/offline UX
                  if (mounted) {
                    setState(() {
                      savingsGoals['Savings'] = value;
                    });
                    _saveLocalOnly();
                  }
                  if (mounted) {
                    Navigator.of(dialogContext, rootNavigator: true).pop();
                  }
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _maybeUploadReceiptAndPersist({
    required String collection, // 'expenses' | 'savings'
    required String id, // '' if new
    required Map<String, dynamic> item,
    required bool isUpdate,
  }) async {
    final hasBytes = item['Receipt'] != null && item['Receipt'] is Uint8List;

    // 1) Save locally first and update UI immediately
    String localId = id;
    if (localId.isEmpty) {
      final existing = (item['id'] as String?) ?? '';
      localId = existing.isNotEmpty
          ? existing
          : 'local_${DateTime.now().millisecondsSinceEpoch}';
    }

    // Ensure a clientHash exists for this item
    final ch = (item['clientHash'] as String?) ?? _clientHash(item);
    item = {...item, 'clientHash': ch};

    if (hasBytes) {
      try {
        final path = await LocalReceiptService().saveReceipt(
          accountId: widget.accountId,
          collection: collection,
          docId: localId,
          bytes: item['Receipt'] as Uint8List,
        );
        setState(() {
          if (collection == 'expenses') {
            _localReceiptPathsExpenses[localId] = path;
            final list = List<Map<String, dynamic>>.from(
              tableData['Expenses'] ?? [],
            );
            // Try by id first
            int idx = list.indexWhere((r) => (r['id'] ?? '') == localId);
            if (idx == -1) {
              // Fallback: match on fingerprint for items without id
              idx = list.lastIndexWhere(
                (r) =>
                    ((r['id'] == null ||
                        (r['id'] as String?)?.isEmpty == true)) &&
                    ((r['clientHash'] as String?) == ch ||
                        _clientHash(r) == ch),
              );
            }
            if (idx != -1) {
              list[idx] = {
                ...list[idx],
                'id': localId,
                'LocalReceiptPath': path,
                'clientHash': ch,
              };
              tableData['Expenses'] = list;
            }
          } else {
            _localReceiptPathsSavings[localId] = path;
            final list = List<Map<String, dynamic>>.from(
              tableData['Savings'] ?? [],
            );
            int idx = list.indexWhere((r) => (r['id'] ?? '') == localId);
            if (idx == -1) {
              idx = list.lastIndexWhere(
                (r) =>
                    ((r['id'] == null ||
                        (r['id'] as String?)?.isEmpty == true)) &&
                    ((r['clientHash'] as String?) == ch ||
                        _clientHash(r) == ch),
              );
            }
            if (idx != -1) {
              list[idx] = {
                ...list[idx],
                'id': localId,
                'LocalReceiptPath': path,
                'clientHash': ch,
              };
              tableData['Savings'] = list;
            }
          }
        });
        _saveLocalOnly();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to save image locally: $e')),
          );
        }
      }
    }

    // 2) Attempt Firestore write if available; reconcile IDs on creations
    try {
      if (_repo == null) return; // offline only; local already saved

      if (isUpdate && localId.isNotEmpty) {
        if (collection == 'expenses') {
          await _repo!.updateExpense(localId, item);
        } else {
          await _repo!.updateSaving(localId, item);
        }
      } else {
        late String newId;
        if (collection == 'expenses') {
          newId = await _repo!.addExpense(item);
        } else {
          newId = await _repo!.addSaving(item);
        }
        if (newId.isNotEmpty && newId != localId) {
          // Update row id and receipt mapping to use newId
          setState(() {
            if (collection == 'expenses') {
              final list = List<Map<String, dynamic>>.from(
                tableData['Expenses'] ?? [],
              );
              final idx = list.indexWhere((r) => (r['id'] ?? '') == localId);
              if (idx != -1) {
                final path = _localReceiptPathsExpenses[localId];
                list[idx] = {
                  ...list[idx],
                  'id': newId,
                  if (path != null && path.isNotEmpty) 'LocalReceiptPath': path,
                  'clientHash': ch,
                };
                if (path != null) {
                  _localReceiptPathsExpenses.remove(localId);
                  _localReceiptPathsExpenses[newId] = path;
                }
                tableData['Expenses'] = list;
              }
            } else {
              final list = List<Map<String, dynamic>>.from(
                tableData['Savings'] ?? [],
              );
              final idx = list.indexWhere((r) => (r['id'] ?? '') == localId);
              if (idx != -1) {
                final path = _localReceiptPathsSavings[localId];
                list[idx] = {
                  ...list[idx],
                  'id': newId,
                  if (path != null && path.isNotEmpty) 'LocalReceiptPath': path,
                  'clientHash': ch,
                };
                if (path != null) {
                  _localReceiptPathsSavings.remove(localId);
                  _localReceiptPathsSavings[newId] = path;
                }
                tableData['Savings'] = list;
              }
            }
          });
          _saveLocalOnly();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved locally. Cloud sync failed: $e')),
        );
      }
    }
  }

  // Bills
  Widget _buildBillsPage() {
    final rows = tableData['Bills'] ?? [];
    return BillsTab(
      rows: rows,
      onRowsChanged: (newRows) {
        setState(() {
          tableData['Bills'] = newRows;
          _saveLocalOnly();
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
