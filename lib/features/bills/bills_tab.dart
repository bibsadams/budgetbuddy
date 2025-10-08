import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:intl/intl.dart';
import 'package:budgetbuddy/widgets/pressable_neumorphic.dart';
import 'package:budgetbuddy/widgets/app_gradient_background.dart';
import '../../services/notification_service.dart';

class BillsTab extends StatefulWidget {
  final List<Map<String, dynamic>> rows;
  final void Function(List<Map<String, dynamic>> newRows) onRowsChanged;

  const BillsTab({super.key, required this.rows, required this.onRowsChanged});

  @override
  State<BillsTab> createState() => _BillsTabState();
}

class _BillsTabState extends State<BillsTab> {
  String _sort = 'Due (soonest)';
  bool _searchExpanded = false;
  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final currency = NumberFormat.currency(symbol: '₱', decimalDigits: 2);
    // Build a stable index mapping sorted and filtered; display-only
    // We keep original indices for scheduling/cancel IDs
    bool _matchesQuery(Map<String, dynamic> r) {
      final q = _query.trim().toLowerCase();
      if (q.isEmpty) return true;
      final name = (r['Name'] ?? '').toString().toLowerCase();
      final note = (r['Note'] ?? '').toString().toLowerCase();
      final due = (r['Due Date'] ?? '').toString().toLowerCase();
      final time = (r['Time'] ?? '').toString().toLowerCase();
      final repeat = (r['Repeat'] ?? '').toString().toLowerCase();
      final amt = ((r['Amount'] ?? 0) as num).toString();
      return name.contains(q) ||
          note.contains(q) ||
          due.contains(q) ||
          time.contains(q) ||
          repeat.contains(q) ||
          amt.contains(q);
    }

    int _group(Map<String, dynamic> r) {
      final enabled = r['Enabled'] == true;
      final repeatStr = (r['Repeat'] ?? 'None').toString();
      final isOneTimePaid = !enabled && repeatStr == 'None';
      final dueStr = (r['Due Date'] ?? '') as String;
      final hasDue = dueStr.isNotEmpty && DateTime.tryParse(dueStr) != null;
      if (isOneTimePaid) return 2; // paid -> last
      if (!hasDue) return 1; // no due date -> near bottom
      return 0; // normal dated item
    }

    int _diffDays(Map<String, dynamic> r) {
      final dueStr = (r['Due Date'] ?? '') as String;
      final dt = DateTime.tryParse(dueStr);
      if (dt == null) return 1 << 20; // effectively large
      final today = DateTime.now();
      final d0 = DateTime(today.year, today.month, today.day);
      final due0 = DateTime(dt.year, dt.month, dt.day);
      return due0.difference(d0).inDays; // negative => overdue
    }

    List<int> _visibleSortedIndices() {
      final idx = <int>[];
      for (int i = 0; i < rows.length; i++) {
        if (_matchesQuery(rows[i])) idx.add(i);
      }
      int byDueAsc(int a, int b) {
        final ra = rows[a];
        final rb = rows[b];
        final ga = _group(ra);
        final gb = _group(rb);
        if (ga != gb) return ga.compareTo(gb);
        if (ga == 0) {
          final da = _diffDays(ra);
          final db = _diffDays(rb);
          if (da != db) return da.compareTo(db);
        }
        final na = (ra['Name'] ?? '').toString().toLowerCase();
        final nb = (rb['Name'] ?? '').toString().toLowerCase();
        return na.compareTo(nb);
      }

      int byDueDesc(int a, int b) => byDueAsc(b, a);
      int byAmtHigh(int a, int b) => ((rows[b]['Amount'] ?? 0) as num)
          .compareTo((rows[a]['Amount'] ?? 0) as num);
      int byAmtLow(int a, int b) => -byAmtHigh(a, b);
      int byName(int a, int b) {
        final na = (rows[a]['Name'] ?? '').toString().toLowerCase();
        final nb = (rows[b]['Name'] ?? '').toString().toLowerCase();
        return na.compareTo(nb);
      }

      switch (_sort) {
        case 'Due (latest)':
          idx.sort(byDueDesc);
          break;
        case 'Amount (high → low)':
          idx.sort(byAmtHigh);
          break;
        case 'Amount (low → high)':
          idx.sort(byAmtLow);
          break;
        case 'Name (A→Z)':
          idx.sort(byName);
          break;
        case 'Due (soonest)':
        default:
          idx.sort(byDueAsc);
      }
      return idx;
    }

