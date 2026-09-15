// encoding_peer.c — a canon-C peer that carries EXACTLY the encoding bytes it
// is told to, interior NUL (U+0000) included.
//
// WHY THIS EXISTS. Seed #10's criterion A demands that an encoding whose MIME
// string contains an interior NUL arrive byte-identical, in BOTH directions.
// The send direction can be driven from Dart. The RECEIVE direction cannot: our
// own send path is the thing under repair, so using it to drive our receive
// path would make one defect hide the other — a green would prove only that the
// two halves truncate in agreement. What drives the receive half in isolation
// is a canon-C publisher/querier/replier that never goes through our shim at
// all, which is what this program is.
//
// It generalises `miss_injector.c`'s mechanism (an in-tree canon-C peer the
// test compiles and drives over stdin) to the encoding channel.
//
// HOW THE BYTES GET HERE WITHOUT A NUL IN THIS FILE. Every encoding this peer
// builds arrives as a HEX string on the command line and is decoded to bytes at
// runtime. That is not decoration: a raw NUL in a tracked artifact silently
// turns the whole file binary to `grep`, which is the review instrument every
// station on this line depends on — measured three times while seed #10 was
// authored. So: no control byte is ever spelled in this source, and the source
// stays NUL-free as text (scanned before commit).
//
// BUILD — note the include path, which is not the obvious one, and note that
// BOTH the includes and the library are VARIANT-scoped:
//
//   cd package && clang -O0 -g test/helpers/encoding_peer.c \
//     -I ../build/linux-x64<-stable>/extern/zenoh-c/release/include \
//     -L native/linux/x86_64/<variant> -lzenohc \
//     -Wl,-rpath,$PWD/native/linux/x86_64/<variant> -o <out>/encoding_peer
//
// The headers MUST come from the BUILD tree, never from `extern/zenoh-c/include`.
// `zenoh_opaque.h` and `zenoh_configure.h` are cargo-GENERATED files that the
// submodule's own .gitignore excludes and that every full build clobbers; the
// source-tree copies are ABI-mismatched against the shipped library. And the
// two build trees differ: `linux-x64` defines Z_FEATURE_UNSTABLE_API and
// Z_FEATURE_SHARED_MEMORY, `linux-x64-stable` does not, which changes the
// layout of every options struct with a guarded member. `src/CMakeLists.txt`
// enforces the same rule for the shim itself and states the reason there.
//
// Every canon symbol used here is at guard depth 0 (stable), so this program
// compiles and runs on BOTH matrix legs.
//
// PROTOCOL (line-based; stdout is line-buffered by the first statement of main
// so it survives a pipe — canon C binaries block-buffer when redirected):
//
//   stdout, once at startup:
//     PEER_READY
//   stdin, one command per line:
//     PUB <keyexpr> <mime> <schema>   -> one z_put;  replies  PUB_DONE rc=<rc>
//     QUERY <selector> <mime> <schema> [<payload>]
//                                     -> one z_get carrying that encoding;
//                                        replies QUERY_DONE rc=<rc>. <payload>
//                                        is `-` for a get with NO payload at
//                                        all, anything else (or absent) for a
//                                        get that carries one. ⚠️ MEASURED: the
//                                        payload is what decides whether the
//                                        receiver sees an absent encoding —
//                                        canon substitutes `zenoh/bytes` the
//                                        moment a payload exists, whatever the
//                                        encoding option said.
//     PUB_EMPTY <keyexpr>             -> one z_put whose encoding is the
//                                        PRESENT-BUT-EMPTY state: id 0xFFFF
//                                        with no schema, built through
//                                        `zc_internal_encoding_from_data`. It
//                                        renders as a ZERO-LENGTH string, which
//                                        is a state NO public canon
//                                        construction route can reach —
//                                        measured (GT-16c), all four render
//                                        "zenoh/bytes". Replies PUB_DONE
//                                        rc=<rc>. This is the driver for the
//                                        cell the shim and seed #5's plan
//                                        archive both record as
//                                        structurally-verified-only.
//     QUERYABLE <keyexpr> <ok|err> <mime> <schema>
//                                     -> declares a queryable that answers
//                                        every incoming query on that arm with
//                                        that encoding; replies
//                                        QUERYABLE_DONE rc=<rc>
//     QUIT                            -> drops everything; replies PEER_EXIT
//   any setup failure:
//     PEER_FATAL <what>               (and a non-zero exit)
//
// <mime>   is a hex string: the exact bytes of the MIME id, decoded here. `-`
//          means NO ENCODING AT ALL — canon's option field is left untouched,
//          which is the only way to drive the absent state a query can
//          genuinely carry (a sample and a reply always render one).
// <schema> is `-` for "no schema at all" (the setter is never called), or
//          `x` followed by hex digits for "set this schema" — `x` alone means
//          the present-but-empty schema, which canon renders as a bare
//          trailing separator on a well-known id.
//
// SELF-TEST MODE (a second, non-interactive argv shape) — the ORACLE for
// criterion A. A cell that publishes through our binding and receives through
// our binding cannot tell "our send side truncates" apart from "canon cannot
// carry this value at all": if both halves truncate at the first NUL they
// agree perfectly and prove nothing. So this mode takes our shim out of the
// loop entirely and measures canon against canon — one process, TWO canon
// sessions, a real TCP wire between them:
//
//   encoding_peer --selftest <endpoint>
//       Session A listens on <endpoint>, session B connects to it and
//       subscribes. A publishes the 20-byte interior-NUL subject and the
//       24-byte NUL-free control (without the control a green would prove the
//       peer works, not that it is length-faithful). Prints PEER_READY, then
//       one SELFTEST_RESULT line per arm, then SELFTEST_DONE, and exits 0.
//   encoding_peer --selftest-unreachable <endpoint>
//       The same run with NO wire: A listens nowhere, so nothing is bound at
//       <endpoint> for B to reach, and multicast and gossip are off on both.
//       No sample can arrive. The BOUNDED deadline expires, one
//       SELFTEST_TIMEOUT line per starved arm is printed, and the peer exits
//       non-zero — it never blocks forever, because an unbounded wait would
//       freeze the serial suite, which is the single sampling opportunity a
//       close run represents.
//
//   stdout, per arm that arrived:
//     SELFTEST_RESULT <label> sent_len=<n> recv_len=<m> recv_hex=<hex>
//   stdout, per arm that starved:
//     SELFTEST_TIMEOUT <label> no sample arrived within <n> ms (last put
//     rc=<rc>)
//   stdout, once, as the verdict:
//     SELFTEST_DONE  (exit 0)  |  SELFTEST_FAILED  (exit 1)
//
// The received bytes travel as HEX for the same reason the interactive mode's
// arguments do: a raw NUL must never enter a pipe or a source file. This mode
// REPORTS and asserts nothing — every assertion lives in the Dart cells, so a
// peer that reports nonsense fails a cell instead of passing itself.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zenoh.h>

