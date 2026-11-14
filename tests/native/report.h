/* Shared result reporting for the native tests: one line per test,
 * "PASS|FAIL|SKIP  name  detail", the same format run_all.sh uses. */
#ifndef REPORT_H
#define REPORT_H
#include <stdarg.h>
#include <stdio.h>
static int g_failed = 0;
static void report(const char *status, const char *name, const char *fmt, ...) {
    char detail[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(detail, sizeof detail, fmt, ap);
    va_end(ap);
    printf("%-4s  %-38s %s\n", status, name, detail);
    fflush(stdout);
    if (status[0] == 'F') g_failed = 1;
}
#endif
