import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

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
    accounts = List<String>.from(box.get('linkedAccounts') ?? []);
    aliases = Map<String, String>.from(
      (box.get('accountAliases') as Map?) ?? {},
    );
    active = box.get('accountId') as String?;
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
                            onPressed: () => Navigator.pop(d),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(d, ctrl.text.trim()),
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
                        box.put('accountAliases', aliases);
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
                        box.put('linkedAccounts', accounts);
                        box.put('accountAliases', aliases);
                        if (active == id) {
                          active = accounts.isNotEmpty ? accounts.first : null;
                          box.put('accountId', active);
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
    );
  }
}
