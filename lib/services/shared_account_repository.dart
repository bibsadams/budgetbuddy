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

  CollectionReference<Map<String, dynamic>> get _billsCol =>
      _accountDoc.collection('bills');

  CollectionReference<Map<String, dynamic>> get _membersCol =>
      _accountDoc.collection('members');

  DocumentReference<Map<String, dynamic>> get _metaDoc =>
      _accountDoc.collection('meta').doc('config');

  CollectionReference<Map<String, dynamic>> get _joinRequestsCol =>
      _accountDoc.collection('joinRequests');

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

  // Quick fetches
  Future<Map<String, dynamic>?> getAccountOnce() async {
    final snap = await _accountDoc.get();
    return snap.data();
  }

  Future<bool> isAccountJoint() async {
    final d = await getAccountOnce();
    return (d?['isJoint'] as bool?) ?? false;
  }

  // Request email verification to join this account. This writes a joinRequests doc
  // which a backend (Cloud Function/Extension) can use to send an email to the owner.
  Future<void> requestJoinVerification({
    String? displayName,
    String? email,
  }) async {
    final jr = _joinRequestsCol.doc(uid);
    try {
      await jr.set({
        'uid': uid,
        'displayName': displayName,
        'email': email,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
        'lastUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } on FirebaseException catch (e) {
      // Fallback: write to a global collection so Cloud Functions can still send an email
      if (e.code == 'permission-denied') {
        await _db.collection('joinRequests').add({
          'accountId': accountId,
          'uid': uid,
          'displayName': displayName,
          'email': email,
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
          'lastUpdatedAt': FieldValue.serverTimestamp(),
        });
      } else {
        rethrow;
      }
    }
  }

  // Read owner metadata (createdByEmail, createdBy) for UX/verification messaging
  Future<Map<String, dynamic>?> getAccountMetaOnce() async {
    final snap = await _accountDoc.get();
    return snap.data();
  }

  // Ensure account exists; owners are auto-added. Non-owners must be approved by owner.
  Future<void> ensureMembership({String? displayName, String? email}) async {
    await _db.runTransaction((tx) async {
      // READ PHASE (all reads must occur before any writes in a transaction)
      final accountSnap = await tx.get(_accountDoc);

      // Decide what needs to be written based on the read results
      final bool createAccount = !accountSnap.exists;

      // Capture existing members and props if account exists
      List<String> members = [];
      String createdBy = '';
      if (accountSnap.exists) {
        final data = accountSnap.data() ?? {};
        members = List<String>.from(data['members'] ?? []);
        createdBy = (data['createdBy'] as String?) ?? '';
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
        // If you're the owner (createdBy == uid), allow seamless access on new device.
        if (createdBy == uid) {
          members.add(uid);
          tx.update(_accountDoc, {'members': members});
        } else {
          // For non-owners, only allow join if account is joint AND an approval doc exists.
          final data = accountSnap.data() ?? {};
          final isJoint = (data['isJoint'] as bool?) ?? false;
          if (!isJoint) {
            // Not a joint account: this Gmail should create/own its own account instead.
            throw StateError(
              'This account is single-owner. Use your own account.',
            );
          }
          // Check for an approved join request to allow automatic membership.
          final reqSnap = await tx.get(_joinRequestsCol.doc(uid));
          final status = (reqSnap.data()?['status'] as String?) ?? 'pending';
          if (status == 'approved') {
            members.add(uid);
            tx.update(_accountDoc, {'members': members});
            // Also upsert member doc below after transaction
          } else {
            throw StateError('Awaiting owner approval to join this account.');
          }
        }
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

  // Explicitly provision a new personal account for this uid (used for “Create” flow)
  Future<void> createPersonalAccount({String? email}) async {
    await _db.runTransaction((tx) async {
      final snap = await tx.get(_accountDoc);
      if (snap.exists) return; // already exists
      tx.set(_accountDoc, {
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': uid,
        if (email != null) 'createdByEmail': email,
        'members': [uid],
        'isJoint': false,
      });
    });
    try {
      await _metaDoc.set({
        'limits': {'Expenses': 0.0},
        'goals': {'Savings': 0.0},
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
    try {
      await _membersCol.doc(uid).set({
        'uid': uid,
        'email': email,
        'joinedAt': FieldValue.serverTimestamp(),
        'lastAccessAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  // Owner: list join requests for this account
  Stream<List<Map<String, dynamic>>> joinRequestsStream() {
    return _joinRequestsCol
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((qs) => qs.docs.map((d) => ({...d.data(), 'id': d.id})).toList());
  }

  // Owner: approve/deny a join request
  Future<void> setJoinRequestStatus(String requestUid, String status) async {
    await _joinRequestsCol.doc(requestUid).set({
      'status': status,
      'lastUpdatedAt': FieldValue.serverTimestamp(),
      'actedBy': uid,
    }, SetOptions(merge: true));
  }

  // Fallback (no Cloud Functions): owner approves and directly adds member.
  // This updates joinRequests status to 'approved', appends the uid to
  // accounts/{id}.members, and upserts accounts/{id}/members/{uid}.
  Future<void> approveAndAddMember(String requestUid) async {
    await _db.runTransaction((tx) async {
      // Ensure account exists (owner-only UI should guard, but double-check).
      final accountSnap = await tx.get(_accountDoc);
      if (!accountSnap.exists) {
        throw StateError('Account not found.');
      }

      // Read the request for displayName/email to store in member profile.
      final reqRef = _joinRequestsCol.doc(requestUid);
      final reqSnap = await tx.get(reqRef);
      final reqData = reqSnap.data();
      final displayName = reqData?['displayName'];
      final email = reqData?['email'];

      // 1) Mark request approved
      tx.set(reqRef, {
        'status': 'approved',
        'actedBy': uid,
        'lastUpdatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // 2) Add to account members (idempotent)
      tx.update(_accountDoc, {
        'members': FieldValue.arrayUnion([requestUid]),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 3) Upsert member profile subdoc
      final memberRef = _membersCol.doc(requestUid);
      tx.set(memberRef, {
        'uid': requestUid,
        if (displayName != null) 'displayName': displayName,
        if (email != null) 'email': email,
        'joinedAt': FieldValue.serverTimestamp(),
        'lastAccessAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
  }

  // Requester: check own request status
  Future<String?> myJoinRequestStatus() async {
    final doc = await _joinRequestsCol.doc(uid).get();
    if (!doc.exists) return null;
    return (doc.data()?['status'] as String?) ?? 'pending';
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

  Stream<List<Map<String, dynamic>>> billsStream() {
    return _billsCol
        .orderBy('dueDate', descending: true)
        .snapshots()
        .map((qs) => qs.docs.map((d) => _fromBillDoc(d)).toList());
  }

  // One-shot fetchers for backup/restore flows
  Future<List<Map<String, dynamic>>> fetchAllExpensesOnce() async {
    final qs = await _expensesCol.orderBy('date', descending: true).get();
    return qs.docs.map((d) => _fromDoc(d)).toList();
  }

  Future<List<Map<String, dynamic>>> fetchAllSavingsOnce() async {
    final qs = await _savingsCol.orderBy('date', descending: true).get();
    return qs.docs.map((d) => _fromDoc(d)).toList();
  }

  // Find Firestore doc id by a stored receiptUid (if present on row)
  Future<String?> findDocIdByReceiptUid({
    required String collection, // 'expenses' | 'savings'
    required String receiptUid,
  }) async {
    final col = collection == 'expenses' ? _expensesCol : _savingsCol;
    final qs = await col
        .where('receiptUid', isEqualTo: receiptUid)
        .limit(1)
        .get();
    if (qs.docs.isEmpty) return null;
    return qs.docs.first.id;
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

  Future<String> addBill(Map<String, dynamic> item, {String? withId}) async {
    if (withId != null && withId.isNotEmpty) {
      await _billsCol.doc(withId).set(_toBillDoc(item));
      return withId;
    }
    final ref = await _billsCol.add(_toBillDoc(item));
    return ref.id;
  }

  Future<void> updateBill(String id, Map<String, dynamic> item) async {
    await _billsCol.doc(id).set(_toBillDoc(item), SetOptions(merge: true));
  }

  Future<void> deleteBill(String id) async {
    await _billsCol.doc(id).delete();
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

  Future<void> setExpensesLimitPercents(Map<String, double> percents) async {
    await _metaDoc.set({
      'expensesLimitPercent': percents,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  Future<void> setSavingsGoalPercents(Map<String, double> percents) async {
    await _metaDoc.set({
      'savingsGoalPercent': percents,
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
      // Stable identifier for an attached receipt image (for backup/restore).
      'ReceiptUid': data['receiptUid'],
      'CreatedBy': data['createdBy'],
    };
  }

  Map<String, dynamic> _fromBillDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final data = d.data() ?? {};
    String dueDateStr = '';
    final rawDue = data['dueDate'];
    if (rawDue is Timestamp) {
      final dt = rawDue.toDate();
      dueDateStr =
          '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
    } else if (rawDue != null) {
      // Accept ISO 8601 or yyyy-MM-dd stored as string
      final dt = DateTime.tryParse(rawDue.toString());
      if (dt != null) {
        dueDateStr =
            '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
      } else {
        dueDateStr = rawDue.toString();
      }
    }
    return {
      'id': d.id,
      'Name': data['name'] ?? 'Bill',
      'Amount': (data['amount'] as num?)?.toDouble() ?? 0.0,
      'Due Date': dueDateStr,
      'Time': data['time']?.toString() ?? '',
      'Repeat': data['repeat']?.toString() ?? 'None',
      'Enabled': (data['enabled'] as bool?) ?? true,
      'Note': data['note']?.toString() ?? '',
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
      // Persist stable receipt uid if present
      if ((item['ReceiptUid'] ?? item['receiptUid']) != null)
        'receiptUid': item['ReceiptUid'] ?? item['receiptUid'],
      'createdBy': uid,
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  Map<String, dynamic> _toBillDoc(Map<String, dynamic> item) {
    return {
      'name': item['Name'],
      'amount': (item['Amount'] as num?)?.toDouble() ?? 0.0,
      'dueDate': _parseDate(item['Due Date']),
      'time': item['Time'], // 'HH:mm'
      'repeat': item['Repeat'] ?? 'None',
      'enabled': item['Enabled'] ?? true,
      'note': item['Note'],
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
