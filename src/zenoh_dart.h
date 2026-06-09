#ifndef ZENOH_DART_H
#define ZENOH_DART_H

#include <stdint.h>
#include <zenoh.h>

// FFI_PLUGIN_EXPORT: marks symbols for visibility from Dart FFI.
#if defined(_WIN32) || defined(__CYGWIN__)
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default")))
#endif

// ---------------------------------------------------------------------------
// Dart API initialization
// ---------------------------------------------------------------------------

/// Initializes the Dart native API for dynamic linking.
///
/// Must be called before any other zenoh_dart functions that use
/// Dart native ports. Pass `NativeApi.initializeApiDLData` from Dart.
///
/// Returns 0 on success.
FFI_PLUGIN_EXPORT intptr_t zd_init_dart_api_dl(void* data);

/// Initializes the zenoh logger from the RUST_LOG environment variable,
/// falling back to the provided filter string if RUST_LOG is not set.
///
/// @param fallback_filter  Filter string (e.g., "error", "info", "debug").
FFI_PLUGIN_EXPORT void zd_init_log(const char* fallback_filter);

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_config_t in bytes.
///
/// Used by Dart to allocate the correct amount of native memory
/// for opaque zenoh types.
FFI_PLUGIN_EXPORT size_t zd_config_sizeof(void);

/// Creates a default configuration.
///
/// @param config  Pointer to an uninitialized z_owned_config_t.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_config_default(z_owned_config_t* config);

/// Inserts a JSON5 value into the configuration at the given key path.
///
/// Takes a mutable owned config pointer. Internally obtains a mutable loan
/// via z_config_loan_mut() before calling zc_config_insert_json5().
///
/// @param config  Pointer to a valid z_owned_config_t.
/// @param key     Configuration key path (e.g., "mode").
/// @param value   JSON5 value string (e.g., "\"peer\"").
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_config_insert_json5(
    z_owned_config_t* config, const char* key, const char* value);

/// Obtains a const loaned reference to the configuration.
///
/// @param config  Pointer to a valid z_owned_config_t.
/// @return Const pointer to the loaned config.
FFI_PLUGIN_EXPORT const z_loaned_config_t* zd_config_loan(
    const z_owned_config_t* config);

/// Drops (frees) the configuration.
///
/// After this call the owned config is in gravestone state.
/// A second drop is a safe no-op.
///
/// @param config  Pointer to a z_owned_config_t to drop.
FFI_PLUGIN_EXPORT void zd_config_drop(z_owned_config_t* config);

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_session_t in bytes.
///
/// Used by Dart to allocate the correct amount of native memory
/// for opaque zenoh types.
FFI_PLUGIN_EXPORT size_t zd_session_sizeof(void);

/// Opens a Zenoh session with the given configuration.
///
/// @param session  Pointer to an uninitialized z_owned_session_t.
/// @param config   Pointer to a z_owned_config_t (consumed by z_open).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_open_session(z_owned_session_t* session,
                                      z_owned_config_t* config);

/// Obtains a const loaned reference to the session.
///
/// @param session  Pointer to a valid z_owned_session_t.
/// @return Const pointer to the loaned session.
FFI_PLUGIN_EXPORT const z_loaned_session_t* zd_session_loan(
    const z_owned_session_t* session);

/// Gracefully closes and drops the session.
///
/// Calls z_close for graceful shutdown, then z_session_drop to release
/// resources. After this call the owned session is in gravestone state.
///
/// @param session  Pointer to a z_owned_session_t to close and drop.
FFI_PLUGIN_EXPORT void zd_close_session(z_owned_session_t* session);

// ---------------------------------------------------------------------------
// KeyExpr
// ---------------------------------------------------------------------------

/// Returns the size of z_view_keyexpr_t in bytes.
///
/// Used by Dart to allocate the correct amount of native memory
/// for opaque zenoh types.
FFI_PLUGIN_EXPORT size_t zd_view_keyexpr_sizeof(void);

/// Creates a view key expression from a null-terminated string.
///
/// The string must remain valid for the lifetime of the view.
///
/// @param ke    Pointer to an uninitialized z_view_keyexpr_t.
/// @param expr  Null-terminated key expression string.
/// @return 0 on success, Z_EINVAL (-1) if the expression is invalid.
FFI_PLUGIN_EXPORT int zd_view_keyexpr_from_str(z_view_keyexpr_t* ke,
                                               const char* expr);

/// Obtains a const loaned reference to the key expression.
///
/// @param ke  Pointer to a valid z_view_keyexpr_t.
/// @return Const pointer to the loaned key expression.
FFI_PLUGIN_EXPORT const z_loaned_keyexpr_t* zd_view_keyexpr_loan(
    const z_view_keyexpr_t* ke);

/// Converts a loaned key expression to a view string.
///
/// The output view string borrows from the key expression and must not
/// outlive it. Returns void -- always succeeds on a valid loaned keyexpr.
///
/// @param ke   Const pointer to a loaned key expression.
/// @param out  Pointer to an uninitialized z_view_string_t to receive the result.
FFI_PLUGIN_EXPORT void zd_keyexpr_as_view_string(
    const z_loaned_keyexpr_t* ke, z_view_string_t* out);

/// Returns true if the key expressions intersect (share at least one key).
///
/// @param a  Pointer to a valid z_view_keyexpr_t.
/// @param b  Pointer to a valid z_view_keyexpr_t.
/// @return true if the key expressions intersect.
FFI_PLUGIN_EXPORT bool zd_keyexpr_intersects(const z_view_keyexpr_t* a,
                                             const z_view_keyexpr_t* b);

/// Returns true if key expression a includes b (every key in b is in a).
///
/// @param a  Pointer to a valid z_view_keyexpr_t.
/// @param b  Pointer to a valid z_view_keyexpr_t.
/// @return true if a includes b.
FFI_PLUGIN_EXPORT bool zd_keyexpr_includes(const z_view_keyexpr_t* a,
                                           const z_view_keyexpr_t* b);

