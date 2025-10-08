import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'services/shared_account_repository.dart';
import 'services/notification_service.dart';

class ManageAccountsPage extends StatefulWidget {
  const ManageAccountsPage({super.key});
  @override
  State<ManageAccountsPage> createState() => _ManageAccountsPageState();
}

class _ManageAccountsPageState extends State<ManageAccountsPage> {
  late Box box;
  List<String> accounts = [];
  Map<String, String> aliases = {};
  String? active;

  @override
  void initState() {
    super.initState();
    box = Hive.box('budgetBox');
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final linkedKey = uid != null ? 'linkedAccounts_$uid' : 'linkedAccounts';
    final aliasesKey = uid != null ? 'accountAliases_$uid' : 'accountAliases';
    final activeKey = uid != null ? 'accountId_$uid' : 'accountId';
    // Read per-user with migration from legacy global keys
    final laUser = box.get(linkedKey);
    if (laUser is List && laUser.isNotEmpty) {
      accounts = List<String>.from(laUser);
    } else {
      final laLegacy = box.get('linkedAccounts');
      accounts = List<String>.from(laLegacy ?? []);
      if (uid != null && accounts.isNotEmpty) box.put(linkedKey, accounts);
    }
    // UI-only aggregation: include accounts known from other users on this device
    final merged = <String>{...accounts};
    final deviceKnown = box.get('linkedAccounts_device');
    if (deviceKnown is List && deviceKnown.isNotEmpty) {
      merged.addAll(deviceKnown.whereType<String>());
    }
    for (final k in box.keys) {
      if (k is String && k.startsWith('linkedAccounts_')) {
        final v = box.get(k);
        if (v is List && v.isNotEmpty) {
          merged.addAll(v.whereType<String>());
        }
      }
    }
    final legacy = box.get('linkedAccounts');
    if (legacy is List && legacy.isNotEmpty) {
      merged.addAll(legacy.whereType<String>());
    }
    accounts = merged.toList()..sort();
    final alUser = box.get(aliasesKey);
    if (alUser is Map && alUser.isNotEmpty) {
      aliases = Map<String, String>.from(
        alUser.map((k, v) => MapEntry(k.toString(), v.toString())),
      );
    } else {
      final alLegacy = box.get('accountAliases');
      aliases = Map<String, String>.from(
        (alLegacy as Map? ?? {}).map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ),
      );
      if (uid != null && aliases.isNotEmpty) box.put(aliasesKey, aliases);
    }
    final legacyActive = box.get('accountId') as String?;
    active = box.get(activeKey) as String? ?? legacyActive;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Manage accounts')),
      body: ListView.separated(
        itemCount: accounts.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          final id = accounts[i];
          final alias = aliases[id] ?? '';
          final isActive = id == active;
          return ListTile(
            leading: Icon(Icons.credit_card, color: cs.primary),
            title: Text(
              alias.isNotEmpty ? alias : id,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: alias.isNotEmpty ? Text(id) : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isActive)
                  const Icon(Icons.check_circle, color: Colors.green),
                IconButton(
                  tooltip: 'Rename',
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () async {
                    final ctrl = TextEditingController(text: aliases[id] ?? '');
                    final val = await showDialog<String>(
                      context: context,
                      builder: (d) => AlertDialog(
                        title: const Text('Rename alias'),
                        content: TextField(
                          controller: ctrl,
                          decoration: const InputDecoration(
                            hintText: 'Alias (optional)',
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(d).pop(),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () =>
                                Navigator.of(d).pop(ctrl.text.trim()),
                            child: const Text('Save'),
                          ),
                        ],
                      ),
                    );
                    if (val != null) {
                      setState(() {
                        if (val.isEmpty) {
                          aliases.remove(id);
                        } else {
                          aliases[id] = val;
                        }
                        final uid = FirebaseAuth.instance.currentUser?.uid;
                        final aliasesKey = uid != null
                            ? 'accountAliases_$uid'
                            : 'accountAliases';
                        box.put(aliasesKey, aliases);
                      });
                    }
                  },
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (d) => AlertDialog(
                        title: const Text('Remove account'),
                        content: Text(
                          'Remove ${alias.isNotEmpty ? alias : id} from this device?',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(d, false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(d, true),
                            child: const Text('Remove'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      setState(() {
                        accounts.removeAt(i);
                        aliases.remove(id);
                        final uid = FirebaseAuth.instance.currentUser?.uid;
                        final linkedKey = uid != null
                            ? 'linkedAccounts_$uid'
                            : 'linkedAccounts';
                        final aliasesKey = uid != null
                            ? 'accountAliases_$uid'
                            : 'accountAliases';
                        final activeKey = uid != null
                            ? 'accountId_$uid'
                            : 'accountId';
                        box.put(linkedKey, accounts);
                        box.put(aliasesKey, aliases);
                        // Update device-wide bucket as well
                        final deviceKey = 'linkedAccounts_device';
                        final devSet = <String>{
                          ...accounts,
                          if (box.get(deviceKey) is List)
                            ...List<String>.from(box.get(deviceKey)),
                        }..remove(id);
                        box.put(deviceKey, devSet.toList()..sort());
                        if (active == id) {
                          active = accounts.isNotEmpty ? accounts.first : null;
                          box.put(activeKey, active);
                        }
                      });
                    }
                  },
                ),
              ],
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add account'),
        onPressed: () async {
          final ctrl = TextEditingController();
          final id = await showDialog<String>(
            context: context,
            builder: (d) => AlertDialog(
              title: const Text('Add account ID'),
              content: TextField(
                controller: ctrl,
                decoration: const InputDecoration(hintText: 'BB-ABCD-1234'),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(d),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(d, ctrl.text.trim()),
                  child: const Text('Add'),
                ),
              ],
            ),
          );
          if (id != null && id.isNotEmpty) {
            setState(() {
              if (!accounts.contains(id)) {
                accounts.add(id);
                accounts.sort();
                final uid = FirebaseAuth.instance.currentUser?.uid;
                final linkedKey = uid != null
                    ? 'linkedAccounts_$uid'
                    : 'linkedAccounts';
                box.put(linkedKey, accounts);
                // Update device-wide bucket for aggregation
                final deviceKey = 'linkedAccounts_device';
                final devSet = <String>{
                  ...accounts,
                  if (box.get(deviceKey) is List)
                    ...List<String>.from(box.get(deviceKey)),
                };
                box.put(deviceKey, devSet.toList()..sort());
              }
            });
            // Best-effort: ensure membership remotely to trigger notifications
            try {
              final user = FirebaseAuth.instance.currentUser;
              final uid = user?.uid;
              if (uid != null) {
                final repo = SharedAccountRepository(accountId: id, uid: uid);
                await repo.ensureMembership(
                  displayName: user?.displayName,
                  email: user?.email,
                );
              }
            } catch (_) {}
            // Immediate local feedback notification
            try {
              await NotificationService().showNow(
                DateTime.now().millisecondsSinceEpoch & 0x7fffffff,
                title: 'Account added',
                body: 'You added account $id',
              );
            } catch (_) {}
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Account added locally.')),
              );
            }
          }
        },
      ),
    );
  }
}
