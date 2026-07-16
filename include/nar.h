#ifndef NAR_H
#define NAR_H

/* Stable C11 ABI for the Native Agent Runtime.  All handles are opaque and
 * generation checked; zero is never a valid handle. */
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NAR_API_VERSION UINT32_C(2)

typedef uint64_t nar_runtime_handle;
typedef uint64_t nar_agent_handle;
typedef uint64_t nar_tool_handle;
typedef uint64_t nar_turn_handle;
typedef uint64_t nar_operation_handle;

typedef enum nar_error_code {
    NAR_OK = 0, NAR_INVALID_ARGUMENT = 1, NAR_INVALID_STATE = 2,
    NAR_CANCELLED = 3, NAR_TIMEOUT = 4, NAR_BUDGET_EXCEEDED = 5,
    NAR_MODEL_UNAVAILABLE = 6, NAR_MODEL_PROTOCOL_ERROR = 7,
    NAR_TOOL_NOT_FOUND = 8, NAR_TOOL_SCHEMA_ERROR = 9,
    NAR_TOOL_PERMISSION_DENIED = 10, NAR_STALE_OBJECT = 11,
    NAR_STALE_WORLD_REVISION = 12, NAR_OPERATION_FAILED = 13,
    NAR_STORAGE_ERROR = 14, NAR_NETWORK_ERROR = 15,
    NAR_INTERNAL_ERROR = 16
} nar_error_code;

typedef enum nar_profile { NAR_PROFILE_MINIMAL = 0, NAR_PROFILE_RUNTIME = 1 } nar_profile;
typedef enum nar_thread_affinity { NAR_THREAD_ANY = 0, NAR_THREAD_MAIN = 1, NAR_THREAD_WORKER = 2 } nar_thread_affinity;
typedef enum nar_cancel_reason { NAR_CANCEL_REQUESTED = 0, NAR_CANCEL_TIMEOUT = 1, NAR_CANCEL_SHUTDOWN = 2, NAR_CANCEL_OWNER_DESTROYED = 3 } nar_cancel_reason;
typedef enum nar_tick_result { NAR_TICK_PROGRESSED = 0, NAR_TICK_WOULD_BLOCK = 1, NAR_TICK_TERMINAL = 2 } nar_tick_result;
typedef enum nar_event_kind { NAR_EVENT_NONE = 0, NAR_EVENT_TEXT_DELTA = 1, NAR_EVENT_FINAL_RESPONSE = 2, NAR_EVENT_TOOL_COMPLETED = 3, NAR_EVENT_OPERATION_PROGRESS = 4, NAR_EVENT_FAILED = 5, NAR_EVENT_CANCELLED = 6, NAR_EVENT_SYSTEM = 7 } nar_event_kind;
typedef enum nar_resource_kind { NAR_RESOURCE_FILE = 0, NAR_RESOURCE_PAGE = 1, NAR_RESOURCE_MEMORY_BUFFER = 2, NAR_RESOURCE_DATABASE_SEGMENT = 3, NAR_RESOURCE_GPU_BUFFER = 4, NAR_RESOURCE_TEXTURE = 5, NAR_RESOURCE_NETWORK_BLOB = 6, NAR_RESOURCE_CUSTOM = 7 } nar_resource_kind;
typedef enum nar_resource_mode { NAR_RESOURCE_READ = 0, NAR_RESOURCE_WRITE = 1, NAR_RESOURCE_CREATE = 2, NAR_RESOURCE_DELETE = 3 } nar_resource_mode;
typedef enum nar_resource_range_kind { NAR_RANGE_WHOLE = 0, NAR_RANGE_PAGE = 1, NAR_RANGE_BYTE = 2 } nar_resource_range_kind;
typedef enum nar_version_constraint_kind { NAR_VERSION_ANY = 0, NAR_VERSION_MUST_NOT_EXIST = 1, NAR_VERSION_EXACT = 2, NAR_VERSION_GENERATION = 3 } nar_version_constraint_kind;

typedef struct nar_slice { const uint8_t *data; uint64_t size; } nar_slice;
typedef struct nar_buffer nar_buffer;
typedef void (*nar_buffer_release_fn)(nar_buffer *buffer);
struct nar_buffer { const uint8_t *data; uint64_t size; nar_buffer_release_fn release; void *userdata; };

typedef nar_error_code (*nar_validate_dispatch_fn)(nar_slice tool_name, nar_slice arguments_json, uint64_t world_revision, void *userdata);
typedef struct nar_resource_key {
    uint32_t kind, reserved;
    uint64_t namespace_high, namespace_low;
    nar_slice name;
    uint64_t page;
} nar_resource_key;
typedef struct nar_resource_version { uint64_t generation, content_hash; uint32_t exists, has_content_hash; } nar_resource_version;
typedef nar_error_code (*nar_resolve_resource_fn)(const nar_resource_key *, nar_resource_version *, void *userdata);

typedef struct nar_runtime_config {
    uint32_t struct_size, api_version;
    nar_profile profile;
    uint32_t reserved0;
    uint64_t max_agents, mailbox_capacity, operation_capacity;
    uint64_t compute_workers, blocking_workers, queue_capacity, observability_capacity;
    /* Capability masks are literal: zero denies all capabilities and
     * UINT64_MAX is the permissive ceiling. */
    uint64_t build_capabilities, shipping_capabilities, project_capabilities, runtime_capabilities;
    uint32_t shipping, reserved1;
    nar_validate_dispatch_fn validate_dispatch;
    nar_resolve_resource_fn resolve_resource;
    void *host_userdata;
} nar_runtime_config;