    final sortedIndices = _visibleSortedIndices();
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppGradientBackground(
        child: Column(
          children: [
            // Header: search + sort controls
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    transitionBuilder: (child, anim) => FadeTransition(
                      opacity: anim,
                      child: ScaleTransition(
                        scale: Tween<double>(
                          begin: 0.95,
                          end: 1.0,
                        ).animate(anim),
                        child: child,
                      ),
                    ),
                    child: _searchExpanded
                        ? Padding(
                            key: const ValueKey('bills-search-expanded'),
                            padding: const EdgeInsets.only(bottom: 8),
                            child: PressableNeumorphic(
                              borderRadius: 16,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 4,
                              ),
                              child: Row(
                                children: [
                                  const Icon(Icons.search, size: 18),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: TextField(
                                      controller: _searchCtrl,
                                      autofocus: true,
                                      decoration: const InputDecoration(
                                        hintText: 'Search bills…',
                                        border: InputBorder.none,
                                      ),
                                      onChanged: (v) =>
                                          setState(() => _query = v),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Clear',
                                    icon: const Icon(Icons.close, size: 20),
                                    onPressed: () {
                                      setState(() {
                                        _searchCtrl.clear();
                                        _query = '';
                                        _searchExpanded = false;
                                      });
                                    },
                                  ),
                                ],
                              ),
                            ),
                          )
                        : const SizedBox.shrink(
                            key: ValueKey('bills-search-collapsed'),
                          ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        PressableNeumorphic(
                          borderRadius: 24,
                          padding: const EdgeInsets.all(8),
                          onTap: () => setState(() => _searchExpanded = true),
                          child: const Icon(Icons.search),
                        ),
                        const SizedBox(width: 8),
                        PopupMenuButton<String>(
                          tooltip: 'Sort',
                          onSelected: (v) => setState(() => _sort = v),
                          itemBuilder: (ctx) => const [
                            PopupMenuItem(
                              value: 'Due (soonest)',
                              child: Text('Due (soonest)'),
                            ),
                            PopupMenuItem(
                              value: 'Due (latest)',
                              child: Text('Due (latest)'),
                            ),
                            PopupMenuItem(
                              value: 'Amount (high → low)',
                              child: Text('Amount (high → low)'),
                            ),
                            PopupMenuItem(
                              value: 'Amount (low → high)',
                              child: Text('Amount (low → high)'),
                            ),
                            PopupMenuItem(
                              value: 'Name (A→Z)',
                              child: Text('Name (A→Z)'),
                            ),
                          ],
                          child: PressableNeumorphic(
                            borderRadius: 24,
                            padding: const EdgeInsets.all(8),
                            child: const Icon(Icons.filter_list),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: sortedIndices.isEmpty
                  ? const Center(child: Text("No bills yet. Tap '+' to add."))
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 96),
                      itemCount: sortedIndices.length,
                      itemBuilder: (context, index) {
                        final origIndex = sortedIndices[index];
                        final bill = rows[origIndex];
                        final enabled = bill['Enabled'] == true;
                        final repeatStr = (bill['Repeat'] ?? 'None') as String;
                        final bool isOneTimePaid =
                            !enabled && repeatStr == 'None';
                        // Compute days-left info based on Due Date (yyyy-MM-dd)
                        final String dueDateStr =
                            (bill['Due Date'] ?? '') as String;
                        String daysInfo = '';
                        if (dueDateStr.isNotEmpty) {
                          final dt = DateTime.tryParse(dueDateStr);
                          if (dt != null) {
                            final today = DateTime.now();
                            final d0 = DateTime(
                              today.year,
                              today.month,
                              today.day,
                            );
                            final due0 = DateTime(dt.year, dt.month, dt.day);
                            final diff = due0.difference(d0).inDays;
                            if (diff > 1) {
                              daysInfo = 'Due in $diff days';
                            } else if (diff == 1) {
                              daysInfo = 'Due tomorrow';
                            } else if (diff == 0) {
                              daysInfo = 'Due today';
                            } else {
                              daysInfo =
                                  'Overdue by ${-diff} day${diff == -1 ? '' : 's'}';
                            }
                          }
                        }
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          child: PressableNeumorphic(
                            borderRadius: 16,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            child: ListTile(
                              visualDensity: const VisualDensity(
                                horizontal: -2,
                                vertical: -2,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              leading: Icon(
                                Icons.receipt_long_outlined,
                                color: enabled
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.grey,
                              ),
                              title: Text(bill['Name'] ?? 'Untitled'),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "${currency.format((bill['Amount'] ?? 0) as num)}  •  ${bill['Due Date'] ?? ''}  ${bill['Time'] ?? ''}",
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (isOneTimePaid) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      'Paid',
                                      style: TextStyle(
                                        color: Colors.green[700],
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ] else if (daysInfo.isNotEmpty) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      daysInfo,
                                      style: TextStyle(
                                        color: daysInfo.startsWith('Overdue')
                                            ? Colors.red
                                            : (daysInfo == 'Due today'
                                                  ? Colors.orange
                                                  : Colors.grey[700]),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              trailing: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Transform.scale(
                                      scale: 0.85,
                                      child: Switch(
                                        value: enabled,
                                        onChanged: (v) async {
                                          final updated =
                                              Map<String, dynamic>.from(bill);
                                          updated['Enabled'] = v;
                                          final newRows =
                                              List<Map<String, dynamic>>.from(
                                                rows,
                                              );
                                          newRows[origIndex] = updated;
                                          widget.onRowsChanged(newRows);
                                          await _scheduleIfNeeded(
                                            origIndex,
                                            updated,
                                          );
                                        },
                                      ),
                                    ),
                                    if (!isOneTimePaid) ...[
                                      IconButton(
                                        iconSize: 20,
                                        padding: EdgeInsets.zero,
                                        constraints:
                                            const BoxConstraints.tightFor(
                                              width: 32,
                                              height: 32,
                                            ),
                                        tooltip: 'Mark as paid',
                                        icon: Icon(
                                          Icons.autorenew,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.tertiary,
                                        ),
                                        onPressed: () async {
                                          final updated =
                                              Map<String, dynamic>.from(bill);
                                          final repeat =
                                              (updated['Repeat'] ?? 'None')
                                                  .toString()
                                                  .toLowerCase();
                                          if (repeat == 'none') {
                                            // One-time: disable reminders and mark as paid
                                            updated['Enabled'] = false;
                                            final newRows =
                                                List<Map<String, dynamic>>.from(
                                                  rows,
                                                );
                                            newRows[origIndex] = updated;
                                            widget.onRowsChanged(newRows);
                                            await _scheduleIfNeeded(
                                              origIndex,
                                              updated,
                                            );
                                          } else {
                                            // Recurring: advance Due Date to the next cycle after today
                                            final currentDueStr =
                                                (updated['Due Date'] ?? '')
                                                    as String;
                                            final currentDue =
                                                currentDueStr.isEmpty
                                                ? null
                                                : DateTime.tryParse(
                                                    currentDueStr,
                                                  );
                                            if (currentDue != null) {
                                              final nextDate =
                                                  _nextOccurrenceDateOnly(
                                                    currentDue,
                                                    repeat,
                                                  );
                                              updated['Due Date'] = _fmtYMD(
                                                nextDate,
                                              );
                                              final newRows =
                                                  List<
                                                    Map<String, dynamic>
                                                  >.from(rows);
                                              newRows[origIndex] = updated;
                                              widget.onRowsChanged(newRows);
                                              await _scheduleIfNeeded(
                                                origIndex,
                                                updated,
                                              );
                                            }
                                          }
                                        },
                                      ),
                                    ],
                                    // Edit icon removed (tap the row to edit)
                                    IconButton(
                                      iconSize: 20,
                                      padding: EdgeInsets.zero,
                                      constraints:
                                          const BoxConstraints.tightFor(
                                            width: 32,
                                            height: 32,
                                          ),
                                      icon: const Icon(
                                        Icons.delete,
                                        color: Colors.redAccent,
                                      ),
                                      onPressed: () async {
                                        final confirm = await showDialog<bool>(
                                          context: context,
                                          builder: (d) => AlertDialog(
                                            title: const Text('Delete Bill'),
                                            content: const Text(
                                              'Delete this bill and its reminder?',
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.of(d).pop(false),
                                                child: const Text('Cancel'),
                                              ),
                                              TextButton(
                                                onPressed: () =>
                                                    Navigator.of(d).pop(true),
                                                child: const Text('Delete'),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (confirm == true) {
                                          final newRows =
                                              List<Map<String, dynamic>>.from(
                                                rows,
                                              );
                                          newRows.removeAt(origIndex);
                                          widget.onRowsChanged(newRows);
                                          // Cancel the entire notification series for this bill
                                          for (final id in _seriesIds(
                                            origIndex,
                                          )) {
                                            await NotificationService().cancel(
                                              id,
                                            );
                                          }
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ),
                              onTap: () async {
                                final edited =
                                    await Navigator.push<Map<String, dynamic>>(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            _BillEditPage(initial: bill),
                                      ),
                                    );
                                if (edited != null) {
                                  final merged = {
                                    ...bill,
                                    ...edited,
                                    if (bill['id'] != null) 'id': bill['id'],
                                  };
                                  final newRows =
                                      List<Map<String, dynamic>>.from(rows);
                                  newRows[origIndex] = merged;
                                  widget.onRowsChanged(newRows);
                                  await _scheduleIfNeeded(origIndex, merged);
                                }
                              },
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'bills-fab',
        icon: const Icon(Icons.add_alert),
        label: const Text('Add Bill Reminder'),
        onPressed: () async {
          final created = await Navigator.push<Map<String, dynamic>>(
            context,
            MaterialPageRoute(builder: (_) => const _BillEditPage()),
          );
          if (created != null) {
            final newRows = List<Map<String, dynamic>>.from(rows)..add(created);
            widget.onRowsChanged(newRows);
            await _scheduleIfNeeded(newRows.length - 1, created);
          }
        },
      ),
    );
  }

  // Reserve a large ID range per bill to support multiple reminders per day
  static int _notifIdFromIndex(int index) => 5000 + index * 1000;

  static Iterable<int> _seriesIds(int index) sync* {
    final base = _notifIdFromIndex(index);
    // New scheme: cancel a wide range reserved per bill
    for (int i = 0; i < 1000; i++) {
      yield base + i;
    }
    // Back-compat: also cancel the older narrow range that used 5000+index+offset
    final oldBase = 5000 + index;
    for (int i = 0; i < 20; i++) {
      yield oldBase + i;
    }
  }

  static Future<void> _scheduleIfNeeded(
    int index,
    Map<String, dynamic> bill,
  ) async {
    final enabled = bill['Enabled'] == true;
    if (!enabled) {
      // Cancel any pending reminders for this bill
      for (final id in _seriesIds(index)) {
        await NotificationService().cancel(id);
      }
      return;
    }

    final name = (bill['Name'] ?? 'Bill') as String;
    final billId = (bill['id'] ?? '').toString();
    final amount = bill['Amount'] is num
        ? (bill['Amount'] as num).toDouble()
        : 0.0;
    final dateStr = (bill['Due Date'] ?? '') as String; // yyyy-MM-dd
    final timeStrRaw = (bill['Time'] ?? '') as String; // may be blank
    final timeStr = timeStrRaw.trim().isEmpty ? '09:00' : timeStrRaw; // HH:mm
    final repeatStr = (bill['Repeat'] ?? 'None') as String;
    final repeat = _parseRepeat(repeatStr);

    if (dateStr.isEmpty) return;
    final parts = dateStr.split('-');
    if (parts.length != 3) return;
    final year = int.tryParse(parts[0]) ?? DateTime.now().year;
    final month = int.tryParse(parts[1]) ?? DateTime.now().month;
    final day = int.tryParse(parts[2]) ?? DateTime.now().day;
    final hm = timeStr.split(':');
    final hour = (hm.isNotEmpty ? int.tryParse(hm[0]) : null) ?? 9;
    final minute = (hm.length > 1 ? int.tryParse(hm[1]) : null) ?? 0;

    final due = DateTime(year, month, day, hour, minute);

    // Cancel any previous series before rescheduling
    for (final id in _seriesIds(index)) {
      await NotificationService().cancel(id);
    }

    // Schedule daily countdown notifications within last 7 days
    final now = DateTime.now();
    final startWindow = due.subtract(const Duration(days: 7));
    final start = now.isAfter(startWindow)
        ? DateTime(now.year, now.month, now.day, hour, minute)
        : DateTime(
            startWindow.year,
            startWindow.month,
            startWindow.day,
            hour,
            minute,
          );

    // Configurable notifications per day at fixed local times to avoid crossing midnight.
    // Use daytime slots compatible with PH time. Adjust here if you prefer different windows.
    const allSlots = <int>[
      9,
      10,
      12,
      14,
      16,
      18,
      20,
      21,
    ]; // hours in local time
    final remindersPerDay = (bill['RemindersPerDay'] is num)
        ? (bill['RemindersPerDay'] as num).clamp(0, 8).toInt()
        : 8;
    final dailySlots = allSlots.take(remindersPerDay).toList();
    final base = _notifIdFromIndex(index);
    int dayIndex = 0;
    for (
      DateTime d = start;
      !d.isAfter(due);
      d = d.add(const Duration(days: 1))
    ) {
      final daysLeft = DateTime(
        due.year,
        due.month,
        due.day,
      ).difference(DateTime(d.year, d.month, d.day)).inDays;
      String whenLabel;
      if (daysLeft > 1) {
        whenLabel = '$daysLeft days left';
      } else if (daysLeft == 1) {
        whenLabel = 'Tomorrow';
      } else {
        whenLabel = 'Today';
      }
      final title = 'Bill due: $name';
      final body =
          '${NumberFormat.currency(symbol: '₱', decimalDigits: 2).format(amount)} • $whenLabel • due $dateStr $timeStr';

      for (int slot = 0; slot < dailySlots.length; slot++) {
        final slotHour = dailySlots[slot];
        // Align minutes to 0 so the reminders are predictable within the hour.
        final dt = DateTime(d.year, d.month, d.day, slotHour, 0);
        if (dt.isAfter(now)) {
          final id = base + (dayIndex * dailySlots.length) + slot;
          await NotificationService().schedule(
            id,
            title: title,
            body: body,
            firstDateTime: dt,
            repeat: RepeatIntervalMode.none,
            payload: billId.isNotEmpty ? 'bill:$billId' : 'bill:$name',
          );
        }
      }
      dayIndex++;
    }

    // Also schedule the main due-time notification with optional repeat rule.
    // Clamp to non-sleep hours (morning/afternoon/early night) to avoid late-night pushes.
    const earliestHour = 9; // 9 AM
    const latestHour = 21; // 9 PM
    DateTime dueClamped;
    if (due.hour < earliestHour) {
      dueClamped = DateTime(due.year, due.month, due.day, earliestHour, 0);
    } else if (due.hour > latestHour) {
      dueClamped = DateTime(due.year, due.month, due.day, latestHour, 0);
    } else {
      // keep the due minute if within allowed window
      dueClamped = DateTime(due.year, due.month, due.day, due.hour, due.minute);
    }

    final finalTitle = 'Bill due: $name';
    final finalBody =
        '${NumberFormat.currency(symbol: '₱', decimalDigits: 2).format(amount)} due on $dateStr at $timeStr';
    // Use a stable high slot within the reserved range for the final due-time reminder
    await NotificationService().schedule(
      _notifIdFromIndex(index) + 999,
      title: finalTitle,
      body: finalBody,
      firstDateTime: dueClamped,
      repeat: repeat,
      payload: billId.isNotEmpty ? 'bill:$billId' : 'bill:$name',
    );
  }

  static RepeatIntervalMode _parseRepeat(String s) {
    switch (s.toLowerCase()) {
      case 'weekly':
        return RepeatIntervalMode.weekly;
      case 'monthly':
        return RepeatIntervalMode.monthly;
      case 'yearly':
        return RepeatIntervalMode.yearly;
      default:
        return RepeatIntervalMode.none;
    }
  }

  // Helpers to compute the next occurrence date (date-only) strictly after today
  static DateTime _today0() {
    final t = DateTime.now();
    return DateTime(t.year, t.month, t.day);
  }

  static DateTime _nextOccurrenceDateOnly(DateTime due, String repeat) {
    final today = _today0();
    DateTime d = DateTime(due.year, due.month, due.day);
    switch (repeat) {
      case 'weekly':
        while (!d.isAfter(today)) {
          d = d.add(const Duration(days: 7));
        }
        return d;
      case 'monthly':
        while (!d.isAfter(today)) {
          d = _addMonthsClamped(d, 1);
        }
        return d;
      case 'yearly':
        while (!d.isAfter(today)) {
          d = _addYearsClamped(d, 1);
        }
        return d;
      default:
        return d; // none - shouldn't be called in that case
    }
  }

  static DateTime _addMonthsClamped(DateTime d, int months) {
    int y = d.year;
    int m = d.month + months;
    while (m > 12) {
      y++;
      m -= 12;
    }
    while (m < 1) {
      y--;
      m += 12;
    }
    final lastDay = DateTime(y, m + 1, 0).day;
    final day = d.day <= lastDay ? d.day : lastDay;
    return DateTime(y, m, day);
  }

  static DateTime _addYearsClamped(DateTime d, int years) {
    final y = d.year + years;
    final m = d.month;
    final lastDay = DateTime(y, m + 1, 0).day;
    final day = d.day <= lastDay ? d.day : lastDay;
    return DateTime(y, m, day);
  }

  static String _fmtYMD(DateTime d) =>
      "${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}";
}

class _BillEditPage extends StatefulWidget {
  final Map<String, dynamic>? initial;
  const _BillEditPage({this.initial});

  @override
  State<_BillEditPage> createState() => _BillEditPageState();
}

class _BillEditPageState extends State<_BillEditPage> {
  late TextEditingController _name;
  late TextEditingController _amount;
  late TextEditingController _date; // yyyy-MM-dd
  late TextEditingController _time; // HH:mm
  late TextEditingController _note;
  String _repeat = 'None';
  bool _enabled = true;
  int _remindersPerDay = 8; // default 8 per day

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _name = TextEditingController(text: widget.initial?['Name'] ?? '');
    _amount = TextEditingController(
      text: widget.initial?['Amount'] is num
          ? (widget.initial!['Amount'] as num).toString()
          : '',
    );
    _date = TextEditingController(
      text:
          widget.initial?['Due Date'] ??
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}",
    );
    _time = TextEditingController(text: widget.initial?['Time'] ?? '');
    _repeat = widget.initial?['Repeat'] ?? 'None';
    _enabled = widget.initial?['Enabled'] ?? true;
    _note = TextEditingController(text: widget.initial?['Note'] ?? '');
    _remindersPerDay = (widget.initial?['RemindersPerDay'] is num)
        ? (widget.initial!['RemindersPerDay'] as num).clamp(0, 8).toInt()
        : 8;
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _date.dispose();
    _time.dispose();
    _note.dispose();
    super.dispose();
  }

  bool get _canSave {
    final amt = double.tryParse(_amount.text.replaceAll(',', '')) ?? 0.0;
    // Only require name and amount
    return _name.text.trim().isNotEmpty && amt > 0;
  }

  Future<void> _pickDate() async {
    final init = DateTime.tryParse(_date.text) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _date.text =
            "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}";
      });
    }
  }

  Future<void> _pickTime() async {
    final parts = _time.text.split(':');
    final hourStr = parts.isNotEmpty ? parts[0] : '9';
    final minuteStr = parts.length > 1 ? parts[1] : '0';
    final init = TimeOfDay(
      hour: int.tryParse(hourStr) ?? 9,
      minute: int.tryParse(minuteStr) ?? 0,
    );
    final picked = await showTimePicker(context: context, initialTime: init);
    if (picked != null) {
      setState(() {
        _time.text =
            "${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppGradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          flexibleSpace: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Container(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.06),
              ),
            ),
          ),
          title: Text(widget.initial == null ? 'Add Bill' : 'Edit Bill'),
          actions: [
            IconButton(
              icon: Icon(
                Icons.save,
                color: _canSave ? Theme.of(context).colorScheme.primary : null,
              ),
              tooltip: _canSave ? 'Save' : 'Fill required fields',
              onPressed: _canSave
                  ? () {
                      final data = <String, dynamic>{
                        'Name': _name.text.trim(),
                        'Amount':
                            double.tryParse(_amount.text.replaceAll(',', '')) ??
                            0.0,
                        'Due Date': _date.text,
                        'Time': _time.text,
                        'Repeat': _repeat,
                        'Enabled': _enabled,
                        'Note': _note.text.trim(),
                        'RemindersPerDay': _remindersPerDay,
                        if (widget.initial?['id'] != null)
                          'id': widget.initial!['id'],
                      };
                      Navigator.pop(context, data);
                    }
                  : null,
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.of(context).padding.top + kToolbarHeight + 8,
            16,
            16,
          ),
          child: PressableNeumorphic(
            borderRadius: 16,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Bill name',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Amount',
                    prefixIcon: Icon(Icons.payments_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _note,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Note (optional)',
                    prefixIcon: Icon(Icons.note_alt_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _date,
                        readOnly: true,
                        onTap: _pickDate,
                        decoration: const InputDecoration(
                          labelText: 'Due date',
                          prefixIcon: Icon(Icons.event_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _time,
                        readOnly: true,
                        onTap: _pickTime,
                        decoration: const InputDecoration(
                          labelText: 'Time',
                          prefixIcon: Icon(Icons.access_time),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _repeat,
                        decoration: const InputDecoration(
                          labelText: 'Repeat',
                          prefixIcon: Icon(Icons.repeat),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'None',
                            child: Text('One time'),
                          ),
                          DropdownMenuItem(
                            value: 'Weekly',
                            child: Text('Weekly'),
                          ),
                          DropdownMenuItem(
                            value: 'Monthly',
                            child: Text('Monthly'),
                          ),
                          DropdownMenuItem(
                            value: 'Yearly',
                            child: Text('Yearly'),
                          ),
                        ],
                        onChanged: (v) => setState(() => _repeat = v ?? 'None'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        initialValue: _remindersPerDay,
                        decoration: const InputDecoration(
                          labelText: 'Reminders per day',
                          prefixIcon: Icon(Icons.notifications_active_outlined),
                        ),
                        items: List.generate(
                          9,
                          (i) => DropdownMenuItem(
                            value: i,
                            child: Text(i == 0 ? 'Off (0)' : '$i per day'),
                          ),
                        ),
                        onChanged: (v) => setState(
                          () => _remindersPerDay = (v ?? 8).clamp(0, 8),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Row(
                      children: [
                        const Text('Reminder'),
                        const SizedBox(width: 8),
                        Switch(
                          value: _enabled,
                          onChanged: (v) => setState(() => _enabled = v),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        bottomNavigationBar: Padding(
          padding: const EdgeInsets.all(16),
          child: PressableNeumorphic(
            borderRadius: 16,
            child: ElevatedButton.icon(
              onPressed: _canSave
                  ? () {
                      final data = <String, dynamic>{
                        'Name': _name.text.trim(),
                        'Amount':
                            double.tryParse(_amount.text.replaceAll(',', '')) ??
                            0.0,
                        'Due Date': _date.text,
                        'Time': _time.text,
                        'Repeat': _repeat,
                        'Enabled': _enabled,
                        'Note': _note.text.trim(),
                        'RemindersPerDay': _remindersPerDay,
                        if (widget.initial?['id'] != null)
                          'id': widget.initial!['id'],
                      };
                      Navigator.pop(context, data);
                    }
                  : null,
              icon: const Icon(Icons.save),
              label: const Text('Save Bill'),
            ),
          ),
        ),
      ),
    );
  }
}
