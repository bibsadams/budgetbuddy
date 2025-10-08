import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'notification_service.dart';
import 'package:hive/hive.dart';

class PushMessagingService {
  PushMessagingService._();
  static final PushMessagingService _i = PushMessagingService._();
  factory PushMessagingService() => _i;

  final _fcm = FirebaseMessaging.instance;

  Future<void> requestPermission() async {
    try {
      await _fcm.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        criticalAlert: false,
        provisional: false,
      );
    } catch (_) {}
  }

  Future<void> registerTokenIfPossible() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      // Ensure permission on iOS/macOS; Android 13+ also requires runtime permission
      await requestPermission();
      final token = await _fcm.getToken();
      if (token == null || token.isEmpty) return;
      // Determine canonical user doc id (adopted id), fallback to uid
      String canonicalId = user.uid;
      try {
        final box = Hive.box('budgetBox');
        final adopted = box.get('userDocId_${user.uid}') as String?;
        if (adopted != null && adopted.isNotEmpty) canonicalId = adopted;
      } catch (_) {}

      final users = FirebaseFirestore.instance.collection('users');
      final uidTokRef = users.doc(user.uid).collection('tokens').doc(token);
      final canonTokRef = users
          .doc(canonicalId)
          .collection('tokens')
          .doc(token);
      final payload = {
        'token': token,
        'platform': Platform.isAndroid
            ? 'android'
            : (Platform.isIOS ? 'ios' : 'other'),
        'createdAt': FieldValue.serverTimestamp(),
        'lastSeenAt': FieldValue.serverTimestamp(),
        'appVersion': null,
        'device': null,
      };
      await uidTokRef.set(payload, SetOptions(merge: true));
      if (canonicalId != user.uid) {
        await canonTokRef.set(payload, SetOptions(merge: true));
      }

      // Listen for token refresh
      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        final uidRef = users.doc(user.uid).collection('tokens').doc(newToken);
        final canonRef = users
            .doc(canonicalId)
            .collection('tokens')
            .doc(newToken);
        final p = {
          'token': newToken,
          'platform': Platform.isAndroid
              ? 'android'
              : (Platform.isIOS ? 'ios' : 'other'),
          'createdAt': FieldValue.serverTimestamp(),
          'lastSeenAt': FieldValue.serverTimestamp(),
        };
        await uidRef.set(p, SetOptions(merge: true));
        if (canonicalId != user.uid) {
          await canonRef.set(p, SetOptions(merge: true));
        }
      });

      // Foreground notifications: show a heads-up using local notifications
      FirebaseMessaging.onMessage.listen((RemoteMessage m) async {
        final notif = m.notification;
        if (notif != null) {
          // Use a simple incremental id by hashing the title/body
          final id = (notif.title ?? notif.body ?? '').hashCode & 0x7fffffff;
          await NotificationService().showNow(
            id,
            title: notif.title ?? 'BudgetBuddy',
            body: notif.body ?? '',
          );
        }
      });

      // If app opened from tap, you may route using NotificationService already
      FirebaseMessaging.onMessageOpenedApp.listen((m) async {
        final accountId = m.data['accountId'];
        if (accountId is String && accountId.isNotEmpty) {
          // Best-effort: emit a payload for app navigation handlers
          // Consumers are already subscribed to NotificationService.onNotificationTap
          await NotificationService().showNow(
            DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
            title: 'Open account',
            body: 'Account: $accountId',
          );
        }
      });
    } catch (_) {
      // Silent failure acceptable during development
    }
  }
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Keep minimal; OS will display notification payload. If a data-only message arrives,
  // we could schedule a local notification here if needed.
}