#define MAX_SPEC 512
#define MAX_QUERYABLES 8

static int fatal(const char *what) {
  printf("PEER_FATAL %s\n", what);
  return 1;
}

/// Decodes `hex` into `out`, returning the byte count, or -1 on a malformed
/// input. An empty `hex` decodes to zero bytes, which is a legal request.
static int hex_decode(const char *hex, unsigned char *out, size_t cap) {
  size_t n = strlen(hex);
  if (n % 2 != 0 || n / 2 > cap) return -1;
  for (size_t i = 0; i < n; i += 2) {
    int hi = -1, lo = -1;
    for (int k = 0; k < 2; k++) {
      char c = hex[i + k];
      int v;
      if (c >= '0' && c <= '9') {
        v = c - '0';
      } else if (c >= 'a' && c <= 'f') {
        v = c - 'a' + 10;
      } else if (c >= 'A' && c <= 'F') {
        v = c - 'A' + 10;
      } else {
        return -1;
      }
      if (k == 0) hi = v; else lo = v;
    }
    out[i / 2] = (unsigned char)((hi << 4) | lo);
  }
  return (int)(n / 2);
}

/// Builds an owned encoding from a hex MIME spec and a schema spec.
///
/// Returns 0 on success. The two channels are independent by construction —
/// which is the whole point of the fix this peer exists to verify.
static int build_encoding(z_owned_encoding_t *enc, const char *mime_hex,
                          const char *schema_spec) {
  unsigned char mime[MAX_SPEC];
  int mime_len = hex_decode(mime_hex, mime, sizeof mime);
  if (mime_len < 0) return -1;

  if (z_encoding_from_substr(enc, (const char *)mime, (size_t)mime_len) < 0)
    return -1;

  if (schema_spec[0] == 'x') {
    unsigned char schema[MAX_SPEC];
    int schema_len = hex_decode(schema_spec + 1, schema, sizeof schema);
    if (schema_len < 0) {
      z_encoding_drop(z_move(*enc));
      return -1;
    }
    if (z_encoding_set_schema_from_substr(z_loan_mut(*enc),
                                          (const char *)schema,
                                          (size_t)schema_len) < 0) {
      z_encoding_drop(z_move(*enc));
      return -1;
    }
  }
  return 0;
}

