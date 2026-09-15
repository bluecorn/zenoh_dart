import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

import 'common_args.dart';

const defaultKeyExpr = 'demo/example/**';

const helpText =
    '''
    Usage: z_storage [OPTIONS]

    Options:
        -k, --key <KEYEXPR> (optional, string, default='$defaultKeyExpr'): The selection of resources to store
        --complete (optional): Declare the storage as complete w.r.t. the key expression
''';

Future<void> main(List<String> arguments) async {
  Zenoh.initLog('error');

  final parser = ArgParser()
    ..addOption('key', abbr: 'k', defaultsTo: defaultKeyExpr)
    ..addFlag('complete', negatable: false);
  addCommonArgs(parser);

  final results = parseArgs(parser, arguments, helpText);
  checkNoPositionalArgs(results);

  final keyExpr = results.option('key')!;
  final complete = results.flag('complete');
  final config = buildConfig(results);

  print('Opening session...');
  final session = await openSession(config);

  // In-memory storage: key expression string -> the stored Sample.
  //
  // This map HOLDS NATIVE HANDLES. The subscriber below is declared with
  // `retainPayload: true`, so every delivered sample carries an owned
  // `payloadZBytes` -- a refcount clone of the payload the network
  // delivered -- and that handle is this program's to release. An entry
  // leaves this map in exactly three ways, and each of them releases the
  // handle it displaces: a DELETE evicts it, a PUT to a key already stored
  // replaces it, and shutdown drops whatever is left. Miss any one and what
  // leaks is the whole payload, not merely the wrapper around it.
  final storage = <String, Sample>{};

  print("Declaring Subscriber on '$keyExpr'...");
  final subscriber = session.declareSubscriber(keyExpr, retainPayload: true);

  print("Declaring Queryable on '$keyExpr'...");
  final queryable = session.declareQueryable(keyExpr, complete: complete);

  print('Press CTRL-C to quit...');

  final completer = Completer<void>();

  // Listen for samples and store/remove them
  final subStreamSub = subscriber.stream.listen((sample) {
    final kindStr = sample.kind == SampleKind.put ? 'PUT' : 'DELETE';
    print(
      ">> [Subscriber] Received $kindStr ('${sample.keyExpr}': "
      "'${sample.payload}')",
    );
    switch (sample.kind) {
      case SampleKind.put:
        // The displaced entry's handle first: overwriting the map slot
        // would otherwise drop its reference with nothing left pointing at
        // it. Null on the common path, where the key is new.
        final displaced = storage[sample.keyExpr];
        storage[sample.keyExpr] = sample;
        displaced?.payloadZBytes?.dispose();
      case SampleKind.delete:
        // TWO handles end here. The evicted entry's, and this DELETE
        // sample's own: retention clones the payload of every sample it
        // delivers, and a DELETE -- whose payload is empty, and which is
        // never stored -- is no exception.
        storage.remove(sample.keyExpr)?.payloadZBytes?.dispose();
        sample.payloadZBytes?.dispose();
    }
  });

  // Listen for queries and reply with matching stored entries
  final queryStreamSub = queryable.stream.listen((query) {
    print(
      ">> [Queryable ] Received Query '${query.keyExpr}' "
      "with parameters '${query.parameters}'",
    );

    final queryKe = KeyExpr(query.keyExpr);
    try {
      for (final entry in storage.entries) {
        final entryKe = KeyExpr(entry.key);
        try {
          if (entryKe.intersects(queryKe)) {
            // Canon clones TWICE and this example performs the second one.
            // Into the store canon puts a whole `z_sample_clone`
            // (z_storage.c:250); out of the store into each matching reply
            // it puts a `z_bytes_clone` of the stored payload
            // (z_storage.c:92-94). What Dart stores is the delivered
            // `Sample` itself -- its key, kind and bytes are already this
            // process's own copies, taken as the sample crossed the seam --
            // plus the one thing a sample clone would still have bought:
            // the retained payload handle. So canon's second clone is the
            // one left to perform, and this is it. `ZBytes.clone()` IS
            // `z_bytes_clone`, a reference-count bump on the payload the
            // network delivered rather than a copy of it, and `replyBytes`
            // consumes the clone -- so each reply releases exactly what it
            // sent. The `!` is the declaration asserting itself: retention
            // is on, so every stored sample carries a handle.
            //
            // Two routes this deliberately does not take. A `ZBytes` built
            // from the sample's `payloadBytes` -- what this used to do --
            // copies every stored byte onto the heap again on every
            // matching reply. And `Sample.payload`, the lenient UTF-8
            // display string, would re-encode every invalid sequence as
            // U+FFFD and silently corrupt binary values.
            query.replyBytes(entry.key, entry.value.payloadZBytes!.clone());
          }
        } finally {
          entryKe.dispose();
        }
      }
    } finally {
      queryKe.dispose();
    }
    query.dispose();
  });

  // Handle SIGINT and SIGTERM for clean shutdown
  final sigintSub = ProcessSignal.sigint.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });
  final sigtermSub = ProcessSignal.sigterm.watch().listen((_) {
    if (!completer.isCompleted) completer.complete();
  });

  await completer.future;

  await sigintSub.cancel();
  await sigtermSub.cancel();
  await subStreamSub.cancel();
  await queryStreamSub.cancel();

  // Nothing can arrive or be queried any more, and the map still owns one
  // retained handle per entry. Canon's `storage_drop(&storage)` at the end
  // of its main is the same act.
  for (final stored in storage.values) {
    stored.payloadZBytes?.dispose();
  }
  storage.clear();

  queryable.close();
  subscriber.close();
  session.close();
}
