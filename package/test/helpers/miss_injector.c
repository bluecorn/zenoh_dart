// miss_injector.c — a canon-C advanced publisher that can be told to lie about
// its sequence numbers.
//
// WHY THIS EXISTS. The shipped native miss-callback bridge
// (`zd_advanced_subscriber_declare_background_sample_miss_listener` ->
// `AdvancedSubscriber.missEvents`) had ZERO executed end-to-end coverage. Its
// only live test self-skipped on every run, and its own skip message said why
// that mattered: "a broken bridge is indistinguishable from a skipped test."
// Over reliable loopback nothing is ever missed, so no arrangement of real
// publishers and subscribers can drive a miss event.
//
// What CAN drive one is a raw `z_put` carrying a crafted `z_source_info_t`: the
// subscriber's gap tracker keys on the source sequence number, so publishing
// sn=10 on an identity whose last-seen sn was 1 makes it report a gap of 8.
// Measured twice at seed #8's authoring, deterministic both times.
//
// WHY IT IS C AND NOT DART. `source_info` on put options is a dated carve —
// unstable-API-by-decision — and so is the session entity id. A public Dart
// source-info surface would touch both carves and exceed this seed's charter.
// As a C-side test instrument the lever touches neither.
//
// BUILD — note the include path, which is not the obvious one:
//
//   cd package && clang -O0 -g test/helpers/miss_injector.c \
//     -I ../build/linux-x64/extern/zenoh-c/release/include \
//     -L native/linux/x86_64/unstable -lzenohc \
//     -Wl,-rpath,$PWD/native/linux/x86_64/unstable -o <out>/miss_injector
//
// The headers MUST come from the BUILD tree, never from `extern/zenoh-c/include`.
// `zenoh_opaque.h` and `zenoh_configure.h` are cargo-GENERATED files that the
// submodule's own .gitignore excludes and that every full build clobbers; the
// source-tree copies declare a 240-byte advanced-publisher struct against a
// library that writes 248. Measured: nine bytes out of bounds, with rc 0
// throughout and correct-looking output. `src/CMakeLists.txt` already enforces
// the same rule for the shim itself and states the reason there.
//
// PROTOCOL (line-based, stdout is line-buffered by the first statement of main
// so it survives a pipe — canon C binaries block-buffer when redirected):
//
//   stdout, once at startup:
//     INJECTOR_ID <32 hex digits, front-to-back> <eid>
//     INJECTOR_READY
//   stdin, one command per line:
//     PUT        -> one advanced put; replies  PUT_DONE <n>
//     GAP <sn>   -> one raw z_put carrying crafted source_info{harvested id, sn};
//                   replies  GAP_DONE <sn> rc=<rc>
//     QUIT       -> drops everything; replies  INJECTOR_EXIT
//   any setup failure:
//     INJECTOR_FATAL <what>   (and a non-zero exit)
//
// The zid is printed front-to-back, NOT through canon's `z_id_to_string`.
// Canon's renderer differs from `ZenohId.toHexString()` on two axes — byte
// order AND leading-zero stripping, the latter a measured 1-in-16 hazard that
// yields 31 digits. Front-to-back `%02x` is always 32 digits and matches our
// renderer exactly, so the identity assertion never has to cross a divergence
// that seed #9 owns. See `package/test/interop/canon.dart` for the boundary
// that does the crossing where it is genuinely needed.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zenoh.h>

static int fatal(const char *what) {
  printf("INJECTOR_FATAL %s\n", what);
  return 1;
}

