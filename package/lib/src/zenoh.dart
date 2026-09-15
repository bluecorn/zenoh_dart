import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:zenoh_dart/src/config.dart';
import 'package:zenoh_dart/src/exceptions.dart';
import 'package:zenoh_dart/src/hello.dart';
import 'package:zenoh_dart/src/id.dart';
import 'package:zenoh_dart/src/log_record.dart';
import 'package:zenoh_dart/src/log_severity.dart';
import 'package:zenoh_dart/src/native_lib.dart' as nl show resolvedLibraryPath;
import 'package:zenoh_dart/src/native_lib.dart';
import 'package:zenoh_dart/src/session.dart' show Session;
import 'package:zenoh_dart/src/whatami.dart';

/// Top-level zenoh utilities.
///
/// Provides static methods for global zenoh initialization that must be
/// called before opening sessions.
class Zenoh {
  Zenoh._(); // prevent instantiation

  /// Initializes the zenoh logger from the `RUST_LOG` environment variable,
  /// falling back to [fallback] if `RUST_LOG` is not set.
  ///
  /// Must be called **before** [Session.open] for logging to take effect.
  /// This is a one-time initialization -- subsequent calls are ignored by
  /// the underlying runtime.
  ///
  /// ⛔ **And it forecloses [initLogWithSink] for the life of the process.**
  /// Canon's logging slot is process-global and first-wins; calling this
  /// **claims it permanently**, so a host that wants records delivered into
  /// its own application must install the sink **first**. The foreclosure
  /// surfaces as a `StateError` **at the sink install**, not here — this call
  /// stays silent, because a caller who asked for the env logger got the env
  /// logger and there is nothing to report.
  ///
  /// Calling it a second time is likewise silent and idempotent, unchanged.
  /// ⭐ **The asymmetry is deliberate and structural**: a throw belongs where
  /// a returned value would otherwise be false. [initLogWithSink] hands back
  /// a `Stream`, and a stream that can never emit is a lie handed back as a
  /// live channel; this returns `void`, and `void` cannot be false. What a
  /// late call to this loses is a filter level, not a channel.
  ///
  /// ⚠️ **The guard sees only inits made through this binding.** Canon
  /// returns `void` from its own init and reports nothing, so there is no
  /// way to observe an init made by other code in the same process — another
  /// binding, or a Rust crate linked into the same image. This is a guard
  /// against an ordering mistake in *your* program, not a view of canon's
  /// state.
  ///
  /// ## What the log channel carries, measured
  ///
  /// This is the route to canon's own explanation of a failure, and the
  /// measurement that made it the recommended one is worth carrying **with
  /// its condition**, because the condition is what a reader needs:
  ///
  /// - `initLog('error')` prints the precise **cause** of a `Session.open`
  ///   failure with **zero leakage** of the config that produced it. That is
  ///   true, and it is why open-failure diagnosis is routed here rather than
  ///   onto the exception message.
  /// - ⚠️ **It is a property of the failure class, not of the channel.**
  ///   **Config-rejection records echo the offending value verbatim** — with
  ///   the surrounding source line and a caret under the offending token — on
  ///   **both** build variants. On the default `stable` build, where the
  ///   exception channel carries no upstream detail at all, **this is the
  ///   only channel that leaks.**
  ///
  /// ⛔ **No severity ceiling removes it**, because the records are emitted at
  /// `error`. The control is a host-side filter on the delivered records,
  /// which is what [initLogWithSink] exists to make possible; this call sends
  /// them to stdout, where the host has no control at all.
  ///
  /// Filter syntax follows the Rust `env_logger` format:
  /// - `"error"` -- errors only (recommended for production)
  /// - `"warn"` -- warnings and errors
  /// - `"info"` -- informational messages
  /// - `"debug"` -- debug-level detail
  /// - `"trace"` -- maximum verbosity
  ///
  /// See: https://docs.rs/env_logger/latest/env_logger/
  static void initLog(String fallback) {
    final cStr = fallback.toNativeUtf8();
    try {
      bindings.zd_init_log(cStr.cast<Char>());
    } finally {
      calloc.free(cStr);
    }
  }

