import 'dart:ui';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'services/auth_service.dart';

import 'services/shared_account_repository.dart';
import 'services/local_receipt_service.dart';
import 'services/receipt_backup_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'features/home/home_tab.dart';
import 'features/expenses/expenses_tab.dart';
import 'features/savings/savings_tab.dart';
import 'features/bills/bills_tab.dart';
import 'features/report/report_tab.dart';
import 'manage_accounts_page.dart';
import 'join_requests_page.dart';
import 'widgets/app_gradient_background.dart';

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
  String? _cloudWarning; // persistent banner for cloud permission issues

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
  late final PageController _pageController;
  // Scroll controllers per tab for tap-to-top (Home, Expenses, Savings, Bills, Report, Settings)
  final _homeScroll = ScrollController();
  final _expensesScroll = ScrollController();
  final _savingsScroll = ScrollController();
  final _billsScroll = ScrollController();
  final _reportScroll = ScrollController();
  final _settingsScroll = ScrollController();
  Map<String, dynamic>? _accountDoc;
  // Multi-account
  List<String> _linkedAccounts = const [];
  Map<String, String> _accountAliases = const {};
  // Debounced autosave on global taps
  Timer? _tapAutosave;
  void _scheduleTapAutosave() {
    _tapAutosave?.cancel();
    _tapAutosave = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _saveLocalOnly();
    });
  }

  @override
  void initState() {
    super.initState();
    box = Hive.box('budgetBox');
    _initShared();
    _pageController = PageController(initialPage: _index);
  }

  // Generate a stable-ish uid for a receipt (no external dependency; 26-28 chars)
  String _genReceiptUid() {
    final now = DateTime.now().toUtc();
    final ts = now.microsecondsSinceEpoch.toRadixString(36);
    final rand = (now.hashCode ^ identityHashCode(this) ^ ts.hashCode)
        .toUnsigned(31)
        .toRadixString(36);
    return 'r_${ts}_$rand';
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
          receiptUid: (currentById[id]?['ReceiptUid'] ?? '').toString(),
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
        String receiptUid = (item['ReceiptUid'] ?? item['receiptUid'] ?? '')
            .toString();
        if (receiptUid.isEmpty) {
          receiptUid = _genReceiptUid();
          item['ReceiptUid'] = receiptUid;
          desired[i] = item;
        }
        final path = await LocalReceiptService().saveReceipt(
          accountId: widget.accountId,
          collection: collection,
          docId: id,
          bytes: item['Receipt'] as Uint8List,
          receiptUid: receiptUid,
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
      if (p != null && p.isNotEmpty) {
        expList[i] = {...expList[i], 'LocalReceiptPath': p};
      }
    }
    tableData['Expenses'] = expList;

    final savList = List<Map<String, dynamic>>.from(tableData['Savings'] ?? []);
    for (int i = 0; i < savList.length; i++) {
      final id = (savList[i]['id'] ?? '').toString();
      final p = _localReceiptPathsSavings[id];
      if (p != null && p.isNotEmpty) {
        savList[i] = {...savList[i], 'LocalReceiptPath': p};
      }
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
    // Load linked accounts list from Hive for account switcher
    final la = box.get('linkedAccounts');
    if (la is List) {
      _linkedAccounts = la.whereType<String>().toList();
    }
    final aliases = box.get('accountAliases');
    if (aliases is Map) {
      _accountAliases = aliases.map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      );
    }
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
      if (remoteRows.isEmpty) {
        return; // keep offline data if backend emits nothing
      }
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
      if (remoteRows.isEmpty) {
        return; // keep offline data if backend emits nothing
      }
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
      // Overlay amount-based legacy values
      final limits = (meta['limits'] as Map?) ?? {};
      final goals = (meta['goals'] as Map?) ?? {};
      // New: percent-based maps from meta
      final expPct = (meta['expensesLimitPercent'] as Map?) ?? {};
      final savPct = (meta['savingsGoalPercent'] as Map?) ?? {};

      // Write percent maps into Hive so tabs immediately read them
      void putNum(String key, Object? v) {
        if (v is num) box.put(key, v.toDouble());
      }

      // Expenses percents
      putNum('expensesLimitPercent_this_week', expPct['this_week']);
      putNum('expensesLimitPercent_this_month', expPct['this_month']);
      putNum('expensesLimitPercent_last_week', expPct['last_week']);
      putNum('expensesLimitPercent_last_month', expPct['last_month']);
      putNum('expensesLimitPercent_all_expenses', expPct['all_expenses']);
      // Savings percents
      putNum('savingsGoalPercent_this_week', savPct['this_week']);
      putNum('savingsGoalPercent_this_month', savPct['this_month']);
      putNum('savingsGoalPercent_last_week', savPct['last_week']);
      putNum('savingsGoalPercent_last_month', savPct['last_month']);
      putNum('savingsGoalPercent_all_savings', savPct['all_savings']);

      setState(() {
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
      // Ensure a stable receipt uid exists on first attach
      String receiptUid = (item['ReceiptUid'] ?? item['receiptUid'] ?? '')
          .toString();
      if (receiptUid.isEmpty) {
        receiptUid = _genReceiptUid();
        item['ReceiptUid'] = receiptUid;
      }
      final path = await LocalReceiptService().saveReceipt(
        accountId: widget.accountId,
        collection: collection,
        docId: id,
        bytes: item['Receipt'] as Uint8List,
        receiptUid: receiptUid,
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
        'ReceiptUid': receiptUid,
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
      String receiptUid = (item['ReceiptUid'] ?? item['receiptUid'] ?? '')
          .toString();
      if (receiptUid.isEmpty) {
        receiptUid = _genReceiptUid();
        item['ReceiptUid'] = receiptUid;
      }
      try {
        final path = await LocalReceiptService().saveReceipt(
          accountId: widget.accountId,
          collection: collection,
          docId: id,
          bytes: item['Receipt'] as Uint8List,
          receiptUid: receiptUid,
        );
        item['LocalReceiptPath'] = path;
        item['clientHash'] =
            (item['clientHash'] as String?) ?? _clientHash(item);
        item['ReceiptUid'] = receiptUid;
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
      PrimaryScrollController(
        controller: _homeScroll,
        child: HomeTab(
          tableData: tableData,
          tabLimits: tabLimits,
          savingsGoals: savingsGoals,
        ),
      ),
      PrimaryScrollController(
        controller: _expensesScroll,
        child: _buildExpensesPage(),
      ),
      PrimaryScrollController(
        controller: _savingsScroll,
        child: _buildSavingsPage(),
      ),
      PrimaryScrollController(
        controller: _billsScroll,
        child: _buildBillsPage(),
      ),
      PrimaryScrollController(
        controller: _reportScroll,
        child: _buildReportPage(),
      ),
      PrimaryScrollController(
        controller: _settingsScroll,
        child: _buildSettingsPage(),
      ),
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

    // Top bar removed; joint indicator moved into Settings

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _scheduleTapAutosave(),
      onPointerUp: (_) => _scheduleTapAutosave(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Stack(
          children: [
            // Gradient background with app content
            AppGradientBackground(
              child: SafeArea(
                child: Padding(
                  // Add bottom padding so content isn't obscured by floating tabs
                  padding: const EdgeInsets.only(bottom: 86),
                  child: Column(
                    children: [
                      if (((widget.initialWarning ?? '').isNotEmpty) ||
                          ((_cloudWarning ?? '').isNotEmpty))
                        Material(
                          color: Colors.amber.shade100,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Padding(
                                  padding: EdgeInsets.only(top: 2),
                                  child: Icon(
                                    Icons.warning_amber_rounded,
                                    size: 18,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if ((widget.initialWarning ?? '')
                                          .isNotEmpty)
                                        Text(
                                          widget.initialWarning!,
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                      if ((widget.initialWarning ?? '')
                                              .isNotEmpty &&
                                          (_cloudWarning ?? '').isNotEmpty)
                                        const SizedBox(height: 4),
                                      if ((_cloudWarning ?? '').isNotEmpty)
                                        Text(
                                          _cloudWarning!,
                                          style: const TextStyle(fontSize: 12),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if ((_cloudWarning ?? '').isNotEmpty)
                                  TextButton(
                                    onPressed: _showCloudFixDialog,
                                    child: const Text('How to fix'),
                                  ),
                                if ((_cloudWarning ?? '').isNotEmpty)
                                  IconButton(
                                    tooltip: 'Dismiss',
                                    icon: const Icon(Icons.close, size: 18),
                                    onPressed: () =>
                                        setState(() => _cloudWarning = null),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      Expanded(
                        child: PageView.builder(
                          controller: _pageController,
                          physics: const BouncingScrollPhysics(),
                          allowImplicitScrolling: true,
                          onPageChanged: (i) {
                            setState(() => _index = i);
                            // Light haptic on settle
                            HapticFeedback.lightImpact();
                          },
                          itemCount: pages.length,
                          itemBuilder: (context, i) {
                            return _FancyPage(
                              controller: _pageController,
                              index: i,
                              child: _KeepAlive(child: pages[i]),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Floating glass tab bar overlay
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _AnimatedGlassTabBar(
                currentIndex: _index,
                destinations: destinations,
                onTap: (i) {
                  if (i == _index) {
                    // Scroll current tab to top
                    final map = {
                      0: _homeScroll,
                      1: _expensesScroll,
                      2: _savingsScroll,
                      3: _billsScroll,
                      4: _reportScroll,
                      5: _settingsScroll,
                    };
                    final ctrl = map[i];
                    if (ctrl != null && ctrl.hasClients) {
                      ctrl.animateTo(
                        0,
                        duration: const Duration(milliseconds: 350),
                        curve: Curves.easeOutCubic,
                      );
                    }
                    return;
                  }
                  HapticFeedback.selectionClick();
                  _pageController.animateToPage(
                    i,
                    duration: const Duration(milliseconds: 360),
                    curve: Curves.easeOutCubic,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _tapAutosave?.cancel();
    _pageController.dispose();
    _homeScroll.dispose();
    _expensesScroll.dispose();
    _savingsScroll.dispose();
    _billsScroll.dispose();
    _reportScroll.dispose();
    _settingsScroll.dispose();
    super.dispose();
  }

  void _showCloudWarning(Object e) {
    String message = 'Saved locally. Cloud sync failed.';
    if (e is FirebaseException) {
      if (e.code == 'permission-denied') {
        message =
            'Cloud sync blocked by security: App Check or membership required.';
      } else if (e.message != null && e.message!.isNotEmpty) {
        message = 'Cloud sync failed: ${e.message}';
      }
    } else {
      final s = e.toString();
      if (s.contains('permission-denied')) {
        message =
            'Cloud sync blocked by security: App Check or membership required.';
      } else {
        message = 'Cloud sync failed: $s';
      }
    }
    if (!mounted) return;
    setState(() => _cloudWarning = message);
  }

  void _showCloudFixDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Fix cloud sync'),
        content: const Text(
          'In development, enable App Check debug: run a debug build, copy the token from logs, and add it in Firebase Console → App Check → Debug tokens.\n\nAlso ensure you are a member of this account: the owner must approve your join request (Settings → Owner tools → Join requests). Then try again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // Settings
  Widget _buildSettingsPage() {
    final createdBy = (_accountDoc?['createdBy'] as String?) ?? '';
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final isOwner = createdBy.isNotEmpty && createdBy == uid;
    final isJoint = (_accountDoc?['isJoint'] as bool?) ?? false;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        // Header row with Joint indicator and Add Account
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              if (_accountDoc != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: isJoint
                        ? Colors.green.withValues(alpha: 0.12)
                        : Colors.blueGrey.withValues(alpha: 0.12),
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
              const Spacer(),
              FilledButton.icon(
                onPressed: () {
                  // Reuse the same flow as Add Account sheet previously
                  _showAddAccountInline(context);
                },
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('Add Account'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Account',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.swap_horiz),
          title: const Text('Switch account'),
          subtitle: const Text('Change the active account'),
          onTap: () => _showAccountSwitcher(context),
        ),
        ListTile(
          leading: const Icon(Icons.manage_accounts_outlined),
          title: const Text('Manage accounts'),
          subtitle: const Text('Rename, remove, or reorder linked accounts'),
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ManageAccountsPage()),
            );
            // Reload aliases and accounts after return
            final la = box.get('linkedAccounts');
            if (la is List) {
              setState(() => _linkedAccounts = la.whereType<String>().toList());
            }
            final aliases = box.get('accountAliases');
            if (aliases is Map) {
              setState(
                () => _accountAliases = aliases.map(
                  (k, v) => MapEntry(k.toString(), v.toString()),
                ),
              );
            }
          },
        ),
        if (isOwner) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Owner tools',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          SwitchListTile.adaptive(
            secondary: const Icon(Icons.groups_2_outlined),
            title: const Text('Enable Joint access'),
            subtitle: const Text(
              'Allow others to request access to this account',
            ),
            value: isJoint,
            onChanged: (v) async {
              if (_repo == null) return;
              try {
                await _repo!.setIsJoint(v);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      v ? 'Joint access enabled' : 'Joint access disabled',
                    ),
                  ),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('Failed to update: $e')));
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.how_to_reg_outlined),
            title: const Text('Join requests'),
            subtitle: const Text('Approve or deny pending access requests'),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => JoinRequestsPage(accountId: widget.accountId),
                ),
              );
            },
          ),
        ],
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text('App', style: Theme.of(context).textTheme.titleMedium),
        ),
        ListTile(
          leading: const Icon(Icons.cloud_done_outlined),
          title: const Text('Validate cloud setup'),
          subtitle: const Text('Check App Check and membership access'),
          onTap: _validateCloudSetup,
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            'Receipts backup',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.file_download_outlined),
          title: const Text('Export receipts'),
          subtitle: const Text(
            'Create a manifest.json and copy images (by receiptUid)',
          ),
          onTap: _exportReceipts,
        ),
        ListTile(
          leading: const Icon(Icons.file_upload_outlined),
          title: const Text('Import receipts'),
          subtitle: const Text('Paste a folder path containing manifest.json'),
          onTap: _importReceiptsPrompt,
        ),
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (context, snap) {
            final version = snap.hasData
                ? '${snap.data!.version} (${snap.data!.buildNumber})'
                : '…';
            final email = FirebaseAuth.instance.currentUser?.email ?? '—';
            return ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('About'),
              subtitle: Text(
                'BudgetBuddy • v$version\nDeveloper: Bryan L. Tejano\nActive account: ${_accountAliases[widget.accountId] ?? widget.accountId}\nGmail: $email',
              ),
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('Sign out'),
          onTap: () async {
            try {
              await AuthService().signOut();
              if (!mounted) return;
              // After sign out, clear to root and let MyApp's auth listener show LoginPage
              Navigator.of(
                context,
                rootNavigator: true,
              ).popUntil((route) => route.isFirst);
            } catch (e) {
              if (!mounted) return;
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text('Failed to sign out: $e')));
            }
          },
        ),
        const SizedBox(height: 48),
      ],
    );
  }

  Future<void> _exportReceipts() async {
    if (_repo == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Cloud not initialized. Sign in and open an account first.',
          ),
        ),
      );
      return;
    }
    try {
      final svc = ReceiptBackupService(
        accountId: widget.accountId,
        repo: _repo!,
      );
      final dir = await svc.exportAll();
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Export complete'),
          content: SelectableText('Saved to:\n${dir.path}'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  Future<void> _importReceiptsPrompt() async {
    // Try a native directory or file picker first
    try {
      // Prefer picking the manifest.json file for clarity
      final manifestResult = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        dialogTitle: 'Pick manifest.json',
        allowMultiple: false,
      );
      if (manifestResult != null && manifestResult.files.isNotEmpty) {
        final filePath = manifestResult.files.single.path;
        if (filePath != null &&
            filePath.toLowerCase().endsWith('manifest.json')) {
          final dir = Directory(File(filePath).parent.path);
          await _importReceiptsFromDirectory(dir);
          return;
        }
      }
      // Fallback: pick a directory
      final dirPath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Pick receipts backup folder',
      );
      if (dirPath != null) {
        await _importReceiptsFromDirectory(Directory(dirPath));
        return;
      }
    } catch (_) {
      // fall through to manual paste prompt
    }

    // Manual path entry fallback (in case picker is not available)
    String path = '';
    bool busy = false;
    String? error;
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) => AlertDialog(
          title: const Text('Import receipts'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Paste the folder path that contains manifest.json'),
              const SizedBox(height: 8),
              TextField(
                onChanged: (v) => setM(() => path = v.trim()),
                decoration: const InputDecoration(
                  labelText: 'Folder path',
                  prefixIcon: Icon(Icons.folder_open),
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setM(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        final dir = Directory(path);
                        if (!await dir.exists()) {
                          throw 'Folder not found';
                        }
                        if (_repo == null) throw 'Cloud not initialized';
                        final svc = ReceiptBackupService(
                          accountId: widget.accountId,
                          repo: _repo!,
                        );
                        final results = await svc.importAll(dir);
                        if (!mounted) return;
                        Navigator.of(ctx).pop();
                        final attached = results
                            .where((r) => r['status'] == 'attached_by_uid')
                            .length;
                        final cachedOnly = results
                            .where((r) => r['status'] == 'cached_only')
                            .length;
                        final skipped = results
                            .where((r) => r['status'] == 'skipped_no_file')
                            .length;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Imported: attached $attached, cached $cachedOnly, skipped $skipped',
                            ),
                            duration: const Duration(seconds: 5),
                          ),
                        );
                        // Trigger a refresh to overlay paths
                        setState(() {});
                      } catch (e) {
                        setM(() {
                          error = 'Failed: $e';
                          busy = false;
                        });
                      }
                    },
              child: const Text('Import'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importReceiptsFromDirectory(Directory dir) async {
    try {
      if (_repo == null) throw 'Cloud not initialized';
      final svc = ReceiptBackupService(
        accountId: widget.accountId,
        repo: _repo!,
      );
      final results = await svc.importAll(dir);
      if (!mounted) return;
      final attached = results
          .where((r) => r['status'] == 'attached_by_uid')
          .length;
      final cachedOnly = results
          .where((r) => r['status'] == 'cached_only')
          .length;
      final skipped = results
          .where((r) => r['status'] == 'skipped_no_file')
          .length;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Imported: attached $attached, cached $cachedOnly, skipped $skipped',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }

  Future<void> _validateCloudSetup() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => const AlertDialog(
          title: Text('Validate cloud setup'),
          content: Text('You are not signed in.'),
        ),
      );
      return;
    }
    final db = FirebaseFirestore.instance;
    final accRef = db.collection('accounts').doc(widget.accountId);

    bool readOk = false;
    bool memberWriteOk = false;
    Object? readErr;
    Object? writeErr;

    // Baseline read (should pass if App Check is trusted and rules allow reads)
    try {
      await accRef.get();
      readOk = true;
    } catch (e) {
      readErr = e;
    }

    // Member-only write to meta (merge). Passes only if you are a member/owner.
    if (readOk) {
      try {
        await accRef.collection('meta').doc('config').set({
          'healthCheckedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
        memberWriteOk = true;
      } catch (e) {
        writeErr = e;
      }
    }

    if (!mounted) return;
    final issues = <String>[];
    if (!readOk) {
      issues.add('App Check not trusted or rules deny baseline read.');
    }
    if (readOk && !memberWriteOk) {
      issues.add('You are not a member of this account.');
    }

    final details = StringBuffer();
    if (!readOk && readErr != null) {
      details.writeln('Read error: $readErr');
    }
    if (readOk && !memberWriteOk && writeErr != null) {
      details.writeln('Write error: $writeErr');
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Validate cloud setup'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    readOk ? Icons.check_circle : Icons.error,
                    color: readOk ? Colors.green : Colors.red,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      readOk
                          ? 'App Check / baseline read: OK'
                          : 'App Check / baseline read: FAILED',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    memberWriteOk ? Icons.check_circle : Icons.error,
                    color: memberWriteOk ? Colors.green : Colors.red,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      memberWriteOk
                          ? 'Membership write: OK'
                          : 'Membership write: FAILED',
                    ),
                  ),
                ],
              ),
              if (issues.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'Next steps:',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
                if (!readOk)
                  const Text(
                    '• Add App Check debug token in Firebase Console → App Check → Debug tokens, then relaunch the app.',
                  ),
                if (readOk && !memberWriteOk)
                  const Text(
                    '• Ask the owner to approve your join request (Settings → Owner tools → Join requests).',
                  ),
                if (details.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    details.toString(),
                    style: const TextStyle(fontSize: 12, color: Colors.black87),
                  ),
                ],
              ],
              if (issues.isEmpty) ...[
                const SizedBox(height: 12),
                const Text('All good! Cloud sync should work.'),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _showAccountSwitcher(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Switch account'),
        content: SizedBox(
          width: 360,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _linkedAccounts.length,
            itemBuilder: (c, i) {
              final id = _linkedAccounts[i];
              final isActive = id == widget.accountId;
              return ListTile(
                leading: Icon(Icons.credit_card, color: cs.primary),
                title: Text(id),
                trailing: isActive
                    ? const Icon(Icons.check_circle, color: Colors.green)
                    : null,
                onTap: () => Navigator.of(ctx).pop(id),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (selected != null && selected != widget.accountId) {
      _openAccount(selected);
    }
  }

  void _showAddAccountInline(BuildContext context) {
    final ctrl = TextEditingController();
    String? error;
    bool sending = false;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) => AlertDialog(
          title: const Text('Add account'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Account number',
                  hintText: 'BB-ABCD-1234 or BB-PERS-... ',
                  prefixIcon: Icon(Icons.credit_card),
                ),
              ),
              const SizedBox(height: 8),
              if (error != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    error!,
                    style: const TextStyle(color: Colors.red),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: sending
                  ? null
                  : () async {
                      final id = ctrl.text.trim().toUpperCase();
                      if (id.isEmpty) {
                        setM(() => error = 'Enter an account number');
                        return;
                      }
                      setM(() {
                        sending = true;
                        error = null;
                      });
                      try {
                        final user = FirebaseAuth.instance.currentUser;
                        if (user == null) throw 'Not signed in';
                        final repo = SharedAccountRepository(
                          accountId: id,
                          uid: user.uid,
                        );
                        // Validate account
                        final acc = await repo.getAccountOnce();
                        if (acc == null) throw 'Account not found';
                        final isJoint = (acc['isJoint'] as bool?) ?? false;
                        if (!isJoint) {
                          throw 'Only joint accounts can be linked. Ask the owner to enable Joint first.';
                        }
                        final members = List<String>.from(acc['members'] ?? []);
                        final myUid = user.uid;
                        if (members.contains(myUid)) {
                          final setList = {..._linkedAccounts};
                          setList.add(id);
                          final arr = setList.toList();
                          box.put('linkedAccounts', arr);
                          if (mounted) setState(() => _linkedAccounts = arr);
                          if (mounted) Navigator.of(ctx).pop();
                          if (mounted)
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Already added in your account. Go to Settings → Switch account.',
                                ),
                              ),
                            );
                          return;
                        }

                        await repo.requestJoinVerification(
                          displayName: user.displayName,
                          email: user.email,
                        );

                        StreamSubscription? sub;
                        sub = FirebaseFirestore.instance
                            .collection('accounts')
                            .doc(id)
                            .collection('joinRequests')
                            .doc(myUid)
                            .snapshots()
                            .listen((doc) async {
                              final status =
                                  (doc.data()?['status'] as String?) ??
                                  'pending';
                              if (status == 'approved') {
                                await repo.ensureMembership(
                                  displayName: user.displayName,
                                  email: user.email,
                                );
                                final setList = {..._linkedAccounts};
                                setList.add(id);
                                final arr = setList.toList();
                                box.put('linkedAccounts', arr);
                                if (mounted)
                                  setState(() => _linkedAccounts = arr);
                                if (mounted)
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Access approved. "$id" added to Switch account.',
                                      ),
                                    ),
                                  );
                                await sub?.cancel();
                              }
                            });

                        if (mounted) Navigator.of(ctx).pop();
                        if (mounted)
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Request Add Account status: Pending. You\'ll be added automatically once approved.',
                              ),
                              duration: Duration(seconds: 5),
                            ),
                          );
                      } catch (e) {
                        setM(() => error = 'Failed: $e');
                      } finally {
                        setM(() => sending = false);
                      }
                    },
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Add Account'),
            ),
          ],
        ),
      ),
    );
  }

  // Removed unused _showAddAccountSheet after moving Add Account to Settings.

  void _openAccount(String id) {
    box.put('accountId', id);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => _EnsureAndOpen(accountId: id)),
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
      savingsRows: List<Map<String, dynamic>>.from(tableData['Savings'] ?? []),
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
                if (((newRows[i]['ReceiptUid'] ?? '') as String).isNotEmpty)
                  'ReceiptUid': (newRows[i]['ReceiptUid'] ?? '').toString(),
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
              receiptUid: (currentById[id]?['ReceiptUid'] ?? '').toString(),
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
        showDialog(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
            builder: (ctx, setLocal) {
              // Read current period from persisted Expenses tab preference
              final currentPeriod =
                  (box.get('expensesSummaryPeriod') as String?) ?? 'this_month';
              String keyFor(String period) {
                switch (period) {
                  case 'this_week':
                    return 'expensesLimitPercent_this_week';
                  case 'last_week':
                    return 'expensesLimitPercent_last_week';
                  case 'last_month':
                    return 'expensesLimitPercent_last_month';
                  case 'all_expenses':
                    return 'expensesLimitPercent_all_expenses';
                  case 'this_month':
                  default:
                    return 'expensesLimitPercent_this_month';
                }
              }

              final periodLabel = switch (currentPeriod) {
                'this_week' => 'This Week',
                'last_week' => 'Last Week',
                'last_month' => 'Last Month',
                'all_expenses' => 'All Expenses',
                _ => 'This Month',
              };
              final helper = 'Percent of $periodLabel savings';
              final valueCtrl = TextEditingController(
                text: (box.get(keyFor(currentPeriod)) ?? '').toString(),
              );
              return AlertDialog(
                title: const Text('Set Limit'),
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
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () =>
                        Navigator.of(dialogContext, rootNavigator: true).pop(),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () async {
                      final numVal = double.tryParse(valueCtrl.text);
                      final val = (numVal ?? 0).clamp(0.0, 100.0);
                      // Apply to all Expenses filters so it works across period switches
                      for (final k in const [
                        'expensesLimitPercent_this_week',
                        'expensesLimitPercent_this_month',
                        'expensesLimitPercent_last_week',
                        'expensesLimitPercent_last_month',
                        'expensesLimitPercent_all_expenses',
                      ]) {
                        box.put(k, val);
                      }
                      // Persist to cloud so it survives sign-in across devices
                      try {
                        if (_repo != null) {
                          await _repo!.setExpensesLimitPercents({
                            'this_week':
                                (box.get('expensesLimitPercent_this_week')
                                        as num?)
                                    ?.toDouble() ??
                                val,
                            'this_month':
                                (box.get('expensesLimitPercent_this_month')
                                        as num?)
                                    ?.toDouble() ??
                                val,
                            'last_week':
                                (box.get('expensesLimitPercent_last_week')
                                        as num?)
                                    ?.toDouble() ??
                                val,
                            'last_month':
                                (box.get('expensesLimitPercent_last_month')
                                        as num?)
                                    ?.toDouble() ??
                                val,
                            'all_expenses':
                                (box.get('expensesLimitPercent_all_expenses')
                                        as num?)
                                    ?.toDouble() ??
                                val,
                          });
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Limit percent saved to cloud.'),
                              ),
                            );
                          }
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Cloud save failed. Kept locally. Use Settings > Validate cloud setup.',
                              ),
                            ),
                          );
                        }
                      }
                      if (mounted) _saveLocalOnly();
                      if (mounted) {
                        Navigator.of(dialogContext, rootNavigator: true).pop();
                      }
                    },
                    child: const Text('Save'),
                  ),
                ],
              );
            },
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
                if (((newRows[i]['ReceiptUid'] ?? '') as String).isNotEmpty)
                  'ReceiptUid': (newRows[i]['ReceiptUid'] ?? '').toString(),
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
              receiptUid: (currentById[id]?['ReceiptUid'] ?? '').toString(),
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
        // Percent-only input (no dropdown, no amount option). Per-period storage.
        showDialog(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
            builder: (ctx, setLocal) {
              // Helper text uses current Savings filter period stored in Hive.
              final String period =
                  (box.get('savingsSummaryPeriod') ?? 'this_month').toString();
              String keyFor(String p) {
                switch (p) {
                  case 'this_week':
                    return 'savingsGoalPercent_this_week';
                  case 'last_week':
                    return 'savingsGoalPercent_last_week';
                  case 'last_month':
                    return 'savingsGoalPercent_last_month';
                  case 'all_savings':
                    return 'savingsGoalPercent_all_savings';
                  case 'this_month':
                  default:
                    return 'savingsGoalPercent_this_month';
                }
              }

              final String periodLabel = switch (period) {
                'this_week' => 'This Week',
                'last_week' => 'Last Week',
                'last_month' => 'Last Month',
                'all_savings' => 'All Savings',
                _ => 'This Month',
              };
              final helper = 'Percent of $periodLabel savings';
              final valueCtrl = TextEditingController(
                text: (box.get(keyFor(period)) ?? '').toString(),
              );
              return AlertDialog(
                title: const Text('Set Savings Goal'),
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
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        helper,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed: () =>
                        Navigator.of(dialogContext, rootNavigator: true).pop(),
                    child: const Text('Cancel'),
                  ),
                  TextButton(
                    onPressed: () async {
                      final numVal = double.tryParse(valueCtrl.text) ?? 0.0;
                      final val = numVal.clamp(0.0, 100.0);
                      // Apply to all Savings filters so it works across period switches
                      for (final k in const [
                        'savingsGoalPercent_this_week',
                        'savingsGoalPercent_this_month',
                        'savingsGoalPercent_last_week',
                        'savingsGoalPercent_last_month',
                        'savingsGoalPercent_all_savings',
                      ]) {
                        box.put(k, val);
                      }
                      // Persist to cloud meta so it survives sign-in
                      try {
                        if (_repo != null) {
                          await _repo!.setSavingsGoalPercents({
                            'this_week':
                                (box.get('savingsGoalPercent_this_week')
                                        as num?)
                                    ?.toDouble() ??
                                val,
                            'this_month':
                                (box.get('savingsGoalPercent_this_month')
                                        as num?)
                                    ?.toDouble() ??
                                val,
                            'last_week':
                                (box.get('savingsGoalPercent_last_week')
                                        as num?)
                                    ?.toDouble() ??
                                val,
                            'last_month':
                                (box.get('savingsGoalPercent_last_month')
                                        as num?)
                                    ?.toDouble() ??
                                val,
                            'all_savings':
                                (box.get('savingsGoalPercent_all_savings')
                                        as num?)
                                    ?.toDouble() ??
                                val,
                          });
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Savings goal percent saved to cloud.',
                                ),
                              ),
                            );
                          }
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Cloud save failed. Kept locally. Use Settings > Validate cloud setup.',
                              ),
                            ),
                          );
                        }
                      }
                      if (mounted) _saveLocalOnly();
                      if (mounted) {
                        Navigator.of(dialogContext, rootNavigator: true).pop();
                      }
                    },
                    child: const Text('Save'),
                  ),
                ],
              );
            },
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
      // Ensure a stable receipt uid exists on first attach
      String receiptUid = (item['ReceiptUid'] ?? item['receiptUid'] ?? '')
          .toString();
      if (receiptUid.isEmpty) {
        receiptUid = _genReceiptUid();
        item = {...item, 'ReceiptUid': receiptUid};
      }
      try {
        final path = await LocalReceiptService().saveReceipt(
          accountId: widget.accountId,
          collection: collection,
          docId: localId,
          bytes: item['Receipt'] as Uint8List,
          receiptUid: (item['ReceiptUid'] ?? '').toString(),
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
                'ReceiptUid': (item['ReceiptUid'] ?? '').toString(),
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
                'ReceiptUid': (item['ReceiptUid'] ?? '').toString(),
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
                  if ((item['ReceiptUid'] ?? '').toString().isNotEmpty)
                    'ReceiptUid': (item['ReceiptUid'] ?? '').toString(),
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
                  if ((item['ReceiptUid'] ?? '').toString().isNotEmpty)
                    'ReceiptUid': (item['ReceiptUid'] ?? '').toString(),
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
        _showCloudWarning(e);
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

  // ... end of _MainTabsPageState
}

// Keep tab widget state alive when swiping between pages
class _KeepAlive extends StatefulWidget {
  final Widget child;
  const _KeepAlive({required this.child});
  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

// Subtle animated transform/opacity for nicer swipe transitions
class _FancyPage extends StatelessWidget {
  final PageController controller;
  final int index;
  final Widget child;
  const _FancyPage({
    required this.controller,
    required this.index,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        double page = controller.initialPage.toDouble();
        if (controller.hasClients && controller.position.haveDimensions) {
          page = controller.page ?? controller.initialPage.toDouble();
        }
        final delta = (index - page).toDouble();
        final d = delta.abs();
        final scale = 1.0 - (0.03 * d).clamp(0.0, 0.03);
        final opacity = 1.0 - (0.08 * d).clamp(0.0, 0.08);
        final shiftX = (-16.0 * delta).clamp(-22.0, 22.0);
        return Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(shiftX, 0),
            child: Transform.scale(
              scale: scale,
              alignment: Alignment.center,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class _AnimatedGlassTabBar extends StatelessWidget {
  final int currentIndex;
  final List<NavigationDestination> destinations;
  final ValueChanged<int> onTap;

  const _AnimatedGlassTabBar({
    required this.currentIndex,
    required this.destinations,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: Container(
              height: 68,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.26),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 12,
                    offset: const Offset(0, -4),
                  ),
                ],
                border: Border(
                  top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.35),
                    width: 0.6,
                  ),
                  left: BorderSide(
                    color: Colors.white.withValues(alpha: 0.2),
                    width: 0.6,
                  ),
                  right: BorderSide(
                    color: Colors.white.withValues(alpha: 0.2),
                    width: 0.6,
                  ),
                  bottom: BorderSide(
                    color: Colors.white.withValues(alpha: 0.15),
                    width: 0.6,
                  ),
                ),
              ),
              child: _PillTabs(
                currentIndex: currentIndex,
                destinations: destinations,
                onTap: onTap,
                textStyle: theme.textTheme.labelMedium,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PillTabs extends StatefulWidget {
  final int currentIndex;
  final List<NavigationDestination> destinations;
  final ValueChanged<int> onTap;
  final TextStyle? textStyle;

  const _PillTabs({
    required this.currentIndex,
    required this.destinations,
    required this.onTap,
    this.textStyle,
  });

  @override
  State<_PillTabs> createState() => _PillTabsState();
}

class _PillTabsState extends State<_PillTabs>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _bounce;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _bounce = TweenSequence<double>(
      [
        TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.06), weight: 60),
        TweenSequenceItem(tween: Tween(begin: 1.06, end: 1.0), weight: 40),
      ],
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
  }

  @override
  void didUpdateWidget(covariant _PillTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.destinations.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final itemW = width / count;
        final pillLeft = itemW * widget.currentIndex + 6;
        final pillW = itemW - 12;
        final tint = _pillTintForIndex(widget.currentIndex);
        return Stack(
          children: [
            // Ripple under the pill
            Positioned(
              left: pillLeft + pillW / 2 - 28,
              top: 6 + 28 - 28,
              width: 56,
              height: 56,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final scale = 0.6 + 0.8 * _controller.value;
                  final opacity = (0.30 * (1.0 - _controller.value)).clamp(
                    0.0,
                    0.30,
                  );
                  return Opacity(
                    opacity: opacity,
                    child: Transform.scale(
                      scale: scale,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: tint.withValues(alpha: 0.22),
                          boxShadow: [
                            BoxShadow(
                              color: tint.withValues(alpha: 0.22),
                              blurRadius: 18,
                              spreadRadius: 6,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // Moving pill
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              left: pillLeft,
              top: 6,
              width: pillW,
              height: 56,
              child: ScaleTransition(
                scale: _bounce,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        tint.withValues(alpha: 0.38),
                        Colors.white.withValues(alpha: 0.22),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: tint.withValues(alpha: 0.28),
                        blurRadius: 12,
                        offset: const Offset(0, 6),
                      ),
                    ],
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.35),
                      width: 0.8,
                    ),
                  ),
                ),
              ),
            ),
            Row(
              children: [
                for (int i = 0; i < count; i++)
                  Expanded(
                    child: _TabItem(
                      selected: i == widget.currentIndex,
                      destination: widget.destinations[i],
                      onTap: () => widget.onTap(i),
                      controller: _controller,
                      textStyle: widget.textStyle,
                      activeColor: _pillTintForIndex(i),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  Color _pillTintForIndex(int index) {
    if (index < 0 || index >= widget.destinations.length) {
      return Colors.blueAccent;
    }
    final label = widget.destinations[index].label.toLowerCase();
    if (label.contains('home')) return const Color(0xFF8A7CF6); // purple
    if (label.contains('expense')) return const Color(0xFFFF6B8B); // pink/red
    if (label.contains('saving')) return const Color(0xFF2EC4B6); // teal
    if (label.contains('bill')) return const Color(0xFFFFC857); // amber
    if (label.contains('report') || label.contains('chart')) {
      return const Color(0xFF4DA3FF); // blue
    }
    if (label.contains('setting')) {
      return const Color(0xFF7C8DB5); // indigo/grey
    }
    return Colors.blueAccent;
  }
}

class _TabItem extends StatelessWidget {
  final bool selected;
  final NavigationDestination destination;
  final VoidCallback onTap;
  final AnimationController controller;
  final TextStyle? textStyle;
  final Color activeColor;

  const _TabItem({
    required this.selected,
    required this.destination,
    required this.onTap,
    required this.controller,
    this.textStyle,
    required this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final baseColor = Theme.of(context).colorScheme.onSurface;
    final active = activeColor;
    final inactive = baseColor.withValues(alpha: 0.6);
    return LayoutBuilder(
      builder: (context, constraints) {
        final showLabel =
            selected && constraints.maxWidth >= 88; // hide on tight
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              HapticFeedback.selectionClick();
              controller.forward(from: 0);
              onTap();
            },
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56, minWidth: 72),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 10,
                ),
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 250),
                  style: (textStyle ?? const TextStyle()).copyWith(
                    color: selected ? active : inactive,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TweenAnimationBuilder<double>(
                        tween: Tween(begin: 1.0, end: selected ? 1.12 : 1.0),
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                        builder: (context, scale, child) => Transform.scale(
                          scale: scale,
                          child: IconTheme(
                            data: IconThemeData(
                              color: selected ? active : inactive,
                            ),
                            child: selected
                                ? (destination.selectedIcon ?? destination.icon)
                                : destination.icon,
                          ),
                        ),
                      ),
                      if (showLabel) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            destination.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// (removed placeholder; real settings implemented in _buildSettingsPage)

class _EnsureAndOpen extends StatefulWidget {
  final String accountId;
  const _EnsureAndOpen({required this.accountId});
  @override
  State<_EnsureAndOpen> createState() => _EnsureAndOpenState();
}

class _EnsureAndOpenState extends State<_EnsureAndOpen> {
  bool _ready = false;
  String? _ensureError;

  @override
  void initState() {
    super.initState();
    _ensure();
  }

  Future<void> _ensure() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        final repo = SharedAccountRepository(
          accountId: widget.accountId,
          uid: user.uid,
        );
        await repo.ensureMembership(
          displayName: user.displayName,
          email: user.email,
        );
      } catch (e, st) {
        _ensureError = 'Cloud join failed: $e';
        // ignore: avoid_print
        print(_ensureError);
        // ignore: avoid_print
        print(st);
      }
    }
    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return MainTabsPage(
      accountId: widget.accountId,
      initialWarning: _ensureError,
    );
  }
}