/// What a declared queryable answers every incoming query with.
///
/// Heap-owned and never freed: the peer is a short-lived test fixture whose
/// queryables live until QUIT, and canon holds this pointer for the closure's
/// whole life. Freeing it at QUIT would be the only correct alternative and
/// buys nothing a process exit does not already give.
typedef struct {
  char arm[8];             // "ok" or "err"
  char mime[MAX_SPEC * 2 + 1];
  char schema[MAX_SPEC * 2 + 2];
} reply_spec_t;

static void on_query(z_loaned_query_t *query, void *context) {
  reply_spec_t *spec = (reply_spec_t *)context;

  z_owned_bytes_t payload;
  z_bytes_copy_from_str(&payload, "canon-peer-reply");

  z_owned_encoding_t enc;
  int have_enc = (spec->mime[0] != '-') &&
                 (build_encoding(&enc, spec->mime, spec->schema) == 0);

  if (strcmp(spec->arm, "err") == 0) {
    z_query_reply_err_options_t opts;
    z_query_reply_err_options_default(&opts);
    if (have_enc) opts.encoding = z_move(enc);
    z_query_reply_err(query, z_move(payload), &opts);
  } else {
    z_query_reply_options_t opts;
    z_query_reply_options_default(&opts);
    if (have_enc) opts.encoding = z_move(enc);
    z_query_reply(query, z_query_keyexpr(query), z_move(payload), &opts);
  }
}

/// Replies to our own gets are not asserted on; the peer only needs the get to
/// leave, and the Dart side observes what arrived at ITS queryable.
static void on_reply(z_loaned_reply_t *reply, void *context) {
  (void)reply;
  (void)context;
}

/// Splits a command line in place into at most `max` whitespace-separated
/// tokens. Returns the token count.
static int tokenize(char *line, char **tok, int max) {
  int n = 0;
  char *p = line;
  while (n < max) {
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') *p++ = '\0';
    if (*p == '\0') break;
    tok[n++] = p;
    while (*p != '\0' && *p != ' ' && *p != '\t' && *p != '\n' && *p != '\r')
      p++;
  }
  return n;
}

// ---------------------------------------------------------------------------
// Self-test mode: canon publisher -> canon subscriber, our shim never involved.
// ---------------------------------------------------------------------------

#define SELFTEST_KEY_NUL "zenoh/dart/s10/oracle/nul"
#define SELFTEST_KEY_CTL "zenoh/dart/s10/oracle/ctl"
#define SELFTEST_KEY_ALL "zenoh/dart/s10/oracle/**"
#define SELFTEST_DEADLINE_MS 15000
#define SELFTEST_RETRY_MS 250

/// The subject: 20 bytes whose byte at index 10 is the interior NUL.
///
/// Spelled as the two-character ESCAPE plus a concatenated literal, never as a
/// raw control byte, so this source stays NUL-free as text. Its length is
/// `sizeof - 1`; `strlen` would answer 10, which is exactly the truncation
/// this whole seed is about.
static const char kSelftestNulMime[] = "text/plain\0" "AFTER-NUL";

/// The control: 24 bytes, NUL-free, carrying canon's own `;` separator.
static const char kSelftestCtlMime[] = "text/plain;charset=utf-8";

/// One arm of the self-test: what gets published, where, and whether the
/// subscriber has seen it yet.
typedef struct {
  const char *label;
  const char *key;
  const char *mime;
  size_t mime_len;
  volatile int received;
  int last_put_rc;
} selftest_case_t;

typedef struct {
  selftest_case_t *cases;
  int n;
} selftest_state_t;

