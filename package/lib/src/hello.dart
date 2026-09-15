import 'package:zenoh_dart/src/id.dart';
import 'package:zenoh_dart/src/whatami.dart';

/// A hello message received during network scouting.
///
/// Contains the identity, type, and locators of a discovered zenoh entity.
class Hello {
  /// Creates a Hello from its components.
  Hello({required this.zid, required this.whatami, required this.locators});

  /// The zenoh ID of the discovered entity.
  final ZenohId zid;

  /// The type of the discovered entity (router, peer, or client).
  final WhatAmI whatami;

  /// The network locators of the discovered entity.
  final List<String> locators;

  @override
  String toString() =>
      'Hello { zid: ${zid.toHexString()}, '
      'whatami: ${whatami.name}, locators: $locators }';
}
