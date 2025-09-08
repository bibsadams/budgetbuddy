import 'package:cloud_firestore/cloud_firestore.dart';

class SharedAccountRepository {
  final _db = FirebaseFirestore.instance;
  final String accountId; // shared BudgetBuddy account number/id
  final String uid; // current user uid

  SharedAccountRepository({required this.accountId, required this.uid});

  // Collection paths
  CollectionReference<Map<String, dynamic>> get _accounts =>
      _db.collection('accounts');

  DocumentReference<Map<String, dynamic>> get _accountDoc =>
      _accounts.doc(accountId);

  CollectionReference<Map<String, dynamic>> get _expensesCol =>
      _accountDoc.collection('expenses');

  CollectionReference<Map<String, dynamic>> get _savingsCol =>
      _accountDoc.collection('savings');

  CollectionReference<Map<String, dynamic>> get _membersCol =>
      _accountDoc.collection('members');

  DocumentReference<Map<String, dynamic>> get _metaDoc =>
      _accountDoc.collection('meta').doc('config');

  // Account doc stream
  Stream<Map<String, dynamic>?> accountStream() {
    return _accountDoc.snapshots().map((d) => d.data());
  }

  // Toggle joint flag
  Future<void> setIsJoint(bool value) async {
    await _accountDoc.set({
      'isJoint': value,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  // Ensure account exists and add current user to members
  Future<void> ensureMembership({String? displayName, String? email}) async {
    await _db.runTransaction((tx) async {
      // READ PHASE (all reads must occur before any writes in a transaction)
      final accountSnap = await tx.get(_accountDoc);

      // Decide what needs to be written based on the read results
      final bool createAccount = !accountSnap.exists;

      // Capture existing members and props if account exists
      List<String> members = [];
      bool isJoint = false;
      if (accountSnap.exists) {
        final data = accountSnap.data() ?? {};
        members = List<String>.from(data['members'] ?? []);
        isJoint = (data['isJoint'] as bool?) ?? false;
      }

      final bool needsJoin = !createAccount && !members.contains(uid);

      // WRITE PHASE (after all reads)
      if (createAccount) {
        tx.set(_accountDoc, {
          'createdAt': FieldValue.serverTimestamp(),
          'createdBy': uid,
          if (email != null) 'createdByEmail': email,
          'members': [uid],
          'isJoint': false, // default to non-joint until owner enables
        });
        // creator implicitly joined
      } else if (needsJoin) {
        // Only allow self-join when the account is marked as joint
        if (!isJoint) {
          throw StateError(
            'Account is not joint. Ask the owner to enable joint access.',
          );
        }
        members.add(uid);
        tx.update(_accountDoc, {'members': members});
        // joined as member
      }
    });

    // Create meta config outside the transaction so rules see membership state
    try {
      final metaSnap = await _metaDoc.get();
      if (!metaSnap.exists) {
        await _metaDoc.set({
          'limits': {'Expenses': 0.0},
          'goals': {'Savings': 0.0},
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (_) {
      // Best-effort: ignore if rules or network temporarily block; UI can set later
    }

    // Upsert member profile to track who accessed and when
    try {
      final docRef = _membersCol.doc(uid);
      final snap = await docRef.get();
      final joinedAtValue = snap.exists
          ? (snap.data()?['joinedAt'] ?? FieldValue.serverTimestamp())
          : FieldValue.serverTimestamp();
      await docRef.set({
        'uid': uid,
        'displayName': displayName,
        'email': email,
        'joinedAt': joinedAtValue,
        'lastAccessAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      // Non-fatal; account still usable. Can be restricted by rules; adjust as needed.
    }
  }

  // Streams for real-time sync
  Stream<List<Map<String, dynamic>>> expensesStream() {
    return _expensesCol
        .orderBy('date', descending: true)
        .snapshots()
        .map((qs) => qs.docs.map((d) => _fromDoc(d)).toList());
  }

  Stream<List<Map<String, dynamic>>> savingsStream() {
    return _savingsCol
        .orderBy('date', descending: true)
        .snapshots()
        .map((qs) => qs.docs.map((d) => _fromDoc(d)).toList());
  }

  Stream<Map<String, dynamic>> metaStream() {
    return _metaDoc.snapshots().map((d) => d.data() ?? {});
  }

  // Mutations
  Future<String> addExpense(Map<String, dynamic> item, {String? withId}) async {
    if (withId != null && withId.isNotEmpty) {
      await _expensesCol.doc(withId).set(_toDoc(item));
      return withId;
    }
    final ref = await _expensesCol.add(_toDoc(item));
    return ref.id;
  }

  Future<void> updateExpense(String id, Map<String, dynamic> item) async {
    await _expensesCol.doc(id).set(_toDoc(item), SetOptions(merge: true));
  }

  Future<void> deleteExpense(String id) async {
    await _expensesCol.doc(id).delete();
  }

  Future<String> addSaving(Map<String, dynamic> item, {String? withId}) async {
    if (withId != null && withId.isNotEmpty) {
      await _savingsCol.doc(withId).set(_toDoc(item));
      return withId;
    }
    final ref = await _savingsCol.add(_toDoc(item));
    return ref.id;
  }

  Future<void> updateSaving(String id, Map<String, dynamic> item) async {
    await _savingsCol.doc(id).set(_toDoc(item), SetOptions(merge: true));
  }

  Future<void> deleteSaving(String id) async {
    await _savingsCol.doc(id).delete();
  }

  Future<void> setExpenseLimit(double amount) async {
    await _metaDoc.set({
      'limits': {'Expenses': amount},
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> setSavingsGoal(double amount) async {
    await _metaDoc.set({
      'goals': {'Savings': amount},
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Map<String, dynamic> _fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data() ?? {};
    return {
      'id': d.id,
      'Category': data['category'],
      'Subcategory': data['subcategory'],
      'Amount': (data['amount'] as num?)?.toDouble() ?? 0.0,
      'Date': (data['date'] is Timestamp)
          ? (data['date'] as Timestamp).toDate().toIso8601String()
          : (data['date']?.toString() ?? ''),
      'Note': data['note'],
      // Receipts are large; store as URL in cloud storage ideally.
      'ReceiptUrl': data['receiptUrl'],
      'CreatedBy': data['createdBy'],
    };
  }

  Map<String, dynamic> _toDoc(Map<String, dynamic> item) {
    return {
      'category': item['Category'],
      'subcategory': item['Subcategory'],
      'amount': (item['Amount'] as num?)?.toDouble() ?? 0.0,
      'date': _parseDate(item['Date']),
      'note': item['Note'],
      'receiptUrl': item['ReceiptUrl'], // files should be uploaded separately
      'createdBy': uid,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  Timestamp? _parseDate(Object? raw) {
    if (raw == null) return null;
    if (raw is DateTime) return Timestamp.fromDate(raw);
    final dt = DateTime.tryParse(raw.toString());
    return dt != null ? Timestamp.fromDate(dt) : null;
  }
}