/// Reports one received encoding on stdout, at most once per arm.
static void on_selftest_sample(z_loaned_sample_t *sample, void *context) {
  selftest_state_t *st = (selftest_state_t *)context;

  z_view_string_t ks;
  z_keyexpr_as_view_string(z_sample_keyexpr(sample), &ks);
  const char *key = z_string_data(z_loan(ks));
  size_t key_len = z_string_len(z_loan(ks));

  for (int i = 0; i < st->n; i++) {
    selftest_case_t *c = &st->cases[i];
    if (c->received) continue;
    if (strlen(c->key) != key_len) continue;
    if (memcmp(c->key, key, key_len) != 0) continue;

    z_owned_string_t rendered;
    z_encoding_to_string(z_sample_encoding(sample), &rendered);
    const char *data = z_string_data(z_loan(rendered));
    size_t len = z_string_len(z_loan(rendered));

    // Assembled into ONE buffer and written with ONE printf: the arms can be
    // delivered concurrently, and two half-written lines would interleave.
    char out[MAX_SPEC * 2 + 128];
    int head = snprintf(out, sizeof out,
                        "SELFTEST_RESULT %s sent_len=%zu recv_len=%zu"
                        " recv_hex=", c->label, c->mime_len, len);
    if (head > 0 && (size_t)head + len * 2 + 1 < sizeof out) {
      size_t at = (size_t)head;
      for (size_t j = 0; j < len; j++) {
        at += (size_t)snprintf(out + at, sizeof out - at, "%02x",
                               (unsigned char)data[j]);
      }
      printf("%s\n", out);
    } else {
      printf("SELFTEST_OVERFLOW %s recv_len=%zu\n", c->label, len);
    }
    z_string_drop(z_move(rendered));
    c->received = 1;
    return;
  }
}

/// Builds a self-test session config: `key`'s endpoints set to `value`, with
/// multicast scouting and gossip both off — exactly as the interactive mode's
/// config does, so the two endpoints can only ever meet over the explicit TCP
/// wire the caller named.
static int selftest_config(z_owned_config_t *cfg, const char *key,
                           const char *value) {
  z_config_default(cfg);
  if (zc_config_insert_json5(z_loan_mut(*cfg), key, value) < 0) return -1;
  if (zc_config_insert_json5(z_loan_mut(*cfg), Z_CONFIG_MULTICAST_SCOUTING_KEY,
                             "false") < 0)
    return -1;
  if (zc_config_insert_json5(z_loan_mut(*cfg), "scouting/gossip/enabled",
                             "false") < 0)
    return -1;
  return 0;
}

/// Publishes one arm once. Retried by the caller until it lands, because how
/// long the subscriber declaration takes to reach the publisher is the
/// network's business, not this program's.
static int selftest_publish(z_loaned_session_t *session, selftest_case_t *c) {
  z_view_keyexpr_t ke;
  if (z_view_keyexpr_from_str(&ke, c->key) < 0) return -1;
  z_owned_encoding_t enc;
  if (z_encoding_from_substr(&enc, c->mime, c->mime_len) < 0) return -1;
  z_owned_bytes_t payload;
  z_bytes_copy_from_str(&payload, "canon-peer-selftest");
  z_put_options_t opts;
  z_put_options_default(&opts);
  opts.encoding = z_move(enc);
  return z_put(session, z_loan(ke), z_move(payload), &opts);
}