/// Returns true if the key expressions are equal in zenoh semantics.
///
/// @param a  Pointer to a valid z_view_keyexpr_t.
/// @param b  Pointer to a valid z_view_keyexpr_t.
/// @return true if the key expressions are equal.
FFI_PLUGIN_EXPORT bool zd_keyexpr_equals(const z_view_keyexpr_t* a,
                                         const z_view_keyexpr_t* b);

// ---------------------------------------------------------------------------
// Bytes
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_bytes_t in bytes.
///
/// Used by Dart to allocate the correct amount of native memory
/// for opaque zenoh types.
FFI_PLUGIN_EXPORT size_t zd_bytes_sizeof(void);

/// Copies a null-terminated string into owned bytes.
///
/// @param bytes  Pointer to an uninitialized z_owned_bytes_t.
/// @param str    Null-terminated string to copy.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_bytes_copy_from_str(z_owned_bytes_t* bytes,
                                             const char* str);

/// Copies a buffer into owned bytes.
///
/// @param bytes  Pointer to an uninitialized z_owned_bytes_t.
/// @param data   Pointer to the buffer data.
/// @param len    Length of the buffer in bytes.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_bytes_copy_from_buf(z_owned_bytes_t* bytes,
                                             const uint8_t* data, size_t len);

/// Converts loaned bytes to an owned string.
///
/// @param bytes  Const pointer to a loaned bytes reference.
/// @param out    Pointer to an uninitialized z_owned_string_t to receive the result.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_bytes_to_string(const z_loaned_bytes_t* bytes,
                                         z_owned_string_t* out);

/// Obtains a const loaned reference to the bytes.
///
/// @param bytes  Pointer to a valid z_owned_bytes_t.
/// @return Const pointer to the loaned bytes.
FFI_PLUGIN_EXPORT const z_loaned_bytes_t* zd_bytes_loan(
    const z_owned_bytes_t* bytes);

/// Returns the total number of bytes in the payload.
///
/// @param bytes  Pointer to a z_owned_bytes_t (cast to uint8_t*).
/// @return Total number of bytes.
FFI_PLUGIN_EXPORT int32_t zd_bytes_len(const uint8_t* bytes);

/// Reads the content of owned bytes into a caller-provided buffer.
///
/// Uses z_bytes_reader to copy up to `capacity` bytes into `out`.
///
/// @param bytes     Pointer to a z_owned_bytes_t (cast to uint8_t*).
/// @param out       Pointer to a buffer to receive the data.
/// @param capacity  Maximum number of bytes to read.
/// @return 0 on success.
FFI_PLUGIN_EXPORT int8_t zd_bytes_to_buf(const uint8_t* bytes,
                                          uint8_t* out, int32_t capacity);

/// Drops (frees) owned bytes.
///
/// After this call the owned bytes are in gravestone state.
/// A second drop is a safe no-op.
///
/// @param bytes  Pointer to a z_owned_bytes_t to drop.
FFI_PLUGIN_EXPORT void zd_bytes_drop(z_owned_bytes_t* bytes);

/// Clones owned bytes into a pre-allocated destination.
///
/// Loans the source, then calls z_bytes_clone() to produce an independent
/// copy that shares the underlying reference-counted data.
///
/// @param dst  Pointer to an uninitialized z_owned_bytes_t (cast to uint8_t*).
/// @param src  Pointer to a valid z_owned_bytes_t (cast to uint8_t*).
/// @return 0 on success.
FFI_PLUGIN_EXPORT int8_t zd_bytes_clone(uint8_t* dst, const uint8_t* src);

// ---------------------------------------------------------------------------
// Owned String
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_string_t in bytes.
///
/// Used by Dart to allocate the correct amount of native memory
/// for opaque zenoh types.
FFI_PLUGIN_EXPORT size_t zd_string_sizeof(void);

/// Obtains a const loaned reference to the owned string.
///
/// @param str  Pointer to a valid z_owned_string_t.
/// @return Const pointer to the loaned string.
FFI_PLUGIN_EXPORT const z_loaned_string_t* zd_string_loan(
    const z_owned_string_t* str);

/// Returns a pointer to the data of a loaned string.
///
/// The returned pointer is NOT guaranteed to be null-terminated.
///
/// @param str  Const pointer to a loaned string.
/// @return Pointer to the string data.
FFI_PLUGIN_EXPORT const char* zd_string_data(const z_loaned_string_t* str);

/// Returns the length of a loaned string (in bytes, NOT including any terminator).
///
/// @param str  Const pointer to a loaned string.
/// @return Length of the string data in bytes.
FFI_PLUGIN_EXPORT size_t zd_string_len(const z_loaned_string_t* str);

/// Drops (frees) an owned string.
///
/// After this call the owned string is in gravestone state.
/// A second drop is a safe no-op.
///
/// @param str  Pointer to a z_owned_string_t to drop.
FFI_PLUGIN_EXPORT void zd_string_drop(z_owned_string_t* str);

// ---------------------------------------------------------------------------
// View String utilities
// ---------------------------------------------------------------------------

/// Returns the size of z_view_string_t in bytes.
///
/// Used by Dart to allocate the correct amount of native memory
/// for opaque zenoh types.
FFI_PLUGIN_EXPORT size_t zd_view_string_sizeof(void);

/// Returns a pointer to the data of a view string.
///
/// Internally loans the view string and calls z_string_data on the loaned ref.
/// The returned pointer is NOT guaranteed to be null-terminated.
///
/// @param str  Pointer to a valid z_view_string_t.
/// @return Pointer to the string data.
FFI_PLUGIN_EXPORT const char* zd_view_string_data(const z_view_string_t* str);

/// Returns the length of a view string (in bytes, NOT including any terminator).
///
/// Internally loans the view string and calls z_string_len on the loaned ref.
///
/// @param str  Pointer to a valid z_view_string_t.
/// @return Length of the string data in bytes.
FFI_PLUGIN_EXPORT size_t zd_view_string_len(const z_view_string_t* str);

