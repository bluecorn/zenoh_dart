// The Dart analogue of `nm -D`: what does this library ACTUALLY export?
//
// Reads the resolved export namespace, so `hide`/`show` clauses are honoured
// and a type declared in an exported file but hidden does not appear.
// A regex over `export` lines counts FILES; this counts NAMES.
import 'dart:io';
import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: export_surface.dart <library.dart> [more...]');
    exit(2);
  }
  final paths = args.map((a) => File(a).absolute.path).toList();
  final collection = AnalysisContextCollection(includedPaths: paths);
  for (final path in paths) {
    if (!File(path).existsSync()) {
      stderr.writeln('MISSING: $path');
      exit(1);
    }
    final ctx = collection.contextFor(path);
    final result = await ctx.currentSession.getResolvedLibrary(path);
    if (result is! ResolvedLibraryResult) {
      stderr.writeln('UNRESOLVED: $path -> $result');
      exit(1);
    }
    final ns = result.element.exportNamespace.definedNames2;
    final names = ns.keys.where((n) => !n.startsWith('_')).toList()..sort();
    for (final n in names) {
      stdout.writeln('${_kind(ns[n])},$n');
    }
    stderr.writeln('# ${path.split('/').last}: ${names.length} exported names');
  }
}

String _kind(Object? e) {
  final t = e.runtimeType.toString();
  if (t.contains('ClassElement')) return 'class';
  if (t.contains('EnumElement')) return 'enum';
  if (t.contains('MixinElement')) return 'mixin';
  if (t.contains('ExtensionElement')) return 'extension';
  if (t.contains('TypeAlias')) return 'typedef';
  if (t.contains('FunctionElement')) return 'function';
  if (t.contains('PropertyAccessor') || t.contains('TopLevelVariable')) return 'var';
  return 'other';
}
