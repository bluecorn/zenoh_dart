// Shared command-line surface for the CLI examples.
//
// Canon is `extern/zenoh-c/examples/parse_args.h`: every C example calls
// `_Z_CHECK_HELP` + `parse_zenoh_common_args()` + `check_unknown_opts()` +
// `parse_pos_args()`. This file is the Dart translation of that block, so all
// examples share one flag surface, one set of message shapes and one set of
// exit codes instead of hand-rolling twenty-six near-copies.
//
// Adopted by every example that canon builds with `parse_zenoh_common_args`.
// `z_bytes` is deliberately excluded: canon's `z_bytes.c` has no argument
// parsing at all and opens no session, so adding a flag surface there would
// *create* a divergence rather than close one.
//
// It also carries [openSession]. That guard is not part of `parse_args.h`, but
// it is the statement every canon example executes immediately *after* it, in
// one identical shape across all twenty-seven of them -- so it belongs with the
// block it always follows, for the same reason the flag surface does: one
// implementation instead of twenty-five near-copies that drift apart.

import 'dart:io';

import 'package:args/args.dart';
import 'package:zenoh_dart/zenoh.dart';

/// The common option block printed by every canon example's `print_help`.
///
/// Mirrors `COMMON_HELP` in `parse_args.h` verbatim.
const commonHelp = '''
        -c, --config <CONFIG> (optional, string): The path to a configuration file for the session. If this option isn't passed, the default configuration will be used.
        -m, --mode <MODE> (optional, string, default='peer'): The zenoh session mode. [possible values: peer, client, router]
        -e, --connect <CONNECT> (optional, string): Endpoint to connect to. Repeat option to pass multiple endpoints. If none are given, endpoints will be discovered through multicast-scouting if it is enabled.
            e.g.: '-e tcp/192.168.1.1:7447'
        -l, --listen <LISTEN> (optional, string): Locator to listen on. Repeat option to pass multiple locators. If none are given, the default configuration will be used.
            e.g.: '-l tcp/192.168.1.1:7447'
        --no-multicast-scouting (optional): By default zenohd replies to multicast scouting messages for being discovered by peers and clients. This option disables this feature.
        --cfg (optional, string): Allows arbitrary configuration changes as column-separated KEY:VALUE pairs. Where KEY must be a valid config path and VALUE must be a valid JSON5 string that can be deserialized to the expected type for the KEY field. Example: --cfg='transport/unicast/max_links:2'.
        -h, --help: Print help
''';

/// The status a shell observes for canon's `exit(-1)` / `return -1`.
///
/// Exported so the examples' own failure paths report the same status canon's
/// do, rather than inventing a second failure code.
const canonFailureExit = 255;

/// Registers the canon common options on [parser].
///
/// Call this after the example's own options so `--help` output order does not
/// matter; `package:args` keys on names, not registration order.
///
/// `splitCommas: false` on the three repeatable options is required for parity,
/// not stylistic. Canon takes multiple values by *repeating the flag*
/// (`COMMON_HELP`: "Repeat option to pass multiple endpoints"), and treats a
/// comma inside a value as a literal character. `package:args` splits on commas
/// by default, which shreds any canon-valid value that contains one -- most
/// visibly `--cfg 'connect/endpoints:["tcp/a:7447","tcp/b:7447"]'`, which
/// fragments into two pieces that no longer parse as `KEY:VALUE`.
void addCommonArgs(ArgParser parser) {
  parser
    ..addOption('config', abbr: 'c')
    ..addOption('mode', abbr: 'm')
    ..addMultiOption('connect', abbr: 'e', splitCommas: false)
    ..addMultiOption('listen', abbr: 'l', splitCommas: false)
    ..addMultiOption('cfg', splitCommas: false)
    ..addFlag('no-multicast-scouting', negatable: false)
    ..addFlag('help', abbr: 'h', negatable: false);
}

/// Parses [arguments], handling `-h`/`--help` and malformed options the way
/// canon does.
///
/// [help] is the example-specific usage block; [commonHelp] is appended to it,
/// mirroring each canon `print_help`'s `printf(COMMON_HELP)` tail.
///
/// Exits 1 on `--help` (canon's `_Z_CHECK_HELP`) and 255 on a bad option
/// (canon's `exit(-1)`), rather than letting an `ArgParserException` escape as
/// an uncaught stack trace.
ArgResults parseArgs(ArgParser parser, List<String> arguments, String help) {
  // Canon checks help *before* parsing anything else, so `-h` wins even when
  // the rest of the command line is malformed.
  if (arguments.contains('-h') || arguments.contains('--help')) {
    _printHelp(help);
  }

  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on ArgParserException catch (e) {
    final name = e.argumentName;
    if (name != null &&
        (e.message.startsWith('Could not find') ||
            // `package:args` reports a typed `--no-X` against a non-negatable
            // flag as a *negation* error, naming the spelling that was typed.
            // Canon has no negation concept at all, so `--no-X` is simply an
            // option it does not have; report it the way canon reports one.
            e.message.startsWith('Cannot negate'))) {
      // canon: check_unknown_opts -> "Unknown option %s"
      print('Unknown option $name');
    } else if (name != null && e.message.startsWith('Missing argument')) {
      // canon: parse_opt -> "Option -%s given without a value"
      print('Option $name given without a value');
    } else {
      print(e.message);
    }
    exit(canonFailureExit);
  }

  // Reachable only for the `--help=VALUE` spelling, which canon's prefix match
  // also accepts but the literal scan above does not.
  if (results.flag('help')) _printHelp(help);

  return results;
}

Never _printHelp(String help) {
  stdout
    ..write(help)
    ..write(commonHelp);
  exit(1);
}