// ---------------------------------------------------------------------------
// Put / Delete
// ---------------------------------------------------------------------------

/// Publishes data on the given key expression.
///
/// The payload and attachment are consumed (moved) by this call -- the
/// caller must not use the owned bytes after calling zd_put, regardless
/// of the return code (z_bytes_move gravestones them either way).
///
/// @param session     Const pointer to a loaned session.
/// @param keyexpr     Const pointer to a loaned key expression.
/// @param payload     Pointer to an owned bytes (consumed via z_bytes_move).
/// @param encoding    Optional MIME-type string, or NULL for the default.
/// @param attachment  Optional owned bytes (consumed via z_bytes_move),
///                    or NULL for no attachment.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_put(
    const z_loaned_session_t* session,
    const z_loaned_keyexpr_t* keyexpr,
    z_owned_bytes_t* payload,
    const char* encoding,
    z_owned_bytes_t* attachment);

/// Deletes a resource on the given key expression.
///
/// @param session  Const pointer to a loaned session.
/// @param keyexpr  Const pointer to a loaned key expression.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_delete(
    const z_loaned_session_t* session,
    const z_loaned_keyexpr_t* keyexpr);

// ---------------------------------------------------------------------------
// Subscriber
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_subscriber_t in bytes.
///
/// Used by Dart to allocate the correct amount of native memory
/// for opaque zenoh types.
FFI_PLUGIN_EXPORT size_t zd_subscriber_sizeof(void);

/// Declares a subscriber on the given key expression.
///
/// Samples are posted to the Dart isolate via `Dart_PostCObject_DL` on
/// the given native port. Each sample is sent as a `Dart_CObject` array
/// of 4 elements: [keyexpr(string), payload(Uint8List), kind(int64),
/// attachment(null or Uint8List)].
///
/// @param session     Const pointer to a loaned session.
/// @param subscriber  Pointer to an uninitialized z_owned_subscriber_t.
/// @param keyexpr     Const pointer to a loaned key expression.
/// @param dart_port   The Dart native port to post samples to.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_declare_subscriber(
    const z_loaned_session_t* session,
    z_owned_subscriber_t* subscriber,
    const z_loaned_keyexpr_t* keyexpr,
    int64_t dart_port);

/// Drops (undeclares and frees) a subscriber.
///
/// After this call the owned subscriber is in gravestone state.
/// A second drop is a safe no-op.
///
/// @param subscriber  Pointer to a z_owned_subscriber_t to drop.
FFI_PLUGIN_EXPORT void zd_subscriber_drop(z_owned_subscriber_t* subscriber);

/// Declares a background subscriber on the given key expression.
///
/// Unlike a regular subscriber, a background subscriber has no handle --
/// it lives until the session is closed. Samples are posted to the Dart
/// native port. When the session closes and the background subscriber is
/// dropped internally by zenoh-c, a null sentinel is posted to signal
/// stream completion.
///
/// @param session   Const pointer to a loaned session.
/// @param key_expr  The key expression string.
/// @param dart_port The Dart native port to post samples to.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_declare_background_subscriber(
    const z_loaned_session_t* session,
    const char* key_expr,
    int64_t dart_port);

// ---------------------------------------------------------------------------
// Publisher
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_publisher_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_publisher_sizeof(void);

/// Declares a publisher on the given key expression.
///
/// @param session             Const pointer to a loaned session.
/// @param publisher           Pointer to an uninitialized z_owned_publisher_t.
/// @param keyexpr             Const pointer to a loaned key expression.
/// @param encoding            MIME type string for default encoding (NULL = default).
/// @param congestion_control  Congestion control strategy (-1 = default/block).
/// @param priority            Message priority (-1 = default/data=5).
/// @param is_express          Express mode (-1 = default, 0 = false, 1 = true).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_declare_publisher(
    const z_loaned_session_t* session,
    z_owned_publisher_t* publisher,
    const z_loaned_keyexpr_t* keyexpr,
    const char* encoding,
    int congestion_control,
    int priority,
    int8_t is_express);

/// Obtains a const loaned reference to the publisher.
FFI_PLUGIN_EXPORT const z_loaned_publisher_t* zd_publisher_loan(
    const z_owned_publisher_t* publisher);

/// Drops (undeclares and frees) a publisher.
FFI_PLUGIN_EXPORT void zd_publisher_drop(z_owned_publisher_t* publisher);

/// Publishes data through the publisher.
///
/// @param publisher   Const pointer to a loaned publisher.
/// @param payload     Pointer to owned bytes (consumed via z_bytes_move).
/// @param encoding    MIME type string for per-put encoding override (NULL = publisher default).
/// @param attachment  Pointer to owned bytes for attachment (consumed if non-NULL, NULL = no attachment).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_publisher_put(
    const z_loaned_publisher_t* publisher,
    z_owned_bytes_t* payload,
    const char* encoding,
    z_owned_bytes_t* attachment);

/// Sends a DELETE through the publisher.
FFI_PLUGIN_EXPORT int zd_publisher_delete(
    const z_loaned_publisher_t* publisher);

/// Returns the key expression of a publisher.
FFI_PLUGIN_EXPORT const z_loaned_keyexpr_t* zd_publisher_keyexpr(
    const z_loaned_publisher_t* publisher);

/// Declares a background matching listener on the publisher.
///
/// Matching status changes are posted to the Dart isolate via the given
/// native port as Int64 values (1 = matching, 0 = not matching).
///
/// @param publisher  Const pointer to a loaned publisher.
/// @param dart_port  The Dart native port to post matching status to.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_publisher_declare_background_matching_listener(
    const z_loaned_publisher_t* publisher,
    int64_t dart_port);

/// Gets the current matching status of a publisher.
///
/// @param publisher  Const pointer to a loaned publisher.
/// @param matching   Out parameter: filled with 0 (no match) or 1 (match).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_publisher_get_matching_status(
    const z_loaned_publisher_t* publisher,
    int* matching);

