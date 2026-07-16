#include "nar.h"

#include <type_traits>

static_assert(std::is_same_v<nar_runtime_handle, uint64_t>);
static_assert(NAR_API_VERSION == 2);
static_assert(sizeof(nar_slice) == 16);

int main() { return nar_api_version() == NAR_API_VERSION ? 0 : 1; }
