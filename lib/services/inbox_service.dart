import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'notification_service.dart';

/// Lightweight client-side inbox watcher to surface important events
/// (like join requests) as local notifications without requiring
/// Cloud Functions. Listens to users/{uid}/inbox where acknowledged=false
/// and shows a heads-up notification, then marks acknowledged=true.
class InboxService {
  InboxService._();
  static final InboxService _i = InboxService._();
  factory InboxService() => _i;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;

  Future<void> startForCurrentUser() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    await start(uid);
  }

  Future<void> start(String uid) async {
    await stop();
    final col = FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .collection('inbox');
    _sub = col
        .where('acknowledged', isEqualTo: false)
        .orderBy('createdAt', descending: false)
        .snapshots()
        .listen((qs) async {
          for (final change in qs.docChanges) {
            // Handle both added and modified to cover serverTimestamp updates
            if (change.type != DocumentChangeType.added &&
                change.type != DocumentChangeType.modified)
              continue;
            final data = change.doc.data() ?? {};
            final title = (data['title'] as String?) ?? 'Notification';
            final body = (data['body'] as String?) ?? '';
            // Use doc id to avoid notification id collisions on similar messages
            final id = (title + body + change.doc.id).hashCode & 0x7fffffff;
            await NotificationService().showNow(id, title: title, body: body);
            // Mark acknowledged to avoid repeats
            try {
              await change.doc.reference.set({
                'acknowledged': true,
                'acknowledgedAt': FieldValue.serverTimestamp(),
              }, SetOptions(merge: true));
            } catch (_) {}
          }
        });
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }
}
