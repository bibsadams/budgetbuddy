import 'dart:ui';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'features/custom_tabs/custom_tab_page.dart';
import 'package:hive/hive.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'services/auth_service.dart';

import 'services/shared_account_repository.dart';
import 'services/local_receipt_service.dart';
import 'services/receipt_backup_service.dart';
import 'services/android_downloads_service.dart';
import 'package:file_picker/file_picker.dart';
import 'features/home/home_tab.dart';
import 'features/expenses/expenses_tab.dart';
import 'features/savings/savings_tab.dart';
import 'features/or/or_tab.dart';
import 'features/bills/bills_tab.dart';
import 'features/report/report_tab.dart';
import 'manage_accounts_page.dart';
import 'join_requests_page.dart';
import 'widgets/app_gradient_background.dart';
import 'features/categories/categories_manager_page.dart';
import 'services/notification_service.dart';

class MainTabsPage extends StatefulWidget {
  final String accountId;
  const MainTabsPage({super.key, required this.accountId});

  @override
  State<MainTabsPage> createState() => _MainTabsPageState();
}

class _MainTabsPageState extends State<MainTabsPage> {
  // Data/state
  late final Box box;
  SharedAccountRepository? _repo;
  // Cloud warning banner suppressed by requirements

  // Streams
  Stream<List<Map<String, dynamic>>>? _expenses$;
  Stream<List<Map<String, dynamic>>>? _savings$;
  Stream<List<Map<String, dynamic>>>? _bills$;
  Stream<List<Map<String, dynamic>>>? _or$;
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
  final Map<String, String> _localReceiptPathsOr = {};

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
  // Dynamic custom tabs
  List<Map<String, String>> _customTabs = const []; // [{id, title}]
  final List<ScrollController> _customScrolls = [];
  StreamSubscription? _customTabsSub;
  String?
  _pendingNavigateCustomTabId; // Navigate to this custom tab when it appears
  Map<String, dynamic>? _accountDoc;
  // Multi-account
  List<String> _linkedAccounts = const [];
  Map<String, String> _accountAliases = const {};
  // One-time migration flags
  bool _billsMigrated = false; // per-account flag read from Hive
  // Debounced autosave on global taps
  Timer? _tapAutosave;
  // Realtime linked accounts for Switch/Manage
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _accMemberSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _accOwnerSub;
  final Set<String> _accMemberIds = {};
  final Set<String> _accOwnerIds = {};
  // no longer store uid locally; we don't overwrite per-user Hive keys from live sync
  StreamSubscription<String>? _notifTapSub;
  void _scheduleTapAutosave() {
    _tapAutosave?.cancel();
    _tapAutosave = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _saveLocalOnly();
    });
  }

  // Aggregate accounts for UI display without mutating persisted per-user lists.
  // Union of:
  // - per-user saved list (base)
  // - live Firestore membership/owner sets
  // - device-known cache (best-effort)
  // Ensures current active account is included.
  List<String> _aggregateAccountsForUi(List<String> base) {
    final set = <String>{...base.whereType<String>()};
    // Add live membership/owner ids (if streams are active)
    set.addAll(_accMemberIds);
    set.addAll(_accOwnerIds);
    // Add device-wide known accounts as a soft fallback
    try {
      final dev = box.get('linkedAccounts_device');
      if (dev is List && dev.isNotEmpty) {
        set.addAll(dev.whereType<String>());
      }
    } catch (_) {}
    // Ensure current active account is present
    if (widget.accountId.isNotEmpty) set.add(widget.accountId);
    final list = set.toList()..sort();
    return list;
  }

  @override
  void initState() {
    super.initState();
    box = Hive.box('budgetBox');
    _initShared();
    _pageController = PageController(initialPage: _index);
    _notifTapSub = NotificationService().onNotificationTap.listen(
      _handleNotificationTap,
    );
    // Also handle the case when app is launched from a terminated state
    // by consuming any pending initial payload after a short delay.
    Future.delayed(const Duration(milliseconds: 300), () {
      final p = NotificationService().consumeInitialLaunchPayload();
      if (p != null && p.isNotEmpty) _handleNotificationTap(p);
    });
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
      // Merge in any existing local ReceiptUids/LocalReceiptPath so we don't
      // accidentally drop multi-image metadata when replacing the list.
      if (collection == 'expenses') {
        tableData['Expenses'] = _mergeLocalReceiptsInto('expenses', desired);
      } else {
        tableData['Savings'] = _mergeLocalReceiptsInto('savings', desired);
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

    // Bills: keep a per-account offline store
    final offlineBills = box.get('offline_bills_${widget.accountId}') as List?;
    if (offlineBills != null) {
      tableData['Bills'] = offlineBills
          .whereType<Map>()
          .map<Map<String, dynamic>>(
            (m) => m.map((k, v) => MapEntry(k.toString(), v)),
          )
          .toList();
    } else {
      tableData['Bills'] = [];
    }

    // OR: keep a per-account offline store; migrate from legacy tableData if needed
    List? offlineOr = box.get('offline_or_${widget.accountId}') as List?;
    if (offlineOr == null || offlineOr.isEmpty) {
      final legacyOr = (rawTableData?["OR"]) as List?; // from older builds
      if (legacyOr is List && legacyOr.isNotEmpty) {
        // Normalize and persist to new per-account key
        final normalized = legacyOr
            .whereType<Map>()
            .map<Map<String, dynamic>>(
              (m) => m.map((k, v) => MapEntry(k.toString(), v)),
            )
            .toList();
        tableData['OR'] = normalized;
        box.put('offline_or_${widget.accountId}', normalized);
      } else {
        tableData['OR'] = [];
      }
    } else {
      tableData['OR'] = offlineOr
          .whereType<Map>()
          .map<Map<String, dynamic>>(
            (m) => m.map((k, v) => MapEntry(k.toString(), v)),
          )
          .toList();
    }

    // Load OR local receipt preview paths map and overlay into rows
    final lrOr = box.get('localReceipts_or_${widget.accountId}') as Map?;
    _localReceiptPathsOr.clear();
    if (lrOr != null) {
      lrOr.forEach((k, v) => _localReceiptPathsOr[k.toString()] = v.toString());
    }
    final orList = List<Map<String, dynamic>>.from(tableData['OR'] ?? []);
    for (int i = 0; i < orList.length; i++) {
      final id = (orList[i]['id'] ?? '').toString();
      final p = _localReceiptPathsOr[id];
      if (p != null && p.isNotEmpty) {
        orList[i] = {...orList[i], 'LocalReceiptPath': p};
      }
    }
    tableData['OR'] = _mergeLocalReceiptsIntoOr(orList);

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
    tableData['Expenses'] = _mergeLocalReceiptsInto('expenses', expList);

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
    // Load custom tabs list per account
    final rawCustomTabs = box.get('customTabs_${widget.accountId}') as List?;
    if (rawCustomTabs is List) {
      _customTabs = rawCustomTabs
          .whereType<Map>()
          .map((m) => m.map((k, v) => MapEntry(k.toString(), v.toString())))
          .map<Map<String, String>>(
            (m) => {
              'id': (m['id'] ?? '').toString(),
              'title': (m['title'] ?? 'New Tab').toString(),
            },
          )
          .where((m) => (m['id'] ?? '').isNotEmpty)
          .toList();
    } else {
      _customTabs = const [];
    }
    _ensureCustomScrolls();
  }

  void _saveLocalOnly() {
    // Only persist local-only sections
    final tb = Map<String, List<Map<String, dynamic>>>.from(tableData);
    tb.remove('Expenses');
    tb.remove('Savings');
    tb.remove('Report');
    tb.remove('Bills');
    tb.remove('OR');
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
    box.put('localReceipts_or_${widget.accountId}', _localReceiptPathsOr);
    // Persist Bills per account
    box.put(
      'offline_bills_${widget.accountId}',
      tableData['Bills'] ?? <Map<String, dynamic>>[],
    );
    // Persist OR per account
    box.put(
      'offline_or_${widget.accountId}',
      tableData['OR'] ?? <Map<String, dynamic>>[],
    );
    // Persist Custom Tabs list per account
    box.put('customTabs_${widget.accountId}', _customTabs);
  }

  void _initShared() {
    _loadLocalOnly();
    // Load linked accounts list from Hive for account switcher
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return; // guarded by login flow
    // uid available from FirebaseAuth.instance.currentUser; no local field needed
    // Use per-user keys with migration from legacy globals
    final uid = user.uid;
    final linkedKey = 'linkedAccounts_$uid';
    final aliasesKey = 'accountAliases_$uid';
    final laUser = box.get(linkedKey);
    if (laUser is List && laUser.isNotEmpty) {
      _linkedAccounts = laUser.whereType<String>().toList();
    } else {
      // Migrate from legacy global if present
      final laLegacy = box.get('linkedAccounts');
      if (laLegacy is List && laLegacy.isNotEmpty) {
        _linkedAccounts = laLegacy.whereType<String>().toList();
        box.put(linkedKey, _linkedAccounts);
      }
      // Fallback: ensure at least the currently active account is present locally
      if ((_linkedAccounts.isEmpty) && (widget.accountId.isNotEmpty)) {
        _linkedAccounts = [widget.accountId];
        box.put(linkedKey, _linkedAccounts);
      }
      // Do NOT aggregate other users' lists here; keep per-user only.
    }
    // Update device-wide known accounts set (never cleared on sign-out)
    final deviceKey = 'linkedAccounts_device';
    final deviceVal = box.get(deviceKey);
    final deviceSet = <String>{
      ..._linkedAccounts,
      if (deviceVal is List) ...deviceVal.whereType<String>(),
    };
    if (deviceSet.isNotEmpty) {
      box.put(deviceKey, deviceSet.toList()..sort());
    }
    final aliasesUser = box.get(aliasesKey);
    if (aliasesUser is Map && aliasesUser.isNotEmpty) {
      _accountAliases = aliasesUser.map(
        (k, v) => MapEntry(k.toString(), v.toString()),
      );
    } else {
      final aliasesLegacy = box.get('accountAliases');
      if (aliasesLegacy is Map && aliasesLegacy.isNotEmpty) {
        _accountAliases = aliasesLegacy.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        );
        box.put(aliasesKey, _accountAliases);
      }
    }
    _repo = SharedAccountRepository(accountId: widget.accountId, uid: user.uid);
    _expenses$ = _repo!.expensesStream();
    _savings$ = _repo!.savingsStream();
    _or$ = _repo!.orStream();
    _bills$ = _repo!.billsStream();
    _meta$ = _repo!.metaStream();
    _account$ = _repo!.accountStream();
    _account$!.listen((doc) => setState(() => _accountDoc = doc ?? {}));

    // Start custom tabs sync (fallback to cached if stream fails)
    _customTabsSub?.cancel();
    _customTabsSub = _repo!.customTabsStream().listen(
      (rows) {
        final tabs = rows
            .map(
              (r) => {
                'id': (r['id'] ?? '').toString(),
                'title': (r['title'] ?? 'Tab').toString(),
              },
            )
            .where((m) => (m['id'] ?? '').isNotEmpty)
            .toList();
        setState(() {
          _customTabs = tabs;
          _ensureCustomScrolls();
        });
        box.put('customTabs_${widget.accountId}', tabs);

        // If we just created a tab, navigate to it once it appears in the stream
        if (_pendingNavigateCustomTabId != null) {
          final idx = tabs.indexWhere(
            (t) => t['id'] == _pendingNavigateCustomTabId,
          );
          if (idx >= 0) {
            // Base pages count = 6 (Home, Expenses, Savings, Bills, OR, Report)
            final target = 6 + idx;
            _pageController.animateToPage(
              target,
              duration: const Duration(milliseconds: 360),
              curve: Curves.easeOutCubic,
            );
            _pendingNavigateCustomTabId = null;
          }
        }
      },
      onError: (_) {
        // keep local cache if stream errors
      },
    );

    // use class method _refreshLinkedAccountsCache()

    // Live-sync linked accounts list for Switch/Manage (auto-add when approved)
    final db = FirebaseFirestore.instance;
    _accMemberSub?.cancel();
    _accOwnerSub?.cancel();
    _accMemberSub = db
        .collection('accounts')
        .where('members', arrayContains: user.uid)
        .snapshots()
        .listen((qs) {
          _accMemberIds
            ..clear()
            ..addAll(qs.docs.map((d) => d.id));
          _refreshLinkedAccountsCache();
        });
    _accOwnerSub = db
        .collection('accounts')
        .where('createdBy', isEqualTo: user.uid)
        .snapshots()
        .listen((qs) {
          _accOwnerIds
            ..clear()
            ..addAll(qs.docs.map((d) => d.id));
          _refreshLinkedAccountsCache();
        });

    // Listen and integrate into tableData in-memory
    _expenses$!.listen((remoteRows) {
      if (remoteRows.isEmpty) {
        return; // keep offline data if backend emits nothing
      }
      debugPrint(
        'expenses stream: remoteRows.len=${remoteRows.length}, ids=${remoteRows.map((r) => (r['id'] ?? '').toString()).toList()}',
      );
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
          debugPrint(
            'expenses stream: remote id=$id, remoteHash=$remoteHash, matchedLocal=${match != null}',
          );
          if (match != null) {
            final localId = (match['id'] ?? '').toString();
            final localPath = _localReceiptPathsExpenses[localId];
            // Also migrate any ReceiptUids that the provisional local row may have
            final provisionalUids = (match['ReceiptUids'] is List)
                ? List<String>.from(match['ReceiptUids'] as List)
                : <String>[];
            // DEBUG: log provisional UIDs when present
            if (provisionalUids.isNotEmpty) {
              debugPrint(
                'expenses stream: provisionalUids for localId=$localId -> $provisionalUids',
              );
            }
            if (localPath != null && localPath.isNotEmpty) {
              // Migrate mapping key from provisional -> remote id
              _localReceiptPathsExpenses.remove(localId);
              _localReceiptPathsExpenses[id] = localPath;
              debugPrint(
                'expenses stream: migrated LocalReceiptPath from $localId to $id (path=$localPath)',
              );
              out = {
                ...r,
                'LocalReceiptPath': localPath,
                'clientHash': remoteHash,
              };
              // If remote row doesn't include ReceiptUids but provisional had them,
              // carry them forward so the gallery can resolve them to local files.
              if ((out['ReceiptUids'] == null ||
                      (out['ReceiptUids'] is! List) ||
                      (out['ReceiptUids'] as List).isEmpty) &&
                  provisionalUids.isNotEmpty) {
                out['ReceiptUids'] = provisionalUids;
                debugPrint(
                  'expenses stream: carried provisional ReceiptUids into remote id=$id -> ${out['ReceiptUids']}',
                );
              }
              consumedLocalIds.add(localId);
              // Ensure this provisional match is not reused for other remote rows with the same clientHash
              localProvisionalByHash.remove(remoteHash);
              debugPrint(
                'expenses stream: removed provisional match for localId=$localId clientHash=$remoteHash',
              );
            } else {
              // Even if no LocalReceiptPath, we still want to carry through ReceiptUids
              if (provisionalUids.isNotEmpty) {
                out = {
                  ...r,
                  'clientHash': remoteHash,
                  if (provisionalUids.isNotEmpty)
                    'ReceiptUids': provisionalUids,
                };
                debugPrint(
                  'expenses stream: carried provisional ReceiptUids (no LocalReceiptPath) into remote id=$id -> ${out['ReceiptUids']}',
                );
              }
              consumedLocalIds.add(localId);
              // Ensure this provisional match is not reused for other remote rows with the same clientHash
              localProvisionalByHash.remove(remoteHash);
              debugPrint(
                'expenses stream: removed provisional match for localId=$localId clientHash=$remoteHash (no LocalReceiptPath)',
              );
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
      // Deduplicate: if a provisional local row (id local_ or empty) and a remote row
      // share the same clientHash, keep the remote and drop the provisional to avoid duplicates
      final uniqValues = uniq.values.toList();
      final remoteByCh = <String, Map<String, dynamic>>{};
      for (final r in uniqValues) {
        final id = (r['id'] ?? '').toString();
        final ch = (r['clientHash'] as String?) ?? _clientHash(r);
        if (ch.isEmpty) continue;
        final isLocal = id.isEmpty || id.startsWith('local_');
        if (!isLocal && !remoteByCh.containsKey(ch)) {
          remoteByCh[ch] = r;
        }
      }
      final dedupedExpenses = uniqValues.where((r) {
        final id = (r['id'] ?? '').toString();
        final ch = (r['clientHash'] as String?) ?? _clientHash(r);
        final isLocal = id.isEmpty || id.startsWith('local_');
        return !(isLocal && ch.isNotEmpty && remoteByCh.containsKey(ch));
      }).toList();

      setState(() {
        tableData['Expenses'] = _mergeLocalReceiptsInto(
          'expenses',
          dedupedExpenses,
        );
      });
      _saveLocalOnly();
    });

    // OR remote sync: merge remote with any local-only rows then persist offline snapshot
    _or$!.listen((remoteRows) {
      final remote = List<Map<String, dynamic>>.from(remoteRows);
      final local = List<Map<String, dynamic>>.from(tableData['OR'] ?? []);
      final remoteById = {
        for (final r in remote)
          if ((r['id'] ?? '').toString().isNotEmpty) (r['id'] as String): r,
      };
      // Overlay local preview paths and carry forward ReceiptUids if remote lacks them
      final mergedRemote = <Map<String, dynamic>>[];
      final localById = {
        for (final r in local)
          if ((r['id'] ?? '').toString().isNotEmpty) (r['id'] as String): r,
      };
      for (final r in remote) {
        final id = (r['id'] ?? '').toString();
        Map<String, dynamic> out = r;
        final p = _localReceiptPathsOr[id];
        if (p != null && p.isNotEmpty) {
          out = {...out, 'LocalReceiptPath': p};
        }
        final l = localById[id];
        if ((out['ReceiptUids'] == null ||
                (out['ReceiptUids'] is List &&
                    (out['ReceiptUids'] as List).isEmpty)) &&
            l != null &&
            l['ReceiptUids'] is List &&
            (l['ReceiptUids'] as List).isNotEmpty) {
          out = {...out, 'ReceiptUids': List<String>.from(l['ReceiptUids'])};
        }
        mergedRemote.add(out);
      }
      // Keep local-only (no id or id not in remote)
      final extras = local.where((r) {
        final id = (r['id'] ?? '').toString();
        return id.isEmpty || !remoteById.containsKey(id);
      });
      final merged = [...mergedRemote, ...extras];
      setState(() {
        tableData['OR'] = _mergeLocalReceiptsIntoOr(merged);
      });
      try {
        box.put('offline_or_${widget.accountId}', tableData['OR']);
      } catch (_) {}
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
            final provisionalUids = (match['ReceiptUids'] is List)
                ? List<String>.from(match['ReceiptUids'] as List)
                : <String>[];
            if (localPath != null && localPath.isNotEmpty) {
              _localReceiptPathsSavings.remove(localId);
              _localReceiptPathsSavings[id] = localPath;
              out = {
                ...r,
                'LocalReceiptPath': localPath,
                'clientHash': remoteHash,
              };
              if ((out['ReceiptUids'] == null ||
                      (out['ReceiptUids'] is! List) ||
                      (out['ReceiptUids'] as List).isEmpty) &&
                  provisionalUids.isNotEmpty) {
                out['ReceiptUids'] = provisionalUids;
              }
              consumedLocalIds.add(localId);
              // Ensure this provisional match is not reused for other remote rows with the same clientHash
              localProvisionalByHash.remove(remoteHash);
              debugPrint(
                'savings stream: removed provisional match for localId=$localId clientHash=$remoteHash',
              );
            } else {
              if (provisionalUids.isNotEmpty) {
                out = {
                  ...r,
                  'clientHash': remoteHash,
                  if (provisionalUids.isNotEmpty)
                    'ReceiptUids': provisionalUids,
                };
              }
              consumedLocalIds.add(localId);
              // Ensure this provisional match is not reused for other remote rows with the same clientHash
              localProvisionalByHash.remove(remoteHash);
              debugPrint(
                'savings stream: removed provisional match for localId=$localId clientHash=$remoteHash (no LocalReceiptPath)',
              );
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
      // Deduplicate Savings similarly by clientHash
      final uniqSavings = uniq.values.toList();
      final remoteSavingsByCh = <String, Map<String, dynamic>>{};
      for (final r in uniqSavings) {
        final id = (r['id'] ?? '').toString();
        final ch = (r['clientHash'] as String?) ?? _clientHash(r);
        if (ch.isEmpty) continue;
        final isLocal = id.isEmpty || id.startsWith('local_');
        if (!isLocal && !remoteSavingsByCh.containsKey(ch)) {
          remoteSavingsByCh[ch] = r;
        }
      }
      final dedupedSavings = uniqSavings.where((r) {
        final id = (r['id'] ?? '').toString();
        final ch = (r['clientHash'] as String?) ?? _clientHash(r);
        final isLocal = id.isEmpty || id.startsWith('local_');
        return !(isLocal && ch.isNotEmpty && remoteSavingsByCh.containsKey(ch));
      }).toList();

      setState(() {
        tableData['Savings'] = _mergeLocalReceiptsInto(
          'savings',
          dedupedSavings,
        );
      });
      _saveLocalOnly();
    });
    // Initialize per-account migrated flag
    _billsMigrated =
        (box.get('bills_migrated_${widget.accountId}') as bool?) ?? false;

    _bills$!.listen((remoteRows) async {
      if (remoteRows.isEmpty) {
        // Optional one-time migration per-account (safe now that Bills are scoped per account)
        if (!_billsMigrated) {
          final localBills = List<Map<String, dynamic>>.from(
            tableData['Bills'] ?? const <Map<String, dynamic>>[],
          );
          if (localBills.isNotEmpty && _repo != null) {
            try {
              for (final b in localBills) {
                final id = (b['id'] ?? '').toString();
                await _repo!.addBill(b, withId: id.isEmpty ? null : id);
              }
              _billsMigrated = true;
              box.put('bills_migrated_${widget.accountId}', true);
            } catch (e) {
              _showCloudWarning(e);
            }
          }
        }
        return;
      }
      setState(() {
        tableData['Bills'] = remoteRows;
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

  void _ensureCustomScrolls() {
    // Keep one scroll controller per custom tab
    while (_customScrolls.length < _customTabs.length) {
      _customScrolls.add(ScrollController());
    }
    while (_customScrolls.length > _customTabs.length) {
      final c = _customScrolls.removeLast();
      c.dispose();
    }
  }

  void _refreshLinkedAccountsCache() {
    // Do not overwrite the user's curated list in Hive. We only update
    // in-memory membership sets via _accMemberIds/_accOwnerIds (already set
    // by callers) and let _aggregateAccountsForUi() compute the union.
    // Trigger a rebuild to reflect new union in Switch/Manage.
    if (!mounted) return;
    setState(() {});
    // Optionally refresh device-known cache as a soft superset for UI.
    try {
      final devKey = 'linkedAccounts_device';
      final dev = box.get(devKey);
      final union = <String>{
        ..._linkedAccounts,
        ..._accMemberIds,
        ..._accOwnerIds,
        if (dev is List) ...dev.whereType<String>(),
      };
      if (union.isNotEmpty) {
        box.put(devKey, union.toList()..sort());
      }
    } catch (_) {}
  }

  // Merge helper: given an incoming list of rows for a collection, preserve any
  // existing LocalReceiptPath and ReceiptUids that we have cached locally so
  // that replacing the entire list won't drop multi-image metadata.
  List<Map<String, dynamic>> _mergeLocalReceiptsInto(
    String collection,
    List<Map<String, dynamic>> incoming,
  ) {
    final out = <Map<String, dynamic>>[];
    final localMap = collection == 'expenses'
        ? _localReceiptPathsExpenses
        : _localReceiptPathsSavings;
    // Build a quick lookup from existing tableData (previous entries)
    final existing = Map<String, Map<String, dynamic>>.fromEntries(
      (tableData[collection == 'expenses' ? 'Expenses' : 'Savings'] ?? [])
          .where((e) => (e['id'] ?? '').toString().isNotEmpty)
          .map((e) => MapEntry((e['id'] as String).toString(), e)),
    );

    for (final r in incoming) {
      final id = (r['id'] ?? '').toString();
      var merged = Map<String, dynamic>.from(r);
      // Prefer explicit LocalReceiptPath in the incoming row; otherwise overlay
      // from our local cache.
      if ((merged['LocalReceiptPath'] == null ||
              (merged['LocalReceiptPath'] as String).isEmpty) &&
          localMap.containsKey(id)) {
        merged['LocalReceiptPath'] = localMap[id];
      }
      // Preserve previous ReceiptUids unless the caller is explicitly signaling
      // a full removal. We consider it a removal only when ALL attachment fields
      // are cleared (no LocalReceiptPath, no URLs, no bytes) AND the caller
      // explicitly provided an empty ReceiptUids list.
      final providesUids = merged.containsKey('ReceiptUids');
      final uidsIsList = merged['ReceiptUids'] is List;
      final explicitEmptyUids =
          providesUids && uidsIsList && (merged['ReceiptUids'] as List).isEmpty;
      final hasBytes =
          merged['Receipt'] is Uint8List ||
          (merged['ReceiptBytes'] is List &&
              (merged['ReceiptBytes'] as List).isNotEmpty);
      final hasLocalPath = ((merged['LocalReceiptPath'] ?? '') as String)
          .toString()
          .isNotEmpty;
      final hasUrl = ((merged['ReceiptUrl'] ?? '') as String)
          .toString()
          .isNotEmpty;
      final urlsLen = (merged['ReceiptUrls'] is List)
          ? (merged['ReceiptUrls'] as List).length
          : 0;
      final isRemovalIntent =
          explicitEmptyUids &&
          !hasBytes &&
          !hasLocalPath &&
          !hasUrl &&
          urlsLen == 0;

      // Preserve previous UIDs if:
      // - caller did not provide ReceiptUids at all, or
      // - caller provided an empty list but it isn't a true removal intent (e.g. append flow)
      final shouldPreservePrevUids =
          (!providesUids ||
          !uidsIsList ||
          (explicitEmptyUids && !isRemovalIntent));

      if (shouldPreservePrevUids && existing.containsKey(id)) {
        final prev = existing[id]!;
        if (prev['ReceiptUids'] is List &&
            (prev['ReceiptUids'] as List).isNotEmpty) {
          merged['ReceiptUids'] = List<String>.from(
            prev['ReceiptUids'] as List,
          );
        } else if ((prev['ReceiptUid'] ?? '').toString().isNotEmpty) {
          merged['ReceiptUids'] = [(prev['ReceiptUid'] ?? '').toString()];
        }
      }
      out.add(merged);
    }
    try {
      final preservedCount = out
          .where(
            (r) =>
                r['ReceiptUids'] is List &&
                (r['ReceiptUids'] as List).isNotEmpty,
          )
          .length;
      final localPathCount = out
          .where((r) => (r['LocalReceiptPath'] ?? '').toString().isNotEmpty)
          .length;
      debugPrint(
        'mergeLocalReceiptsInto: collection=$collection incoming=${incoming.length} out=${out.length} preservedReceiptRows=$preservedCount localPathRows=$localPathCount',
      );
    } catch (_) {}
    return out;
  }

  // OR-specific merge: overlay LocalReceiptPath from cache and preserve ReceiptUids
  List<Map<String, dynamic>> _mergeLocalReceiptsIntoOr(
    List<Map<String, dynamic>> incoming,
  ) {
    final out = <Map<String, dynamic>>[];
    final existing = Map<String, Map<String, dynamic>>.fromEntries(
      (tableData['OR'] ?? [])
          .where((e) => (e['id'] ?? '').toString().isNotEmpty)
          .map((e) => MapEntry((e['id'] as String).toString(), e)),
    );
    for (final r in incoming) {
      final id = (r['id'] ?? '').toString();
      var merged = Map<String, dynamic>.from(r);
      // Overlay preview path from cache when not provided
      final hasPath = ((merged['LocalReceiptPath'] ?? '') as String)
          .toString()
          .isNotEmpty;
      if (!hasPath && _localReceiptPathsOr.containsKey(id)) {
        merged['LocalReceiptPath'] = _localReceiptPathsOr[id];
      }
      // Preserve prior ReceiptUids unless explicitly cleared with an empty list and no other attachments
      final providesUids = merged.containsKey('ReceiptUids');
      final uidsIsList = merged['ReceiptUids'] is List;
      final explicitEmpty =
          providesUids && uidsIsList && (merged['ReceiptUids'] as List).isEmpty;
      final hasAnyAttach =
          ((merged['LocalReceiptPath'] ?? '') as String)
              .toString()
              .isNotEmpty ||
          ((merged['ReceiptUrl'] ?? '') as String).toString().isNotEmpty ||
          (merged['ReceiptUrls'] is List &&
              (merged['ReceiptUrls'] as List).isNotEmpty) ||
          (merged['Receipt'] is Uint8List) ||
          (merged['ReceiptBytes'] is List &&
              (merged['ReceiptBytes'] as List).isNotEmpty);
      final removalIntent = explicitEmpty && !hasAnyAttach;
      if (!removalIntent && existing.containsKey(id)) {
        final prev = existing[id]!;
        if (prev['ReceiptUids'] is List &&
            (prev['ReceiptUids'] as List).isNotEmpty &&
            (!providesUids || !uidsIsList || explicitEmpty)) {
          merged['ReceiptUids'] = List<String>.from(
            prev['ReceiptUids'] as List,
          );
        }
      }
      out.add(merged);
    }
    return out;
  }

  // Immediately persist attachment for a newly added row at a known index.
  Future<Map<String, dynamic>?> _saveNewRowAttachmentImmediately({
    required String collection, // 'expenses' | 'savings'
    required int index,
  }) async {
    final list = List<Map<String, dynamic>>.from(
      tableData[collection == 'expenses' ? 'Expenses' : 'Savings'] ?? [],
    );
    if (index < 0 || index >= list.length) return null;
    final item = Map<String, dynamic>.from(list[index]);
    // Support both legacy single 'Receipt' (Uint8List) and new 'ReceiptBytes' (List<Uint8List>)
    final hasSingleBytes =
        item['Receipt'] != null && item['Receipt'] is Uint8List;
    final hasMultiBytes =
        item['ReceiptBytes'] != null &&
        item['ReceiptBytes'] is List &&
        (item['ReceiptBytes'] as List).isNotEmpty;
    if (!hasSingleBytes && !hasMultiBytes) return null;

    // Assign a local id if absent
    String id = (item['id'] as String?) ?? '';
    if (id.isEmpty) {
      id = 'local_${DateTime.now().millisecondsSinceEpoch}';
    }

    try {
      // Persist one or multiple receipt bytes locally and assign stable receipt UIDs
      final LocalReceiptService lrs = LocalReceiptService();
      List<String> savedPaths = [];
      List<String> savedUids = [];
      if (hasMultiBytes) {
        final List raw = item['ReceiptBytes'] as List;
        for (int i = 0; i < raw.length; i++) {
          final bytes = raw[i];
          if (bytes is! Uint8List) continue;
          String receiptUid = _genReceiptUid();
          final path = await lrs.saveReceipt(
            accountId: widget.accountId,
            collection: collection,
            docId: id,
            bytes: bytes,
            receiptUid: receiptUid,
          );
          // DEBUG: log exactly where each receipt UID was saved
          try {
            debugPrint(
              'savedReceipt: receiptUid=$receiptUid path=$path docId=$id collection=$collection accountId=${widget.accountId}',
            );
          } catch (_) {}
          savedPaths.add(path);
          savedUids.add(receiptUid);
        }
        if (savedUids.isNotEmpty) item['ReceiptUids'] = savedUids;
        // Prevent later duplicate processing during creation flow
        item.remove('ReceiptBytes');
      } else if (hasSingleBytes) {
        String receiptUid = (item['ReceiptUid'] ?? item['receiptUid'] ?? '')
            .toString();
        if (receiptUid.isEmpty) {
          receiptUid = _genReceiptUid();
          item['ReceiptUid'] = receiptUid;
        }
        final path = await lrs.saveReceipt(
          accountId: widget.accountId,
          collection: collection,
          docId: id,
          bytes: item['Receipt'] as Uint8List,
          receiptUid: receiptUid,
        );
        // DEBUG: log exactly where the single receipt UID was saved
        try {
          debugPrint(
            'savedReceipt: receiptUid=$receiptUid path=$path docId=$id collection=$collection accountId=${widget.accountId}',
          );
        } catch (_) {}
        savedPaths.add(path);
        savedUids.add(receiptUid);
      }

      // Update maps and row in-place for immediate UI
      // Store the first path in the local path map for immediate UI display
      final firstPath = savedPaths.isNotEmpty ? savedPaths.first : null;
      if (collection == 'expenses') {
        if (firstPath != null) _localReceiptPathsExpenses[id] = firstPath;
      } else {
        if (firstPath != null) _localReceiptPathsSavings[id] = firstPath;
      }
      final ch = (item['clientHash'] as String?) ?? _clientHash(item);
      list[index] = {
        ...item,
        'id': id,
        if (firstPath != null) 'LocalReceiptPath': firstPath,
        if (savedUids.isNotEmpty) 'ReceiptUids': savedUids,
        // Backwards-compat: populate single legacy fields from first item
        if (savedUids.isNotEmpty) 'ReceiptUid': savedUids.first,
        'clientHash': ch,
      };
      // DEBUG: provisional creation event
      if (savedUids.isNotEmpty) {
        debugPrint(
          'provisionalCreated: localId=$id path=$firstPath ReceiptUids=$savedUids',
        );
      } else {
        debugPrint(
          'provisionalCreated: localId=$id path=$firstPath ReceiptUid=${(list[index]['ReceiptUid'] ?? '')}',
        );
      }
      setState(() {
        if (collection == 'expenses') {
          tableData['Expenses'] = _mergeLocalReceiptsInto('expenses', list);
        } else {
          tableData['Savings'] = _mergeLocalReceiptsInto('savings', list);
        }
      });
      _saveLocalOnly();
      return {'id': id, 'path': firstPath ?? '', 'uids': savedUids};
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
          tableData['Expenses'] = _mergeLocalReceiptsInto('expenses', list);
        } else {
          tableData['Savings'] = _mergeLocalReceiptsInto('savings', list);
        }
      });
      _saveLocalOnly();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Base pages
    final basePages = <Widget>[
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
        controller: _billsScroll, // reuse scroll controller for now
        child: _buildOrPage(),
      ),
      PrimaryScrollController(
        controller: _reportScroll,
        child: _buildReportPage(),
      ),
    ];
    // Dynamic custom tab pages inserted after Report
    final customPages = <Widget>[
      for (int i = 0; i < _customTabs.length; i++)
        PrimaryScrollController(
          controller: _customScrolls[i],
          child: CustomTabPageHost(
            accountId: widget.accountId,
            tabId: _customTabs[i]['id']!,
            title: _customTabs[i]['title']!,
          ),
        ),
    ];
    final pages = <Widget>[
      ...basePages,
      ...customPages,
      PrimaryScrollController(
        controller: _settingsScroll,
        child: _buildSettingsPage(),
      ),
    ];

    final baseDestinations = const <NavigationDestination>[
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
        icon: Icon(Icons.account_balance_wallet_outlined),
        selectedIcon: Icon(Icons.account_balance_wallet),
        label: 'OR',
      ),
      NavigationDestination(
        icon: Icon(Icons.pie_chart_outline),
        selectedIcon: Icon(Icons.pie_chart),
        label: 'Report',
      ),
    ];
    final customDestinations = <NavigationDestination>[
      for (final t in _customTabs)
        NavigationDestination(
          icon: const Icon(Icons.tab_outlined),
          selectedIcon: const Icon(Icons.tab),
          label: t['title'] ?? 'Tab',
        ),
    ];
    final destinations = <NavigationDestination>[
      ...baseDestinations,
      ...customDestinations,
      const NavigationDestination(
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
                    final controllers = <ScrollController>[
                      _homeScroll,
                      _expensesScroll,
                      _savingsScroll,
                      _billsScroll,
                      _reportScroll,
                      ..._customScrolls,
                      _settingsScroll,
                    ];
                    if (i >= 0 && i < controllers.length) {
                      final ctrl = controllers[i];
                      if (ctrl.hasClients) {
                        ctrl.animateTo(
                          0,
                          duration: const Duration(milliseconds: 350),
                          curve: Curves.easeOutCubic,
                        );
                      }
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
    _customTabsSub?.cancel();
    _pageController.dispose();
    _homeScroll.dispose();
    _expensesScroll.dispose();
    _savingsScroll.dispose();
    _billsScroll.dispose();
    _reportScroll.dispose();
    _settingsScroll.dispose();
    _accMemberSub?.cancel();
    _accOwnerSub?.cancel();
    _notifTapSub?.cancel();
    super.dispose();
  }

  void _handleNotificationTap(String payload) {
    if (!payload.startsWith('bill:')) return;
    final token = payload.substring(5);
    // Navigate to Bills tab (index 3 in base pages)
    const billsPageIndex = 3;
    _pageController.animateToPage(
      billsPageIndex,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
    // After the page is visible, try to scroll to the bill entry
    Future.delayed(const Duration(milliseconds: 420), () {
      final rows = tableData['Bills'] ?? const <Map<String, dynamic>>[];
      if (rows.isEmpty) return;
      // Compute the same sorted order as BillsTab
      int group(Map<String, dynamic> r) {
        final enabled = r['Enabled'] == true;
        final repeatStr = (r['Repeat'] ?? 'None').toString();
        final isOneTimePaid = !enabled && repeatStr == 'None';
        final dueStr = (r['Due Date'] ?? '') as String;
        final hasDue = dueStr.isNotEmpty && DateTime.tryParse(dueStr) != null;
        if (isOneTimePaid) return 2;
        if (!hasDue) return 1;
        return 0;
      }

      int diffDays(Map<String, dynamic> r) {
        final dueStr = (r['Due Date'] ?? '') as String;
        final dt = DateTime.tryParse(dueStr);
        if (dt == null) return 1 << 20;
        final today = DateTime.now();
        final d0 = DateTime(today.year, today.month, today.day);
        final due0 = DateTime(dt.year, dt.month, dt.day);
        return due0.difference(d0).inDays;
      }

      final sorted = List<int>.generate(rows.length, (i) => i);
      sorted.sort((a, b) {
        final ra = rows[a];
        final rb = rows[b];
        final ga = group(ra);
        final gb = group(rb);
        if (ga != gb) return ga.compareTo(gb);
        if (ga == 0) {
          final da = diffDays(ra);
          final db = diffDays(rb);
          if (da != db) return da.compareTo(db);
        }
        final na = (ra['Name'] ?? '').toString().toLowerCase();
        final nb = (rb['Name'] ?? '').toString().toLowerCase();
        return na.compareTo(nb);
      });
      // Find original index by id/name, then map to sorted position
      int origIndex = -1;
      if (token.isNotEmpty) {
        origIndex = rows.indexWhere(
          (r) => (r['id']?.toString() ?? '') == token,
        );
        if (origIndex < 0) {
          final low = token.toLowerCase();
          origIndex = rows.indexWhere(
            (r) => (r['Name']?.toString().toLowerCase() ?? '') == low,
          );
        }
      }
      if (origIndex >= 0) {
        final targetIndex = sorted.indexOf(origIndex);
        if (targetIndex >= 0 && _billsScroll.hasClients) {
          const estimatedExtent = 84.0; // approximate row height
          final offset = (targetIndex * estimatedExtent).clamp(
            0.0,
            double.infinity,
          );
          _billsScroll.animateTo(
            offset,
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
          );
        }
      }
    });
  }

  void _showCloudWarning(Object e) {
    // Suppress cloud warning UI; keep silent to avoid blocking UX
    // ignore: avoid_print
    // print('Cloud sync error (suppressed): $e');
  }

  // _showCloudFixDialog removed per requirements

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
                  // Open inline add account flow; target account will be validated
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
        // Membership visibility note
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Icon(Icons.info_outline, size: 16),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'You\'ll see accounts you own or those shared with this Gmail. To add accounts from your other gmails, use Add Account and have the owner approve under Join requests.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        // Show Active account and Gmail directly under Account section
        Builder(
          builder: (context) {
            final ownerEmail =
                (_accountDoc?['createdByEmail'] as String?) ?? '';
            final email = ownerEmail.isNotEmpty
                ? ownerEmail
                : (FirebaseAuth.instance.currentUser?.email ?? '—');
            final activeAccountLabel =
                _accountAliases[widget.accountId] ?? widget.accountId;
            return ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text('Active account'),
              subtitle: Text('$activeAccountLabel\nGmail: $email'),
              isThreeLine: true,
            );
          },
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
            final uid = FirebaseAuth.instance.currentUser?.uid;
            final la = box.get(
              uid != null ? 'linkedAccounts_$uid' : 'linkedAccounts',
            );
            if (la is List) {
              setState(() => _linkedAccounts = la.whereType<String>().toList());
            }
            final aliases = box.get(
              uid != null ? 'accountAliases_$uid' : 'accountAliases',
            );
            if (aliases is Map) {
              setState(
                () => _accountAliases = aliases.map(
                  (k, v) => MapEntry(k.toString(), v.toString()),
                ),
              );
            }
          },
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'Custom tabs',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.add_to_photos_outlined),
          title: const Text('Add New Tab'),
          subtitle: const Text('Create a custom tab after Reports'),
          onTap: () async {
            String name = 'New Tab';
            await showDialog(
              context: context,
              builder: (d) => StatefulBuilder(
                builder: (ctx, setM) => AlertDialog(
                  title: const Text('Create New Tab'),
                  content: TextField(
                    decoration: const InputDecoration(
                      labelText: 'Tab name',
                      prefixIcon: Icon(Icons.tab_outlined),
                    ),
                    onChanged: (v) => name = v.trim(),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                      },
                      child: const Text('Create'),
                    ),
                  ],
                ),
              ),
            );
            if (name.isEmpty) name = 'New Tab';
            try {
              if (_repo == null) return;
              final id = await _repo!.addCustomTab(
                title: name,
                order: _customTabs.length,
              );
              if (!mounted) return;
              // Remember to navigate when the stream delivers the new tab
              _pendingNavigateCustomTabId = id;
              // Navigate once the stream pushes new list; optimistic fallback after short delay
              Future.delayed(const Duration(milliseconds: 300), () {
                if (!mounted) return;
                final idx = _customTabs.indexWhere((t) => t['id'] == id);
                // Base pages count = 6 (Home, Expenses, Savings, Bills, OR, Report)
                final baseCount = 6;
                final target = idx >= 0
                    ? (baseCount + idx)
                    : (baseCount + _customTabs.length);
                _pageController.animateToPage(
                  target,
                  duration: const Duration(milliseconds: 360),
                  curve: Curves.easeOutCubic,
                );
              });
            } catch (e) {
              if (!mounted) return;
              final msg = e.toString().contains('Maximum custom tabs')
                  ? 'Limit reached (10 custom tabs max)'
                  : 'Failed to create tab';
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(msg)));
            }
          },
        ),
        if (_customTabs.isNotEmpty) ...[
          for (int i = 0; i < _customTabs.length; i++)
            ListTile(
              leading: const Icon(Icons.tab),
              title: Text(_customTabs[i]['title'] ?? 'Tab'),
              // Removed ID and creator details per request
              subtitle: null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Rename',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () async {
                      String newName = _customTabs[i]['title'] ?? 'Tab';
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (d) => AlertDialog(
                          title: const Text('Rename Tab'),
                          content: TextField(
                            controller: TextEditingController(text: newName),
                            onChanged: (v) => newName = v.trim(),
                            decoration: const InputDecoration(
                              labelText: 'Tab name',
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(d).pop(false),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.of(d).pop(true),
                              child: const Text('Save'),
                            ),
                          ],
                        ),
                      );
                      if (!mounted) return;
                      if (ok == true) {
                        try {
                          if (_repo == null) return;
                          await _repo!.renameCustomTab(
                            _customTabs[i]['id']!,
                            newName.isEmpty ? 'Tab' : newName,
                          );
                        } catch (e) {
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Failed to rename: $e')),
                          );
                        }
                      }
                    },
                  ),
                  IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.redAccent,
                    ),
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (d) => AlertDialog(
                          title: const Text('Remove Tab'),
                          content: Text(
                            'Remove "${_customTabs[i]['title']}"? Records will be removed from cloud.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(d).pop(false),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.of(d).pop(true),
                              child: const Text('Remove'),
                            ),
                          ],
                        ),
                      );
                      if (!mounted) return;
                      if (ok == true) {
                        try {
                          if (_repo == null) return;
                          final removingId = _customTabs[i]['id']!;
                          await _repo!.deleteCustomTab(removingId);
                        } catch (e, st) {
                          if (!mounted) return;
                          debugPrint('Tab delete error: $e\n$st');
                          final es = e.toString();
                          final msg = es.contains('PERMISSION_DENIED')
                              ? 'Permission denied deleting tab.'
                              : 'Failed to remove tab';
                          final detail = es.length > 160
                              ? '${es.substring(0, 160)}…'
                              : es;
                          // Archive fallback: if permission denied on delete, try marking archived
                          if (es.contains('PERMISSION_DENIED')) {
                            final removingId = _customTabs[i]['id']!;
                            // First attempt: set createdBy to current uid if empty then retry delete
                            try {
                              final docRef = FirebaseFirestore.instance
                                  .collection('accounts')
                                  .doc(widget.accountId)
                                  .collection('customTabs')
                                  .doc(removingId);
                              final snap = await docRef.get();
                              final data = snap.data();
                              final currentUid =
                                  FirebaseAuth.instance.currentUser?.uid;
                              final tabCreator = data?['createdBy'];
                              final ownerUid = _accountDoc?['createdBy'];
                              final isOwner =
                                  ownerUid != null && currentUid == ownerUid;
                              final members =
                                  (_accountDoc?['members'] as List?)
                                      ?.map((e) => e.toString())
                                      .toList() ??
                                  const [];
                              final isMember =
                                  currentUid != null &&
                                  members.contains(currentUid);
                              final diag =
                                  'Delete denied. uid=$currentUid tab.createdBy=$tabCreator owner=$ownerUid isOwner=$isOwner isMember=$isMember archived=${data?['archived']}';
                              debugPrint(diag);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    diag.substring(
                                      0,
                                      diag.length.clamp(0, 180),
                                    ),
                                  ),
                                ),
                              );
                              if (currentUid != null &&
                                  (data?['createdBy'] == null ||
                                      (data?['createdBy'] as String).isEmpty)) {
                                await docRef.set({
                                  'createdBy': currentUid,
                                  'updatedAt': FieldValue.serverTimestamp(),
                                }, SetOptions(merge: true));
                                // Retry delete
                                try {
                                  await _repo!.deleteCustomTab(removingId);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Tab deleted after owner claim',
                                      ),
                                    ),
                                  );
                                  return;
                                } catch (re) {
                                  debugPrint('Retry delete failed: $re');
                                }
                              }
                            } catch (claimErr) {
                              debugPrint(
                                'Owner claim attempt failed: $claimErr',
                              );
                            }
                            // Second attempt: archive fallback
                            try {
                              await FirebaseFirestore.instance
                                  .collection('accounts')
                                  .doc(widget.accountId)
                                  .collection('customTabs')
                                  .doc(removingId)
                                  .set({
                                    'archived': true,
                                    'updatedAt': FieldValue.serverTimestamp(),
                                  }, SetOptions(merge: true));
                              setState(() {
                                _customTabs.removeWhere(
                                  (t) => t['id'] == removingId,
                                );
                              });
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Tab archived (hidden)'),
                                ),
                              );
                              return;
                            } catch (ae) {
                              debugPrint('Archive fallback failed: $ae');
                            }
                          }
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('$msg\n$detail')),
                          );
                        }
                      }
                    },
                  ),
                ],
              ),
            ),
        ],
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
          leading: const Icon(Icons.category_outlined),
          title: const Text('Categories'),
          subtitle: const Text('Browse categories and subcategories'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    CategoriesManagerPage(accountId: widget.accountId),
              ),
            );
          },
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
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('About'),
          subtitle: Text(
            'BudgetBuddy • v4.3.2\nDeveloper: Bryan L. Tejano\nGmail: bryantejano@gmail.com',
          ),
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
      // Zip and move to Downloads/BudgetBuddy
      final zipName =
          'bb_receipts_${widget.accountId}_${DateTime.now().millisecondsSinceEpoch}.zip';
      final zipped = await AndroidDownloadsService.zipToDownloads(
        sourceDir: dir,
        fileName: zipName,
      );
      if (!mounted) return;
      final path = zipped?.path ?? dir.path;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exported to Downloads/BudgetBuddy: $path')),
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
    // final cs = Theme.of(context).colorScheme; // no longer needed (icon removed)
    final list = _aggregateAccountsForUi(_linkedAccounts);
    // Prefetch owner emails (Gmails) for display
    final Map<String, String> emailMap = {};
    try {
      final futures = list.map((id) async {
        try {
          final snap = await FirebaseFirestore.instance
              .collection('accounts')
              .doc(id)
              .get();
          final data = snap.data();
          String email =
              (data != null ? (data['createdByEmail'] as String?) : null) ?? '';
          // Optional: if missing, attempt to read creator's member profile email
          if (email.isEmpty) {
            final createdBy = data != null
                ? (data['createdBy'] as String?)
                : null;
            if (createdBy != null && createdBy.isNotEmpty) {
              try {
                final mem = await FirebaseFirestore.instance
                    .collection('accounts')
                    .doc(id)
                    .collection('members')
                    .doc(createdBy)
                    .get();
                final md = mem.data();
                final mEmail = md != null ? (md['email'] as String?) : null;
                if (mEmail != null && mEmail.isNotEmpty) email = mEmail;
              } catch (_) {}
            }
          }
          emailMap[id] = email;
        } catch (_) {
          emailMap[id] = '';
        }
      }).toList();
      await Future.wait(futures);
    } catch (_) {}

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Switch account'),
        content: SizedBox(
          width: 360,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: list.length,
            itemBuilder: (c, i) {
              final id = list[i];
              final isActive = id == widget.accountId;
              return ListTile(
                title: Text(id),
                subtitle: (emailMap[id] != null && emailMap[id]!.isNotEmpty)
                    ? Text(emailMap[id]!)
                    : null,
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
                  hintText: 'BB-ABCD-1234',
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
                        // Validate account and require Joint Access on the TARGET account
                        final acc = await repo.getAccountOnce();
                        if (acc == null) throw 'Account not found';
                        final targetIsJoint =
                            (acc['isJoint'] as bool?) ?? false;
                        if (!targetIsJoint) {
                          setM(
                            () => error =
                                'This account is not Joint. Ask the owner to enable Joint Access.',
                          );
                          return;
                        }
                        final members = List<String>.from(acc['members'] ?? []);
                        final myUid = user.uid;
                        if (members.contains(myUid)) {
                          final setList = {..._linkedAccounts};
                          setList.add(id);
                          final arr = setList.toList();
                          final linkedKey = 'linkedAccounts_${user.uid}';
                          box.put(linkedKey, arr);
                          if (mounted) {
                            setState(() => _linkedAccounts = arr);
                          }
                          if (mounted) {
                            Navigator.of(ctx).pop();
                          }
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Already added in your account. Go to Settings → Switch account.',
                                ),
                              ),
                            );
                          }
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
                                final linkedKey = 'linkedAccounts_${user.uid}';
                                box.put(linkedKey, arr);
                                if (mounted) {
                                  setState(() => _linkedAccounts = arr);
                                }
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Access approved. "$id" added to Switch account.',
                                      ),
                                    ),
                                  );
                                }
                                await sub?.cancel();
                              }
                            });

                        if (mounted) Navigator.of(ctx).pop();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Request sent. Awaiting approval.'),
                              duration: Duration(seconds: 5),
                            ),
                          );
                        }
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
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      box.put('accountId_$uid', id);
    }
    // Keep legacy/global key for parts of the app that still read it
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
        // Debug: log incoming rows
        debugPrint(
          'Expenses.onRowsChanged called: prevLen=${rawRows.length}, newLen=${newRows.length}, ids=${newRows.map((r) => (r['id'] ?? '').toString()).toList()}',
        );
        // Ensure each incoming row has a clientHash for stable matching
        final normalized = newRows.map<Map<String, dynamic>>((r) {
          final item = Map<String, dynamic>.from(r);
          final ch = (item['clientHash'] as String?) ?? _clientHash(item);
          item['clientHash'] = ch;
          return item;
        }).toList();
        newRows = normalized;
        // Immediate UI + offline persistence
        setState(() {
          tableData['Expenses'] = _mergeLocalReceiptsInto(
            'expenses',
            List<Map<String, dynamic>>.from(newRows),
          );
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
              debugPrint('Expenses: attachment saved for index $i -> $res');
              // Keep the same id for later Firestore creation & UI
              final uids =
                  (res['uids'] as List?)?.whereType<String>().toList() ?? [];
              newRows[i] = {
                ...newRows[i],
                'id': res['id'],
                if (res['path'] != null) 'LocalReceiptPath': res['path'],
                if (uids.isNotEmpty) 'ReceiptUids': uids,
                if (uids.isNotEmpty) 'ReceiptUid': uids.first,
                if (uids.isEmpty &&
                    ((newRows[i]['ReceiptUid'] ?? '') as String).isNotEmpty)
                  'ReceiptUid': (newRows[i]['ReceiptUid'] ?? '').toString(),
              };
            }
          }
          // Re-sync updated newRows back into state so callers/UI see id/path immediately
          setState(() {
            tableData['Expenses'] = _mergeLocalReceiptsInto(
              'expenses',
              List<Map<String, dynamic>>.from(newRows),
            );
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
              // Suppress delete error SnackBar per requirements
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
            final hasMulti =
                desiredItem['ReceiptBytes'] != null &&
                desiredItem['ReceiptBytes'] is List &&
                (desiredItem['ReceiptBytes'] as List).isNotEmpty;
            // Detect attachment differences explicitly so removal triggers updates
            bool attachmentsDiffer() {
              final cur = currentById[id]!;
              bool curHasPath = ((cur['LocalReceiptPath'] ?? '') as String)
                  .toString()
                  .isNotEmpty;
              bool desHasPath =
                  ((desiredItem['LocalReceiptPath'] ?? '') as String)
                      .toString()
                      .isNotEmpty;
              bool curHasUrl = ((cur['ReceiptUrl'] ?? '') as String)
                  .toString()
                  .isNotEmpty;
              bool desHasUrl = ((desiredItem['ReceiptUrl'] ?? '') as String)
                  .toString()
                  .isNotEmpty;
              int curUrlsLen = (cur['ReceiptUrls'] is List)
                  ? (cur['ReceiptUrls'] as List).length
                  : 0;
              int desUrlsLen = (desiredItem['ReceiptUrls'] is List)
                  ? (desiredItem['ReceiptUrls'] as List).length
                  : 0;
              int curUidsLen = (cur['ReceiptUids'] is List)
                  ? (cur['ReceiptUids'] as List).length
                  : 0;
              int desUidsLen = (desiredItem['ReceiptUids'] is List)
                  ? (desiredItem['ReceiptUids'] as List).length
                  : 0;
              bool curHasBytes =
                  cur['Receipt'] is Uint8List ||
                  (cur['ReceiptBytes'] is List &&
                      (cur['ReceiptBytes'] as List).isNotEmpty);
              bool desHasBytes =
                  desiredItem['Receipt'] is Uint8List ||
                  (desiredItem['ReceiptBytes'] is List &&
                      (desiredItem['ReceiptBytes'] as List).isNotEmpty);
              return curHasPath != desHasPath ||
                  curHasUrl != desHasUrl ||
                  curUrlsLen != desUrlsLen ||
                  curUidsLen != desUidsLen ||
                  curHasBytes != desHasBytes;
            }

            final changed =
                fingerprint(currentById[id]!) != fingerprint(desiredItem) ||
                (desiredItem['Receipt'] != null &&
                    desiredItem['Receipt'] is Uint8List) ||
                hasMulti ||
                attachmentsDiffer();
            if (changed) {
              await _maybeUploadReceiptAndPersist(
                collection: 'expenses',
                id: id,
                item: desiredItem,
                isUpdate: true,
              );
              // After processing multi-images, clear bytes to avoid re-saving
              if (hasMulti) {
                final idx = desired.indexWhere((r) => (r['id'] ?? '') == id);
                if (idx != -1) {
                  desired[idx] = Map<String, dynamic>.from(desired[idx])
                    ..remove('ReceiptBytes');
                }
              }
            }
          }
        }

        // Creations: include rows with null id or provisional local_ ids
        for (final r in desired.where((e) {
          final sid = e['id'] as String?;
          return sid == null || sid.startsWith('local_');
        })) {
          debugPrint(
            'Expenses: creating record for provisional id ${(r['id'] as String?) ?? ''}, clientHash=${(r['clientHash'] ?? _clientHash(r)).toString()}',
          );
          // Guard: Do not pass ReceiptBytes to avoid double-processing; they
          // are handled by _saveNewRowAttachmentImmediately immediately upon add.
          final clean = Map<String, dynamic>.from(r)..remove('ReceiptBytes');
          await _maybeUploadReceiptAndPersist(
            collection: 'expenses',
            id: (clean['id'] as String?) ?? '',
            item: clean,
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
                        // Suppress cloud error SnackBar per requirements; keep local changes only
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
          tableData['Savings'] = _mergeLocalReceiptsInto(
            'savings',
            List<Map<String, dynamic>>.from(newRows),
          );
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
            tableData['Savings'] = _mergeLocalReceiptsInto(
              'savings',
              List<Map<String, dynamic>>.from(newRows),
            );
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
                        // Suppress cloud error SnackBar per requirements; keep local changes only
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
    final hasMultiBytes =
        item['ReceiptBytes'] != null &&
        item['ReceiptBytes'] is List &&
        (item['ReceiptBytes'] as List).isNotEmpty;

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

    // If this is an update and all attachment fields are cleared, reflect that
    // immediately in local state (table rows and preview cache) so UI updates.
    final removedAll =
        isUpdate &&
        !hasBytes &&
        !hasMultiBytes &&
        (((item['LocalReceiptPath'] ?? '') as String).isEmpty) &&
        (((item['ReceiptUrl'] ?? '') as String).isEmpty) &&
        (!(item['ReceiptUrls'] is List) ||
            (item['ReceiptUrls'] as List).isEmpty) &&
        (!(item['ReceiptUids'] is List) ||
            (item['ReceiptUids'] as List).isEmpty);

    if (removedAll) {
      setState(() {
        if (collection == 'expenses') {
          final list = List<Map<String, dynamic>>.from(
            tableData['Expenses'] ?? [],
          );
          // Locate row by id or fingerprint
          int idx = list.indexWhere((r) => (r['id'] ?? '') == localId);
          if (idx == -1) {
            idx = list.lastIndexWhere(
              (r) =>
                  ((r['id'] == null ||
                      (r['id'] as String?)?.isEmpty == true)) &&
                  ((r['clientHash'] as String?) == ch || _clientHash(r) == ch),
            );
          }
          if (idx != -1) {
            list[idx] = {
              ...list[idx],
              'id': localId,
              'LocalReceiptPath': null,
              'Receipt': null,
              'ReceiptUid': '',
              'ReceiptUids': <String>[],
              'ReceiptUrl': '',
              'ReceiptUrls': <String>[],
              // Do not keep any pending bytes on the row
              'ReceiptBytes': <Uint8List>[],
              'clientHash': ch,
            };
            tableData['Expenses'] = list;
          }
          // Clear preview cache so overlay will not re-inject
          _localReceiptPathsExpenses.remove(localId);
        } else {
          final list = List<Map<String, dynamic>>.from(
            tableData['Savings'] ?? [],
          );
          int idx = list.indexWhere((r) => (r['id'] ?? '') == localId);
          if (idx == -1) {
            idx = list.lastIndexWhere(
              (r) =>
                  ((r['id'] == null ||
                      (r['id'] as String?)?.isEmpty == true)) &&
                  ((r['clientHash'] as String?) == ch || _clientHash(r) == ch),
            );
          }
          if (idx != -1) {
            list[idx] = {
              ...list[idx],
              'id': localId,
              'LocalReceiptPath': null,
              'Receipt': null,
              'ReceiptUid': '',
              'ReceiptUids': <String>[],
              'ReceiptUrl': '',
              'ReceiptUrls': <String>[],
              'ReceiptBytes': <Uint8List>[],
              'clientHash': ch,
            };
            tableData['Savings'] = list;
          }
          _localReceiptPathsSavings.remove(localId);
        }
      });
      _saveLocalOnly();
    }

    // When multiple new images are provided, append them all and skip the
    // single-image path to avoid duplicate saves.
    // Only handle multi-image append during updates; creations already handled
    // in _saveNewRowAttachmentImmediately.
    if (hasMultiBytes && isUpdate) {
      try {
        final List raw = item['ReceiptBytes'] as List;
        final savedPaths = <String>[];
        final newUids = <String>[];

        // Determine if caller already provided target UIDs by comparing with
        // existing row's ReceiptUids (if any). We'll try to reuse them to keep
        // UI in sync immediately.
        List<String> providedAllUids = const [];
        List<String> existingUidsForRow = const [];
        // Locate current row for UID comparison
        Map<String, dynamic>? currentRow;
        if (collection == 'expenses') {
          final list = List<Map<String, dynamic>>.from(
            tableData['Expenses'] ?? [],
          );
          int idx = list.indexWhere((r) => (r['id'] ?? '') == localId);
          if (idx == -1) {
            idx = list.lastIndexWhere(
              (r) =>
                  ((r['id'] == null ||
                      (r['id'] as String?)?.isEmpty == true)) &&
                  ((r['clientHash'] as String?) == ch || _clientHash(r) == ch),
            );
          }
          if (idx != -1) currentRow = list[idx];
        } else {
          final list = List<Map<String, dynamic>>.from(
            tableData['Savings'] ?? [],
          );
          int idx = list.indexWhere((r) => (r['id'] ?? '') == localId);
          if (idx == -1) {
            idx = list.lastIndexWhere(
              (r) =>
                  ((r['id'] == null ||
                      (r['id'] as String?)?.isEmpty == true)) &&
                  ((r['clientHash'] as String?) == ch || _clientHash(r) == ch),
            );
          }
          if (idx != -1) currentRow = list[idx];
        }
        if (item['ReceiptUids'] is List) {
          providedAllUids = (item['ReceiptUids'] as List)
              .whereType<String>()
              .toList();
        }
        if (currentRow != null && currentRow['ReceiptUids'] is List) {
          existingUidsForRow = (currentRow['ReceiptUids'] as List)
              .whereType<String>()
              .toList();
        }
        final canReuseProvided =
            providedAllUids.isNotEmpty &&
            providedAllUids.length >= existingUidsForRow.length + raw.length;
        final providedTail = canReuseProvided
            ? providedAllUids.sublist(providedAllUids.length - raw.length)
            : const <String>[];
        for (int i = 0; i < raw.length; i++) {
          final bytes = raw[i];
          if (bytes is! Uint8List) continue;
          final receiptUid = (i < providedTail.length)
              ? providedTail[i]
              : _genReceiptUid();
          final path = await LocalReceiptService().saveReceipt(
            accountId: widget.accountId,
            collection: collection,
            docId: localId,
            bytes: bytes,
            receiptUid: receiptUid,
          );
          savedPaths.add(path);
          newUids.add(receiptUid);
        }

        // Compute combined UIDs with any existing on the row
        final combinedUids = [...existingUidsForRow, ...newUids];

        // Update local maps and table data
        setState(() {
          if (collection == 'expenses') {
            final list = List<Map<String, dynamic>>.from(
              tableData['Expenses'] ?? [],
            );
            // Locate row by id or fingerprint
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
              final existingUids = (list[idx]['ReceiptUids'] is List)
                  ? List<String>.from(list[idx]['ReceiptUids'] as List)
                  : <String>[];
              final allUids = [...existingUids, ...newUids];
              // Set a preview path if none exists
              String? previewPath = list[idx]['LocalReceiptPath'] as String?;
              if ((previewPath == null || previewPath.isEmpty) &&
                  savedPaths.isNotEmpty) {
                previewPath = savedPaths.first;
                _localReceiptPathsExpenses[localId] = previewPath;
              }
              list[idx] = {
                ...list[idx],
                'id': localId,
                if (previewPath != null && previewPath.isNotEmpty)
                  'LocalReceiptPath': previewPath,
                'ReceiptUids': allUids,
                // Legacy single uid left unchanged; multi is canonical
                'clientHash': ch,
              };
              tableData['Expenses'] = _mergeLocalReceiptsInto('expenses', list);
            }
          } else {
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
              final existingUids = (list[idx]['ReceiptUids'] is List)
                  ? List<String>.from(list[idx]['ReceiptUids'] as List)
                  : <String>[];
              final allUids = [...existingUids, ...newUids];
              String? previewPath = list[idx]['LocalReceiptPath'] as String?;
              if ((previewPath == null || previewPath.isEmpty) &&
                  savedPaths.isNotEmpty) {
                previewPath = savedPaths.first;
                _localReceiptPathsSavings[localId] = previewPath;
              }
              list[idx] = {
                ...list[idx],
                'id': localId,
                if (previewPath != null && previewPath.isNotEmpty)
                  'LocalReceiptPath': previewPath,
                'ReceiptUids': allUids,
                'clientHash': ch,
              };
              tableData['Savings'] = list;
            }
          }
        });
        _saveLocalOnly();
        // Clear processed bytes and carry combined UIDs for Firestore merge
        item = Map<String, dynamic>.from(item)
          ..remove('ReceiptBytes')
          ..['ReceiptUids'] = combinedUids;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to save images locally: $e')),
          );
        }
      }
    } else if (hasBytes) {
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
                // Preserve multi-image uids when present (either on the item or existing list entry)
                if ((item['ReceiptUids'] ?? list[idx]['ReceiptUids']) != null)
                  'ReceiptUids':
                      item['ReceiptUids'] ?? list[idx]['ReceiptUids'],
                'clientHash': ch,
              };
              // DEBUG: log local persist details
              debugPrint(
                'maybeUpload: persisted localId=$localId path=$path ReceiptUids=${(item['ReceiptUids'] ?? list[idx]['ReceiptUids'])}',
              );
              tableData['Expenses'] = _mergeLocalReceiptsInto('expenses', list);
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
                if ((item['ReceiptUids'] ?? list[idx]['ReceiptUids']) != null)
                  'ReceiptUids':
                      item['ReceiptUids'] ?? list[idx]['ReceiptUids'],
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

      // Do not upload images to cloud. Keep receipts local only.
      // Prepare a copy of item for persistence that strips local-only byte/path fields.
      final persistItem = Map<String, dynamic>.from(item);
      persistItem.remove('ReceiptBytes');
      persistItem.remove('LocalReceiptPath');
      // Keep legacy ReceiptUrl/ReceiptUid if present; otherwise don't upload images
      // Persist using the cleaned map

      if (isUpdate && localId.isNotEmpty) {
        if (collection == 'expenses') {
          await _repo!.updateExpense(localId, persistItem);
        } else {
          await _repo!.updateSaving(localId, persistItem);
        }
      } else {
        late String newId;
        if (collection == 'expenses') {
          newId = await _repo!.addExpense(persistItem);
        } else {
          newId = await _repo!.addSaving(persistItem);
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
                  // Preserve any multi-image ReceiptUids present on the item or existing entry
                  if ((item['ReceiptUids'] ?? list[idx]['ReceiptUids']) != null)
                    'ReceiptUids':
                        item['ReceiptUids'] ?? list[idx]['ReceiptUids'],
                  'clientHash': ch,
                };
                if (path != null) {
                  _localReceiptPathsExpenses.remove(localId);
                  _localReceiptPathsExpenses[newId] = path;
                }
                // DEBUG: migration from localId->newId
                debugPrint(
                  'maybeUpload: reconciled id $localId -> $newId; moved path=$path ReceiptUids=${item['ReceiptUids'] ?? list[idx]['ReceiptUids']}',
                );
                tableData['Expenses'] = _mergeLocalReceiptsInto(
                  'expenses',
                  list,
                );
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
                  if ((item['ReceiptUids'] ?? list[idx]['ReceiptUids']) != null)
                    'ReceiptUids':
                        item['ReceiptUids'] ?? list[idx]['ReceiptUids'],
                  'clientHash': ch,
                };
                if (path != null) {
                  _localReceiptPathsSavings.remove(localId);
                  _localReceiptPathsSavings[newId] = path;
                }
                tableData['Savings'] = _mergeLocalReceiptsInto('savings', list);
              }
            }
          });
          _saveLocalOnly();
        }
      }
    } catch (e) {
      if (mounted) {
        _showCloudWarning(e);
        // Suppress SnackBar: keep silent to avoid blocking UX; data remains saved locally
      }
    }
  }

  // Bills
  Widget _buildBillsPage() {
    final rows = tableData['Bills'] ?? [];
    return BillsTab(
      rows: rows,
      onRowsChanged: (newRows) {
        // Compute diff vs previous rows and sync with Firestore when possible
        final prev = List<Map<String, dynamic>>.from(rows);
        final prevById = {
          for (final r in prev)
            if (r['id'] != null && (r['id'] as String).isNotEmpty)
              (r['id'] as String): r,
        };
        final nextById = {
          for (final r in newRows)
            if (r['id'] != null && (r['id'] as String).isNotEmpty)
              (r['id'] as String): r,
        };
        Future(() async {
          if (_repo != null) {
            try {
              // Deletions
              for (final id in prevById.keys) {
                if (!nextById.containsKey(id)) {
                  await _repo!.deleteBill(id);
                }
              }
              // Adds/Updates
              for (final r in newRows) {
                final id = (r['id'] ?? '').toString();
                final isNew = id.isEmpty || !prevById.containsKey(id);
                if (isNew) {
                  final assignedId = await _repo!.addBill(
                    r,
                    withId: id.isEmpty ? null : id,
                  );
                  if (id.isEmpty) {
                    r['id'] = assignedId;
                  }
                } else {
                  await _repo!.updateBill(id, r);
                }
              }
            } catch (e) {
              _showCloudWarning(e);
            }
          }
        });
        setState(() {
          tableData['Bills'] = newRows;
          _saveLocalOnly();
        });
        // Also write per-account offline snapshot right away
        box.put('offline_bills_${widget.accountId}', newRows);
      },
    );
  }

  // OR (Official Receipts) - mirrors savings style minimal for now
  Widget _buildOrPage() {
    final rawOr = tableData['OR'] ?? [];
    // Always overlay local receipt paths for OR similar to Expenses
    final rows = rawOr.map<Map<String, dynamic>>((r) {
      final id = (r['id'] ?? '').toString();
      final lp = _localReceiptPathsOr[id];
      if (lp != null && lp.isNotEmpty) return {...r, 'LocalReceiptPath': lp};
      return r;
    }).toList();
    final expensesRows = tableData['Expenses'] ?? [];
    return OrTab(
      rows: rows,
      expensesRows: expensesRows,
      onRowsChanged: (newRows) async {
        // Immediate UI update preserving local receipt metadata
        setState(() {
          tableData['OR'] = _mergeLocalReceiptsIntoOr(
            List<Map<String, dynamic>>.from(newRows),
          );
        });
        _saveLocalOnly();

        // Immediately persist attachments for appended rows
        final prevLen = rawOr.length;
        final addedCount = newRows.length - prevLen;
        if (addedCount > 0) {
          for (int i = prevLen; i < newRows.length; i++) {
            // Handle both legacy single and multi-image bytes
            final item = Map<String, dynamic>.from(newRows[i]);
            final hasSingle = item['Receipt'] is Uint8List;
            final hasMulti =
                item['ReceiptBytes'] is List &&
                (item['ReceiptBytes'] as List).isNotEmpty;
            if (!hasSingle && !hasMulti) continue;
            String id = (item['id'] as String?) ?? '';
            if (id.isEmpty)
              id = 'local_${DateTime.now().millisecondsSinceEpoch}';
            final lrs = LocalReceiptService();
            String? firstPath;
            final uids = <String>[];
            if (hasMulti) {
              final List raw = item['ReceiptBytes'] as List;
              for (final b in raw) {
                if (b is! Uint8List) continue;
                final uid = _genReceiptUid();
                final path = await lrs.saveReceipt(
                  accountId: widget.accountId,
                  collection: 'or',
                  docId: id,
                  bytes: b,
                  receiptUid: uid,
                );
                firstPath ??= path;
                uids.add(uid);
              }
              if (uids.isNotEmpty) item['ReceiptUids'] = uids;
              item.remove('ReceiptBytes');
            } else if (hasSingle) {
              String uid = (item['ReceiptUid'] ?? '').toString();
              if (uid.isEmpty) uid = _genReceiptUid();
              final path = await lrs.saveReceipt(
                accountId: widget.accountId,
                collection: 'or',
                docId: id,
                bytes: item['Receipt'] as Uint8List,
                receiptUid: uid,
              );
              firstPath = path;
              uids.add(uid);
            }
            if (firstPath != null) _localReceiptPathsOr[id] = firstPath;
            newRows[i] = {
              ...newRows[i],
              'id': id,
              if (firstPath != null) 'LocalReceiptPath': firstPath,
              if (uids.isNotEmpty) 'ReceiptUids': uids,
              if (uids.isNotEmpty) 'ReceiptUid': uids.first,
            };
          }
          setState(() {
            tableData['OR'] = _mergeLocalReceiptsIntoOr(
              List<Map<String, dynamic>>.from(newRows),
            );
          });
          _saveLocalOnly();
        }

        // Robust fallback: ensure any row with bytes has a local file (single or multi)
        for (int i = 0; i < newRows.length; i++) {
          final item = Map<String, dynamic>.from(newRows[i]);
          String id = (item['id'] as String?) ?? '';
          if (id.isEmpty) id = 'local_${DateTime.now().millisecondsSinceEpoch}';

          final hasSingle = item['Receipt'] is Uint8List;
          final hasMulti =
              item['ReceiptBytes'] is List &&
              (item['ReceiptBytes'] as List).isNotEmpty;
          final hasLocalPath =
              ((item['LocalReceiptPath'] ?? '') as String).isNotEmpty;

          // Persist multi-image attachments
          if (hasMulti) {
            final lrs = LocalReceiptService();
            String? firstPath;
            final uids = <String>[];
            final List raw = item['ReceiptBytes'] as List;
            for (final b in raw) {
              if (b is! Uint8List) continue;
              final uid = _genReceiptUid();
              try {
                final path = await lrs.saveReceipt(
                  accountId: widget.accountId,
                  collection: 'or',
                  docId: id,
                  bytes: b,
                  receiptUid: uid,
                );
                firstPath ??= path;
                uids.add(uid);
              } catch (_) {}
            }
            if (firstPath != null) _localReceiptPathsOr[id] = firstPath;
            newRows[i] = {
              ...newRows[i],
              'id': id,
              if (firstPath != null) 'LocalReceiptPath': firstPath,
              if (uids.isNotEmpty) 'ReceiptUids': uids,
              if (uids.isNotEmpty) 'ReceiptUid': uids.first,
            };
            // Clear in-memory bytes after persisting
            newRows[i].remove('ReceiptBytes');
          }

          // Persist legacy single-image attachment if no local path yet
          if (hasSingle && !hasLocalPath) {
            String uid = (item['ReceiptUid'] ?? '').toString();
            if (uid.isEmpty) uid = _genReceiptUid();
            try {
              final path = await LocalReceiptService().saveReceipt(
                accountId: widget.accountId,
                collection: 'or',
                docId: id,
                bytes: item['Receipt'] as Uint8List,
                receiptUid: uid,
              );
              _localReceiptPathsOr[id] = path;
              newRows[i] = {
                ...newRows[i],
                'id': id,
                'LocalReceiptPath': path,
                'ReceiptUid': uid,
              };
            } catch (_) {}
          }
        }
        setState(() {
          tableData['OR'] = _mergeLocalReceiptsIntoOr(
            List<Map<String, dynamic>>.from(newRows),
          );
        });
        _saveLocalOnly();

        // Firestore sync
        Future(() async {
          if (_repo == null) return;
          final prev = rows;
          final prevById = {
            for (final r in prev)
              if ((r['id'] ?? '').toString().isNotEmpty) (r['id'] as String): r,
          };
          for (final r in newRows) {
            final id = (r['id'] ?? '').toString();
            final isNew = id.isEmpty || !prevById.containsKey(id);
            try {
              if (isNew) {
                final assigned = await _repo!.addOr(
                  r,
                  withId: id.isEmpty ? null : id,
                );
                if (id.isEmpty) r['id'] = assigned;
              } else {
                await _repo!.updateOr(id, r);
              }
            } catch (e) {
              if (mounted) _showCloudWarning(e);
            }
          }
          final nextIds = {
            for (final r in newRows)
              if ((r['id'] ?? '').toString().isNotEmpty) (r['id'] as String),
          };
          for (final id in prevById.keys) {
            if (!nextIds.contains(id)) {
              try {
                await _repo!.deleteOr(id);
              } catch (e) {
                if (mounted) _showCloudWarning(e);
              }
            }
          }
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
  final ScrollController _scroll = ScrollController();
  bool _atStart = true;
  bool _atEnd = false;

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

    // Ensure initially selected tab is visible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureSelectedVisible(animate: false);
    });

    _scroll.addListener(_onScrollChanged);
  }

  @override
  void didUpdateWidget(covariant _PillTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _controller.forward(from: 0);
      _ensureSelectedVisible();
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScrollChanged);
    _scroll.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.destinations.length;
    const double itemW =
        60.0; // tighter fixed width per tab for icons-only layout
    final double contentW = (count * itemW).toDouble();
    final double pillLeft = (widget.currentIndex * itemW) + 6.0;
    final double pillW = itemW - 12.0;
    final tint = _pillTintForIndex(widget.currentIndex);

    final Widget contentStack = SizedBox(
      width: contentW,
      height: 68,
      child: Stack(
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
                SizedBox(
                  width: itemW,
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
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final bool overflow = contentW > constraints.maxWidth + 0.5;
        final Color glass = Colors.white.withValues(alpha: 0.26);
        final Widget scroller = SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: contentStack,
        );

        return SizedBox(
          height: 68,
          child: Stack(
            children: [
              scroller,
              // Left gradient fade
              if (overflow && !_atStart)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 28,
                  child: IgnorePointer(
                    ignoring: true,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            glass.withValues(alpha: 0.9),
                            glass.withValues(alpha: 0.0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              // Right gradient fade
              if (overflow && !_atEnd)
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: 28,
                  child: IgnorePointer(
                    ignoring: true,
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            glass.withValues(alpha: 0.0),
                            glass.withValues(alpha: 0.9),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              // Left chevron
              if (overflow && !_atStart)
                Positioned(
                  left: 2,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _ChevronButton(
                      direction: AxisDirection.left,
                      onTap: () {
                        final viewport = constraints.maxWidth;
                        final target = (_scroll.offset - viewport * 0.6).clamp(
                          0.0,
                          _scroll.position.maxScrollExtent,
                        );
                        _scroll.animateTo(
                          target,
                          duration: const Duration(milliseconds: 240),
                          curve: Curves.easeOutCubic,
                        );
                      },
                    ),
                  ),
                ),
              // Right chevron
              if (overflow && !_atEnd)
                Positioned(
                  right: 2,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _ChevronButton(
                      direction: AxisDirection.right,
                      onTap: () {
                        final viewport = constraints.maxWidth;
                        final target = (_scroll.offset + viewport * 0.6).clamp(
                          0.0,
                          _scroll.position.maxScrollExtent,
                        );
                        _scroll.animateTo(
                          target,
                          duration: const Duration(milliseconds: 240),
                          curve: Curves.easeOutCubic,
                        );
                      },
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _ensureSelectedVisible({bool animate = true}) {
    final count = widget.destinations.length;
    if (count == 0 || !_scroll.hasClients) return;
    const double itemW = 60.0;
    final double viewportW = _scroll.position.viewportDimension;
    final double contentW = count * itemW;
    final double targetCenter = (widget.currentIndex * itemW) + (itemW / 2);
    double targetOffset = targetCenter - (viewportW / 2);
    if (targetOffset < 0) targetOffset = 0;
    final double maxOffset = (contentW - viewportW).clamp(0.0, double.infinity);
    if (targetOffset > maxOffset) targetOffset = maxOffset;
    if (animate) {
      _scroll.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scroll.jumpTo(targetOffset);
    }
  }

  void _onScrollChanged() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final atStart = pos.pixels <= pos.minScrollExtent + 0.5;
    final atEnd = pos.pixels >= pos.maxScrollExtent - 0.5;
    if (atStart != _atStart || atEnd != _atEnd) {
      setState(() {
        _atStart = atStart;
        _atEnd = atEnd;
      });
    }
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

class _ChevronButton extends StatelessWidget {
  final AxisDirection direction;
  final VoidCallback onTap;
  const _ChevronButton({required this.direction, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isLeft = direction == AxisDirection.left;
    final icon = isLeft ? Icons.chevron_left : Icons.chevron_right;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Ink(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: 0.42),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.12),
                blurRadius: 8,
              ),
            ],
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.5),
              width: 0.6,
            ),
          ),
          width: 28,
          height: 28,
          child: Icon(
            icon,
            size: 20,
            color: Colors.black.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
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
        // icons-only layout: no label rendering
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
              constraints: const BoxConstraints(minHeight: 56, minWidth: 52),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
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
                      // no labels in icons-only layout
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
    return MainTabsPage(accountId: widget.accountId);
  }
}
