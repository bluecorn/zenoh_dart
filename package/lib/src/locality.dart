/// Restricts which peers an operation reaches, or accepts traffic from.
///
/// Mirrors zenoh-c's `z_locality_t` (`zenoh_commons.h:68-94`), whose wire
/// values are assigned explicitly by canon: `ANY = 0`, `SESSION_LOCAL = 1`,
/// `REMOTE = 2`. The [value] getter carries those numbers directly rather
/// than deriving them from Dart declaration order.
///
/// Canon's default on every field that takes a locality is [any]
/// (`z_locality_default()`), so omitting the parameter — or passing `null` —
/// leaves canon to supply it.
///
/// Two directions of the same idea share this type:
///
/// * `allowedDestination` on a **send** operation limits who receives it.
/// * `allowedOrigin` on a **declaration** limits whose traffic it accepts.
///
/// [sessionLocal] means "within the declaring session only" — not "within this
/// process" and not "within this host". Two sessions in one Dart process are
/// remote to each other.
///
/// This enum is send-only: canon exposes no accessor that returns a locality,
/// so there is deliberately no `fromWire` decoder.
enum Locality {
  /// Reach, or accept from, both same-session and remote peers.
  ///
  /// `Z_LOCALITY_ANY = 0`, and canon's default (`z_locality_default()`).
  any(0),

  /// Reach, or accept from, only peers within the declaring session.
  ///
  /// `Z_LOCALITY_SESSION_LOCAL = 1`.
  sessionLocal(1),

  /// Reach, or accept from, only peers outside the declaring session.
  ///
  /// `Z_LOCALITY_REMOTE = 2`.
  remote(2);

  const Locality(this.value);

  /// The zenoh-c wire value. Explicit; never derived from declaration order.
  final int value;
}
