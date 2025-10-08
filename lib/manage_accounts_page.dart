import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
    // Read per-user with migration from legacy global keys
    final laUser = box.get(linkedKey);
    final base = (laUser is List)
        ? laUser.whereType<String>().toList()
        : <String>[];
    // Read active before computing the final set (we'll ensure it's included)
    active =
        (uid != null
            ? box.get('accountId_$uid') as String?
            : box.get('accountId') as String?) ??
        box.get('accountId') as String?;
    // For display only, union with device-known list so previously used accounts are visible.
    final dev = box.get('linkedAccounts_device');
    final set = <String>{...base, if (dev is List) ...dev.whereType<String>()};
    // Ensure active account shows up even if neither list includes it yet
    if ((active ?? '').isNotEmpty) set.add(active!);
    accounts = set.toList()..sort();
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
    // aliases and active already loaded
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
                        final prevDev = box.get(deviceKey);
                        final devSet = <String>{
                          if (prevDev is List) ...prevDev.whereType<String>(),
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
                final prevDev = box.get(deviceKey);
                final devSet = <String>{
                  if (prevDev is List) ...prevDev.whereType<String>(),
                }..add(id);
                box.put(deviceKey, devSet.toList()..sort());
              }
            });
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
