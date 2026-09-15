/// Which key expressions a query accepts replies on.
///
/// Mirrors zenoh-c `z_reply_keyexpr_t`. Canon's default is [matchingQuery]
/// (`z_reply_keyexpr_default()`).
enum ReplyKeyExpr {
  /// Replies to any key expression (`Z_REPLY_KEYEXPR_ANY = 0`).
  any(0),

  /// Replies only to intersecting key expressions
  /// (`Z_REPLY_KEYEXPR_MATCHING_QUERY = 1`).
  matchingQuery(1);

  const ReplyKeyExpr(this.value);

  /// The zenoh-c wire value. Explicit; never derived from declaration order.
  final int value;

  /// Decodes a zenoh-c wire `z_reply_keyexpr_t` value (0/1) into a
  /// [ReplyKeyExpr].
  ///
  /// Any out-of-range value falls back to [ReplyKeyExpr.matchingQuery] rather
  /// than crashing on an unbounded index.
  static ReplyKeyExpr fromWire(int raw) {
    if (raw < 0 || raw >= ReplyKeyExpr.values.length) {
      return ReplyKeyExpr.matchingQuery;
    }
    return ReplyKeyExpr.values[raw];
  }
}
