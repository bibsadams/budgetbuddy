# BudgetBuddy Cloud Functions

This folder contains optional Cloud Functions to support the multi-account verification flow.

## What it does

- onJoinRequestCreated: When a user requests to join an account, writes a document to `/mail`. Install the Firebase Extension "Trigger Email" to send the email to the owner (`accounts/{id}.createdByEmail`).
- onJoinRequestApproved (optional): When owner updates `status=approved` on `accounts/{id}/joinRequests/{uid}`, the function adds the uid to `accounts/{id}.members`.

## Setup

1. Install Firebase CLI and initialize functions (Node 18):
   - `firebase init functions` (or adapt your existing config)
2. Deploy rules and functions:
   - `firebase deploy --only firestore:rules,functions`
3. Install the Email Extension (recommended):
   - In Console → Extensions → Trigger Email.
   - Configure to read from `/mail` collection.

## Security

- Firestore rules provided in `firestore.rules` allow:
  - Users: create/read their own `joinRequests` docs.
  - Owner: list/update join requests; update account (members, isJoint).
  - Members/Owner: read/write account data collections.
  - Mail writes: allowed to signed-in clients for demo; in production, restrict to Functions service account by adding App Check or custom claims.