// ---------------------------------------------------------------------------
// Info (Session identity)
// ---------------------------------------------------------------------------

/// Copies the session's own ZID (16 bytes) into the provided buffer.
///
/// @param session  Const pointer to a loaned session.
/// @param out_id   Pointer to a 16-byte buffer to receive the ZID.
FFI_PLUGIN_EXPORT void zd_info_zid(const z_loaned_session_t* session,
                                   uint8_t* out_id);

/// Converts a 16-byte ZID to its string representation.
///
/// @param id   Pointer to a 16-byte ZID buffer.
/// @param out  Pointer to an uninitialized z_owned_string_t to receive the result.
FFI_PLUGIN_EXPORT void zd_id_to_string(const uint8_t* id,
                                       z_owned_string_t* out);

/// Collects connected router ZIDs into a caller-provided buffer.
///
/// Each ZID is 16 bytes. The buffer must be at least max_count * 16 bytes.
///
/// @param session    Const pointer to a loaned session.
/// @param out_ids    Pointer to a buffer for ZID bytes (16 bytes per ZID).
/// @param max_count  Maximum number of ZIDs to collect.
/// @return Number of ZIDs written to the buffer.
FFI_PLUGIN_EXPORT int zd_info_routers_zid(const z_loaned_session_t* session,
                                          uint8_t* out_ids, int max_count);

/// Collects connected peer ZIDs into a caller-provided buffer.
///
/// Each ZID is 16 bytes. The buffer must be at least max_count * 16 bytes.
///
/// @param session    Const pointer to a loaned session.
/// @param out_ids    Pointer to a buffer for ZID bytes (16 bytes per ZID).
/// @param max_count  Maximum number of ZIDs to collect.
/// @return Number of ZIDs written to the buffer.
FFI_PLUGIN_EXPORT int zd_info_peers_zid(const z_loaned_session_t* session,
                                        uint8_t* out_ids, int max_count);

// ---------------------------------------------------------------------------
// Scout
// ---------------------------------------------------------------------------

/// Scouts for zenoh entities on the network.
///
/// Each discovered hello is posted to the Dart native port as a
/// Dart_CObject array of 3 elements:
///   [0] TypedData(Uint8, 16 bytes) -- ZID
///   [1] Int64 -- whatami value
///   [2] String -- locators joined with ';'
///
/// After z_scout returns, a null sentinel is posted to signal completion.
///
/// @param config      Pointer to an owned config (consumed). NULL = default config.
/// @param dart_port   The Dart native port to post Hello messages to.
/// @param timeout_ms  Scouting timeout in milliseconds.
/// @param what        Bitmask of entity types to scout for (e.g., 3 = router+peer).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_scout(z_owned_config_t* config, int64_t dart_port,
                               uint64_t timeout_ms, int what);

/// Converts a whatami integer to a human-readable view string.
///
/// @param whatami  The whatami value (1=router, 2=peer, 4=client).
/// @param out      Pointer to an uninitialized z_view_string_t.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_whatami_to_view_string(int whatami,
                                                z_view_string_t* out);

// ---------------------------------------------------------------------------
// Queryable
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_queryable_t in bytes.
FFI_PLUGIN_EXPORT int32_t zd_queryable_sizeof(void);

/// Returns the size of z_owned_query_t in bytes.
FFI_PLUGIN_EXPORT int32_t zd_query_sizeof(void);

/// Declares a queryable on the given key expression.
///
/// Incoming queries are posted to the Dart isolate via the given native port.
///
/// @param queryable_out  Pointer to an uninitialized z_owned_queryable_t.
/// @param session        Const pointer to a loaned session (as uint8_t*).
/// @param key_expr       Null-terminated key expression string.
/// @param port           The Dart native port to post queries to.
/// @param complete       Whether this queryable is complete (1) or not (0).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_declare_queryable(
    uint8_t* queryable_out,
    const uint8_t* session,
    const char* key_expr,
    int64_t port,
    int8_t complete);

/// Drops (undeclares and frees) a queryable.
///
/// @param queryable  Pointer to a z_owned_queryable_t to drop.
FFI_PLUGIN_EXPORT void zd_queryable_drop(uint8_t* queryable);

/// Performs a get query on the given selector.
///
/// Replies are posted to the Dart isolate via the given native port.
///
/// @param session        Const pointer to a loaned session (as uint8_t*).
/// @param selector       Null-terminated selector string.
/// @param port           The Dart native port to post replies to.
/// @param target         Query target (0=bestMatching, 1=all, 2=allComplete).
/// @param consolidation  Consolidation mode (-1=auto, 0=none, 1=monotonic, 2=latest).
/// @param payload        Pointer to z_owned_bytes_t (NULL = no payload).
///                       Consumed via z_bytes_move if non-NULL.
/// @param encoding       MIME type string (NULL = default).
/// @param timeout_ms     Timeout in milliseconds.
/// @param parameters     Additional query parameters (NULL = none).
/// @param attachment     Pointer to z_owned_bytes_t (NULL = no attachment).
///                       Consumed via z_bytes_move if non-NULL.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_get(
    const uint8_t* session,
    const char* selector,
    int64_t port,
    int8_t target,
    int8_t consolidation,
    uint8_t* payload,
    const char* encoding,
    uint64_t timeout_ms,
    const char* parameters,
    uint8_t* attachment);

/// Sends a reply to a query.
///
/// @param query        Const pointer to a loaned query (as uint8_t*).
/// @param key_expr     Null-terminated key expression string.
/// @param payload      Pointer to z_owned_bytes_t (consumed via z_bytes_move).
/// @param encoding     MIME type string (NULL = default).
/// @param attachment   Pointer to z_owned_bytes_t (NULL = no attachment).
///                     Consumed via z_bytes_move if non-NULL.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_query_reply(
    const uint8_t* query,
    const char* key_expr,
    uint8_t* payload,
    const char* encoding,
    uint8_t* attachment);

