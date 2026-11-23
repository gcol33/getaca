/*
 * A timer that touches the locks this process holds.
 *
 * A waiter on another machine of a shared filesystem cannot ask whether the
 * holder's process is running, so it reads the age of the holder file instead.
 * That age has to keep moving for as long as the holder lives, whatever the
 * holder is doing: a transfer, a combiner, or a processor that runs for an
 * hour inside one R call. Nothing in R runs on a timer while R is busy, so the
 * touching is done from a second thread.
 *
 * The thread calls the operating system and nothing else. It never enters R,
 * and on POSIX it is created with every signal blocked, so an interrupt is
 * still delivered to the thread R runs on.
 *
 * The thread exists only while at least one lock is held.
 */

#define R_NO_REMAP

#include <R.h>
#include <Rinternals.h>

#include <stdlib.h>
#include <string.h>

#ifdef _WIN32

#include <windows.h>

typedef wchar_t path_char;

static CRITICAL_SECTION mu;
static CONDITION_VARIABLE cv;
static HANDLE thread;
static int ready = 0;

static void guard_init(void)
{
  if (ready) return;
  InitializeCriticalSection(&mu);
  InitializeConditionVariable(&cv);
  ready = 1;
}

static void guard_lock(void)   { EnterCriticalSection(&mu); }
static void guard_unlock(void) { LeaveCriticalSection(&mu); }
static void guard_wake(void)   { WakeConditionVariable(&cv); }

static void guard_wait(double seconds)
{
  SleepConditionVariableCS(&cv, &mu, (DWORD) (seconds * 1000.0));
}

static void touch(const path_char *path)
{
  FILETIME now;
  /* Sharing everything, so a release that removes the file while it is being
     touched is not refused. */
  HANDLE h = CreateFileW(path, FILE_WRITE_ATTRIBUTES,
                         FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                         NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
  if (h == INVALID_HANDLE_VALUE) return;
  GetSystemTimeAsFileTime(&now);
  SetFileTime(h, NULL, NULL, &now);
  CloseHandle(h);
}

static path_char *path_copy(const char *utf8)
{
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
  path_char *out;
  if (n <= 0) return NULL;
  out = (path_char *) malloc((size_t) n * sizeof(path_char));
  if (out == NULL) return NULL;
  if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, out, n) <= 0) {
    free(out);
    return NULL;
  }
  return out;
}

#else

#include <pthread.h>
#include <signal.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

typedef char path_char;

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static pthread_t thread;
static pid_t owner = 0;

static void guard_lock(void)   { pthread_mutex_lock(&mu); }
static void guard_unlock(void) { pthread_mutex_unlock(&mu); }
static void guard_wake(void)   { pthread_cond_signal(&cv); }

static void guard_wait(double seconds)
{
  struct timeval now;
  struct timespec until;
  long whole = (long) seconds;
  long nanos;

  gettimeofday(&now, NULL);
  nanos = (long) now.tv_usec * 1000L + (long) ((seconds - (double) whole) * 1e9);
  until.tv_sec = now.tv_sec + whole + nanos / 1000000000L;
  until.tv_nsec = nanos % 1000000000L;
  pthread_cond_timedwait(&cv, &mu, &until);
}

/* The filesystem's own clock sets the time, which on a network filesystem is
   the server's and so the same for every machine reading it. */
static void touch(const path_char *path)
{
  utimes(path, NULL);
}

static path_char *path_copy(const char *utf8)
{
  size_t n = strlen(utf8) + 1;
  path_char *out = (path_char *) malloc(n);
  if (out != NULL) memcpy(out, utf8, n);
  return out;
}

#endif

static path_char **held = NULL;
static int n_held = 0;
static double interval = 30;
static int running = 0;
static int stopping = 0;
static double beats = 0;

static void free_paths(path_char **paths, int n)
{
  int i;
  if (paths == NULL) return;
  for (i = 0; i < n; i++) free(paths[i]);
  free(paths);
}

static void beat_loop(void)
{
  int i;
  guard_lock();
  while (!stopping) {
    for (i = 0; i < n_held; i++) touch(held[i]);
    beats += 1;
    guard_wait(interval);
  }
  guard_unlock();
}

