/// The type of a zenoh entity (router, peer, or client).
///
/// Values correspond to zenoh-c bitmask values:
/// router=1, peer=2, client=4.
enum WhatAmI {
  /// A zenoh router.
  router,

  /// A zenoh peer.
  peer,

  /// A zenoh client.
  client,

  /// An unrecognized entity kind.
  ///
  /// Fallback sentinel for a wire bitmask value that is not one of the known
  /// `router=1` / `peer=2` / `client=4` codes. It is never returned for those
  /// known values; it exists so the receive-side decode is *total* and cannot
  /// throw (which would strand the scout `Completer` and hang `scout()`).
  unknown;

  /// Maps a zenoh-c integer bitmask value to a [WhatAmI] enum value.
  ///
  /// Total decode: known bitmask codes map to `router=1` / `peer=2` /
  /// `client=4`; any other value yields [WhatAmI.unknown] rather than throwing.
  static WhatAmI fromInt(int value) {
    switch (value) {
      case 1:
        return WhatAmI.router;
      case 2:
        return WhatAmI.peer;
      case 4:
        return WhatAmI.client;
      default:
        return WhatAmI.unknown;
    }
  }
}
