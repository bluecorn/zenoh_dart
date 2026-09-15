// Seed [OWN] — the criterion-(ii) driver: does THIS class's native release
// reach a Dart C API?
//
// Runs one subject's SHIPPED release path with `test/helpers/post_hook.c`
// installed over `Dart_PostCObject_DL`, and reports the post count, the count
// with a named drop symbol on the stack, and the thread.
//
// ⚠️ CRITERION (ii) IS A PROPERTY OF THE NATIVE RELEASE ENTRY, NOT OF THE
// FINALIZER. `zd_publisher_drop` posts or it does not, whether it is reached
// from `close()` or from a callback — so every arm here drives the shipped
// release and needs no finalizer to exist. That is what lets this measure
// classes before they are admitted to the net rather than after.
//
// ⛔ AND EVERY RESULT CARRIES ITS TOPOLOGY. The same release posts or does not
// depending on whether the peers share a process: on the one-session path a
// drop can run canon's callbacks inline, while over TCP loopback the same posts
// land on IO threads. A (ii) result without its topology is not a result, so
// `--topology` is required and is echoed into the output.
//
// ⛔ AND THE HOOK IS A TEST HELPER, NEVER PRODUCTION SURFACE. It is loaded only
// under this harness, referenced nowhere in `package/lib`, and its built `.so`
// is not committed. See the header of `post_hook.c`.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/zenoh_unstable.dart';

typedef _IntVoidC = Int Function();
typedef _IntVoid = int Function();
typedef _VoidVoidC = Void Function();
typedef _VoidVoid = void Function();

/// The hook's exported surface, resolved once.
class _Hook {
  _Hook(DynamicLibrary lib)
    : install = lib.lookupFunction<_IntVoidC, _IntVoid>('zdh_install'),
      uninstall = lib.lookupFunction<_VoidVoidC, _VoidVoid>('zdh_uninstall'),
      reset = lib.lookupFunction<_VoidVoidC, _VoidVoid>('zdh_reset'),
      posts = lib.lookupFunction<_IntVoidC, _IntVoid>('zdh_posts'),
      underMarker = lib.lookupFunction<_IntVoidC, _IntVoid>(
        'zdh_posts_under_marker',
      ),
      lastOnMain = lib.lookupFunction<_IntVoidC, _IntVoid>(
        'zdh_last_on_main_value',
      ),
      _arm = lib
          .lookupFunction<
            Void Function(Pointer<Char>),
            void Function(Pointer<Char>)
          >('zdh_arm');

  final int Function() install;
  final void Function() uninstall;
  final void Function() reset;
  final int Function() posts;
  final int Function() underMarker;
  final int Function() lastOnMain;
  final void Function(Pointer<Char>) _arm;

  void arm(String symbol) {
    // ALLOCATE-LAST + outer-finally, like everywhere else on this seam.
    final buf = symbol.toNativeUtf8();
    try {
      _arm(buf.cast());
    } finally {
      malloc.free(buf);
    }
  }
}

Config _quiet() => Config()
  ..insertJson5('scouting/multicast/enabled', 'false')
  ..insertJson5('scouting/gossip/enabled', 'false')
  // The advanced publisher needs it, and it is harmless for every other
  // subject -- one session shape rather than a per-subject branch.
  ..insertJson5('timestamping/enabled', 'true');

/// The sessions a topology needs.
///
/// ⚠️ `one` is ONE session used as both ends. Two quiet sessions in one
/// process CANNOT discover each other — multicast and gossip are both off,
/// which is the measured counter-case — so a same-process query round-trip
/// needs exactly one session.
class _Topology {
  _Topology(this.a, this.b, this.name);
  final Session a;
  final Session b;
  final String name;

  void close() {
    a.close();
    if (!identical(a, b)) b.close();
  }
}

