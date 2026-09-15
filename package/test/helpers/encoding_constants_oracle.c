// encoding_constants_oracle.c -- canon's own answer for the 53 predefined
// encodings, read out of the LIBRARY rather than out of its documentation.
//
// WHY THIS EXISTS. `Encoding` ships a table of predefined MIME constants and
// every one of them is a claim about what canon calls that encoding. A test
// that asserts such a table against a copy of the same table transcribed into
// the test proves only that the code agrees with itself. This program asks the
// linked `libzenohc.so` directly: it calls each `z_encoding_*(void)` accessor
// and prints the string canon renders for it, so the comparison in
// `encoding_constants_oracle_test.dart` runs against a value canon produced.
//
// WHY IT IS THE PRIMARY INSTRUMENT AND THE DOC-LINE GREP IS ONLY A CONTROL.
// Canon's own test suite asserts just 2 of the 53 documented alias strings
// (`zenoh/bytes` and `zenoh/string`), so the doc comment is weaker evidence
// than the function's return value. The two are cross-checked against each
// other in the Dart test; disagreement between them is a red.
//
// THE ACCESSOR TABLE IS DERIVED, NOT TRANSCRIBED. Its 53 entries were
// generated from the pinned header's own declarations
// (`const struct z_loaned_encoding_t *z_encoding_<name>(void)`), with
// `z_encoding_loan_default` excluded: it is a loan helper, not a predefined
// encoding -- its doc says "Returns a loaned default", it carries no
// `Constant alias for string:` line, and it returns the same value as
// `z_encoding_zenoh_bytes()`. Counting it is what turns 53 into 54.
//
// BUILD -- the include path is not the obvious one, and is VARIANT-SCOPED:
//
//   cd package && clang -O0 -g test/helpers/encoding_constants_oracle.c \
//     -I ../build/linux-x64/extern/zenoh-c/release/include \
//     -L native/linux/x86_64/unstable -lzenohc \
//     -Wl,-rpath,$PWD/native/linux/x86_64/unstable -o <out>/oracle
//
// `helpers/canon_peer.dart` picks the pair for the loaded variant, which is
// what lets this run on both matrix legs. The headers MUST come from the BUILD
// tree, never from `extern/zenoh-c/include`: those copies of `zenoh_opaque.h`
// and `zenoh_configure.h` are cargo-GENERATED, excluded by the submodule's own
// .gitignore, and clobbered by every full build. All 53 accessors are at guard
// depth 0 and both variant headers declare all 53 -- measured on both trees.
//
// OUTPUT (stdout, line-oriented, one line per accessor then a trailer):
//
//   ENC <accessor> <mime>
//   ORACLE_COUNT <n>
//
// The count is taken from the table's own size, so a truncated run cannot be
// read as a complete one. No MIME string among the 53 contains a space; the
// reader nonetheless splits on the FIRST two spaces only, so one would not be
// silently cut.

#include <stdio.h>
#include <zenoh.h>

// Pairs an accessor with its own name, so the emitted line carries canon's
// spelling of both halves and a mismatch names itself.
#define ZD_ENC(fn) {#fn, fn}

static const struct {
  const char *accessor;
  const z_loaned_encoding_t *(*get)(void);
} kAccessors[] = {
    ZD_ENC(z_encoding_application_cbor),
    ZD_ENC(z_encoding_application_cdr),
    ZD_ENC(z_encoding_application_coap_payload),
    ZD_ENC(z_encoding_application_java_serialized_object),
    ZD_ENC(z_encoding_application_json),
    ZD_ENC(z_encoding_application_json_patch_json),
    ZD_ENC(z_encoding_application_json_seq),
    ZD_ENC(z_encoding_application_jsonpath),
    ZD_ENC(z_encoding_application_jwt),
    ZD_ENC(z_encoding_application_mp4),
    ZD_ENC(z_encoding_application_octet_stream),
    ZD_ENC(z_encoding_application_openmetrics_text),
    ZD_ENC(z_encoding_application_protobuf),
    ZD_ENC(z_encoding_application_python_serialized_object),
    ZD_ENC(z_encoding_application_soap_xml),
    ZD_ENC(z_encoding_application_sql),
    ZD_ENC(z_encoding_application_x_www_form_urlencoded),
    ZD_ENC(z_encoding_application_xml),
    ZD_ENC(z_encoding_application_yaml),
    ZD_ENC(z_encoding_application_yang),
    ZD_ENC(z_encoding_audio_aac),
    ZD_ENC(z_encoding_audio_flac),
    ZD_ENC(z_encoding_audio_mp4),
    ZD_ENC(z_encoding_audio_ogg),
    ZD_ENC(z_encoding_audio_vorbis),
    ZD_ENC(z_encoding_image_bmp),
    ZD_ENC(z_encoding_image_gif),
    ZD_ENC(z_encoding_image_jpeg),
    ZD_ENC(z_encoding_image_png),
    ZD_ENC(z_encoding_image_webp),
    ZD_ENC(z_encoding_text_css),
    ZD_ENC(z_encoding_text_csv),
    ZD_ENC(z_encoding_text_html),
    ZD_ENC(z_encoding_text_javascript),
    ZD_ENC(z_encoding_text_json),
    ZD_ENC(z_encoding_text_json5),
    ZD_ENC(z_encoding_text_markdown),
    ZD_ENC(z_encoding_text_plain),
    ZD_ENC(z_encoding_text_xml),
    ZD_ENC(z_encoding_text_yaml),
    ZD_ENC(z_encoding_video_h261),
    ZD_ENC(z_encoding_video_h263),
    ZD_ENC(z_encoding_video_h264),
    ZD_ENC(z_encoding_video_h265),
    ZD_ENC(z_encoding_video_h266),
    ZD_ENC(z_encoding_video_mp4),
    ZD_ENC(z_encoding_video_ogg),
    ZD_ENC(z_encoding_video_raw),
    ZD_ENC(z_encoding_video_vp8),
    ZD_ENC(z_encoding_video_vp9),
    ZD_ENC(z_encoding_zenoh_bytes),
    ZD_ENC(z_encoding_zenoh_serialized),
    ZD_ENC(z_encoding_zenoh_string),
};

int main(void) {
  // Line-buffer stdout: canon C binaries block-buffer when redirected, and
  // this one is always read through a pipe.
  setvbuf(stdout, NULL, _IOLBF, 0);

  const size_t n = sizeof(kAccessors) / sizeof(kAccessors[0]);
  for (size_t i = 0; i < n; i++) {
    z_owned_string_t rendered;
    z_encoding_to_string(kAccessors[i].get(), &rendered);
    const z_loaned_string_t *loaned = z_string_loan(&rendered);
    // Length-delimited, never `%s`: canon's strings are not NUL-terminated by
    // contract, and printing one as if it were would be exactly the
    // truncating read this seed exists to remove.
    printf("ENC %s %.*s\n", kAccessors[i].accessor, (int)z_string_len(loaned),
           z_string_data(loaned));
    z_string_drop(z_string_move(&rendered));
  }
  printf("ORACLE_COUNT %zu\n", n);
  return 0;
}
