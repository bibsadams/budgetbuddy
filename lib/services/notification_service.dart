import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tzdata;

enum RepeatIntervalMode { none, weekly, monthly, yearly }

class NotificationService {
  NotificationService._internal();
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );
    await _plugin.initialize(initSettings);
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
  }

  Future<void> cancel(int id) async {
    await _plugin.cancel(id);
  }

  Future<void> schedule(
    int id, {
    required String title,
    required String body,
    required DateTime firstDateTime,
    RepeatIntervalMode repeat = RepeatIntervalMode.none,
  }) async {
    await init();

    final tz.TZDateTime tzTime = tz.TZDateTime.from(firstDateTime, tz.local);
    const androidDetails = AndroidNotificationDetails(
      'bills_channel',
      'Bills & Reminders',
      channelDescription: 'Bill due reminders',
      importance: Importance.max,
      priority: Priority.high,
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
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            matchDateTimeComponents: null,
          );
          break;
        case RepeatIntervalMode.weekly:
          await _plugin.zonedSchedule(
            id,
            title,
            body,
            _nextWeekly(tzTime),
            details,
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
          );
          break;
        case RepeatIntervalMode.monthly:
          await _plugin.zonedSchedule(
            id,
            title,
            body,
            _nextMonthly(tzTime),
            details,
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            matchDateTimeComponents: DateTimeComponents.dayOfMonthAndTime,
          );
          break;
        case RepeatIntervalMode.yearly:
          await _plugin.zonedSchedule(
            id,
            title,
            body,
            _nextYearly(tzTime),
            details,
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            uiLocalNotificationDateInterpretation:
                UILocalNotificationDateInterpretation.absoluteTime,
            matchDateTimeComponents: DateTimeComponents.dateAndTime,
          );
          break;
      }
    } catch (e) {
      // Gracefully ignore scheduling failures (e.g., exact alarms not permitted)
      // Optionally, you could fallback to a basic show() here or log to a box.
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
}
