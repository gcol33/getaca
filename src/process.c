/*
 * Whether a process is running, and which process it is.
 *
 * A lock in the cache names the process that took it. Whether that process is
 * still there is a question for the operating system, and the answer has to
 * tell a holder apart from a later process that was handed the same number:
 * process ids are reused, on Windows within minutes. The start time is what
 * separates the two, so it is returned alongside the liveness wherever the
 * platform makes it readable.
 *
 * The result is one number:
 *   NA       no such process
 *   0        a process with this id is running, and its start is not readable
 *   other    a stamp of when it started, comparable only for equality and only
 *            against a stamp taken on the same machine
 */

#define R_NO_REMAP

#include <R.h>
#include <Rinternals.h>

#ifdef _WIN32

#include <windows.h>

static double process_stamp_of(int pid)
{
  HANDLE h;
  DWORD code;
  FILETIME created, exited, kernel, user;
  ULARGE_INTEGER ticks;
  double stamp = 0;

  if (pid <= 0) return NA_REAL;

  h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, (DWORD) pid);
  if (h == NULL) {
    /* A process this session may not inspect is still a process. */
    return GetLastError() == ERROR_ACCESS_DENIED ? 0 : NA_REAL;
  }
  /* A handle someone still holds keeps the id of an exited process open. */
  if (GetExitCodeProcess(h, &code) && code != STILL_ACTIVE) {
    CloseHandle(h);
    return NA_REAL;
  }
  if (GetProcessTimes(h, &created, &exited, &kernel, &user)) {
    ticks.LowPart = created.dwLowDateTime;
    ticks.HighPart = created.dwHighDateTime;
    /* Milliseconds rather than the 100 ns the system counts in, so the stamp
       is an integer a double holds exactly and a text file round-trips. */
    stamp = (double) (ticks.QuadPart / 10000ULL);
  }
  CloseHandle(h);
  return stamp;
}

#else

#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#ifdef __linux__
/*
 * Field 22 of /proc/<pid>/stat, in clock ticks since boot. The second field is
 * the command name in parentheses and may itself contain spaces and
 * parentheses, so the fields are counted from the last closing one.
 */
static double linux_start(int pid)
{
  char path[64], line[2048];
  char *at, *end;
  FILE *fp;
  size_t got;
  int field;
  unsigned long long ticks;

  snprintf(path, sizeof(path), "/proc/%d/stat", pid);
  fp = fopen(path, "r");
  if (fp == NULL) return 0;
  got = fread(line, 1, sizeof(line) - 1, fp);
  fclose(fp);
  line[got] = '\0';

  at = strrchr(line, ')');
  if (at == NULL) return 0;
  at++;
  /* The state is field 3, so the start is the twentieth field from here. */
  for (field = 3; field < 22; field++) {
    while (*at == ' ') at++;
    while (*at != ' ' && *at != '\0') at++;
  }
  while (*at == ' ') at++;
  if (*at == '\0') return 0;

  ticks = strtoull(at, &end, 10);
  if (end == at) return 0;
  return (double) ticks;
}
#endif

static double process_stamp_of(int pid)
{
  if (pid <= 0) return NA_REAL;
  /* Signal 0 delivers nothing and reports whether it could have. Being
     refused permission is an answer about a process that exists. */
  if (kill((pid_t) pid, 0) != 0 && errno == ESRCH) return NA_REAL;
#ifdef __linux__
  return linux_start(pid);
#else
  return 0;
#endif
}

#endif

SEXP getaca_process_stamp(SEXP pid)
{
  if (TYPEOF(pid) != INTSXP || LENGTH(pid) != 1) {
    Rf_error("getaca: a process is named by one integer");
  }
  if (INTEGER(pid)[0] == NA_INTEGER) return Rf_ScalarReal(NA_REAL);
  return Rf_ScalarReal(process_stamp_of(INTEGER(pid)[0]));
}