  /// The filesystem path `libzenoh_dart.so` was actually loaded from, or
  /// `null`.
  ///
  /// The one value that answers *"which library did you actually load?"* —
  /// the question a consumer asks precisely when a variant mismatch, a stale
  /// build or a packaging mistake is the suspect.
  ///
  /// ⛔ **Reading this does NOT initialise anything**, and that is deliberate.
  /// An accessor whose purpose is diagnosing a load problem must not depend on
  /// the load succeeding: it would throw at exactly the moment it is most
  /// needed, and merely asking would drag a 13 MB library into the address
  /// space. It is total and never throws. ⚠️ This diverges on purpose from the
  /// internal `bindings` getter, which *does* auto-initialise.
  ///
  /// **`null` means exactly one of three things**, and the third is the one
  /// nobody guesses:
  ///
  /// 1. **nothing has been loaded yet** — no zenoh call has been made in this
  ///    isolate group;
  /// 2. **the load failed** — see the `StateError` it threw, which names the
  ///    paths it probed;
  /// 3. **the OS linker resolved the library by soname**, so there was never a
  ///    path to record. This is the normal case on Android (the APK's
  ///    `lib/<abi>/`) and on Flutter desktop (`RUNPATH=$ORIGIN/lib`) —
  ///    `null` there is correct and says nothing is wrong.
  ///
  /// It reports the variant **actually loaded**, not the one requested: a
  /// consumer diagnosing a variant question gets the truth rather than their
  /// own request echoed back.
  // ignore: unnecessary_library_prefix -- forwards the loader's own getter.
  static String? get resolvedLibraryPath => nl.resolvedLibraryPath;

