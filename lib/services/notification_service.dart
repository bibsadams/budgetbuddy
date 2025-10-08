import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:flutter_timezone/flutter_timezone.dart';

enum RepeatIntervalMode { none, weekly, monthly, yearly }

class NotificationService {
  NotificationService._internal();
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  final StreamController<String> _tapController =
      StreamController<String>.broadcast();
  Stream<String> get onNotificationTap => _tapController.stream;
  String? _initialLaunchPayload;

  Future<void> init() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      final name = (info as dynamic).name as String? ?? info.toString();
      tz.setLocalLocation(tz.getLocation(name));
    } catch (_) {
      // Fallback: keep default local
    }

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );
    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse r) {
        final p = r.payload;
        if (p != null && p.isNotEmpty) {
          _tapController.add(p);
        }
      },
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );
    // Request permissions where required
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.requestNotificationsPermission();
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    await ios?.requestPermissions(alert: true, badge: true, sound: true);
    _initialized = true;

    // If the app was launched via a notification tap, emit its payload
    final details = await _plugin.getNotificationAppLaunchDetails();
    final resp = details?.notificationResponse;
    final p = resp?.payload;
    if (p != null && p.isNotEmpty) {
      _initialLaunchPayload = p;
      // Defer to ensure listeners are attached
      Future.microtask(() => _tapController.add(p));
    }
  }

  Future<void> cancel(int id) async {
    await _plugin.cancel(id);
  }

  Future<void> showNow(
    int id, {
    required String title,
    required String body,
  }) async {
    await init();
    const androidDetails = AndroidNotificationDetails(
      'general_channel',
      'General',
      channelDescription: 'General notifications',
      importance: Importance.max,
      priority: Priority.high,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
    await _plugin.show(id, title, body, details);
  }

  Future<void> schedule(
    int id, {
    required String title,
    required String body,
    required DateTime firstDateTime,
    RepeatIntervalMode repeat = RepeatIntervalMode.none,
    String? payload,
  }) async {
    await init();

    final tz.TZDateTime tzTime = tz.TZDateTime.from(firstDateTime, tz.local);
    const androidDetails = AndroidNotificationDetails(
      'bills_channel',
      'Bills & Reminders',
      channelDescription: 'Bill due reminders',
      importance: Importance.max,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );
    const iosDetails = DarwinNotificationDetails();
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    try {
      switch (repeat) {
        case RepeatIntervalMode.none:
          await _plugin.zonedSchedule(
            id,
            title,
            body,
            tzTime,
            details,
            androidScheduleMode: AndroidScheduleMode.exact,
            matchDateTimeComponents: null,
            payload: payload,
          );
          break;
        case RepeatIntervalMode.weekly:
          await _plugin.zonedSchedule(
            id,
            title,
            body,
            _nextWeekly(tzTime),
            details,
            androidScheduleMode: AndroidScheduleMode.exact,
            matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
            payload: payload,
          );
          break;
        case RepeatIntervalMode.monthly:
          await _plugin.zonedSchedule(
            id,
            title,
            body,
            _nextMonthly(tzTime),
            details,
            androidScheduleMode: AndroidScheduleMode.exact,
            matchDateTimeComponents: DateTimeComponents.dayOfMonthAndTime,
            payload: payload,
          );
          break;
        case RepeatIntervalMode.yearly:
          await _plugin.zonedSchedule(
            id,
            title,
            body,
            _nextYearly(tzTime),
            details,
            androidScheduleMode: AndroidScheduleMode.exact,
            matchDateTimeComponents: DateTimeComponents.dateAndTime,
            payload: payload,
          );
          break;
      }
    } catch (e) {
      // Fallback: if scheduling failed, fire an immediate notification so the user still gets alerted
      await showNow(id, title: title, body: body);
    }
  }

  tz.TZDateTime _nextWeekly(tz.TZDateTime dt) {
    // If time is in the past today, move to next week same weekday/time
    var scheduled = tz.TZDateTime(
      tz.local,
      dt.year,
      dt.month,
      dt.day,
      dt.hour,
      dt.minute,
    );
    if (scheduled.isBefore(tz.TZDateTime.now(tz.local))) {
      scheduled = scheduled.add(const Duration(days: 7));
    }
    return scheduled;
  }

  tz.TZDateTime _nextMonthly(tz.TZDateTime dt) {
    final now = tz.TZDateTime.now(tz.local);
    var year = now.year;
    var month = now.month;
    final day = dt.day;
    var scheduled = tz.TZDateTime(
      tz.local,
      year,
      month,
      day,
      dt.hour,
      dt.minute,
    );
    if (scheduled.isBefore(now)) {
      month += 1;
      if (month > 12) {
        month = 1;
        year += 1;
      }
      scheduled = tz.TZDateTime(tz.local, year, month, day, dt.hour, dt.minute);
    }
    return scheduled;
  }

  tz.TZDateTime _nextYearly(tz.TZDateTime dt) {
    final now = tz.TZDateTime.now(tz.local);
    var year = now.year;
    var scheduled = tz.TZDateTime(
      tz.local,
      year,
      dt.month,
      dt.day,
      dt.hour,
      dt.minute,
    );
    if (scheduled.isBefore(now)) {
      scheduled = tz.TZDateTime(
        tz.local,
        year + 1,
        dt.month,
        dt.day,
        dt.hour,
        dt.minute,
      );
    }
    return scheduled;
  }

  /// Returns and clears the payload if the app was launched by tapping
  /// a notification while it was terminated.
  String? consumeInitialLaunchPayload() {
    final p = _initialLaunchPayload;
    _initialLaunchPayload = null;
    return p;
  }
}

@pragma('vm:entry-point')
void notificationTapBackground(NotificationResponse response) {
  // No-op: the response will be delivered again in onDidReceiveNotificationResponse
}
