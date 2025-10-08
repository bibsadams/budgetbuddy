import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'notification_service.dart';

class JoinRequestWatcher {
  JoinRequestWatcher._();
  static final JoinRequestWatcher _i = JoinRequestWatcher._();
  factory JoinRequestWatcher() => _i;

  final _db = FirebaseFirestore.instance;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _accountsSub;
  final Map<String, StreamSubscription<QuerySnapshot<Map<String, dynamic>>>?>
  _joinSubs = {};

  Future<void> startForCurrentUser() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await start(uid);
  }

  Future<void> start(String uid) async {
    await stop();
    // Watch accounts created by this user
    final q = _db.collection('accounts').where('createdBy', isEqualTo: uid);
    _accountsSub = q.snapshots().listen((qs) {
      _handleAccountsSnapshot(qs);
    });
  }

  void _handleAccountsSnapshot(QuerySnapshot<Map<String, dynamic>> qs) {
    final currentIds = qs.docs.map((d) => d.id).toSet();
    // Remove listeners for accounts no longer present
    for (final id in _joinSubs.keys.toList()) {
      if (!currentIds.contains(id)) {
        _joinSubs[id]?.cancel();
        _joinSubs.remove(id);
      }
    }
    // Add/update listeners
    for (final d in qs.docs) {
      final accId = d.id;
      if (_joinSubs.containsKey(accId)) continue;
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
            final id = (title + body).hashCode & 0x7fffffff;
            NotificationService().showNow(id, title: title, body: body);
          }
        }
      });
    }
  }

  Future<void> stop() async {
    await _accountsSub?.cancel();
    _accountsSub = null;
    for (final s in _joinSubs.values) {
      await s?.cancel();
    }
    _joinSubs.clear();
  }
}
