import 'package:meta/meta.dart';

/// Exception thrown when a zenoh operation fails.
///
/// Carries a human-readable [message] and the native [returnCode]
/// from the zenoh-c API.
class ZenohException implements Exception {
  /// Creates a [ZenohException] with the given [message] and [returnCode].
  ZenohException(this.message, this.returnCode);

  /// Creates a [ZenohException] carrying upstream [detail] alongside
  /// [baseMessage].
  ///
  /// [detail] is canon's own explanation of the failure, and it must be the
  /// one **the calling code received from the very call it is reporting** —
  /// the shim writes it into caller-supplied storage as part of that call.
  /// Pass `null` when no detail was produced, which is the whole answer on
  /// the `stable` variant: `zc_get_last_error` is compiled out there, so
  /// there is nothing to carry and the message is the base text alone.
  ///
  /// ## Why the third parameter is required
  ///
  /// It used to be absent. The factory fetched the detail itself, from a
  /// `_Thread_local` buffer the shim kept across calls — and that mechanism
  /// was measured returning **another operation's message 249 times out of
  /// 300** when the read straddled an event-loop turn
  /// (`development/independent/concurrency-reappraisal-20260827.md:118`).
  /// The VM migrates an isolate between OS threads, so the read landed on a
  /// thread that had never made the call. Pinning the isolate to its thread
  /// was measured **not** to fix it: 255 of 300 migrations happened anyway.
  ///
  /// A misattributed error message is worse than no message — it is a
  /// confident, specific, wrong answer, and a reader cannot tell it from a
  /// right one.
  ///
  /// The parameter is **required, and positional, on purpose**. A factory
  /// named `enriched` that can be called with nothing to enrich from would
  /// preserve, at the type level, exactly the affordance that made the
  /// read-back necessary. With the detail travelling as an argument there is
  /// no buffer to read and no later call to read it, so a foreign read is
  /// **unrepresentable** rather than merely discouraged.
  ///
  /// ## The truncation chain this detail crossed
  ///
  /// ⚠️ **Four stages, not one figure**, and stages 2 and 3 **silently drop**
  /// what does not fit — there is no marker, no ellipsis and no flag to say a
  /// message was cut:
  ///
  /// 1. **canon's per-thread `ERROR_DESCRIPTION`, a 1024-byte store.** What
  ///    canon itself would not keep never reaches this binding at all.
  /// 2. **the shim's copy**, capped by `ZD_LAST_ERROR_CAP` (512) and
  ///    **clamped to 511 bytes plus a terminator**. ⛔ So **511** is the
  ///    surviving length — the obvious reading of the cap is off by one.
  /// 3. **the capacity the caller supplied**, whichever is smaller. This
  ///    binding passes `ZD_LAST_ERROR_CAP`, so in practice stage 2 binds; a
  ///    smaller buffer would bind first.
  /// 4. **a lenient UTF-8 decode.** A multi-byte sequence cut by the clamp
  ///    becomes U+FFFD rather than throwing — a truncated message is worth
  ///    more than an exception raised while reporting an exception.
  ///
  /// The same 511-byte clamp applies to the offloaded `Session.open` path,
  /// which captures through the same helper.
  ///
  /// ## The enrichment surface, and why it is fenced
  ///
  /// **The definition comes before the count.** An *enriched site* is a throw
  /// or post site in `package/lib` whose exception carries canon's own text
  /// for the failure being reported. Two mechanisms produce one, and the
  /// obvious one-mechanism definition is blind to the other:
  ///
  /// 1. **This factory** — called where the detail came back from the failing
  ///    call in caller-supplied storage. Three call sites, all in
  ///    `config.dart`: the shared named-constructor build path, `insertJson5`,
  ///    and `get`.
  /// 2. **The post** — the offloaded `Session.open`, where the detail is
  ///    captured on the worker immediately after the failing call and
  ///    marshalled *with* the post. It never calls this factory, so a count
  ///    that looks only for the factory cannot see it. One site, in
  ///    `session.dart`.
  ///
  /// A third mechanism — capture at a site, read back by a later call — was
  /// **deleted**. The plain constructor carries nothing; every detail-carrying
  /// path now captures at the failing call and carries the detail out with it.
  ///
  /// **Census, measured, two disjoint patterns, two instruments.** The plain
  /// form cannot match the factory form, because the `.` sits between them:
  ///
  /// ```sh
  /// find package/lib -name '*.dart' | xargs \
  ///   awk '{n+=gsub(/ZenohException\(/,"")} END{print n+0}'          # 105
  /// find package/lib -name '*.dart' | xargs \
  ///   awk '{n+=gsub(/ZenohException\.enriched\(/,"")} END{print n+0}' #   4
  /// ```
  ///
  /// ⚠️ The two are **not** a subset relation, and presenting the second as
  /// "of which" was a recorded error. The 4 counts **3 call sites plus this
  /// declaration**; the declaration is not a site.
  ///
  /// ⚠️ **The plain count moved 103 → 105 and the enriched count did not.**
  /// The two additions are `undecodableError` below and `session.dart`'s
  /// `_canonNames`, both of which construct a **plain** exception — so the
  /// fenced surface is unchanged and the census is not. Stated rather than
  /// re-baselined, because a number that moves without a reason recorded is a
  /// number nobody can check next time.
  ///
  /// **The fence counts `package/lib`; the impact sweep covers the whole
  /// tree, and conflating the two domains is how a call site was missed:**
  /// `config_test.dart` holds a fifth call to this factory, outside the
  /// fence's domain **by design**, and an audit that assumed the fence covered
  /// everything reported four when there were five.
  ///
  /// **Widening is gated on a decision, not on taste.** Any new site must
  /// decide redaction first — see the warning below. `enrichment_surface_test`
  /// fails on a surface that has grown *or shrunk* by one site, and names that
  /// precondition in the failure rather than reporting a count.
  ///
  /// ### Deliberate non-adoptions, recorded so they are not rediscovered
  ///
  /// - **`zd_scout`'s path was verified enrichment-eligible** during an
  ///   earlier unit and is **deliberately not adopted** here. Silence on it
  ///   would cost someone the same investigation twice.
  /// - **`zd_config_to_string`'s capture was removed rather than promoted.**
  ///   It was wired and never read; promoting it would widen the surface to a
  ///   call whose input is the whole rendered config, and its Dart site is
  ///   `Object.toString()`, which must not throw.
  /// - **The two renderings are not unified.** This factory renders the base
  ///   text, a colon and the detail; the open path renders the base text, a
  ///   full stop, a `Zenoh says` prefix and the detail. Unifying them was not
  ///   in scope for the unit that wrote this, and is recorded here rather
  ///   than left looking like an oversight.
  ///
  ///   ⚠️ Spelled out that way on purpose. Writing the open path's rendering
  ///   as a literal would put a second match for the fence's posted-detail
  ///   pattern inside this very file — which is what happened, and which the
  ///   fence caught. The fix is to not write it, never to add this file to
  ///   the fence's expected map: a prose match in the map would make a REAL
  ///   second post site here invisible.
  ///
  /// ## What this message may contain
  ///
  /// ⚠️ **No redaction is applied.** On the config paths canon echoes the
  /// offending value and the surrounding source line — including adjacent
  /// intact secrets — and its JSON5 parser prints a caret under the offending
  /// token. Do not forward this message into a log or a bug report without
  /// deciding that first. A general redactor is not implementable at this
  /// seam: the shim receives one opaque string with no structure to redact
  /// against, and a partial one would manufacture confidence.
  factory ZenohException.enriched(
    String baseMessage,
    int returnCode,
    String? detail,
  ) {
    return (detail != null && detail.isNotEmpty)
        ? ZenohException('$baseMessage: $detail', returnCode)
        : ZenohException(baseMessage, returnCode);
  }