Future<_Topology> _openTopology(String name, int port) async {
  if (name == 'one') {
    final s = await Session.open(config: _quiet());
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return _Topology(s, s, name);
  }
  final a = await Session.open(
    config: Config()
      ..insertJson5('listen/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('timestamping/enabled', 'true'),
  );
  await Future<void>.delayed(const Duration(milliseconds: 500));
  final b = await Session.open(
    config: Config()
      ..insertJson5('connect/endpoints', '["tcp/127.0.0.1:$port"]')
      ..insertJson5('timestamping/enabled', 'true'),
  );
  await Future<void>.delayed(const Duration(seconds: 1));
  return _Topology(a, b, name);
}

/// The native release entry each subject's shipped path runs through.
///
/// Separate from [_drive] because THE MARKER MUST BE ARMED BEFORE THE RELEASE
/// RUNS. An earlier cut of this harness drove once to learn the symbol and
/// again to measure it; that is two releases where the cell asserts about one,
/// and the first one's side effects survive into the second.
String _markerFor(String subject) => switch (subject) {
  'config' => 'zd_config_drop',
  'bytes' => 'zd_bytes_drop',
  'keyexpr' => 'zd_keyexpr_drop',
  'writer' => 'zd_bytes_writer_drop',
  'serializer' => 'zd_serializer_drop',
  // No canon call beneath it at all -- the whole release is a bare `free`.
  // Reported as n/a rather than as a measured 0 by the cell that reads it.
  'deserializer' => '',
  'querier-inflight' => 'z_undeclare_querier',
  // Slice 12: the clone is made and posted inside _zd_query_callback, so the
  // marker is the callback's own frame reached through canon's closure.
  'knp-shipped' => '',
  'knp-shipped-deferred' => '',
  'query-drop' => 'zd_query_drop',
  'publisher' => 'zd_publisher_drop',
  'advpublisher' => 'zd_advanced_publisher_drop',
  'shmmut' => 'zd_shm_mut_drop',
  'shmprovider' => 'zd_shm_provider_drop',
  _ => '',
};

/// Drives one subject's shipped release.
Future<void> _drive(String subject, _Topology t) async {
  switch (subject) {
    // --- the five value-drop entries slice 3 declares ---------------------
    // Seed [10b]: the offloaded open posts EXACTLY ONCE per call, from the
    // worker. Counted rather than reasoned, because "exactly one post" is what
    // the single-exit worker and the isCompleted guard between them rest on --
    // a second post would be inert but would mean the worker had two exits.
    //
    // No marker is armed: the post happens on the WORKER thread inside the
    // static `_zd_open_worker`, which is not in the dynamic symbol table, so a
    // stack-walk filter could not see it. The raw count is the measurement.
    case 'session-open':
      for (var i = 0; i < 5; i++) {
        final s = await Session.open(
          config: Config()
            ..insertJson5('scouting/multicast/enabled', 'false')
            ..insertJson5('scouting/gossip/enabled', 'false'),
        );
        s.close();
      }

    case 'config':
      // `Config` is consumed by `Session.open`, so a config that reaches
      // `dispose()` is one that was never handed over. Build and dispose.
      _quiet().dispose();
      return;
    case 'bytes':
      ZBytes.fromString('criterion-ii').dispose();
      return;
    case 'keyexpr':
      KeyExpr('demo/own/fin/ii').dispose();
      return;
    case 'writer':
      ZBytesWriter().dispose();
      return;
    case 'serializer':
      ZSerializer().dispose();
      return;

    // --- the degenerate row ------------------------------------------------
    case 'deserializer':
      // No canon call beneath it at all: the whole release is a bare `free`.
      // Reported as n/a rather than as a measured 0 by the cell that reads it.
      ZDeserializer(ZBytes.fromString('x')).dispose();
      return;

    // --- the two rows whose (ii) had been READ TWICE and measured never ----
    case 'publisher':
      // `enableMatchingListener` left at its DEFAULT (false) -- the only
      // configuration that is in the net. The ml:ON form is excluded
      // separately and is not what this measures.
      t.a.declarePublisher('demo/own/fin/pub').close();
      return;

    case 'advpublisher':
      t.a.declareAdvancedPublisher('demo/own/fin/apub').close();
      return;

    // --- the two shared-memory rows ----------------------------------------
    case 'shmmut':
      final provider = ShmProvider(size: 65536);
      final r = provider.alloc(1024);
      if (r is! AllocOk) {
        stdout.writeln('HOOK_SHM_SETUP_FAILED=$r');
        exit(2);
      }
      r.buffer.dispose();
      provider.close();
      return;

    case 'shmprovider':
      ShmProvider(size: 65536).close();
      return;

    // --- slice 13: WHY `Query` is out of the net ---------------------------
    case 'query-drop':
      // A RECEIVED query released through its shipped `dispose()`. On the
      // ONE-SESSION path `zd_query_drop` posts -- and a NativeFinalizer routed
      // into it would make that post happen INSIDE the callback, on a thread
      // with no isolate, which is the documented-UB ground `Session` is
      // excluded on. Over TCP loopback the same drop posts nothing.
      final qd = t.a.declareQueryable('demo/own/out/qdrop');
      Query? received;
      qd.stream.listen((q) => received = q);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      t.b.get('demo/own/out/qdrop').listen((_) {}, onError: (Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 600));
      received?.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      qd.close();
      return;

    // --- slice 12: how many query CLONES are orphaned ----------------------
    case 'knp-shipped':
    case 'knp-shipped-deferred':
      // posts = clones created (one per query the callback handled).
      // seen   = clones that reached a Dart owner.
      // ORPHANED = posts - seen, and that is the magnitude the kNativePointer
      // ruling turns on. `seen=0` alone is ambiguous -- it fits both "N clones
      // orphaned" and "no clone was ever created" -- which is why the post
      // count is the discriminator.
      final qa2 = t.a.declareQueryable('demo/own/fin/knps');
      var seen = 0;
      qa2.stream.listen((q) {
        seen++;
        q.dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      for (var i = 0; i < 16; i++) {
        t.b.get('demo/own/fin/knps').listen((_) {}, onError: (Object _) {});
      }
      // ⭐ THE CONTROL, and it is PR #86's own recorded shape: "closing the
      // port in the same turn delivers 0 of 5 queued messages; deferring by
      // one turn delivers 5 of 5." Deferring here is what ATTRIBUTES the post
      // count -- whatever the deferred arm delivers is how many of the posts
      // were query posts, and therefore how many the prompt arm orphaned.
      if (subject == 'knp-shipped-deferred') {
        await Future<void>.delayed(const Duration(milliseconds: 800));
      }
      qa2.close();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      stdout.writeln('HOOK_SEEN=$seen');
      return;

    // --- the calibration ---------------------------------------------------
    case 'querier-inflight':
      // The POSITIVE control: a release measured to post. `z_undeclare_querier`
      // posts the getter's sentinel from inside the undeclare, so closing a
      // querier with a `get()` in flight must be seen by any instrument that
      // works.
      final qa = t.a.declareQueryable('demo/own/fin/cal');
      qa.stream.listen((q) async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        q
          ..reply('demo/own/fin/cal', 'late')
          ..dispose();
      });
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final querier = t.b.declareQuerier('demo/own/fin/cal');
      querier.get().listen((_) {}, onError: (Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      querier.close();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      qa.close();
      return;

    case _:
      stdout.writeln('HOOK_UNKNOWN_SUBJECT=$subject');
      exit(2);
  }
}

Future<void> main(List<String> args) async {
  String opt(String name, String fallback) {
    final i = args.indexOf('--$name');
    return (i == -1 || i + 1 >= args.length) ? fallback : args[i + 1];
  }

  final hookPath = opt('hook', '');
  final subject = opt('subject', 'config');
  final topologyName = opt('topology', 'one');
  // Overrides the marker this subject would normally arm. Used ONLY by the
  // negative calibration: arming a symbol that exists but is nowhere on the
  // posting stack must report posts > 0 and under-marker == 0. Without that
  // arm, a marker filter that matched EVERYTHING would look identical to one
  // that worked.
  final markerOverride = opt('marker', '');
  final port = int.parse(opt('port', '19600'));

  // ⚠️ Leading newline: the toolchain's "Running build hooks..." carries no
  // trailing newline and would otherwise swallow the first marker.
  stdout
    ..writeln()
    ..writeln('HOOK_READY subject=$subject topology=$topologyName');

  // The package must be initialised BEFORE the hook installs: the slot it
  // wraps is populated by `zd_init_dart_api_dl`, and wrapping an empty slot
  // would read a spurious zero.
  ensureInitialized();

  final hook = _Hook(DynamicLibrary.open(hookPath));
  final rc = hook.install();
  stdout.writeln('HOOK_INSTALL_RC=$rc');
  if (rc != 0) {
    // ⛔ A failed install is reported and the run STOPS. Continuing would
    // produce "0 posts", which is exactly what a healthy negative result looks
    // like — the single most misleading output this harness could emit.
    stdout.writeln('HOOK_DONE');
    await stdout.flush();
    exit(3);
  }

  final topology = await _openTopology(topologyName, port);

  // ARM FIRST, THEN RESET, THEN DRIVE -- in that order. A marker armed after
  // the release has nothing left to see, and a reset after the drive discards
  // the very posts being counted.
  final marker = markerOverride.isEmpty ? _markerFor(subject) : markerOverride;
  hook
    ..arm(marker)
    ..reset();
  await _drive(subject, topology);

  stdout
    ..writeln('HOOK_MARKER=$marker')
    ..writeln('HOOK_POSTS=${hook.posts()}')
    ..writeln('HOOK_POSTS_UNDER_MARKER=${hook.underMarker()}')
    ..writeln('HOOK_ON_MAIN=${hook.lastOnMain()}')
    ..writeln('HOOK_TOPOLOGY=$topologyName');

  // ⛔ THE IN-RUN POSITIVE CONTROL, and it is not optional.
  //
  // Every value-drop subject above reports ZERO posts, and zero is precisely
  // what a hook that failed to install, or that was installed over an empty
  // slot, or that is watching the wrong process's globals, also reports. The
  // calibration runs in other processes cannot speak for THIS one.
  //
  // So after the measurement — never before, or it would contaminate the
  // counts — the same process drives a shape MEASURED to post, and reports
  // what the hook saw. A run whose control reads 0 has proved nothing about
  // its subject, and the cell reading this output must treat it that way.
  if (subject != 'querier-inflight') {
    hook
      ..arm('')
      ..reset();
    await _drive('querier-inflight', topology);
    stdout.writeln('HOOK_CONTROL_POSTS=${hook.posts()}');
  } else {
    // The control subject IS the control; re-running it would say nothing new.
    stdout.writeln('HOOK_CONTROL_POSTS=${hook.posts()}');
  }

  hook.uninstall();
  topology.close();

  stdout.writeln('HOOK_DONE');
  await stdout.flush();
  exit(0);
}
