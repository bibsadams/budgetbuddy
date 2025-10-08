import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'notification_service.dart';

class JoinRequestWatcher {
  JoinRequestWatcher._();
  static final JoinRequestWatcher _i = JoinRequestWatcher._();
  factory JoinRequestWatcher() => _i;

  final _db = FirebaseFirestore.instance;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _ownerAccountsSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _memberAccountsSub;
  final Map<String, StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?>
  _joinSubs = {};
  final Set<String> _currentAccountIds = {};
  final Set<String> _ownerIds = {};
  final Set<String> _memberIds = {};

  Future<void> startForCurrentUser() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await start(uid);
  }

  Future<void> start(String uid) async {
    await stop();
    // Watch accounts created by this user
    final qOwner = _db
        .collection('accounts')
        .where('createdBy', isEqualTo: uid);
    _ownerAccountsSub = qOwner.snapshots().listen(_handleOwnerAccountsSnapshot);
    // Also watch accounts where this user is a member (covers legacy/migrated owners)
    final qMember = _db
        .collection('accounts')
        .where('members', arrayContains: uid);
    _memberAccountsSub = qMember.snapshots().listen(
      _handleMemberAccountsSnapshot,
    );
  }

  void _handleOwnerAccountsSnapshot(QuerySnapshot<Map<String, dynamic>> qs) {
    _ownerIds
      ..clear()
      ..addAll(qs.docs.map((d) => d.id));
    _reconcileJoinListeners();
  }

  void _handleMemberAccountsSnapshot(QuerySnapshot<Map<String, dynamic>> qs) {
    _memberIds
      ..clear()
      ..addAll(qs.docs.map((d) => d.id));
    _reconcileJoinListeners();
  }

  void _reconcileJoinListeners() {
    final incoming = <String>{..._ownerIds, ..._memberIds};
    // Remove listeners for accounts no longer present in the UNION
    final toRemove = _currentAccountIds.difference(incoming);
    for (final id in toRemove) {
      _joinSubs[id]?.cancel();
      _joinSubs.remove(id);
      _currentAccountIds.remove(id);
    }
    // Add new listeners for new accounts in the UNION
    final toAdd = incoming.difference(_currentAccountIds);
    for (final accId in toAdd) {
      final col = _db
          .collection('accounts')
          .doc(accId)
          .collection('joinRequests');
      _joinSubs[accId] = col.snapshots().listen((jrQs) {
        for (final change in jrQs.docChanges) {
          final data = change.doc.data();
          if (data == null) continue;
          final status = (data['status'] as String?) ?? 'pending';
          if (status != 'pending') continue;
          if (change.type == DocumentChangeType.added ||
              change.type == DocumentChangeType.modified) {
            final requester =
                (data['displayName'] as String?) ??
                (data['email'] as String?) ??
                change.doc.id;
            final title = 'Join request received';
            final body = '$requester requested to join $accId.';
            final id = (title + body + change.doc.id).hashCode & 0x7fffffff;
            NotificationService().showNow(id, title: title, body: body);
          }
        }
      });
      _currentAccountIds.add(accId);
    }
  }

  Future<void> stop() async {
    await _ownerAccountsSub?.cancel();
    _ownerAccountsSub = null;
    await _memberAccountsSub?.cancel();
    _memberAccountsSub = null;
    for (final s in _joinSubs.values) {
      await s?.cancel();
    }
    _joinSubs.clear();
    _currentAccountIds.clear();
    _ownerIds.clear();
    _memberIds.clear();
  }
}
