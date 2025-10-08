import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'services/shared_account_repository.dart';

class JoinRequestsPage extends StatefulWidget {
  final String accountId;
  const JoinRequestsPage({super.key, required this.accountId});

  @override
  State<JoinRequestsPage> createState() => _JoinRequestsPageState();
}

class _JoinRequestsPageState extends State<JoinRequestsPage> {
  late final SharedAccountRepository _repo;
  final Map<String, String> _requesterAccountCache = {};

  Future<String> _getRequesterAccountNumber(String uid) async {
    if (_requesterAccountCache.containsKey(uid)) {
      return _requesterAccountCache[uid] ?? '';
    }
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();
      final acc =
          ((snap.data() ?? const <String, dynamic>{})['accountNumber'] ?? '')
              .toString();
      _requesterAccountCache[uid] = acc;
      return acc;
    } catch (_) {
      return '';
    }
  }

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
              final statusRaw = (r['status'] as String?) ?? 'pending';
              final pending = statusRaw == 'pending';
              final status = statusRaw.isNotEmpty
                  ? (statusRaw[0].toUpperCase() + statusRaw.substring(1))
                  : statusRaw;
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (pending)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Deny',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 40,
                                minHeight: 40,
                              ),
                              icon: const Icon(Icons.close, size: 24),
                              color: Theme.of(context).colorScheme.error,
                              onPressed: () async {
                                try {
                                  await _repo.setJoinRequestStatus(
                                    uid,
                                    'denied',
                                  );
                                  if (!mounted) return;
                                  final reqAcc =
                                      _requesterAccountCache[uid] ?? '';
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Denied request for ${reqAcc.isNotEmpty ? reqAcc : uid} • $email',
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
                            ),
                            const SizedBox(width: 4),
                            IconButton(
                              tooltip: 'Approve',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 40,
                                minHeight: 40,
                              ),
                              icon: const Icon(Icons.check_circle, size: 24),
                              color: Theme.of(context).colorScheme.primary,
                              onPressed: () async {
                                try {
                                  await _repo.approveAndAddMember(uid);
                                  if (!mounted) return;
                                  final reqAcc =
                                      _requesterAccountCache[uid] ?? '';
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Approved request for ${reqAcc.isNotEmpty ? reqAcc : uid} • $email',
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
                            ),
                          ],
                        ),
                      )
                    else
                      const SizedBox(width: 0, height: 0),
                    if (pending) const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name.isNotEmpty ? name : email,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 2),
                          FutureBuilder<String>(
                            future: _getRequesterAccountNumber(uid),
                            builder: (context, snap) {
                              final acc = (snap.data ?? '').toString();
                              if (acc.isEmpty) {
                                return const SizedBox.shrink();
                              }
                              return Text(
                                'Account: $acc',
                                style: Theme.of(context).textTheme.bodySmall,
                              );
                            },
                          ),
                          Text(
                            'Gmail: $email',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          Text(
                            'Status: $status',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: status.toLowerCase() == 'approved'
                                      ? cs.primary
                                      : (status.toLowerCase() == 'denied'
                                            ? cs.error
                                            : null),
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
