#include "nar.h"

#include <type_traits>

static_assert(std::is_same_v<nar_runtime_handle, uint64_t>);
static_assert(NAR_API_VERSION == 1);

int main() { return nar_api_version() == NAR_API_VERSION ? 0 : 1; }