/* Registers one OpenAI Chat Completions compatible streaming model on a
 * runtime-profile host. Every slice is copied during registration. Remote
 * origins must be HTTPS and explicitly listed in allowed_origins; localhost
 * HTTP is allowed for development fixtures. api_key is only used to create a
 * temporary Authorization request header. curl_library_path identifies the
 * libcurl dynamic library used by the runtime transport. */
typedef struct nar_openai_model_config {
    uint32_t struct_size, api_version;
    nar_slice provider_id, model_id, base_url, api_key, curl_library_path;
    const nar_slice *allowed_origins; uint64_t allowed_origin_count;
    uint64_t connect_timeout_ms, first_byte_timeout_ms, timeout_ms;
    uint64_t response_limit, event_limit, queue_capacity, max_requests;
} nar_openai_model_config;

typedef struct nar_budget { uint64_t wall_time_ns, model_calls, tool_calls, context_tokens, output_tokens, cost_micros, trace_bytes; } nar_budget;
typedef struct nar_resource_access {
    uint32_t struct_size, api_version;
    nar_resource_key key;
    uint32_t mode, range_kind, version_kind, reserved;
    uint64_t range_start, range_end, version_value;
} nar_resource_access;
typedef struct nar_tool_descriptor {
    uint32_t struct_size, api_version;
    nar_slice name, description, version, input_schema, output_schema;
    uint64_t required_capabilities;
    const nar_resource_access *resources; uint64_t resource_count;
    nar_thread_affinity thread_affinity;
    uint32_t flags, profile_mask, revision_policy;
} nar_tool_descriptor;
typedef struct nar_invocation { nar_slice arguments_json; uint64_t world_revision; uint64_t object_id; uint32_t object_generation; uint32_t reserved; nar_operation_handle operation; } nar_invocation;
typedef struct nar_result_sink nar_result_sink;
typedef nar_error_code (*nar_result_complete_fn)(nar_result_sink *, nar_slice json);
typedef nar_error_code (*nar_result_fail_fn)(nar_result_sink *, nar_error_code);
struct nar_result_sink { nar_result_complete_fn complete; nar_result_fail_fn fail; void *userdata; };
typedef void (*nar_tool_callback)(const nar_invocation *, nar_result_sink *, void *userdata);

typedef struct nar_agent_config {
    uint32_t struct_size, api_version;
    nar_slice provider_id, model_id, system_context, static_context;
    const nar_slice *allowed_tools; uint64_t allowed_tool_count;
    nar_budget budget;
    uint64_t max_repeated_tool_calls, capabilities;
    uint32_t tool_error_policy, reserved;
} nar_agent_config;
typedef struct nar_world_section { nar_slice name, payload; } nar_world_section;
typedef struct nar_submit_request { uint32_t struct_size, api_version; nar_slice input; uint64_t world_revision, captured_at_ns; const nar_world_section *sections; uint64_t section_count; } nar_submit_request;
typedef struct nar_event { uint32_t struct_size, api_version; nar_event_kind kind; uint32_t reserved; uint64_t sequence, turn, timestamp_ns, operation; nar_error_code error; nar_cancel_reason cancel_reason; nar_buffer buffer; } nar_event;

uint32_t nar_api_version(void);
nar_error_code nar_runtime_create(const nar_runtime_config *, nar_runtime_handle *);
nar_error_code nar_runtime_register_openai_model(nar_runtime_handle, const nar_openai_model_config *);
/* Validates and copies a complete trace. The replay model route is
 * provider_id="replay", model_id="replay" and never falls back to HTTP. */
nar_error_code nar_replay_runtime_create(const nar_runtime_config *, nar_slice trace, nar_runtime_handle *);
/* A zero deadline waits for convergence. A finite absolute monotonic deadline
 * returns NAR_TIMEOUT when staged shutdown has not converged; destroy remains
 * required and performs final convergence. */
nar_error_code nar_runtime_shutdown(nar_runtime_handle, uint64_t deadline_monotonic_ns);
void nar_runtime_destroy(nar_runtime_handle);
nar_error_code nar_tool_register(nar_runtime_handle, const nar_tool_descriptor *, nar_tool_callback, void *, nar_tool_handle *);
nar_error_code nar_tool_unregister(nar_runtime_handle, nar_tool_handle);
nar_error_code nar_agent_create(nar_runtime_handle, const nar_agent_config *, nar_agent_handle *);
nar_error_code nar_agent_destroy(nar_runtime_handle, nar_agent_handle);
nar_error_code nar_agent_submit(nar_runtime_handle, nar_agent_handle, const nar_submit_request *, nar_turn_handle *);
nar_error_code nar_agent_tick(nar_runtime_handle, nar_agent_handle, nar_tick_result *);
nar_error_code nar_runtime_pump_main_thread(nar_runtime_handle, uint64_t max_jobs, uint64_t max_nanos, uint64_t *completed_jobs);
nar_error_code nar_agent_poll(nar_runtime_handle, nar_agent_handle, nar_event *);
nar_error_code nar_agent_cancel(nar_runtime_handle, nar_agent_handle, nar_cancel_reason);
nar_error_code nar_operation_complete(nar_runtime_handle, nar_operation_handle, nar_slice);
nar_error_code nar_operation_fail(nar_runtime_handle, nar_operation_handle, nar_error_code);
nar_error_code nar_operation_cancel(nar_runtime_handle, nar_operation_handle, nar_cancel_reason);
void nar_buffer_release(nar_buffer *);

#ifdef __cplusplus
}
#endif
#endif
