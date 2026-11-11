#include <cstdint>
#include <mutex>
#include <unordered_map>

#if defined(_WIN32)
#define ZVEC_EXPORT extern "C" __declspec(dllexport)
#else
#define ZVEC_EXPORT extern "C" __attribute__((visibility("default")))
#endif

namespace {
using Close = uint32_t (*)(void*);
struct Entry { void* handle; Close close; bool failed; };
std::mutex mutex;
std::unordered_map<int64_t, Entry> entries;
int64_t next_id = 1;
}

ZVEC_EXPORT int64_t dart_zvec_track(void* handle, Close close) {
  std::lock_guard<std::mutex> lock(mutex);
  if (!handle || !close || next_id <= 0 || next_id >= INTPTR_MAX) return 0;
  auto id = next_id++;
  entries.emplace(id, Entry{handle, close, false});
  return id;
}

// A failure is retained and cannot be retried: the native API does not promise
// that a failed close leaves its handle valid.
ZVEC_EXPORT int32_t dart_zvec_close_tracked(int64_t id) {
  std::lock_guard<std::mutex> lock(mutex);
  auto it = entries.find(id);
  if (it == entries.end()) return 0;
  if (it->second.failed) return -1;
  if (it->second.close(it->second.handle) != 0) {
    it->second.failed = true;
    return -1;
  }
  entries.erase(it);
  return 0;
}

// Caller has stopped every thread/isolate that can access these handles.
ZVEC_EXPORT int32_t dart_zvec_close_all_tracked() {
  std::lock_guard<std::mutex> lock(mutex);
  bool failed = false;
  for (auto it = entries.begin(); it != entries.end();) {
    if (it->second.failed || it->second.close(it->second.handle) != 0) {
      it->second.failed = true;
      failed = true;
      ++it;
    } else {
      it = entries.erase(it);
    }
  }
  return failed ? -1 : 0;
}

ZVEC_EXPORT int32_t dart_zvec_is_tracked(int64_t id) {
  std::lock_guard<std::mutex> lock(mutex);
  auto it = entries.find(id);
  return it != entries.end() && !it->second.failed ? 1 : 0;
}