/// Sends an error reply to a query.
///
/// Mirrors z_query_reply_err: error replies carry a payload + encoding only.
/// There is NO key expression and NO attachment (unanimous oracle carve-out:
/// z_query_reply_err_options_t exposes only `encoding`).
///
/// @param query        Const pointer to a loaned query (as uint8_t*).
/// @param payload      Pointer to z_owned_bytes_t (consumed via z_bytes_move).
/// @param encoding     MIME type string (NULL = default).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_query_reply_err(
    const uint8_t* query,
    uint8_t* payload,
    const char* encoding);

/// Drops (frees) an owned query.
///
/// @param query  Pointer to a z_owned_query_t to drop.
FFI_PLUGIN_EXPORT void zd_query_drop(uint8_t* query);

/// Returns the key expression of a query as a null-terminated string.
///
/// @param query  Const pointer to a loaned query (as uint8_t*).
/// @return Null-terminated key expression string.
FFI_PLUGIN_EXPORT const char* zd_query_keyexpr(const uint8_t* query);

/// Returns the parameters of a query as a null-terminated string.
///
/// @param query  Const pointer to a loaned query (as uint8_t*).
/// @return Null-terminated parameters string (empty string if no parameters).
FFI_PLUGIN_EXPORT const char* zd_query_parameters(const uint8_t* query);

/// Copies the payload of a query into a caller-provided buffer.
///
/// @param query        Const pointer to a loaned query (as uint8_t*).
/// @param payload_out  Pointer to a buffer to receive the payload.
/// @param max_len      Maximum number of bytes to copy.
/// @return Number of bytes copied, or negative on failure.
FFI_PLUGIN_EXPORT int32_t zd_query_payload(
    const uint8_t* query,
    uint8_t* payload_out,
    int32_t max_len);

// ---------------------------------------------------------------------------
// Shared Memory (SHM)
// ---------------------------------------------------------------------------
#if defined(Z_FEATURE_SHARED_MEMORY) && defined(Z_FEATURE_UNSTABLE_API)

/// Returns the size of z_owned_shm_provider_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_shm_provider_sizeof(void);

/// Creates a default SHM provider with the given total size.
///
/// @param provider  Pointer to an uninitialized z_owned_shm_provider_t.
/// @param total_size  Total size of the SHM pool in bytes.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_shm_provider_new(z_owned_shm_provider_t* provider,
                                          size_t total_size);

/// Obtains a const loaned reference to the SHM provider.
FFI_PLUGIN_EXPORT const z_loaned_shm_provider_t* zd_shm_provider_loan(
    const z_owned_shm_provider_t* provider);

/// Drops (frees) the SHM provider.
FFI_PLUGIN_EXPORT void zd_shm_provider_drop(z_owned_shm_provider_t* provider);

/// Returns the available (free) bytes in the SHM provider.
FFI_PLUGIN_EXPORT size_t zd_shm_provider_available(
    const z_loaned_shm_provider_t* provider);

/// Returns the size of z_owned_shm_mut_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_shm_mut_sizeof(void);

/// Allocates a mutable SHM buffer from the provider.
///
/// @param provider  Const pointer to a loaned SHM provider.
/// @param buf       Pointer to an uninitialized z_owned_shm_mut_t.
/// @param size      Size of the buffer to allocate.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_shm_provider_alloc(
    const z_loaned_shm_provider_t* provider,
    z_owned_shm_mut_t* buf,
    size_t size);

/// Allocates a mutable SHM buffer with GC + defrag + blocking.
///
/// @param provider  Const pointer to a loaned SHM provider.
/// @param buf       Pointer to an uninitialized z_owned_shm_mut_t.
/// @param size      Size of the buffer to allocate.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_shm_provider_alloc_gc_defrag_blocking(
    const z_loaned_shm_provider_t* provider,
    z_owned_shm_mut_t* buf,
    size_t size);

/// Obtains a mutable loaned reference to the SHM buffer.
FFI_PLUGIN_EXPORT z_loaned_shm_mut_t* zd_shm_mut_loan_mut(
    z_owned_shm_mut_t* buf);

/// Returns a mutable pointer to the SHM buffer data.
FFI_PLUGIN_EXPORT uint8_t* zd_shm_mut_data_mut(z_loaned_shm_mut_t* buf);

/// Returns the length of the SHM buffer.
FFI_PLUGIN_EXPORT size_t zd_shm_mut_len(const z_loaned_shm_mut_t* buf);

/// Converts a mutable SHM buffer into owned bytes (consuming the buffer).
///
/// @param bytes  Pointer to an uninitialized z_owned_bytes_t.
/// @param buf    Pointer to a z_owned_shm_mut_t (consumed).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int zd_bytes_from_shm_mut(z_owned_bytes_t* bytes,
                                            z_owned_shm_mut_t* buf);

/// Drops (frees) a mutable SHM buffer.
FFI_PLUGIN_EXPORT void zd_shm_mut_drop(z_owned_shm_mut_t* buf);

/// Checks whether owned bytes are backed by shared memory.
///
/// Uses z_bytes_as_loaned_shm() to probe the bytes. If the call succeeds
/// (returns 0), the bytes are SHM-backed.
///
/// @param bytes  Pointer to a z_owned_bytes_t (cast to uint8_t*).
/// @return 1 if SHM-backed, 0 otherwise.
FFI_PLUGIN_EXPORT int8_t zd_bytes_is_shm(const uint8_t* bytes);

#endif // Z_FEATURE_SHARED_MEMORY && Z_FEATURE_UNSTABLE_API

// ---------------------------------------------------------------------------
// Pull Subscriber (ring channel)
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_ring_handler_sample_t in bytes.
FFI_PLUGIN_EXPORT int32_t zd_ring_handler_sample_sizeof(void);