  /// Routes zenoh's own log records into this application, at [minSeverity]
  /// and above.
  ///
  /// Returns a **broadcast** stream of [LogRecord]. Canon normally writes its
  /// records to stderr under `RUST_LOG`; this hands them to you instead,
  /// which is what makes a level ceiling in code — and host-side redaction —
  /// possible at all.
  ///
  /// [minSeverity] is **required and has no default** on purpose: it *is* the
  /// ceiling, and a default would let a host install a sink without making
  /// the one decision the feature exists to give them.
  ///
  /// ## What you are agreeing to receive
  ///
  /// ⚠️ **Zenoh logs config material.** A rejected configuration value is
  /// echoed into a record verbatim, with the surrounding source line and a
  /// caret under the offending token — on **both** build variants, including
  /// the `stable` one where the exception channel carries no upstream detail
  /// at all. Filtering these records on the host side is the control; the
  /// severity ceiling is not, because the leak is at `error`.
  ///
  /// ## The contract, and who each part binds
  ///
  /// Canon calls the sink **synchronously on the thread that emitted the
  /// record, possibly concurrently.** That constrains the C shim, which
  /// copies and posts and returns without blocking. It does **not** constrain
  /// your listener: your listener runs on your own event loop, one post
  /// later, and may take as long as it likes.
  ///
  /// - **Records emitted before the install are lost.** There is **no
  ///   buffering** — canon has no retrospective delivery, so nothing exists
  ///   to replay.
  /// - **Records arriving with no listener are discarded.** The stream is
  ///   broadcast; that protects listeners from each other, not memory.
  /// - **The buffer is the VM's port queue, and it is unbounded.** It sits
  ///   *upstream* of the broadcast discard, so a starved event loop
  ///   accumulates records regardless of whether anyone is listening.
  /// - **A slow listener costs you memory, not zenoh's throughput.** The post
  ///   enqueues and returns; it never back-pressures zenoh's runtime threads.
  ///
  /// ### What a flood actually costs, measured
  ///
  /// The numbers, so the policy above is checkable rather than reassuring.
  /// Driven at `LogSeverity.trace` on Linux x64, resident memory sampled in
  /// the driving process:
  ///
  /// - **A sink adds nothing to the producing side.** 4 000 records: 51 ms of
  ///   driving with a sink installed against 64 ms with none. The same
  ///   instrument, with a 200 µs block injected into every post, took
  ///   **1 242 ms** — so the flat reading is a real negative and not a blind
  ///   one.
  /// - **A starved event loop accumulates**, at roughly 0.6 KiB per queued
  ///   record: **200,000 records posted with no event-loop turn grew resident
  ///   memory by ~129 MiB.** That is the unbounded port queue, and it is the
  ///   only shape in which this grows at all — a loop that yields peaks ~28
  ///   MiB and returns to its starting figure.
  /// - ⭐ **It is a backlog, not a leak.** A second identical flood in the
  ///   same process, after the first drained, grew resident memory by **0
  ///   MiB** — the first round's memory was **reclaimed** and reused. Growth
  ///   is bounded by the deepest backlog you allow, never by the total volume
  ///   ever logged.
  ///
  /// ⛔ **So there is deliberately NO SHIM-SIDE BOUND.** Imposing one would
  /// mean this binding silently dropping records a host asked for, with no
  /// channel to tell them — a confident wrong answer, which is the exact
  /// defect class this feature exists to remove. Your two controls are real
  /// ones: raise [minSeverity], and do not starve your own event loop.
  /// - **There is no removal.** Canon offers none, so a sink installed is
  ///   installed for the life of the process. This is stated as an absence
  ///   rather than papered over with a `close()` that would not do anything.
  /// - **Only severity and message cross.** Target, file, line, thread and
  ///   span are dropped at the zenoh-c layer — see [LogRecord].
  ///
  /// ## Exclusivity
  ///
  /// Canon's logging slot is **process-global and first-wins**. Calling
  /// [initLog] claims it permanently, so a host that wants a sink must
  /// install the sink **first**.
  ///
  /// Throws [StateError] if the slot was already claimed through this
  /// binding — by an earlier [initLog], or by an earlier sink install.
  /// ⛔ **It throws rather than returning a stream**, because a stream that
  /// can never emit is a lie handed back as a live channel.
  ///
  /// ⚠️ **The guard sees only inits made through this binding**, and canon
  /// returns `void` from `zc_init_log_with_callback`, so it reports nothing
  /// itself. An init made by other code in the same process claims canon's
  /// slot without this binding ever knowing.
  ///
  /// Throws [ArgumentError] if [minSeverity] is not one canon defines, which
  /// the enum makes unreachable from Dart.
  static Stream<LogRecord> initLogWithSink({
    required LogSeverity minSeverity,
  }) {
    // ⛔ RawReceivePort, not ReceivePort, and `keepIsolateAlive = false`.
    //
    // A receive port keeps its isolate alive until closed, and this sink has
    // no session, no handle and no removal to close it from. A ReceivePort
    // here would mean every process that installed a sink hangs at exit — a
    // measured failure mode on this codebase, not a hypothetical one.
    //
    // `keepIsolateAlive` is declared on RawReceivePort and not on
    // ReceivePort, so this is a SHAPE constraint rather than a flag: the sink
    // uses a raw port with a handler, never `ReceivePort.listen`.
    //
    // ⚠️ The cost, priced rather than hidden: records still in flight when
    // the isolate shuts down are dropped. Losing tail records beats never
    // exiting.
    final port = RawReceivePort()..keepIsolateAlive = false;
    final controller = StreamController<LogRecord>.broadcast();

    port.handler = (dynamic message) {
      if (message is! List || message.length != 2) return;
      final severity = LogSeverity.fromWire(message[0] as int);
      final bytes = message[1] as Uint8List;
      // Lenient: canon's messages are canon's bytes, and a decode that threw
      // inside a log delivery would take down the host's error reporting at
      // exactly the moment it is needed.
      controller.add(
        LogRecord(severity, utf8.decode(bytes, allowMalformed: true)),
      );
    };

    final rc = bindings.zd_init_log_with_callback(
      minSeverity.wireValue,
      port.sendPort.nativePort,
    );
    if (rc != 0) {
      // Nothing was installed and no record will ever arrive, so the port and
      // the controller are released here rather than left as a channel that
      // looks live.
      port.close();
      unawaited(controller.close());
      throw StateError(
        rc > 0
            ? "zenoh's logging slot was already claimed through this binding "
                  '(by an earlier Zenoh.initLog or Zenoh.initLogWithSink). '
                  "Canon's logging init is process-global and first-wins, so "
                  'install the sink before any other init.'
            : 'zd_init_log_with_callback rejected the severity '
                  '${minSeverity.name} (code $rc)',
      );
    }

    return controller.stream;
  }

