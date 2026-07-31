# Studio fork: validation-capable StoreKit 2

Fork of [godot-sdk-integrations/godot-storekit2](https://github.com/godot-sdk-integrations/godot-storekit2)
at `v0.2`, diverging on one axis only: **the app must be able to validate a
purchase on a server before the transaction is finished.**

Kept in a separate file from `README.md` so upstream merges stay clean.

## Why upstream cannot be used as shipped

The [godot-mobile](https://github.com/Seneku/godot-mobile) template requires
server validation before `finish()`. Upstream v0.2 makes that impossible, for
three independent reasons, all verified against the `v0.2` tag:

| # | Gap | Evidence |
|---|---|---|
| 1 | Transactions are finished before GDScript ever sees them | `GodotStoreKit2Swift.swift:162` and `:165` — `await transaction.finish()` inside `purchaseProduct`, in both the verified and unverified branches |
| 2 | No signed proof is surfaced | `TransactionData` carries `productId`, `transactionState`, `purchaseDate`, `revocationDate`. `Transaction.jwsRepresentation` is never read |
| 3 | No stable transaction identity | Same — `Transaction.id` and `originalID` are never read, so nothing can act as an idempotency key |

There is also no prebuilt artifact for Godot 4.7.1, so a source build is
required regardless.

Consequence: a receipt cannot be verified server-side, a purchase cannot be
correlated to a validation response, and the transaction is already consumed by
the time the game could refuse it. Upstream is fine for a client-trusts-client
model; it cannot support one where the server decides.

## What this fork must change

1. **Stop finishing on purchase.** Remove both `await transaction.finish()`
   calls from `purchaseProduct`. A purchase returns to GDScript *unfinished*.
2. **Surface the proof.** Add `jws` (`Transaction.jwsRepresentation`) to
   `TransactionData`.
3. **Surface identity.** Add `id` (`Transaction.id`) and, for restores,
   `originalId`. This is the idempotency key the validator keys on.
4. **Add explicit finish.** Expose `finish_transaction(transaction_id: String)`
   which looks the transaction up in `Transaction.unfinished` and finishes it.
5. **Add a definitive completion callback.** Emit
   `transaction_finished(transaction_id: String, success: bool, message: String)`
   once `finish()` has actually completed — not when it was requested.
6. **Preserve the adapter contract.** `StoreKit2Adapter` in the template
   discovers methods and signals by name and tolerates several spellings; see
   `addons/mobile_core/runtime/adapters/storekit2_adapter.gd`. Nothing already
   working may change shape.

Items 1–5 are additive apart from item 1, which is a deliberate behaviour
change and the whole point of the fork.

## Consumer contract

The template's adapter looks for these. Names in **bold** are the ones this fork
should provide; the adapter accepts alternatives but there is no reason to use
them.

**Methods** — **`request_product_info(id)`**, **`purchase_product(id)`**,
**`sync()`**, **`finish_transaction(id) -> bool`**

**Signals** — **`product_info_received`**, **`transaction_state_changed`**,
**`synchronized`**, **`transaction_finished`**

`transaction_state_changed` must carry a Dictionary the adapter can normalise:
`product_id`, `id`, `jws`, `purchase_date`, `transaction_state`.

## Building

`scripts/make_release.sh` already produces debug and release xcframeworks and
generates the Godot headers on first run. It must be pointed at **Godot 4.7.1**
headers — do not substitute an older engine binary, as the template's
`dependencies.lock.json` pins the engine and the ABI is not stable across
versions.

Publish as a tagged release; the template pins it by URL and SHA-256 in
`dependencies.lock.json` alongside AdMob and Play Billing, and
`tools/install-native-dependencies.sh` fetches it. Binaries are never committed
to consuming projects — those gitignore `addons/` plugin directories entirely.

## Verification

Cannot be judged from a build succeeding. It needs the App Store Connect sandbox
matrix — purchase, cancel, Ask to Buy, restore, refund, duplicate callback,
offline validation, and recovery after the app is killed mid-purchase. The
consuming project's docs carry that matrix.

The one check worth stating outright: after a purchase and before validation,
the transaction must still appear in `Transaction.unfinished`. If it does not,
item 1 has regressed and the entire fork is pointless.
