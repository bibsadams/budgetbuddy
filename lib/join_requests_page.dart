import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'services/shared_account_repository.dart';

class JoinRequestsPage extends StatefulWidget {
  final String accountId;
  const JoinRequestsPage({super.key, required this.accountId});

  @override
  State<JoinRequestsPage> createState() => _JoinRequestsPageState();
}

class _JoinRequestsPageState extends State<JoinRequestsPage> {
  late final SharedAccountRepository _repo;

  @override
  void initState() {
    super.initState();
    final user = FirebaseAuth.instance.currentUser!;
    _repo = SharedAccountRepository(accountId: widget.accountId, uid: user.uid);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Join requests')),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: _repo.joinRequestsStream(),
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return const Center(child: Text('No join requests'));
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (ctx, i) {
              final r = items[i];
              final uid = (r['uid'] as String?) ?? '';
              final name = (r['displayName'] as String?) ?? '';
              final email = (r['email'] as String?) ?? '';
              final status = (r['status'] as String?) ?? 'pending';
              final pending = status == 'pending';
              final accNumber = widget.accountId;
              return ListTile(
                leading: CircleAvatar(
                  child: Text(
                    (name.isNotEmpty
                            ? name[0]
                            : email.isNotEmpty
                            ? email[0]
                            : '?')
                        .toUpperCase(),
                  ),
                ),
                title: Text(name.isNotEmpty ? name : email),
                subtitle: Text(
                  'Account: $accNumber\nGmail: $email\nStatus: $status',
                ),
                isThreeLine: true,
                trailing: pending
                    ? Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () async {
                              try {
                                await _repo.setJoinRequestStatus(uid, 'denied');
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Denied request for $accNumber • $email',
                                    ),
                                  ),
                                );
                              } catch (e) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Failed: $e')),
                                );
                              }
                            },
                            icon: const Icon(Icons.close),
                            label: const Text('Deny'),
                          ),
                          FilledButton.icon(
                            onPressed: () async {
                              try {
                                await _repo.approveAndAddMember(uid);
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Approved request for $accNumber • $email',
                                    ),
                                  ),
                                );
                              } catch (e) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text('Failed: $e')),
                                );
                              }
                            },
                            icon: const Icon(Icons.check_circle),
                            label: const Text('Approve'),
                          ),
                        ],
                      )
                    : Text(
                        status.toUpperCase(),
                        style: TextStyle(
                          color: status == 'approved' ? cs.primary : cs.error,
                        ),
                      ),
              );
            },
          );
        },
      ),
    );
  }
}
