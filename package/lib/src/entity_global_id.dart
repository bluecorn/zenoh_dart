import 'package:meta/meta.dart';
import 'package:zenoh_dart/src/id.dart';

/// A globally-unique identifier for a Zenoh entity (e.g. a queryable,
/// publisher).
///
/// Mirrors cpp `EntityGlobalId`: a [zid] (the session id) plus an [eid]
/// (the entity id, a uint32) that distinguishes multiple entities declared
/// on the same session. Both fields are load-bearing for identity — two
/// entities on one session share [zid] but differ in [eid].
@immutable
class EntityGlobalId {
  /// Creates an [EntityGlobalId] from a session [zid] and an entity [eid].
  const EntityGlobalId(this.zid, this.eid);

  /// The Zenoh session id of the entity.
  final ZenohId zid;

  /// The entity id (uint32) — distinguishes entities within one session.
  final int eid;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is EntityGlobalId && zid == other.zid && eid == other.eid);

  @override
  int get hashCode => Object.hash(zid, eid);

  @override
  String toString() => 'EntityGlobalId(zid: $zid, eid: $eid)';
}