  /// Human-readable description of the error.
  final String message;

  /// Return code from the zenoh-c API (0 = success, negative = error).
  final int returnCode;

  /// Canon's own name(s) for [returnCode], or empty when canon defines none.
  ///
  /// A reader who sees `-7` has to go looking; canon calls it
  /// `Z_EDESERIALIZE`. The name is offered **alongside** the number in
  /// [toString], never in place of it — a caller matching on a code, or
  /// pasting one into a search, still needs the integer.
  ///
  /// ## Why a list, and not a name
  ///
  /// ⛔ **Canon aliases one value.** `Z_EINVAL_MUTEX` and `Z_EPOISON_MUTEX`
  /// are **both** `-22`. A map keyed by number cannot render that honestly by
  /// picking one, so this returns every name canon gives the value, in
  /// canon's declaration order. The collision becomes type-level instead of a
  /// silent choice, and the unnamed case falls out naturally as `[]`.
  ///
  /// ## What is deliberately absent
  ///
  /// - **Binding-owned positive codes** (`10`, `11`, `12`, `13`) yield no
  ///   name, because they are **channel-scoped** rather than global: `12` is
  ///   the shim's allocation failure on the *open* channel **and** trailing
  ///   data on the *deserialize* channel. A number-keyed global accessor
  ///   structurally cannot render two meanings for one number, so it renders
  ///   neither. ⚠️ **That double meaning is ACCEPTED, not resolved** — stated
  ///   here because an accepted collision left silent reads as an oversight.
  /// - **Canon's channel states.** `Z_CHANNEL_DISCONNECTED` (`1`) and
  ///   `Z_CHANNEL_NODATA` (`2`) are canon's, but they are **states, not
  ///   errors**. ⛔ The `!= 0` convention this binding applies everywhere else
  ///   must **not** be applied to the **recv** family, or an ordinary empty
  ///   channel reads as a failure.
  /// - **Per-code prose.** Canon defines names, not meanings, so this offers
  ///   no explanation of what a code implies. Where a path needs one it says
  ///   so locally — see `Session.open`'s rendering, which qualifies
  ///   `Z_ENETWORK` as a catch-all because the symbol alone would read as a
  ///   diagnosis canon never made.
  List<String> get codeNames => _canonErrorNames[returnCode] ?? const [];