  /// Scouts for zenoh entities on the network.
  ///
  /// Returns a list of [Hello] messages from discovered entities.
  /// The scouting runs for [timeoutMs] milliseconds (default 1000).
  ///
  /// **Does not block the calling isolate.** The blocking native scout runs on
  /// a background thread owned by the C shim, so timers keep firing, other
  /// futures keep progressing, and a Flutter frame pipeline keeps running for
  /// the whole [timeoutMs]. Await the returned future as normal.
  ///
  /// If [config] is provided, it is consumed by the scout call and must
  /// not be reused. If [config] is null, a default configuration is used.
  ///
  /// The [what] parameter specifies which entity types to scout for
  /// (default 3 = routers + peers). Uses zenoh-c bitmask values:
  /// 1=router, 2=peer, 4=client, combined by summing.
  ///
  /// The accepted domain is exactly what canon's `z_what_t` enumerates --
  /// 1, 2, 3, 4, 5, 6 and 7. Nothing else is in it: 0, 8 and every negative
  /// are refused.
  ///
  /// Throws [ArgumentError] naming the offending value if [what] is outside
  /// that domain. The guard runs before any native call and before [config]
  /// is read, so the throw leaves the caller's [config] untouched and still
  /// usable.
  ///
  /// Throws [StateError] if [config] has been consumed or disposed.
  ///
  /// Throws [ZenohException] if scouting could not be *started* -- the future
  /// is never left to hang. A failure that happens *inside* the native scout,
  /// after it started, instead surfaces as a normally-completing future with
  /// an empty list: the native call reports its outcome long after this method
  /// has returned, and there is no channel for it that would not change the
  /// public surface.
  static Future<List<Hello>> scout({
    Config? config,
    int timeoutMs = 1000,
    int what = 3,
  }) async {
    // The domain guard runs first, ahead of everything. Two reasons:
    //
    // 1. It must fire before anything touches native. `what` crosses into an
    //    unsigned native field (the shim casts to z_what_t), so a negative
    //    would arrive as a bit pattern rather than as any value canon names,
    //    and 0 / 8 are simply not in canon's enumeration.
    // 2. Guarding ahead of the config read is what leaves a rejected call
    //    inert: the ArgumentError propagates with the caller's Config
    //    untouched and still usable -- nothing happened. Had the guard run
    //    after the config check, a caller passing both a bad mask and a live
    //    config would be left holding a config in an indeterminate
    //    relationship with a call that was never made.
    if (what < 1 || what > 7) {
      throw ArgumentError.value(
        what,
        'what',
        'must be in the z_what_t domain 1..7 (1=router, 2=peer, 4=client)',
      );
    }

    // Validate config state before proceeding
    int configAddr;
    if (config != null) {
      // This will throw StateError if consumed or disposed
      configAddr = config.nativePtr.address;
    } else {
      configAddr = 0;
    }

    final receivePort = ReceivePort();
    final hellos = <Hello>[];
    final completer = Completer<List<Hello>>();

    receivePort.listen((dynamic message) {
      if (message == null) {
        // Null sentinel from C -- scouting complete
        completer.complete(hellos);
        receivePort.close();
      } else if (message is List) {
        final zidBytes = message[0] as Uint8List;
        final whatami = message[1] as int;
        // Locators arrive as a per-element array of strings (the shim marshals
        // each locator as its own Dart_CObject string). Reading the list
        // directly -- rather than splitting a ';'-joined blob -- preserves any
        // ';' inside a single locator and keeps an empty set as [] (not ['']).
        final locators = (message[2] as List).cast<String>();
        hellos.add(
          Hello(
            zid: ZenohId(zidBytes),
            whatami: WhatAmI.fromInt(whatami),
            locators: locators,
          ),
        );
      }
    });

    final nativePort = receivePort.sendPort.nativePort;

    // zd_scout returns immediately: it hands the blocking scout to a
    // shim-owned detached worker thread, so the caller's event loop keeps
    // running. Hellos and the completion sentinel are posted to the NativePort
    // from that worker.
    //
    // cfgPtr is reconstructed from the address captured above, so it aliases
    // the config's native block. zd_scout takes the config's *content* into
    // worker-owned storage before it returns and gravestones the block, so
    // markConsumed's free below lands on a moved-out husk -- the worker never
    // reads memory that Dart has freed.
    final cfgPtr = configAddr != 0
        ? Pointer<Void>.fromAddress(configAddr)
        : nullptr;
    final rc = bindings.zd_scout(cfgPtr.cast(), nativePort, timeoutMs, what);

    // Unconditional, as at every other consuming site: the shim takes the
    // config's content before any step that can fail, so it is consumed on
    // every path where zd_scout was entered with one.
    if (config != null) {
      config.markConsumed();
    }

    // rc != 0 means nothing started and no sentinel will ever be posted, so
    // awaiting the completer would hang forever. Close the port and surface
    // the failure instead. (rc == 0 means the worker started and exactly one
    // sentinel will arrive.)
    if (rc != 0) {
      receivePort.close();
      throw ZenohException('Failed to start scouting', rc);
    }

    return completer.future;
  }
}
