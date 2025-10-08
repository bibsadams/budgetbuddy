// Clean single-definition main.dart to resolve duplicate classes
import 'dart:async';
import 'dart:math';
import 'dart:ui' show ImageFilter;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'main_tabs_page.dart';
import 'widgets/app_gradient_background.dart';
import 'services/auth_service.dart';
import 'services/firebase_service.dart';
import 'services/shared_account_repository.dart';
import 'services/notification_service.dart';
import 'services/push_messaging_service.dart';
import 'services/inbox_service.dart';
import 'services/join_request_watcher.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FirebaseService.init();
  // Ensure Hive is initialized and the box is opened before any Hive.box() usage.
  await Hive.initFlutter();
  await Hive.openBox('budgetBox');
  // Prepare local notifications (channels, permissions)
  await NotificationService().init();
  // Register background handler for FCM (must be a top-level or static function)
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});
  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  bool isSignedIn = FirebaseAuth.instance.currentUser != null;
  String? accountId;
  List<String> linkedAccounts = const [];
  String? _lastUid;
  late final Stream<User?> _authSub;

  // Exposed as a VoidCallback; runs async work in the background.
  void _afterSignIn() {
    () async {
      await _afterSignInImpl();
    }();
  }

  Future<void> _afterSignInImpl() async {
    final box = await Hive.openBox('budgetBox');
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid;
    if (uid == null) return; // defensive
    final email = (user?.email ?? '').toString();
    final linkedKey = 'linkedAccounts_$uid';
    final activeKey = 'accountId_$uid';
    final userDocIdKey = 'userDocId_$uid';
    String? active = box.get(activeKey) as String?;
    List<String> savedAccounts = List<String>.from(box.get(linkedKey) ?? []);

    // 1) Prefer adopting an existing user doc by email; do not create a new one if one exists
    String accountNumber = '';
    try {
      final usersCol = FirebaseFirestore.instance.collection('users');
      final emailKey = email.trim().toLowerCase();
      // Prefer a previously adopted user doc id if present
      final persistedUserDocId = box.get(userDocIdKey) as String?;
      DocumentSnapshot<Map<String, dynamic>>? adopted;
      String? mappedIdFromMapping;
      bool mappingDocExists = false;
      // Track if mapping points to a missing doc (not used directly, but indicates repair path)
      if (persistedUserDocId != null && persistedUserDocId.isNotEmpty) {
        try {
          final snap = await usersCol.doc(persistedUserDocId).get();
          if (snap.exists) {
            adopted = snap;
          }
        } catch (_) {}
      }
      // Check global mapping userEmails/<emailLower> for canonical user doc id
      if (adopted == null) {
        try {
          final mappingRef = FirebaseFirestore.instance
              .collection('userEmails')
              .doc(emailKey);
          final m = await mappingRef.get();
          if (m.exists) {
            final data = m.data();
            final mappedId =
                ((data ?? const <String, dynamic>{})['userDocId'] ?? '')
                    as String;
            if (mappedId.isNotEmpty) {
              mappingDocExists = true;
              mappedIdFromMapping = mappedId;
              final snap = await usersCol.doc(mappedId).get();
              if (snap.exists) {
                adopted = snap;
              } else {
                // Mapping points to a missing doc; we'll repair it when we write chosen
              }
            }
          }
        } catch (_) {}
      }
      // Try case-insensitive matching: first by emailLower, then fallbacks by email
      List<DocumentSnapshot<Map<String, dynamic>>> candidates = [];
      if (adopted == null) {
        final byLower = await usersCol
            .where('emailLower', isEqualTo: emailKey)
            .limit(20)
            .get();
        candidates = byLower.docs
            .cast<DocumentSnapshot<Map<String, dynamic>>>();
      }
      if (candidates.isEmpty) {
        final exact = await usersCol
            .where('email', isEqualTo: email)
            .limit(20)
            .get();
        candidates = exact.docs.cast<DocumentSnapshot<Map<String, dynamic>>>();
        if (candidates.isEmpty && emailKey != email) {
          final lowerOnEmail = await usersCol
              .where('email', isEqualTo: emailKey)
              .limit(20)
              .get();
          candidates = lowerOnEmail.docs
              .cast<DocumentSnapshot<Map<String, dynamic>>>();
        }
        // Legacy field fallbacks for older user docs that may not have 'email' or 'emailLower'
        if (candidates.isEmpty) {
          for (final field in const [
            'mail',
            'emailAddress',
            'userEmail',
            'gmail',
            'username',
          ]) {
            final q1 = await usersCol
                .where(field, isEqualTo: email)
                .limit(20)
                .get();
            if (q1.docs.isNotEmpty) {
              candidates = q1.docs
                  .cast<DocumentSnapshot<Map<String, dynamic>>>();
              break;
            }
            final q2 = await usersCol
                .where(field, isEqualTo: emailKey)
                .limit(20)
                .get();
            if (q2.docs.isNotEmpty) {
              candidates = q2.docs
                  .cast<DocumentSnapshot<Map<String, dynamic>>>();
              break;
            }
          }
        }
      }
      if (adopted == null && candidates.isEmpty) {
        // Try direct doc IDs that may have been used historically
        final emailIdSnap = await usersCol.doc(email).get();
        if (emailIdSnap.exists) {
          candidates = [emailIdSnap];
        } else {
          final emailLowerIdSnap = await usersCol.doc(emailKey).get();
          if (emailLowerIdSnap.exists) {
            candidates = [emailLowerIdSnap];
          }
        }
      }
      if (adopted == null && candidates.isEmpty) {
        // As a final attempt, search by uid field in any user doc
        final byUid = await usersCol
            .where('uid', isEqualTo: uid)
            .limit(20)
            .get();
        if (byUid.docs.isNotEmpty) {
          candidates = byUid.docs
              .cast<DocumentSnapshot<Map<String, dynamic>>>();
        }
      }
      if (adopted != null || candidates.isNotEmpty) {
        // Pick a doc that already has an accountNumber, otherwise first
        DocumentSnapshot<Map<String, dynamic>> chosen;
        if (adopted != null) {
          chosen = adopted;
        } else {
          try {
            chosen = candidates.firstWhere(
              (d) =>
                  (((d.data() ?? const <String, dynamic>{})['accountNumber'] ??
                              '')
                          .toString())
                      .isNotEmpty,
            );
          } catch (_) {
            chosen = candidates.first;
          }
        }
        var data = chosen.data() ?? <String, dynamic>{};
        accountNumber = (data['accountNumber'] ?? '').toString();

        // Ensure chosen has uid/email/dateCreated
        await chosen.reference.set({
          'uid': uid,
          'email': email,
          'emailLower': emailKey,
          if ((data['dateCreated']) == null)
            'dateCreated': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        // Ensure an accountNumber exists on the chosen doc
        if (accountNumber.isEmpty) {
          String genLetters(int n) {
            const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
            final r = Random();
            return String.fromCharCodes(
              List.generate(
                n,
                (_) => letters.codeUnitAt(r.nextInt(letters.length)),
              ),
            );
          }

          String genDigits(int n) {
            const digits = '0123456789';
            final r = Random();
            return String.fromCharCodes(
              List.generate(
                n,
                (_) => digits.codeUnitAt(r.nextInt(digits.length)),
              ),
            );
          }

          accountNumber = 'BB-${genLetters(4)}-${genDigits(4)}';
          await chosen.reference.set({
            'accountNumber': accountNumber,
          }, SetOptions(merge: true));
        }

        // Best-effort delete other duplicates for this email/emailLower
        for (final d in candidates) {
          if (d.id != chosen.id) {
            try {
              await d.reference.delete();
            } catch (_) {
              // ignore permission/rules failures
            }
          }
        }
        // Also clean up a stray users/<uid> if it's a different doc than chosen
        try {
          final uidRef = usersCol.doc(uid);
          final uidSnap = await uidRef.get();
          if (uidSnap.exists && uidSnap.id != chosen.id) {
            await uidRef.delete();
          }
        } catch (_) {}
        // Persist adopted doc id so we use the same one next time
        await box.put(userDocIdKey, chosen.id);
        // Write/update mapping so other devices adopt the same doc id (repairs stale mapping)
        try {
          await FirebaseFirestore.instance
              .collection('userEmails')
              .doc(emailKey)
              .set({
                'userDocId': chosen.id,
                'emailLower': emailKey,
                'email': email,
                'uid': uid,
                'updatedAt': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
        } catch (_) {}
      } else {
        // No user doc exists for this email; enforce canonical mapping via transaction
        String ensureAccountNumber() {
          String genLetters(int n) {
            const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
            final r = Random();
            return String.fromCharCodes(
              List.generate(
                n,
                (_) => letters.codeUnitAt(r.nextInt(letters.length)),
              ),
            );
          }

          String genDigits(int n) {
            const digits = '0123456789';
            final r = Random();
            return String.fromCharCodes(
              List.generate(
                n,
                (_) => digits.codeUnitAt(r.nextInt(digits.length)),
              ),
            );
          }

          return 'BB-${genLetters(4)}-${genDigits(4)}';
        }

        // Case A: Mapping exists -> create/repair the mapped user doc atomically
        if (mappingDocExists &&
            (mappedIdFromMapping != null && mappedIdFromMapping.isNotEmpty)) {
          final mappedId =
              mappedIdFromMapping; // non-null, enforced by check above
          await FirebaseFirestore.instance.runTransaction((tx) async {
            final mappingRef = FirebaseFirestore.instance
                .collection('userEmails')
                .doc(emailKey);
            final userRef = usersCol.doc(mappedId);
            final mSnap = await tx.get(mappingRef);
            // Keep mapping doc in sync and (re)create missing user doc at mapped id
            final uSnap = await tx.get(userRef);
            Map<String, dynamic> newData = {
              'uid': uid,
              'email': email,
              'emailLower': emailKey,
              'dateCreated': FieldValue.serverTimestamp(),
            };
            if (!uSnap.exists) {
              accountNumber = ensureAccountNumber();
              newData['accountNumber'] = accountNumber;
              tx.set(userRef, newData);
            } else {
              final data = uSnap.data();
              accountNumber = ((data?['accountNumber']) ?? '').toString();
              tx.set(userRef, newData, SetOptions(merge: true));
            }
            final mappingData = {
              'userDocId': mappedId,
              'emailLower': emailKey,
              'email': email,
              'uid': uid,
              if (!mSnap.exists) 'createdAt': FieldValue.serverTimestamp(),
              'updatedAt': FieldValue.serverTimestamp(),
            };
            tx.set(mappingRef, mappingData, SetOptions(merge: true));
          });
          await box.put(userDocIdKey, mappedId);
          // Best-effort duplicate cleanup (keep only mappedId for this email)
          try {
            final dupQ = await usersCol
                .where('emailLower', isEqualTo: emailKey)
                .get();
            for (final d in dupQ.docs) {
              if (d.id != mappedId) {
                try {
                  await d.reference.delete();
                } catch (_) {}
              }
            }
          } catch (_) {}
        } else {
          // Case B: No mapping exists -> atomically claim mapping and create the user doc
          final proposedId = emailKey.isNotEmpty ? emailKey : uid;
          bool claimed = false;
          try {
            await FirebaseFirestore.instance.runTransaction((tx) async {
              final mappingRef = FirebaseFirestore.instance
                  .collection('userEmails')
                  .doc(emailKey);
              final mSnap = await tx.get(mappingRef);
              if (mSnap.exists) {
                // Someone else claimed; abort this path
                return;
              }
              final userRef = usersCol.doc(proposedId);
              final uSnap = await tx.get(userRef);
              if (!uSnap.exists) {
                accountNumber = ensureAccountNumber();
                tx.set(userRef, {
                  'uid': uid,
                  'email': email,
                  'emailLower': emailKey,
                  'accountNumber': accountNumber,
                  'dateCreated': FieldValue.serverTimestamp(),
                });
              } else {
                final data = uSnap.data();
                accountNumber = ((data?['accountNumber']) ?? '').toString();
                tx.set(userRef, {
                  'uid': uid,
                  'email': email,
                  'emailLower': emailKey,
                  if ((data?['dateCreated']) == null)
                    'dateCreated': FieldValue.serverTimestamp(),
                }, SetOptions(merge: true));
              }
              tx.set(mappingRef, {
                'userDocId': proposedId,
                'emailLower': emailKey,
                'email': email,
                'uid': uid,
                'createdAt': FieldValue.serverTimestamp(),
                'updatedAt': FieldValue.serverTimestamp(),
              });
              claimed = true;
            });
          } catch (_) {}

          if (claimed) {
            await box.put(userDocIdKey, proposedId);
            // Best-effort duplicate cleanup (keep only proposedId for this email)
            try {
              final dupQ = await usersCol
                  .where('emailLower', isEqualTo: emailKey)
                  .get();
              for (final d in dupQ.docs) {
                if (d.id != proposedId) {
                  try {
                    await d.reference.delete();
                  } catch (_) {}
                }
              }
            } catch (_) {}
          } else {
            // Mapping was claimed by another client; adopt it now
            try {
              final mappingSnap = await FirebaseFirestore.instance
                  .collection('userEmails')
                  .doc(emailKey)
                  .get();
              final mapped =
                  ((mappingSnap.data() ??
                              const <String, dynamic>{})['userDocId'] ??
                          '')
                      as String;
              if (mapped.isNotEmpty) {
                final chosen = await usersCol.doc(mapped).get();
                if (chosen.exists) {
                  final data = chosen.data() ?? <String, dynamic>{};
                  accountNumber = (data['accountNumber'] ?? '').toString();
                  await chosen.reference.set({
                    'uid': uid,
                    'email': email,
                    'emailLower': emailKey,
                    if ((data['dateCreated']) == null)
                      'dateCreated': FieldValue.serverTimestamp(),
                  }, SetOptions(merge: true));
                  await box.put(userDocIdKey, mapped);
                  // Best-effort duplicate cleanup
                  try {
                    final dupQ = await usersCol
                        .where('emailLower', isEqualTo: emailKey)
                        .get();
                    for (final d in dupQ.docs) {
                      if (d.id != mapped) {
                        try {
                          await d.reference.delete();
                        } catch (_) {}
                      }
                    }
                  } catch (_) {}
                }
              }
            } catch (_) {}
          }
        }
      }
    } catch (_) {
      // Firestore may be unreachable; fall back to a random number with the standard format
      String genLetters(int n) {
        const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
        final r = Random();
        return String.fromCharCodes(
          List.generate(
            n,
            (_) => letters.codeUnitAt(r.nextInt(letters.length)),
          ),
        );
      }

      String genDigits(int n) {
        const digits = '0123456789';
        final r = Random();
        return String.fromCharCodes(
          List.generate(n, (_) => digits.codeUnitAt(r.nextInt(digits.length))),
        );
      }

      accountNumber = 'BB-${genLetters(4)}-${genDigits(4)}';
    }

    // 2) Load existing accounts for this user; include personal accountNumber
    if (active == null) {
      try {
        final q1 = await FirebaseFirestore.instance
            .collection('accounts')
            .where('members', arrayContains: uid)
            .limit(10)
            .get();
        var docs = q1.docs;
        if (docs.isEmpty) {
          final q2 = await FirebaseFirestore.instance
              .collection('accounts')
              .where('createdBy', isEqualTo: uid)
              .limit(10)
              .get();
          docs = q2.docs;
        }
        // Keep original order of fetched account ids (member/owner)
        final fetchedOrdered = docs.map((d) => d.id).toList();
        // Append personal accountNumber to the end (do not make it default)
        if (accountNumber.isNotEmpty &&
            !fetchedOrdered.contains(accountNumber)) {
          fetchedOrdered.add(accountNumber);
        }
        if (fetchedOrdered.isNotEmpty) {
          final seen = <String>{...fetchedOrdered};
          for (final k in box.keys) {
            if (k is String && k.startsWith('linkedAccounts_')) {
              final v = box.get(k);
              if (v is List && v.isNotEmpty) {
                seen.addAll(v.whereType<String>());
              }
            }
          }
          final legacy = box.get('linkedAccounts');
          if (legacy is List && legacy.isNotEmpty) {
            seen.addAll(legacy.whereType<String>());
          }
          savedAccounts = seen.toList();
          // Choose active: keep previous if valid, else prefer the first real shared account
          if (active == null || !savedAccounts.contains(active)) {
            final real = fetchedOrdered
                .where((id) => id != accountNumber)
                .toList();
            active = real.isNotEmpty ? real.first : fetchedOrdered.first;
          }
          await box.put(linkedKey, savedAccounts);
          await box.put(activeKey, active);
        }
      } catch (_) {
        // Ignore; we'll provision locally if needed
      }
    }

    // 3) Provision a local personal account if still none
    if (active == null) {
      String genId() {
        const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
        const digits = '23456789';
        final r = Random();
        String pick(int n, String chars) => String.fromCharCodes(
          List.generate(n, (_) => chars.codeUnitAt(r.nextInt(chars.length))),
        );
        return 'BB-${pick(4, letters)}-${pick(4, digits)}';
      }

      String personalId = genId();
      int attempts = 0;
      while (savedAccounts.contains(personalId) && attempts < 5) {
        personalId = genId();
        attempts++;
      }
      final accNum2 = accountNumber;
      active = accNum2.isNotEmpty ? accNum2 : personalId;
      if (!savedAccounts.contains(active)) {
        savedAccounts.insert(0, active);
      }
      final seen = <String>{...savedAccounts};
      for (final k in box.keys) {
        if (k is String && k.startsWith('linkedAccounts_')) {
          final v = box.get(k);
          if (v is List && v.isNotEmpty) {
            seen.addAll(v.whereType<String>());
          }
        }
      }
      final legacy = box.get('linkedAccounts');
      if (legacy is List && legacy.isNotEmpty) {
        seen.addAll(legacy.whereType<String>());
      }
      savedAccounts = seen.toList();
      await box.put(linkedKey, savedAccounts);
      await box.put(activeKey, active);
    }

    // Persist merged list for this user and device-wide bucket
    final mergedForUser = <String>{...savedAccounts};
    for (final k in box.keys) {
      if (k is String && k.startsWith('linkedAccounts_')) {
        final v = box.get(k);
        if (v is List && v.isNotEmpty) {
          mergedForUser.addAll(v.whereType<String>());
        }
      }
    }
    final legacy2 = box.get('linkedAccounts');
    if (legacy2 is List && legacy2.isNotEmpty) {
      mergedForUser.addAll(legacy2.whereType<String>());
    }
    final mergedList = mergedForUser.toList()..sort();
    await box.put(linkedKey, mergedList);
    final deviceKey = 'linkedAccounts_device';
    final devVal = box.get(deviceKey);
    final devSet = <String>{
      ...mergedList,
      if (devVal is List) ...devVal.whereType<String>(),
    };
    await box.put(deviceKey, devSet.toList()..sort());

    if (!mounted) return;
    setState(() {
      isSignedIn = true;
      accountId = active;
      linkedAccounts = mergedList;
    });

    // Best-effort: register this device for push notifications (FCM)
    // so owner/member notifications can be delivered.
    try {
      await PushMessagingService().registerTokenIfPossible();
    } catch (_) {}
    // Start inbox listener for owner/member events (no Functions required)
    try {
      await InboxService().startForCurrentUser();
    } catch (_) {}
    // Start direct join-request watcher for accounts you own
    try {
      await JoinRequestWatcher().startForCurrentUser();
    } catch (_) {}

    // Reset navigation to main tabs
    _navKey.currentState?.pushAndRemoveUntil(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => MainTabsScaffold(
          activeAccountId: accountId,
          linkedAccounts: linkedAccounts,
          onSwitchAccount: (id) async {
            final box2 = await Hive.openBox('budgetBox');
            final uid2 = FirebaseAuth.instance.currentUser?.uid;
            final activeKey2 = uid2 != null ? 'accountId_$uid2' : 'accountId';
            await box2.put(activeKey2, id);
            if (mounted) setState(() => accountId = id);
          },
          onAccountsChanged: (list) async {
            final box2 = await Hive.openBox('budgetBox');
            final uid2 = FirebaseAuth.instance.currentUser?.uid;
            final linkedKey2 = uid2 != null
                ? 'linkedAccounts_$uid2'
                : 'linkedAccounts';
            await box2.put(linkedKey2, list);
            if (mounted)
              setState(() => linkedAccounts = List<String>.from(list));
          },
        ),
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
      (route) => false,
    );
  }

  @override
  void initState() {
    super.initState();
    _lastUid = FirebaseAuth.instance.currentUser?.uid;
    _bootstrapFromLocal();
    // React to sign-in/sign-out
    _authSub = FirebaseAuth.instance.authStateChanges();
    _authSub.listen((user) async {
      final signedInNow = user != null;
      if (user != null) {
        _lastUid = user.uid;
      }
      if (mounted && signedInNow != isSignedIn) {
        setState(() => isSignedIn = signedInNow);
        if (!signedInNow) {
          // Clear any per-user active selection (kept per uid)
          final box = await Hive.openBox('budgetBox');
          final prevUid = _lastUid;
          if (prevUid != null) {
            // Keep linkedAccounts_<uid> to preserve device-known accounts for UI aggregation
            await box.delete('accountId_$prevUid');
          }
          _lastUid = null;
          setState(() => accountId = null);
          // Hard reset the navigation stack to LoginPage
          final ctx = _navKey.currentContext;
          if (ctx != null) {
            _navKey.currentState?.pushAndRemoveUntil(
              PageRouteBuilder(
                pageBuilder: (_, __, ___) => LoginPage(onSignIn: _afterSignIn),
                transitionDuration: Duration.zero,
                reverseTransitionDuration: Duration.zero,
              ),
              (route) => false,
            );
          }
        } else {
          // Signed in: no forced navigation here; onSignIn will handle provisioning and navigation.
        }
      }
    });
  }

  Future<void> _bootstrapFromLocal() async {
    final box = await Hive.openBox('budgetBox');
    final user = FirebaseAuth.instance.currentUser;
    final uid = user?.uid;
    final linkedKey = uid != null ? 'linkedAccounts_$uid' : 'linkedAccounts';
    final activeKey = uid != null ? 'accountId_$uid' : 'accountId';
    List<String> savedAccounts = List<String>.from(box.get(linkedKey) ?? []);
    String? savedActive = box.get(activeKey) as String?;
    // If signed-in and empty cache, fetch accounts once (owner or member)
    if (uid != null && savedAccounts.isEmpty) {
      try {
        final q1 = await FirebaseFirestore.instance
            .collection('accounts')
            .where('members', arrayContains: uid)
            .limit(20)
            .get();
        final memberIds = q1.docs.map((d) => d.id);
        final q2 = await FirebaseFirestore.instance
            .collection('accounts')
            .where('createdBy', isEqualTo: uid)
            .limit(20)
            .get();
        final ownerIds = q2.docs.map((d) => d.id);
        savedAccounts = {...memberIds, ...ownerIds}.toList();
        if (savedAccounts.isNotEmpty) {
          await box.put(linkedKey, savedAccounts);
          savedActive ??= savedAccounts.first;
          await box.put(activeKey, savedActive);
        }
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        linkedAccounts = savedAccounts;
        accountId =
            savedActive ??
            (savedAccounts.isNotEmpty ? savedAccounts.first : null);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      navigatorKey: _navKey,
      home: isSignedIn
          ? MainTabsScaffold(
              activeAccountId: accountId,
              linkedAccounts: linkedAccounts,
              onSwitchAccount: (id) async {
                final box = await Hive.openBox('budgetBox');
                final uid = FirebaseAuth.instance.currentUser?.uid;
                final activeKey = uid != null ? 'accountId_$uid' : 'accountId';
                await box.put(activeKey, id);
                if (mounted) setState(() => accountId = id);
              },
              onAccountsChanged: (list) async {
                final box = await Hive.openBox('budgetBox');
                final uid = FirebaseAuth.instance.currentUser?.uid;
                final linkedKey = uid != null
                    ? 'linkedAccounts_$uid'
                    : 'linkedAccounts';
                await box.put(linkedKey, list);
                if (mounted)
                  setState(() => linkedAccounts = List<String>.from(list));
              },
            )
          : LoginPage(onSignIn: _afterSignIn),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Listen for notification taps and route to Bills
    NotificationService().onNotificationTap.listen((payload) {
      // Expected payload format: bill:<id> or bill:<name>
      // For now, just navigate to the Bills tab; selection behavior can be added in-page.
      final ctx = _navKey.currentContext;
      if (ctx == null) return;
      try {
        // If already on MainTabsScaffold, it exposes an API via an inherited method (optional).
        // Minimal: push a no-op route to ensure app is visible then rely on default tab restoration.
        // Real navigation to a specific record will require wiring a select/highlight API.
      } catch (_) {}
    });
  }
}

// Simple wrapper that renders the main tabs for the active account
class MainTabsScaffold extends StatelessWidget {
  final String? activeAccountId;
  final List<String> linkedAccounts;
  final Future<void> Function(String id) onSwitchAccount;
  final Future<void> Function(List<String> list) onAccountsChanged;
  const MainTabsScaffold({
    super.key,
    required this.activeAccountId,
    required this.linkedAccounts,
    required this.onSwitchAccount,
    required this.onAccountsChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (activeAccountId == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return MainTabsPageProvider(accountId: activeAccountId!);
  }
}

class LoginPage extends StatelessWidget {
  final VoidCallback onSignIn;
  const LoginPage({super.key, required this.onSignIn});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppGradientBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: _GlassCard(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Logo with safe sizing and BoxFit.contain to avoid clipping/stretching
                      LayoutBuilder(
                        builder: (context, c) {
                          final double maxW = c.maxWidth;
                          final double size = maxW.clamp(120, 200);
                          return Center(
                            child: TweenAnimationBuilder<double>(
                              duration: const Duration(milliseconds: 600),
                              curve: Curves.easeOutCubic,
                              tween: Tween(begin: 0.9, end: 1),
                              builder: (context, scale, child) =>
                                  Transform.scale(scale: scale, child: child),
                              child: Container(
                                width: size,
                                height: size,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: LinearGradient(
                                    colors: [
                                      Colors.white.withValues(alpha: 0.85),
                                      Colors.white.withValues(alpha: 0.65),
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.08,
                                      ),
                                      blurRadius: 22,
                                      offset: const Offset(0, 10),
                                    ),
                                  ],
                                ),
                                padding: const EdgeInsets.all(20),
                                child: ClipOval(
                                  child: Image.asset(
                                    'assets/app_logo.png',
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.high,
                                    errorBuilder:
                                        (context, error, stackTrace) => Icon(
                                          Icons.account_balance_wallet_rounded,
                                          size: size * 0.6,
                                          color: cs.primary,
                                        ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 20),
                      Center(
                        child: Text(
                          'BudgetBuddy',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: Colors.black87,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Center(
                        child: Text(
                          'Smarter spending. Happier saving.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.black54,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 52,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black87,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                              side: BorderSide(
                                color: Colors.black.withValues(alpha: 0.08),
                              ),
                            ),
                          ),
                          onPressed: () async {
                            try {
                              final user = await AuthService()
                                  .signInWithGoogle();
                              if (user != null) onSignIn();
                            } catch (e) {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Google Sign-In failed: $e'),
                                ),
                              );
                            }
                          },
                          icon: Image.asset('assets/g-logo.png', height: 22),
                          label: const Text(
                            'Sign in with Google',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Minimal glassmorphic card used on the login screen
class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: Stack(
        children: [
          // Frosted blur
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: const SizedBox.expand(),
            ),
          ),
          // Translucent surface
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.50),
                  Colors.white.withValues(alpha: 0.36),
                ],
              ),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.5),
                width: 0.8,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class AccountChooser extends StatefulWidget {
  final void Function(String accountId) onConfirmed;
  const AccountChooser({super.key, required this.onConfirmed});

  @override
  State<AccountChooser> createState() => _AccountChooserState();
}

class _AccountChooserState extends State<AccountChooser> {
  final TextEditingController _joinCtrl = TextEditingController();
  final TextEditingController _createCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  int _tab = 0; // 0 = Join, 1 = Create

  @override
  void initState() {
    super.initState();
    _createCtrl.text = _generateAccountId();
  }

  @override
  void dispose() {
    _joinCtrl.dispose();
    _createCtrl.dispose();
    super.dispose();
  }

  String _generateAccountId() {
    const letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    const digits = '23456789';
    final r = Random();
    String pick(int n, String chars) => String.fromCharCodes(
      List.generate(n, (_) => chars.codeUnitAt(r.nextInt(chars.length))),
    );
    final partA = pick(4, letters);
    final partB = pick(4, digits);
    return 'BB-$partA-$partB';
  }

  // _exists helper removed; join flow performs existence check directly.

  // _existsWithRetry removed; direct server check is used in Join flow.

  void _addRecent(Box box, String id) {
    final List<String> recent = List<String>.from(
      box.get('recentAccounts') ?? [],
    );
    recent.remove(id);
    recent.insert(0, id);
    if (recent.length > 5) recent.removeRange(5, recent.length);
    box.put('recentAccounts', recent);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final box = Hive.box('budgetBox');
    final List<String> recent = List<String>.from(
      box.get('recentAccounts') ?? [],
    );
    // Enforce account number format like BB-ABCD-1234
    final reg = RegExp(r'^BB-[A-Z]{4}-\d{4}$');
    bool formatOk(String s) => reg.hasMatch(s.trim().toUpperCase());
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [cs.surfaceContainerHighest, cs.primaryContainer],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Card(
                  elevation: 6,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: cs.primaryContainer,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(
                                Icons.groups_2_outlined,
                                size: 28,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Choose or Create Account',
                                style: Theme.of(context).textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Join an existing shared BudgetBuddy account with its number, or create a new one to share later.',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: Colors.black87),
                        ),
                        const SizedBox(height: 16),
                        if (recent.isNotEmpty) ...[
                          Text(
                            'Recent accounts',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final id in recent)
                                ActionChip(
                                  label: Text(id),
                                  avatar: const Icon(Icons.history, size: 18),
                                  onPressed: () => setState(() {
                                    _tab = 0;
                                    _joinCtrl.text = id;
                                  }),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                        ],
                        SegmentedButton<int>(
                          segments: const [
                            ButtonSegment(
                              value: 0,
                              icon: Icon(Icons.login),
                              label: Text('Join existing'),
                            ),
                            ButtonSegment(
                              value: 1,
                              icon: Icon(Icons.add_circle_outline),
                              label: Text('Create new'),
                            ),
                          ],
                          selected: {_tab},
                          onSelectionChanged: (s) =>
                              setState(() => _tab = s.first),
                        ),
                        const SizedBox(height: 16),
                        if (_tab == 0) ...[
                          TextField(
                            controller: _joinCtrl,
                            textCapitalization: TextCapitalization.characters,
                            decoration: const InputDecoration(
                              labelText: 'Account number',
                              hintText: 'BB-ABCD-1234',
                              prefixIcon: Icon(
                                Icons.confirmation_number_outlined,
                              ),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 12),
                          FilledButton.icon(
                            icon: const Icon(Icons.check_circle_outline),
                            onPressed: _loading
                                ? null
                                : () async {
                                    FocusScope.of(context).unfocus();
                                    final id = _joinCtrl.text
                                        .trim()
                                        .toUpperCase();
                                    if (id.isEmpty) {
                                      setState(
                                        () => _error =
                                            'Please enter an account number.',
                                      );
                                      return;
                                    }
                                    if (!formatOk(id)) {
                                      setState(
                                        () => _error =
                                            'Format should be BB-ABCD-1234. You can still choose "Use anyway".',
                                      );
                                      return;
                                    }
                                    setState(() {
                                      _loading = true;
                                      _error = null;
                                    });
                                    try {
                                      final doc = await FirebaseFirestore
                                          .instance
                                          .collection('accounts')
                                          .doc(id)
                                          .get();
                                      final ok = doc.exists;
                                      if (!mounted) return;
                                      if (ok) {
                                        // No additional validation required

                                        // Allow joining any existing account (no joint/owner restriction)
                                        _addRecent(box, id);
                                        widget.onConfirmed(id);
                                      } else {
                                        setState(
                                          () => _error =
                                              'Account not found. Check the number or switch to Create.',
                                        );
                                      }
                                    } catch (e) {
                                      if (!mounted) return;
                                      setState(
                                        () => _error = 'Validation failed: $e',
                                      );
                                    } finally {
                                      if (mounted) {
                                        setState(() => _loading = false);
                                      }
                                    }
                                  },
                            label: const Text('Join account'),
                          ),
                          const SizedBox(height: 6),
                        ] else ...[
                          TextField(
                            controller: _createCtrl,
                            textCapitalization: TextCapitalization.characters,
                            decoration: const InputDecoration(
                              labelText: 'New account number',
                              hintText: 'Customize or use suggested',
                              prefixIcon: Icon(Icons.badge_outlined),
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              icon: const Icon(
                                Icons.playlist_add_check_circle_outlined,
                              ),
                              onPressed: _loading
                                  ? null
                                  : () async {
                                      FocusScope.of(context).unfocus();
                                      final id = _createCtrl.text
                                          .trim()
                                          .toUpperCase();
                                      if (id.isEmpty) {
                                        setState(
                                          () => _error =
                                              'Please enter an account number.',
                                        );
                                        return;
                                      }
                                      if (!formatOk(id)) {
                                        setState(
                                          () => _error =
                                              'Format should be BB-ABCD-1234.',
                                        );
                                        return;
                                      }
                                      setState(() {
                                        _loading = true;
                                        _error = null;
                                      });
                                      // Temporary: skip Firestore existence check to allow testing without backend
                                      _addRecent(box, id);
                                      if (!mounted) return;
                                      widget.onConfirmed(id);
                                      if (mounted) {
                                        setState(() => _loading = false);
                                      }
                                    },
                              label: const Text('Create'),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _loading
                                    ? null
                                    : () => setState(
                                        () => _createCtrl.text =
                                            _generateAccountId(),
                                      ),
                                icon: const Icon(Icons.refresh),
                                label: const Text('Suggest'),
                              ),
                              OutlinedButton.icon(
                                onPressed: () async {
                                  await Clipboard.setData(
                                    ClipboardData(
                                      text: _createCtrl.text
                                          .trim()
                                          .toUpperCase(),
                                    ),
                                  );
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Account number copied'),
                                    ),
                                  );
                                },
                                icon: const Icon(Icons.copy_all_outlined),
                                label: const Text('Copy'),
                              ),
                              IconButton.filledTonal(
                                tooltip: 'Share',
                                onPressed: () async {
                                  final id = _createCtrl.text
                                      .trim()
                                      .toUpperCase();
                                  await Share.share(
                                    'Join my BudgetBuddy account: $id',
                                  );
                                },
                                icon: const Icon(Icons.share_outlined),
                              ),
                            ],
                          ),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _error!,
                            style: const TextStyle(color: Colors.red),
                          ),
                        ],
                        const SizedBox(height: 8),
                        if (_loading)
                          const LinearProgressIndicator(minHeight: 2),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MainTabsPageProvider extends StatefulWidget {
  final String accountId;
  const MainTabsPageProvider({super.key, required this.accountId});

  @override
  State<MainTabsPageProvider> createState() => _MainTabsPageProviderState();
}

class _MainTabsPageProviderState extends State<MainTabsPageProvider> {
  bool _ready = false;
  String? _ensureError;

  @override
  void initState() {
    super.initState();
    _ensure();
  }

  Future<void> _ensure() async {
    final user = FirebaseAuth.instance.currentUser!;
    try {
      final repo = SharedAccountRepository(
        accountId: widget.accountId,
        uid: user.uid,
      );
      await repo.ensureMembership(
        displayName: user.displayName,
        email: user.email,
      );
    } catch (_) {
      // Allow navigation even if Firebase is not configured yet, but keep why.
      try {
        rethrow;
      } catch (e, st) {
        // If user chose an account they don't own and it's not joint/approved,
        // show a warning but don't block app shell; user can switch or create.
        _ensureError = 'Cloud join failed: $e';
        // Log details for debugging in console
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
