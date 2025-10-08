import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';
import { firestore as AdminFirestore } from 'firebase-admin';

admin.initializeApp();
const db = admin.firestore();

// Helper: determine which user(s) should be notified as the account owner/admin.
async function resolveOwnerUids(accountId: string): Promise<string[]> {
  const accRef = db.doc(`accounts/${accountId}`);
  const accSnap = await accRef.get();
  if (!accSnap.exists) return [];
  const data = accSnap.data() as any;
  const result = new Set<string>();
  const createdBy = (data?.createdBy as string) || '';
  if (createdBy) result.add(createdBy);

  // Check members subcollection for role=owner
  try {
    const membersSnap = await accRef.collection('members').get();
    for (const d of membersSnap.docs) {
      const role = (d.get('role') as string) || '';
      const uid = (d.get('uid') as string) || d.id;
      if (role.toLowerCase() == 'owner' && uid) result.add(uid);
    }
  } catch (_) {
    // ignore
  }

  // Fallback to members array in the account doc
  const membersArr: string[] = Array.isArray(data?.members) ? data.members : [];
  if (!result.size && membersArr.length) {
    // Pick the first member as a final fallback
    result.add(membersArr[0]);
  }

  return Array.from(result);
}

// When a join request is created, enqueue an email via the 'mail' collection
// (Use the Firebase Extensions 'Trigger Email' to send the email)
export const onJoinRequestCreated = functions.firestore
  .document('accounts/{accountId}/joinRequests/{uid}')
  .onCreate(async (snap, ctx) => {
    const accountId = ctx.params.accountId as string;
    const req = snap.data() as any;

    const accountDoc = await db.doc(`accounts/${accountId}`).get();
    const ownerEmail = (accountDoc.get('createdByEmail') as string) || '';
    const ownerCandidates = await resolveOwnerUids(accountId);

    const requesterEmail = (req.email as string) || 'a user';
    const requesterName = (req.displayName as string) || '';

    // Write to /mail for the email extension
    if (ownerEmail) {
      await db.collection('mail').add({
        to: ownerEmail,
        message: {
          subject: `BudgetBuddy: Join request for ${accountId}`,
          text: `${requesterName || requesterEmail} is requesting access to account ${accountId}.\n\n` +
                `To approve, set status=approved on the join request and add their uid to the account members.`,
          html: `<p><b>${requesterName || requesterEmail}</b> is requesting access to account <b>${accountId}</b>.</p>` +
                `<p>To approve, set <code>status=approved</code> on the join request and add their uid to <code>accounts/${accountId}.members</code>.</p>`
        }
      });
    }

    // Also send a push notification to the owner device(s)
    if (ownerCandidates.length) {
      try {
        await Promise.all(ownerCandidates.map((uid) => notifyUserTokens(
          uid,
          'Join request received',
          `${requesterName || requesterEmail} requested to join ${accountId}.`,
          { accountId, type: 'join_request', requestUid: req.uid || '' }
        )));
      } catch (e) {
        console.warn('Failed to send push for join request', e);
      }
    } else {
      console.warn(`No owner candidates to notify for account ${accountId}`);
    }
  });

// Fallback: when a global joinRequests doc is created by clients that
// couldn't write to account subcollection due to rules, send email too.
export const onGlobalJoinRequestCreated = functions.firestore
  .document('joinRequests/{docId}')
  .onCreate(async (snap: functions.firestore.QueryDocumentSnapshot) => {
    const req = snap.data() as any;
    const accountId = (req.accountId as string) || '';
    if (!accountId) return;
    const accountDoc = await db.doc(`accounts/${accountId}`).get();
    const ownerEmail = (accountDoc.get('createdByEmail') as string) || '';
    const ownerCandidates = await resolveOwnerUids(accountId);
    const requesterEmail = (req.email as string) || 'a user';
    const requesterName = (req.displayName as string) || '';
    if (ownerEmail) {
      await db.collection('mail').add({
        to: ownerEmail,
        message: {
          subject: `BudgetBuddy: Join request for ${accountId}`,
          text: `${requesterName || requesterEmail} is requesting access to account ${accountId}.\n\n` +
                `To approve, create or update accounts/${accountId}/joinRequests/${req.uid} with status=approved and add their uid to the account members.`,
          html: `<p><b>${requesterName || requesterEmail}</b> is requesting access to account <b>${accountId}</b>.</p>` +
                `<p>To approve, create/update <code>accounts/${accountId}/joinRequests/${req.uid}</code> with <code>status=approved</code> and add their uid to <code>accounts/${accountId}.members</code>.</p>`
        }
      });
    }

    if (ownerCandidates.length) {
      try {
        await Promise.all(ownerCandidates.map((uid) => notifyUserTokens(
          uid,
          'Join request received',
          `${requesterName || requesterEmail} requested to join ${accountId}.`,
          { accountId, type: 'join_request', requestUid: req.uid || '' }
        )));
      } catch (e) {
        console.warn('Failed to send push for global join request', e);
      }
    }
  });

