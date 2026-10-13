// Linked into the web build only (see tool/build_web.sh).
//
// Without -pthread, Emscripten implements pthread mutexes as no-op stubs:
// pthread_mutex_trylock always succeeds, even on a mutex that is held. Rust's
// std::sync::Mutex is built on pthread mutexes on this target, and Loro checks
// that its transaction lock is held with Mutex::try_lock, so it needs mutexes
// that remember their state. The stubs are weak aliases, so these strong
// definitions replace them. The module is single-threaded, so a flag is
// enough: blocking on a held mutex could never be resolved by another thread.
#include <errno.h>
#include <pthread.h>

#define LOCKED(m) ((m)->__u.__i[1])

int pthread_mutex_lock(pthread_mutex_t *m) {
  if (LOCKED(m)) return EDEADLK;
  LOCKED(m) = 1;
  return 0;
}

int pthread_mutex_trylock(pthread_mutex_t *m) {
  if (LOCKED(m)) return EBUSY;
  LOCKED(m) = 1;
  return 0;
}

int pthread_mutex_unlock(pthread_mutex_t *m) {
  LOCKED(m) = 0;
  return 0;
}