/// Declares a pull subscriber using a ring channel buffer.
///
/// @param subscriber_out  Pointer to an uninitialized z_owned_subscriber_t (as uint8_t*).
/// @param handler_out     Pointer to an uninitialized z_owned_ring_handler_sample_t (as uint8_t*).
/// @param session         Const pointer to a loaned session (as uint8_t*).
/// @param key_expr        Null-terminated key expression string.
/// @param capacity        Ring buffer capacity.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_declare_pull_subscriber(
    uint8_t* subscriber_out, uint8_t* handler_out,
    const uint8_t* session, const char* key_expr,
    int32_t capacity);

/// Tries to receive a sample from the ring handler.
///
/// Return codes: 0=sample available, 1=channel disconnected, 2=buffer empty.
/// When 0, all out_ parameters are populated (malloc'd; caller must free).
///
/// @param handler           Const pointer to an owned ring handler (as uint8_t*).
/// @param out_keyexpr       Out: malloc'd null-terminated key expression string.
/// @param out_payload       Out: malloc'd payload bytes.
/// @param out_payload_len   Out: payload length.
/// @param out_kind          Out: sample kind (0=put, 1=delete).
/// @param out_encoding      Out: malloc'd null-terminated encoding string (or NULL).
/// @param out_attachment     Out: malloc'd attachment bytes (or NULL).
/// @param out_attachment_len Out: attachment length.
/// @return 0=sample, 1=disconnected, 2=empty.
FFI_PLUGIN_EXPORT int8_t zd_pull_subscriber_try_recv(
    const uint8_t* handler,
    char** out_keyexpr, uint8_t** out_payload, int32_t* out_payload_len,
    int8_t* out_kind, char** out_encoding,
    uint8_t** out_attachment, int32_t* out_attachment_len);

/// Drops (frees) the ring handler.
///
/// @param handler  Pointer to a z_owned_ring_handler_sample_t (as uint8_t*).
FFI_PLUGIN_EXPORT void zd_ring_handler_sample_drop(uint8_t* handler);

// ---------------------------------------------------------------------------
// Querier
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_querier_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_querier_sizeof(void);

/// Declares a querier on the given key expression.
///
/// @param querier_out    Pointer to uninitialized z_owned_querier_t (as uint8_t*).
/// @param session        Pointer to a loaned session (as uint8_t*).
/// @param key_expr       Null-terminated key expression string.
/// @param target         Query target (z_query_target_t value).
/// @param consolidation  Consolidation mode (-1=auto, 0=none, 1=monotonic, 2=latest).
/// @param timeout_ms     Timeout in milliseconds (0 = default).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_declare_querier(
    uint8_t* querier_out, const uint8_t* session,
    const char* key_expr, int8_t target,
    int8_t consolidation, uint64_t timeout_ms);

/// Drops (frees) the querier.
///
/// @param querier  Pointer to a z_owned_querier_t (as uint8_t*).
FFI_PLUGIN_EXPORT void zd_querier_drop(uint8_t* querier);

/// Sends a query via a declared querier.
///
/// Replies are delivered asynchronously to the Dart NativePort.
/// Reuses the same reply callback as zd_get.
///
/// @param querier     Pointer to a z_owned_querier_t (as uint8_t*).
/// @param parameters  Optional query parameters string (NULL for none).
/// @param port        Dart NativePort for reply callbacks.
/// @param payload     Optional z_owned_bytes_t* (consumed if non-NULL).
/// @param encoding    Optional encoding string (NULL for none).
/// @param attachment  Optional z_owned_bytes_t* (consumed if non-NULL).
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_querier_get(
    const uint8_t* querier, const char* parameters,
    int64_t port, uint8_t* payload, const char* encoding,
    uint8_t* attachment);

/// Declares a background matching listener for a querier.
///
/// Reuses the same matching status callback and drop function as publisher.
///
/// @param querier    Pointer to a z_owned_querier_t (as uint8_t*).
/// @param port       Dart NativePort for matching status callbacks.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_querier_declare_background_matching_listener(
    const uint8_t* querier, int64_t port);

/// Gets the current matching status of a querier.
///
/// @param querier        Pointer to a z_owned_querier_t (as uint8_t*).
/// @param matching_out   Output: 1 if matching queryables exist, 0 otherwise.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_querier_get_matching_status(
    const uint8_t* querier, int8_t* matching_out);

// ---------------------------------------------------------------------------
// Liveliness
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_liveliness_token_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_liveliness_token_sizeof(void);

/// Declares a liveliness token on the given key expression.
///
/// @param token_out  Pointer to an uninitialized z_owned_liveliness_token_t (as uint8_t*).
/// @param session    Const pointer to a loaned session (as uint8_t*).
/// @param key_expr   Null-terminated key expression string.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_liveliness_declare_token(
    uint8_t* token_out, const uint8_t* session, const char* key_expr);

/// Drops (undeclares and frees) a liveliness token.
///
/// @param token  Pointer to a z_owned_liveliness_token_t (as uint8_t*).
FFI_PLUGIN_EXPORT void zd_liveliness_token_drop(uint8_t* token);

/// Declares a liveliness subscriber on the given key expression.
///
/// Reuses the same z_owned_subscriber_t type and _zd_sample_callback/drop
/// as the regular subscriber. Samples are posted to the Dart NativePort.
///
/// @param subscriber_out  Pointer to an uninitialized z_owned_subscriber_t (as uint8_t*).
/// @param session         Const pointer to a loaned session (as uint8_t*).
/// @param key_expr        Null-terminated key expression string.
/// @param port            Dart NativePort for sample callbacks.
/// @param history         Boolean (0=false, 1=true) for receiving pre-existing token state.
/// @return 0 on success, negative on failure.
FFI_PLUGIN_EXPORT int8_t zd_liveliness_declare_subscriber(
    uint8_t* subscriber_out, const uint8_t* session,
    const char* key_expr, int64_t port, int8_t history);