/// Runs the canon-to-canon measurement. `reachable` false removes the wire.
///
/// The early `fatal` returns leave the sessions undropped, exactly as the
/// interactive mode's do: this is a short-lived fixture that exits on the
/// next statement, and the process teardown is the release.
static int run_selftest(const char *endpoint, int reachable) {
  char endpoints[512];
  snprintf(endpoints, sizeof endpoints, "[\"%s\"]", endpoint);

  z_owned_config_t pub_cfg;
  if (selftest_config(&pub_cfg, Z_CONFIG_LISTEN_KEY,
                      reachable ? endpoints : "[]") != 0)
    return fatal("selftest publisher config");
  z_owned_session_t pub_session;
  if (z_open(&pub_session, z_move(pub_cfg), NULL) < 0)
    return fatal("selftest publisher z_open");

  // Measured: a connect endpoint nothing is listening on does NOT fail
  // z_open, which is what lets the unreachable run reach PEER_READY and then
  // starve on the deadline rather than dying at startup.
  z_owned_config_t sub_cfg;
  if (selftest_config(&sub_cfg, Z_CONFIG_CONNECT_KEY, endpoints) != 0)
    return fatal("selftest subscriber config");
  z_owned_session_t sub_session;
  if (z_open(&sub_session, z_move(sub_cfg), NULL) < 0)
    return fatal("selftest subscriber z_open");

  selftest_case_t cases[2];
  cases[0].label = "nul";
  cases[0].key = SELFTEST_KEY_NUL;
  cases[0].mime = kSelftestNulMime;
  cases[0].mime_len = sizeof kSelftestNulMime - 1;
  cases[0].received = 0;
  cases[0].last_put_rc = 0;
  cases[1].label = "ctl";
  cases[1].key = SELFTEST_KEY_CTL;
  cases[1].mime = kSelftestCtlMime;
  cases[1].mime_len = sizeof kSelftestCtlMime - 1;
  cases[1].received = 0;
  cases[1].last_put_rc = 0;

  selftest_state_t state;
  state.cases = cases;
  state.n = 2;

  z_view_keyexpr_t sub_ke;
  if (z_view_keyexpr_from_str(&sub_ke, SELFTEST_KEY_ALL) < 0)
    return fatal("selftest keyexpr");
  z_owned_closure_sample_t callback;
  z_closure(&callback, on_selftest_sample, NULL, (void *)&state);
  z_subscriber_options_t sopts;
  z_subscriber_options_default(&sopts);
  z_owned_subscriber_t sub;
  if (z_declare_subscriber(z_loan(sub_session), &sub, z_loan(sub_ke),
                           z_move(callback), &sopts) < 0)
    return fatal("selftest declare_subscriber");

  printf("PEER_READY\n");

  z_clock_t start = z_clock_now();
  for (;;) {
    for (int i = 0; i < state.n; i++) {
      if (!state.cases[i].received)
        state.cases[i].last_put_rc =
            selftest_publish(z_loan_mut(pub_session), &state.cases[i]);
    }
    z_sleep_ms(SELFTEST_RETRY_MS);
    int outstanding = 0;
    for (int i = 0; i < state.n; i++)
      if (!state.cases[i].received) outstanding++;
    if (outstanding == 0) break;
    if (z_clock_elapsed_ms(&start) >= SELFTEST_DEADLINE_MS) break;
  }

  int starved = 0;
  for (int i = 0; i < state.n; i++) {
    if (!state.cases[i].received) {
      // The last put's rc rides along so a starved arm cannot silently blame
      // the wire for a send that never left.
      printf("SELFTEST_TIMEOUT %s no sample arrived within %d ms"
             " (last put rc=%d)\n",
             state.cases[i].label, SELFTEST_DEADLINE_MS,
             state.cases[i].last_put_rc);
      starved = 1;
    }
  }

  z_subscriber_drop(z_move(sub));
  z_session_drop(z_move(sub_session));
  z_session_drop(z_move(pub_session));

  if (starved) {
    printf("SELFTEST_FAILED\n");
    return 1;
  }
  printf("SELFTEST_DONE\n");
  return 0;
}

