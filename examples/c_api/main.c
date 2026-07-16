#include "nar.h"

#include <string.h>

static nar_slice bytes(const char *value) {
    nar_slice result = {(const uint8_t *)value, strlen(value)};
    return result;
}

static void confirm_on_main(const nar_invocation *invocation,
                            nar_result_sink *sink, void *userdata) {
    (void)invocation;
    (void)userdata;
    (void)sink->complete(sink, bytes("{\"confirmed\":true}"));
}

int main(void) {
    nar_runtime_config config = {0};
    config.struct_size = sizeof(config);
    config.api_version = NAR_API_VERSION;
    config.profile = NAR_PROFILE_MINIMAL;
    config.max_agents = 1;
    config.mailbox_capacity = 8;
    config.operation_capacity = 4;
    config.queue_capacity = 4;

    nar_runtime_handle runtime = 0;
    if (nar_runtime_create(&config, &runtime) != NAR_OK) return 1;

    nar_tool_descriptor descriptor = {0};
    descriptor.struct_size = sizeof(descriptor);
    descriptor.api_version = NAR_API_VERSION;
    descriptor.name = bytes("confirm_main");
    descriptor.version = bytes("1");
    descriptor.input_schema = bytes("{\"type\":\"object\"}");
    descriptor.thread_affinity = NAR_THREAD_MAIN;
    nar_tool_handle tool = 0;
    if (nar_tool_register(runtime, &descriptor, confirm_on_main, NULL, &tool) != NAR_OK) return 2;

    uint64_t completed = 0;
    if (nar_runtime_pump_main_thread(runtime, 4, 1000000, &completed) != NAR_OK) return 3;
    if (nar_tool_unregister(runtime, tool) != NAR_OK) return 4;
    if (nar_runtime_shutdown(runtime, 0) != NAR_OK) return 5;
    nar_runtime_destroy(runtime);
    return 0;
}