/// Queries liveliness tokens matching the given key expression.
///
/// Replies are posted to the Dart NativePort as arrays (same format as
/// zd_get replies). A null sentinel signals completion.
///
/// @param session   Loaned session pointer.
/// @param key_expr  Key expression to query liveliness for.
/// @param port      Dart NativePort for reply callbacks.
/// @param timeout_ms  Timeout in milliseconds (0 = default).
/// @return 0 on success.
FFI_PLUGIN_EXPORT int8_t zd_liveliness_get(
    const uint8_t* session, const char* key_expr,
    int64_t port, uint64_t timeout_ms);

// ---------------------------------------------------------------------------
// Serializer
// ---------------------------------------------------------------------------

/// Returns the size of ze_owned_serializer_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_serializer_sizeof(void);

/// Initializes an empty serializer.
///
/// @param ser  Pointer to an uninitialized ze_owned_serializer_t.
/// @return 0 on success.
FFI_PLUGIN_EXPORT int8_t zd_serializer_empty(ze_owned_serializer_t* ser);

/// Obtains a mutable loaned reference to the owned serializer.
///
/// @param ser  Pointer to a valid ze_owned_serializer_t.
/// @param out  Receives the mutable loaned pointer.
FFI_PLUGIN_EXPORT void zd_serializer_loan_mut(
    ze_owned_serializer_t* ser, ze_loaned_serializer_t** out);

/// Finishes the serializer and produces a z_owned_bytes_t.
///
/// The serializer is consumed (moved) by this call.
///
/// @param ser  Pointer to a valid ze_owned_serializer_t (consumed).
/// @param out  Receives the produced z_owned_bytes_t.
FFI_PLUGIN_EXPORT void zd_serializer_finish(
    ze_owned_serializer_t* ser, z_owned_bytes_t* out);

/// Drops (frees) an owned serializer.
///
/// After this call the owned serializer is in gravestone state.
///
/// @param ser  Pointer to a ze_owned_serializer_t to drop.
FFI_PLUGIN_EXPORT void zd_serializer_drop(ze_owned_serializer_t* ser);

// ---------------------------------------------------------------------------
// Serializer — arithmetic type serialization
// ---------------------------------------------------------------------------

/// Serializes a uint8_t value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_uint8(
    ze_loaned_serializer_t* ser, uint8_t val);

/// Serializes a uint16_t value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_uint16(
    ze_loaned_serializer_t* ser, uint16_t val);

/// Serializes a uint32_t value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_uint32(
    ze_loaned_serializer_t* ser, uint32_t val);

/// Serializes a uint64_t value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_uint64(
    ze_loaned_serializer_t* ser, uint64_t val);

/// Serializes an int8_t value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_int8(
    ze_loaned_serializer_t* ser, int8_t val);

/// Serializes an int16_t value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_int16(
    ze_loaned_serializer_t* ser, int16_t val);

/// Serializes an int32_t value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_int32(
    ze_loaned_serializer_t* ser, int32_t val);

/// Serializes an int64_t value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_int64(
    ze_loaned_serializer_t* ser, int64_t val);

/// Serializes a float value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_float(
    ze_loaned_serializer_t* ser, float val);

/// Serializes a double value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_double(
    ze_loaned_serializer_t* ser, double val);

/// Serializes a bool value.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_bool(
    ze_loaned_serializer_t* ser, bool val);

// ---------------------------------------------------------------------------
// Serializer — compound type serialization
// ---------------------------------------------------------------------------

/// Serializes a null-terminated UTF-8 string.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_string(
    ze_loaned_serializer_t* ser, const char* val);

/// Serializes a byte buffer of the given length.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_buf(
    ze_loaned_serializer_t* ser, const uint8_t* data, size_t len);

/// Serializes a sequence length header for a subsequent sequence of elements.
FFI_PLUGIN_EXPORT int8_t zd_serializer_serialize_sequence_length(
    ze_loaned_serializer_t* ser, size_t len);

// ---------------------------------------------------------------------------
// Deserializer
// ---------------------------------------------------------------------------

/// Returns the size of ze_deserializer_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_deserializer_sizeof(void);

/// Creates a deserializer from loaned bytes.
///
/// @param bytes  Loaned bytes to deserialize from.
/// @param out    Pointer to an uninitialized ze_deserializer_t.
FFI_PLUGIN_EXPORT void zd_deserializer_from_bytes(
    const z_loaned_bytes_t* bytes, ze_deserializer_t* out);

/// Checks if the deserializer has consumed all data.
///
/// @return true if no more data to parse, false otherwise.
FFI_PLUGIN_EXPORT bool zd_deserializer_is_done(const ze_deserializer_t* deser);