// Optional: When owner marks a request approved, auto-add the user to members
export const onJoinRequestApproved = functions.firestore
  .document('accounts/{accountId}/joinRequests/{uid}')
  .onUpdate(async (change: functions.Change<functions.firestore.QueryDocumentSnapshot>, ctx: functions.EventContext) => {
    const before = change.before.data() as any;
    const after = change.after.data() as any;
    if (before.status === 'approved' || after.status !== 'approved') return;

    const accountId = ctx.params.accountId as string;
    const uid = ctx.params.uid as string;

    const accRef = db.doc(`accounts/${accountId}`);
    await db.runTransaction(async (tx: AdminFirestore.Transaction) => {
      const accSnap = await tx.get(accRef);
      const members: string[] = (accSnap.get('members') as string[]) || [];
      if (!members.includes(uid)) {
        members.push(uid);
        tx.update(accRef, { members });
      }
      const memberRef = accRef.collection('members').doc(uid);
      tx.set(memberRef, {
        uid,
        role: 'member',
        displayName: after.displayName || null,
        email: after.email || null,
        addedAt: admin.firestore.FieldValue.serverTimestamp(),
        addedBy: 'function:onJoinRequestApproved'
      }, { merge: true });
    });

    // Mark request processed
    await change.after.ref.set({ lastUpdatedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
  });

// When a join request transitions back to 'pending' (e.g., after being denied),
// notify the owner again so they always receive a new request notification.
export const onJoinRequestRePending = functions.firestore
  .document('accounts/{accountId}/joinRequests/{uid}')
  .onUpdate(async (change, ctx) => {
    const before = change.before.data() as any;
    const after = change.after.data() as any;
    const beforeStatus = (before?.status as string) || '';
    const afterStatus = (after?.status as string) || '';
    if (afterStatus !== 'pending') return; // only act when it becomes pending
    if (beforeStatus === 'pending') return; // ignore no-op

    const accountId = ctx.params.accountId as string;
    const accountDoc = await db.doc(`accounts/${accountId}`).get();
    const ownerEmail = (accountDoc.get('createdByEmail') as string) || '';
    const ownerUid = (accountDoc.get('createdBy') as string) || '';
    const requesterEmail = (after?.email as string) || 'a user';
    const requesterName = (after?.displayName as string) || '';

    if (ownerEmail) {
      await db.collection('mail').add({
        to: ownerEmail,
        message: {
          subject: `BudgetBuddy: Join request re-submitted for ${accountId}`,
          text: `${requesterName || requesterEmail} re-submitted a join request for ${accountId}.\n\n` +
                `To approve, set status=approved on the join request and add their uid to the account members.`,
          html: `<p><b>${requesterName || requesterEmail}</b> re-submitted a join request for <b>${accountId}</b>.</p>` +
                `<p>To approve, set <code>status=approved</code> and add their uid to <code>accounts/${accountId}.members</code>.</p>`
        }
      });
    }

    if (ownerUid) {
      await notifyUserTokens(
        ownerUid,
        'Join request re-submitted',
        `${requesterName || requesterEmail} requested to join ${accountId} again.`,
        { accountId }
      );
    }
  });

// Helper: send FCM to all tokens for a user doc id (users/<uid>/tokens/*)
async function notifyUserTokens(uid: string, title: string, body: string, data?: Record<string, string>) {
  const tokSnap = await db.collection('users').doc(uid).collection('tokens').get();
  const tokens = tokSnap.docs.map(d => (d.get('token') as string)).filter(Boolean);
  if (!tokens.length) return;
  const payload: admin.messaging.MulticastMessage = {
    tokens,
    notification: { title, body },
    data: data || {},
    android: { priority: 'high' },
    apns: { headers: { 'apns-priority': '10' } },
  };
  await admin.messaging().sendEachForMulticast(payload);
}

// When an account is created or when members array is updated to include a new member, notify relevant users
export const onAccountMembersChanged = functions.firestore
  .document('accounts/{accountId}')
  .onWrite(async (change, ctx) => {
    const accountId = ctx.params.accountId as string;
    const before = change.before.exists ? change.before.data() as any : {};
    const after = change.after.exists ? change.after.data() as any : {};

    const beforeMembers: string[] = Array.isArray(before.members) ? before.members : [];
    const afterMembers: string[] = Array.isArray(after.members) ? after.members : [];

    // New account creation: notify creator if present
    if (!change.before.exists && change.after.exists) {
      const creatorUid = (after.createdBy as string) || '';
      if (creatorUid) {
        await notifyUserTokens(
          creatorUid,
          'Account created',
          `Your account ${accountId} was created successfully.`,
          { accountId }
        );
      }
      return;
    }

    // Detect newly added members
    const added = afterMembers.filter((m) => !beforeMembers.includes(m));
    if (!added.length) return;

    // Notify the newly added members
    await Promise.all(added.map(async (uid: string) => {
      await notifyUserTokens(
        uid,
        'Added to account',
        `You were added to account ${accountId}.`,
        { accountId }
      );
    }));

    // Optionally notify owner/creator that members were added
    const creatorUid = (after.createdBy as string) || '';
    if (creatorUid) {
      await notifyUserTokens(
        creatorUid,
        'Member added',
        `New member(s) added to ${accountId}: ${added.join(', ')}`,
        { accountId }
      );
    }
  });

// Callable: send a test push notification to current user
export const sendTestPush = functions.https.onCall(async (data, context) => {
  const uid = context.auth?.uid;
  if (!uid) throw new functions.https.HttpsError('unauthenticated', 'Sign in required');
  const title = (data?.title as string) || 'Test Notification';
  const body = (data?.body as string) || 'This is a test push from BudgetBuddy.';
  await notifyUserTokens(uid, title, body, { accountId: data?.accountId || '' });
  return { ok: true };
});