int main(int argc, char **argv) {
  // FIRST statement: a canon C binary's stdout block-buffers under a pipe, and
  // the harness reads it through one. Cured here rather than by wrapping the
  // spawn in stdbuf, because this source is ours to change.
  setvbuf(stdout, NULL, _IOLBF, 0);

  if (argc < 3) return fatal("usage: miss_injector <listen-endpoint> <keyexpr>");
  const char *endpoint = argv[1];
  const char *keyexpr = argv[2];

  char listen[512];
  snprintf(listen, sizeof listen, "[\"%s\"]", endpoint);

  z_owned_config_t cfg;
  z_config_default(&cfg);
  if (zc_config_insert_json5(z_loan_mut(cfg), Z_CONFIG_LISTEN_KEY, listen) < 0)
    return fatal("config listen");
  if (zc_config_insert_json5(z_loan_mut(cfg), Z_CONFIG_MULTICAST_SCOUTING_KEY,
                             "false") < 0)
    return fatal("config multicast");
  if (zc_config_insert_json5(z_loan_mut(cfg), "scouting/gossip/enabled",
                             "false") < 0)
    return fatal("config gossip");
  if (zc_config_insert_json5(z_loan_mut(cfg), Z_CONFIG_ADD_TIMESTAMP_KEY,
                             "true") < 0)
    return fatal("config timestamping");

  z_owned_session_t session;
  if (z_open(&session, z_move(cfg), NULL) < 0) return fatal("z_open");

  z_view_keyexpr_t ke;
  if (z_view_keyexpr_from_str(&ke, keyexpr) < 0) return fatal("keyexpr");

  ze_advanced_publisher_options_t po;
  ze_advanced_publisher_options_default(&po);
  ze_advanced_publisher_cache_options_default(&po.cache);
  po.cache.max_samples = 10;
  ze_advanced_publisher_sample_miss_detection_options_default(
      &po.sample_miss_detection);
  po.sample_miss_detection.heartbeat_mode =
      ZE_ADVANCED_PUBLISHER_HEARTBEAT_MODE_PERIODIC;
  po.sample_miss_detection.heartbeat_period_ms = 100;
  po.publisher_detection = true;

  ze_owned_advanced_publisher_t pub;
  if (ze_declare_advanced_publisher(z_loan(session), &pub, z_loan(ke), &po) < 0)
    return fatal("declare advanced publisher");

  // The identity every crafted put will claim. There is no constructor for an
  // entity id anywhere in canon: it can only be harvested from a live entity.
  z_entity_global_id_t id = ze_advanced_publisher_id(z_loan(pub));
  z_id_t zid = z_entity_global_id_zid(&id);
  printf("INJECTOR_ID ");
  for (int i = 0; i < 16; i++) printf("%02x", zid.id[i]);
  printf(" %u\n", z_entity_global_id_eid(&id));
  printf("INJECTOR_READY\n");

  char line[256];
  int puts_done = 0;
  while (fgets(line, sizeof line, stdin) != NULL) {
    if (strncmp(line, "PUT", 3) == 0) {
      // A REAL advanced put: canon attaches the next source sn itself, which
      // is what establishes the baseline the crafted gap is measured against.
      char text[64];
      snprintf(text, sizeof text, "inj-%d", puts_done);
      z_owned_bytes_t payload;
      z_bytes_copy_from_str(&payload, text);
      ze_advanced_publisher_put_options_t opts;
      ze_advanced_publisher_put_options_default(&opts);
      int rc = ze_advanced_publisher_put(z_loan_mut(pub), z_move(payload),
                                         &opts);
      printf("PUT_DONE %d rc=%d\n", puts_done++, rc);
    } else if (strncmp(line, "GAP ", 4) == 0) {
      uint32_t sn = (uint32_t)strtoul(line + 4, NULL, 10);
      z_owned_bytes_t payload;
      z_bytes_copy_from_str(&payload, "crafted");
      z_put_options_t opts;
      z_put_options_default(&opts);
      z_source_info_t si = z_source_info_new(&id, sn);
      opts.source_info = &si;
      int rc = z_put(z_loan_mut(session), z_loan(ke), z_move(payload), &opts);
      printf("GAP_DONE %u rc=%d\n", sn, rc);
    } else if (strncmp(line, "QUIT", 4) == 0) {
      break;
    }
  }

  ze_advanced_publisher_drop(z_move(pub));
  z_session_drop(z_move(session));
  printf("INJECTOR_EXIT\n");
  return 0;
}