// ---------------------------------------------------------------------------
// Deserializer — type deserialization
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_uint8(
    ze_deserializer_t* deser, uint8_t* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_uint16(
    ze_deserializer_t* deser, uint16_t* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_uint32(
    ze_deserializer_t* deser, uint32_t* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_uint64(
    ze_deserializer_t* deser, uint64_t* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_int8(
    ze_deserializer_t* deser, int8_t* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_int16(
    ze_deserializer_t* deser, int16_t* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_int32(
    ze_deserializer_t* deser, int32_t* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_int64(
    ze_deserializer_t* deser, int64_t* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_float(
    ze_deserializer_t* deser, float* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_double(
    ze_deserializer_t* deser, double* out);

FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_bool(
    ze_deserializer_t* deser, bool* out);

/// Deserializes a string. Caller must drop the owned string.
FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_string(
    ze_deserializer_t* deser, z_owned_string_t* out);

/// Deserializes a byte buffer (slice). Outputs owned bytes.
FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_buf(
    ze_deserializer_t* deser, z_owned_bytes_t* out);

/// Deserializes a sequence length header.
FFI_PLUGIN_EXPORT int8_t zd_deserializer_deserialize_sequence_length(
    ze_deserializer_t* deser, size_t* out);

// ---------------------------------------------------------------------------
// Bytes Writer
// ---------------------------------------------------------------------------

/// Returns the size of z_owned_bytes_writer_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_bytes_writer_sizeof(void);

/// Creates an empty bytes writer.
FFI_PLUGIN_EXPORT int8_t zd_bytes_writer_empty(z_owned_bytes_writer_t* writer);

/// Obtains a mutable loan of the writer.
FFI_PLUGIN_EXPORT void zd_bytes_writer_loan_mut(
    z_owned_bytes_writer_t* writer, z_loaned_bytes_writer_t** out);

/// Writes all bytes from src into the writer.
FFI_PLUGIN_EXPORT int8_t zd_bytes_writer_write_all(
    z_loaned_bytes_writer_t* writer, const uint8_t* data, size_t len);

/// Appends owned bytes into the writer. Consumes the bytes.
FFI_PLUGIN_EXPORT int8_t zd_bytes_writer_append(
    z_loaned_bytes_writer_t* writer, z_owned_bytes_t* bytes);

/// Finishes the writer and produces owned bytes.
FFI_PLUGIN_EXPORT void zd_bytes_writer_finish(
    z_owned_bytes_writer_t* writer, z_owned_bytes_t* out);

/// Drops the writer without finishing.
FFI_PLUGIN_EXPORT void zd_bytes_writer_drop(z_owned_bytes_writer_t* writer);

// ---------------------------------------------------------------------------
// Bytes Slice Iterator
// ---------------------------------------------------------------------------

/// Returns the size of z_bytes_slice_iterator_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_bytes_slice_iterator_sizeof(void);

/// Creates a slice iterator from loaned bytes and copies it to *iter.
///
/// @param bytes  Const pointer to loaned bytes.
/// @param iter   Pointer to caller-allocated z_bytes_slice_iterator_t.
FFI_PLUGIN_EXPORT void zd_bytes_get_slice_iterator(
    const z_loaned_bytes_t* bytes, z_bytes_slice_iterator_t* iter);

/// Advances the slice iterator.
///
/// @param iter  Pointer to a z_bytes_slice_iterator_t.
/// @param out   Pointer to a z_view_slice_t to receive the next slice.
/// @return true if a slice was written to out, false if iteration is done.
FFI_PLUGIN_EXPORT bool zd_bytes_slice_iterator_next(
    z_bytes_slice_iterator_t* iter, z_view_slice_t* out);

/// Returns the size of z_view_slice_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_view_slice_sizeof(void);

/// Returns a pointer to the slice data.
///
/// @param slice  Const pointer to a z_view_slice_t.
/// @return Pointer to the data bytes.
FFI_PLUGIN_EXPORT const uint8_t* zd_view_slice_data(
    const z_view_slice_t* slice);

/// Returns the length of the slice data.
///
/// @param slice  Const pointer to a z_view_slice_t.
/// @return Number of bytes in the slice.
FFI_PLUGIN_EXPORT size_t zd_view_slice_len(const z_view_slice_t* slice);

// ---------------------------------------------------------------------------
// Advanced Publisher
// ---------------------------------------------------------------------------
#if defined(Z_FEATURE_UNSTABLE_API)

/// Returns the size of ze_owned_advanced_publisher_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_advanced_publisher_sizeof(void);

/// Declares an advanced publisher on the given key expression.
FFI_PLUGIN_EXPORT int zd_declare_advanced_publisher(
    const z_loaned_session_t* session,
    ze_owned_advanced_publisher_t* publisher,
    const z_loaned_keyexpr_t* keyexpr,
    bool enable_cache,
    size_t cache_max_samples,
    bool publisher_detection,
    bool sample_miss_detection,
    int heartbeat_mode,
    uint64_t heartbeat_period_ms);

/// Publishes data through the advanced publisher.
FFI_PLUGIN_EXPORT int zd_advanced_publisher_put(
    const ze_loaned_advanced_publisher_t* publisher,
    z_owned_bytes_t* payload,
    const char* encoding,
    z_owned_bytes_t* attachment);

/// Sends a DELETE through the advanced publisher.
FFI_PLUGIN_EXPORT int zd_advanced_publisher_delete(
    const ze_loaned_advanced_publisher_t* publisher);

/// Obtains a const loaned reference to the advanced publisher.
FFI_PLUGIN_EXPORT const ze_loaned_advanced_publisher_t* zd_advanced_publisher_loan(
    const ze_owned_advanced_publisher_t* publisher);

/// Drops (undeclares and frees) an advanced publisher.
FFI_PLUGIN_EXPORT void zd_advanced_publisher_drop(
    ze_owned_advanced_publisher_t* publisher);

// ---------------------------------------------------------------------------
// Advanced Subscriber
// ---------------------------------------------------------------------------

/// Returns the size of ze_owned_advanced_subscriber_t in bytes.
FFI_PLUGIN_EXPORT size_t zd_advanced_subscriber_sizeof(void);

/// Declares an advanced subscriber on the given key expression.
FFI_PLUGIN_EXPORT int zd_declare_advanced_subscriber(
    const z_loaned_session_t* session,
    ze_owned_advanced_subscriber_t* subscriber,
    const z_loaned_keyexpr_t* keyexpr,
    int64_t dart_port,
    bool history,
    bool history_detect_late_publishers,
    bool recovery,
    bool recovery_last_sample_miss_detection,
    uint64_t recovery_periodic_queries_period_ms,
    bool subscriber_detection);

/// Declares a background sample miss listener on the advanced subscriber.
FFI_PLUGIN_EXPORT int zd_advanced_subscriber_declare_background_sample_miss_listener(
    const ze_loaned_advanced_subscriber_t* subscriber,
    int64_t dart_port);

/// Obtains a const loaned reference to the advanced subscriber.
FFI_PLUGIN_EXPORT const ze_loaned_advanced_subscriber_t* zd_advanced_subscriber_loan(
    const ze_owned_advanced_subscriber_t* subscriber);

/// Drops (undeclares and frees) an advanced subscriber.
FFI_PLUGIN_EXPORT void zd_advanced_subscriber_drop(
    ze_owned_advanced_subscriber_t* subscriber);

#endif // Z_FEATURE_UNSTABLE_API

#endif // ZENOH_DART_H
