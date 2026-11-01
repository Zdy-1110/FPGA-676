#include "nav.h"

int nav_load(nav_table_t *table, const char *path)
{
    if (!table || !path) return -1;
    table->count = 0;

    FILE *fp = fopen(path, "r");
    if (!fp) {
        fprintf(stderr, "nav_load: failed to open '%s'\n", path);
        return -1;
    }

    char line[256];
    int line_num = 0;
    while (fgets(line, sizeof(line), fp)) {
        line_num++;
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\0' || *p == '#' || *p == '\r' || *p == '\n') {
            continue;
        }

        if (table->count >= NAV_MAX_ENTRIES) {
            fprintf(stderr, "nav_load: exceeded max entries %d in '%s'\n",
                    NAV_MAX_ENTRIES, path);
            fclose(fp);
            table->count = 0;
            return -1;
        }

        double t0 = 0.0, t1 = 0.0;
        char dir = 0;
        if (sscanf(p, "%lf %lf %c", &t0, &t1, &dir) != 3) {
            fprintf(stderr, "nav_load: syntax error in '%s':%d: %s\n",
                    path, line_num, line);
            fclose(fp);
            table->count = 0;
            return -1;
        }

        if (dir != 'L' && dir != 'R' && dir != 'U' && dir != 'S') {
            fprintf(stderr, "nav_load: unknown direction '%c' in '%s':%d\n",
                    dir, path, line_num);
            fclose(fp);
            table->count = 0;
            return -1;
        }

        if (t0 > t1) {
            fprintf(stderr, "nav_load: invalid interval [%.1f, %.1f) in '%s':%d\n",
                    t0, t1, path, line_num);
            fclose(fp);
            table->count = 0;
            return -1;
        }

        table->entries[table->count].t0 = t0;
        table->entries[table->count].t1 = t1;
        table->entries[table->count].dir = dir;
        table->count++;
    }

    fclose(fp);
    return 0;
}

char nav_lookup(const nav_table_t *table, double t)
{
    if (!table) return 0;
    for (int i = 0; i < table->count; i++) {
        if (t >= table->entries[i].t0 && t < table->entries[i].t1) {
            return table->entries[i].dir;
        }
    }
    return 0;
}