#ifdef _WIN32

static DWORD WINAPI beat_main(LPVOID arg)
{
  (void) arg;
  beat_loop();
  return 0;
}

static int beat_start(void)
{
  thread = CreateThread(NULL, 0, beat_main, NULL, 0, NULL);
  return thread != NULL;
}

static void beat_join(void)
{
  WaitForSingleObject(thread, INFINITE);
  CloseHandle(thread);
}

#else

static void *beat_main(void *arg)
{
  (void) arg;
  beat_loop();
  return NULL;
}

static int beat_start(void)
{
  sigset_t all, before;
  int failed;

  sigfillset(&all);
  pthread_sigmask(SIG_SETMASK, &all, &before);
  failed = pthread_create(&thread, NULL, beat_main, NULL);
  pthread_sigmask(SIG_SETMASK, &before, NULL);
  return !failed;
}

static void beat_join(void)
{
  pthread_join(thread, NULL);
}

static void free_paths(path_char **paths, int n);

/* A forked child has this state and not the thread, and may have been forked
   while the thread held the mutex. Its parent goes on holding the locks; the
   paths the child frees are its own copy of them. */
static void forget_if_forked(void)
{
  pid_t me = getpid();
  if (owner == me) return;
  if (owner != 0) {
    pthread_mutex_init(&mu, NULL);
    pthread_cond_init(&cv, NULL);
    free_paths(held, n_held);
    held = NULL;
    n_held = 0;
    running = 0;
    stopping = 0;
  }
  owner = me;
}

#endif

static void beat_stop(void)
{
  if (!running) return;
  guard_lock();
  stopping = 1;
  guard_wake();
  guard_unlock();
  beat_join();
  running = 0;
  stopping = 0;
}

/*
 * The files to keep touching, replacing whatever was being touched, and how
 * many seconds to leave between touches. Returns whether a thread is doing it;
 * FALSE with files to touch means one could not be started.
 */
SEXP getaca_heartbeat(SEXP paths, SEXP every)
{
  path_char **fresh = NULL, **old;
  int n, old_n, i;
  double seconds;

  if (TYPEOF(paths) != STRSXP) {
    Rf_error("getaca: the files to touch are named by a character vector");
  }
  seconds = Rf_asReal(every);
  if (!R_FINITE(seconds) || seconds <= 0) {
    Rf_error("getaca: the interval between touches is a positive number of seconds");
  }
  n = LENGTH(paths);

#ifdef _WIN32
  guard_init();
#else
  forget_if_forked();
#endif

  if (n > 0) {
    /* Translated before anything is allocated, since translating can fail
       with an R error and that would leak the copies made so far. */
    const char **utf8 = (const char **) R_alloc((size_t) n, sizeof(char *));
    for (i = 0; i < n; i++) utf8[i] = Rf_translateCharUTF8(STRING_ELT(paths, i));

    fresh = (path_char **) calloc((size_t) n, sizeof(path_char *));
    if (fresh == NULL) Rf_error("getaca: out of memory");
    for (i = 0; i < n; i++) {
      fresh[i] = path_copy(utf8[i]);
      if (fresh[i] == NULL) {
        free_paths(fresh, n);
        Rf_error("getaca: cannot record a lock to keep alive");
      }
    }
  }

  guard_lock();
  old = held;
  old_n = n_held;
  held = fresh;
  n_held = n;
  interval = seconds;
  guard_unlock();
  free_paths(old, old_n);

  if (n == 0) {
    beat_stop();
  } else if (!running) {
    running = beat_start();
  }
  return Rf_ScalarLogical(running);
}

/* How many rounds of touching have been made since the library was loaded. */
SEXP getaca_heartbeat_count(void)
{
  double count;
#ifdef _WIN32
  guard_init();
#endif
  guard_lock();
  count = beats;
  guard_unlock();
  return Rf_ScalarReal(count);
}

/* The thread runs code in this library, so it has to be gone before the
   library is. */
void getaca_heartbeat_unload(void)
{
#ifndef _WIN32
  if (owner != getpid()) return;
#endif
  beat_stop();
}
