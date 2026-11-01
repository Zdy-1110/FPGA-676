#ifndef NAV_H
#define NAV_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NAV_MAX_ENTRIES 256

typedef struct {
    double t0;
    double t1;
    char dir; /* 'L', 'R', 'U', 'S' */
} nav_entry_t;

typedef struct {
    nav_entry_t entries[NAV_MAX_ENTRIES];
    int count;
} nav_table_t;

/* Parse .nav file into table.
 * Returns 0 on success, -1 on failure.
 * Max entries: 256. Unknown direction or syntax error returns -1.
 */
int nav_load(nav_table_t *table, const char *path);

/* Query direction at time t in interval [t0, t1).
 * Returns 'L', 'R', 'U', 'S' if match found, or 0 if no instruction active.
 */
char nav_lookup(const nav_table_t *table, double t);

#ifdef __cplusplus
}
#endif

#endif /* NAV_H */