/// Builds the session configuration from the common options.
///
/// Mirrors `parse_zenoh_common_args`: `-c` selects the base configuration,
/// then `-m`, `-e`, `-l`, `--cfg` and `--no-multicast-scouting` are layered on
/// top in that order.
Config buildConfig(ArgResults results) {
  final configFile = results.option('config');
  final Config config;
  if (configFile != null) {
    // canon ignores `zc_config_from_file`'s return code and lets the failure
    // surface later as "Unable to open session!"; reporting it here is
    // strictly more informative and still a nonzero exit.
    try {
      config = Config.fromFile(configFile);
    } on ZenohException {
      print("Couldn't read configuration file `$configFile`");
      exit(canonFailureExit);
    }
  } else {
    config = Config();
  }

  final mode = results.option('mode');
  if (mode != null) {
    _insert(
      config,
      'mode',
      "'$mode'",
      "Couldn't insert value `$mode` in configuration at `mode`. "
          "Value must be one of: 'client', 'peer' or 'router'",
    );
  }

  _insertEndpoints(config, results.multiOption('connect'), 'connect/endpoints');
  _insertEndpoints(config, results.multiOption('listen'), 'listen/endpoints');

  for (final pair in results.multiOption('cfg')) {
    final sep = pair.indexOf(':');
    if (sep < 0) {
      print('--cfg` argument: expected KEY:VALUE pair, got $pair ');
      exit(canonFailureExit);
    }
    final key = pair.substring(0, sep);
    final value = pair.substring(sep + 1);
    // Message mirrors canon's, including its swapped key/value arguments
    // (parse_args.h:229) -- a canon quirk, reproduced rather than corrected.
    _insert(
      config,
      key,
      value,
      "Couldn't insert value `$key` in configuration at `$value`",
    );
  }

  if (results.flag('no-multicast-scouting')) {
    _insert(
      config,
      'scouting/multicast/enabled',
      'false',
      "Couldn't disable multicast-scouting.",
    );
  }

  return config;
}

void _insertEndpoints(Config config, List<String> endpoints, String key) {
  if (endpoints.isEmpty) return;
  // canon builds a single-quoted JSON5 list: ['tcp/a','tcp/b'].
  final json = "[${endpoints.map((e) => "'$e'").join(',')}]";
  _insert(
    config,
    key,
    json,
    "Couldn't insert value `$json` in configuration at `$key`\n"
    '`$json` is either not a JSON-serialized list of strings, or values '
    'within the list do not respect expected format for `$key`',
  );
}

void _insert(Config config, String key, String value, String errorMessage) {
  try {
    config.insertJson5(key, value);
  } on ZenohException {
    print(errorMessage);
    exit(canonFailureExit);
  }
}

/// Opens a session, reporting a failed open the way canon reports it.
///
/// Mirrors the guard every canon example performs immediately after building
/// its config -- identical in all twenty-seven of them:
///
/// ```c
/// if (z_open(&s, z_move(config), NULL) < 0) {
///     printf("Unable to open session!\n");
///     exit(-1);
/// }
/// ```
///
/// zenoh-c returns a negative code where Dart throws, so the translation of
/// `< 0` is a `catch`. Everything else is canon's: the message verbatim, and
/// `exit(-1)`'s observed status via [canonFailureExit].
///
/// This is deliberately the *whole* difference. It reports the failure; it does
/// not retry, wait, or otherwise change what [Session.open] does -- the most
/// likely newcomer failure (client mode with no reachable router) simply stops
/// presenting as an unhandled `ZenohException` stack trace.
Future<Session> openSession(Config config) async {
  try {
    return await Session.open(config: config);
  } on ZenohException {
    print('Unable to open session!');
    exit(canonFailureExit);
  }
}

/// Rejects any positional argument, mirroring the
/// `parse_pos_args(argc, argv, 1)` + "Unexpected positional arguments" check
/// that every canon example without a positional performs.
void checkNoPositionalArgs(ArgResults results) {
  if (results.rest.isNotEmpty) {
    print('Unexpected positional arguments');
    exit(canonFailureExit);
  }
}

/// Returns the single required positional argument named [name].
///
/// Mirrors the `<PAYLOAD_SIZE>` check in canon's `z_ping`, `z_ping_shm`,
/// `z_pub_thr` and `z_pub_shm_thr`.
int requirePositionalSize(ArgResults results, String name) {
  if (results.rest.isEmpty) {
    print('$name argument is required');
    exit(canonFailureExit);
  }
  if (results.rest.length > 1) {
    print('Unexpected positional arguments');
    exit(canonFailureExit);
  }
  return parseIntArg(results.rest[0]);
}

/// Parses a numeric option the way canon's `atoi` does: a non-numeric argument
/// yields 0 rather than aborting.
int parseIntArg(String value) => int.tryParse(value) ?? 0;

/// Mirrors `parse_query_target`: an unrecognised value is fatal, not a silent
/// fallback to the default target.
QueryTarget parseQueryTarget(String arg) {
  switch (arg) {
    case 'BEST_MATCHING':
      return QueryTarget.bestMatching;
    case 'ALL':
      return QueryTarget.all;
    case 'ALL_COMPLETE':
      return QueryTarget.allComplete;
    default:
      print('Unsupported query target value [$arg]');
      exit(canonFailureExit);
  }
}

/// Mirrors `parse_priority`: values outside the `Z_PRIORITY_REAL_TIME` ..
/// `Z_PRIORITY_BACKGROUND` range are fatal.
Priority parsePriority(String arg) {
  final p = parseIntArg(arg);
  if (p < 1 || p > Priority.values.length) {
    print('Unsupported priority value [$arg]');
    exit(canonFailureExit);
  }
  return Priority.values[p - 1];
}
