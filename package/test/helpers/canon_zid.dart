// Canon's zid-rendering contract, in the one place both suites can reach.
//
// It used to live in `test/interop/canon.dart`. The release carries
// `test/helpers/` and does not carry `test/interop/` (ruling 3, 2026-09-11),
// and two carried cells assert against this pattern — so while it lived there,
// neither of them compiled where the candidate is certified. `canon.dart`
// re-exports it, so every interop file still reaches it through the import it
// already has.

/// Canon's contract for a rendered zid: **1-32 lowercase hex digits, never a
/// leading `0`.**
///
/// This is zenoh's own definition, not an observation of it. Feed canon a zid
/// with a leading zero digit and it refuses the config outright:
///
///     Invalid id: 00112233445566778899aabbccddeeff - Leading 0s are not valid
///       (commons/zenoh-protocol/src/core/mod.rs:181)
///
/// Asserting `hasLength(32)` on canon's output -- which this suite did until
/// 2026-07-31 -- is therefore an assertion about a *sample*, not about canon.
/// It was false for 1 zid in 16.
///
/// Since seed #9 OUR rendering satisfies this same contract, so the pattern
/// applies to both sides and a width assertion is wrong on either.
final canonZidPattern = RegExp(r'^[1-9a-f][0-9a-f]{0,31}$');