int main(int argc, char **argv) {
  // FIRST statement: a canon C binary's stdout block-buffers under a pipe, and
  // the harness reads it through one.
  setvbuf(stdout, NULL, _IOLBF, 0);

  if (argc >= 3 && strcmp(argv[1], "--selftest") == 0)
    return run_selftest(argv[2], 1);
  if (argc >= 3 && strcmp(argv[1], "--selftest-unreachable") == 0)
    return run_selftest(argv[2], 0);

  if (argc < 2)
    return fatal("usage: encoding_peer [--selftest[-unreachable]] <endpoint>");
  const char *endpoint = argv[1];

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

  z_owned_session_t session;
  if (z_open(&session, z_move(cfg), NULL) < 0) return fatal("z_open");

  printf("PEER_READY\n");

  z_owned_queryable_t queryables[MAX_QUERYABLES];
  int n_queryables = 0;

  char line[2048];
  while (fgets(line, sizeof line, stdin) != NULL) {
    char *tok[8];
    int n = tokenize(line, tok, 8);
    if (n == 0) continue;

    if (strcmp(tok[0], "PUB") == 0) {
      if (n < 4) {
        printf("PUB_DONE rc=-1\n");
        continue;
      }
      z_view_keyexpr_t ke;
      if (z_view_keyexpr_from_str(&ke, tok[1]) < 0) {
        printf("PUB_DONE rc=-2\n");
        continue;
      }
      z_owned_encoding_t enc;
      int have_enc = 0;
      if (tok[2][0] != '-') {
        if (build_encoding(&enc, tok[2], tok[3]) != 0) {
          printf("PUB_DONE rc=-3\n");
          continue;
        }
        have_enc = 1;
      }
      z_owned_bytes_t payload;
      z_bytes_copy_from_str(&payload, "canon-peer");
      z_put_options_t opts;
      z_put_options_default(&opts);
      if (have_enc) opts.encoding = z_move(enc);
      int rc = z_put(z_loan_mut(session), z_loan(ke), z_move(payload), &opts);
      printf("PUB_DONE rc=%d\n", rc);
    } else if (strcmp(tok[0], "PUB_EMPTY") == 0) {
      if (n < 2) {
        printf("PUB_DONE rc=-1\n");
        continue;
      }
      z_view_keyexpr_t ke;
      if (z_view_keyexpr_from_str(&ke, tok[1]) < 0) {
        printf("PUB_DONE rc=-2\n");
        continue;
      }
      // Guard depth 0 in the pinned header (the nearest enclosing
      // Z_FEATURE_UNSTABLE_API block closes above it), so this compiles into
      // the STABLE peer too and the cell runs on both matrix legs.
      zc_internal_encoding_data_t data;
      data.id = 65535;
      data.schema_ptr = NULL;
      data.schema_len = 0;
      z_owned_encoding_t enc;
      zc_internal_encoding_from_data(&enc, data);
      z_owned_bytes_t payload;
      z_bytes_copy_from_str(&payload, "canon-peer");
      z_put_options_t opts;
      z_put_options_default(&opts);
      opts.encoding = z_move(enc);
      int rc = z_put(z_loan_mut(session), z_loan(ke), z_move(payload), &opts);
      printf("PUB_DONE rc=%d\n", rc);
    } else if (strcmp(tok[0], "QUERY") == 0) {
      if (n < 4) {
        printf("QUERY_DONE rc=-1\n");
        continue;
      }
      z_view_keyexpr_t ke;
      if (z_view_keyexpr_from_str(&ke, tok[1]) < 0) {
        printf("QUERY_DONE rc=-2\n");
        continue;
      }
      z_owned_encoding_t enc;
      int have_enc = 0;
      if (tok[2][0] != '-') {
        if (build_encoding(&enc, tok[2], tok[3]) != 0) {
          printf("QUERY_DONE rc=-3\n");
          continue;
        }
        have_enc = 1;
      }
      z_owned_closure_reply_t closure;
      z_closure(&closure, on_reply, NULL, NULL);
      z_get_options_t opts;
      z_get_options_default(&opts);
      z_owned_bytes_t payload;
      if (n < 5 || tok[4][0] != '-') {
        z_bytes_copy_from_str(&payload, "canon-peer-query");
        opts.payload = z_move(payload);
      }
      if (have_enc) opts.encoding = z_move(enc);
      opts.timeout_ms = 5000;
      int rc = z_get(z_loan(session), z_loan(ke), "", z_move(closure), &opts);
      printf("QUERY_DONE rc=%d\n", rc);
    } else if (strcmp(tok[0], "QUERYABLE") == 0) {
      if (n < 5 || n_queryables >= MAX_QUERYABLES) {
        printf("QUERYABLE_DONE rc=-1\n");
        continue;
      }
      z_view_keyexpr_t ke;
      if (z_view_keyexpr_from_str(&ke, tok[1]) < 0) {
        printf("QUERYABLE_DONE rc=-2\n");
        continue;
      }
      reply_spec_t *spec = (reply_spec_t *)calloc(1, sizeof(reply_spec_t));
      if (spec == NULL) {
        printf("QUERYABLE_DONE rc=-4\n");
        continue;
      }
      snprintf(spec->arm, sizeof spec->arm, "%s", tok[2]);
      snprintf(spec->mime, sizeof spec->mime, "%s", tok[3]);
      snprintf(spec->schema, sizeof spec->schema, "%s", tok[4]);

      z_owned_closure_query_t callback;
      z_closure(&callback, on_query, NULL, (void *)spec);
      z_queryable_options_t qopts;
      z_queryable_options_default(&qopts);
      int rc = z_declare_queryable(z_loan(session), &queryables[n_queryables],
                                   z_loan(ke), z_move(callback), &qopts);
      if (rc == 0) n_queryables++;
      printf("QUERYABLE_DONE rc=%d\n", rc);
    } else if (strcmp(tok[0], "QUIT") == 0) {
      break;
    }
  }

  for (int i = 0; i < n_queryables; i++) {
    z_queryable_drop(z_move(queryables[i]));
  }
  z_session_drop(z_move(session));
  printf("PEER_EXIT\n");
  return 0;
}
