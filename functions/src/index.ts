import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';
import { firestore as AdminFirestore } from 'firebase-admin';

admin.initializeApp();
const db = admin.firestore();

// When a join request is created, enqueue an email via the 'mail' collection
// (Use the Firebase Extensions 'Trigger Email' to send the email)
export const onJoinRequestCreated = functions.firestore
  .document('accounts/{accountId}/joinRequests/{uid}')
  .onCreate(async (snap, ctx) => {
    const accountId = ctx.params.accountId as string;
    const req = snap.data() as any;

    const accountDoc = await db.doc(`accounts/${accountId}`).get();
    const ownerEmail = (accountDoc.get('createdByEmail') as string) || '';
    if (!ownerEmail) {
      console.warn('Owner email missing; cannot send');
      return;
    }

    const requesterEmail = (req.email as string) || 'a user';
    const requesterName = (req.displayName as string) || '';

    // Write to /mail for the email extension
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
    if (!ownerEmail) return;
    const requesterEmail = (req.email as string) || 'a user';
    const requesterName = (req.displayName as string) || '';
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