  /// The shipped rendering, plus canon's name(s) when there are any.
  ///
  /// ⛔ **A superset, deliberately.** The prefix
  /// `'ZenohException: <message> (code: <rc>)'` is unchanged, so every
  /// message assertion written against the old form still holds.
  @override
  String toString() {
    final names = codeNames;
    final base = 'ZenohException: $message (code: $returnCode)';
    return names.isEmpty ? base : '$base [${names.join(', ')}]';
  }
}

/// Canon's error names by value, in canon's declaration order.
///
/// Mirrors `Z_E*` in zenoh-c's `zenoh_concrete.h` at the pinned version:
/// **14 names over 13 distinct values**, the one collision being `-22`.
/// `Z_EGENERIC` is canon's `INT8_MIN`.
///
/// ⚠️ **A hand-written mirror of a generated header, and the price of that is
/// drift.** `exception_code_name_test.dart` parses the build-generated header
/// at test time and checks this against it, rather than against a second copy
/// of itself — an embedded oracle asserted against this table would agree
/// with it through any upstream rename.
const Map<int, List<String>> _canonErrorNames = {
  -1: ['Z_EINVAL'],
  -2: ['Z_EPARSE'],
  -3: ['Z_EIO'],
  -4: ['Z_ENETWORK'],
  -5: ['Z_ENULL'],
  -6: ['Z_EUNAVAILABLE'],
  -7: ['Z_EDESERIALIZE'],
  -8: ['Z_ESESSION_CLOSED'],
  -9: ['Z_EUTF8'],
  -16: ['Z_EBUSY_MUTEX'],
  -22: ['Z_EINVAL_MUTEX', 'Z_EPOISON_MUTEX'],
  -11: ['Z_EAGAIN_MUTEX'],
  -128: ['Z_EGENERIC'],
};

/// Reads a posted bytes slot that may carry a conversion FAILURE instead.
///
/// ⛔ THE SHAPE, AND WHY IT IS AN `int`. The shim posts every bytes-carrying
/// slot as `Uint8List` — or as `null` where the value is legitimately absent,
/// which an attachment often is. When canon refuses to convert a value the
/// shim posts **canon's rc as an int64** in that slot instead. A bytes slot is
/// never legitimately an integer, so the three cases are distinguishable
/// without a new array element and without a sentinel hidden inside the bytes.
///
/// Returns the rc when the slot carries a failure, and `null` otherwise —
/// including for a legitimately empty or absent value, which are **not**
/// failures and must keep delivering.
@internal
int? undecodableRc(Object? slot) => slot is int ? slot : null;

/// The error surfaced when zenoh delivered a value this binding could not
/// convert.
///
/// [what] names the value class as a full noun phrase — `'a payload'`,
/// `'an attachment'`, `'an error payload'` — because the three have different
/// consequences for a reader and a bare "conversion failed" would not say
/// which one went missing. It carries its own article so the sentence reads
/// correctly for all three; the first cut interpolated a bare noun after "a"
/// and produced "a attachment".
///
/// ⛔ **No binding code is minted for this.** The rc is canon's own. There is
/// no rc channel on a receive path to allocate into, and inventing a number
/// here would put a value on the wire that means nothing to anybody.
@internal
ZenohException undecodableError(String what, int rc) => ZenohException(
  'zenoh delivered $what this binding could not convert. It is surfaced as '
  'a stream error rather than as empty or absent data, because an empty value '
  'is a legitimate value on every one of these paths and a silent empty would '
  'be indistinguishable from one',
  rc,
);
