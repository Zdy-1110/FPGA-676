#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <math.h>
#include "nav.h"

int main(int argc, char **argv)
{
    const char *nav_path = "tools/nav_proto/out/video_20260929_112739.nav";
    if (argc > 1) {
        nav_path = argv[1];
    }

    nav_table_t table;
    int r = nav_load(&table, nav_path);
    if (r != 0) {
        fprintf(stderr, "FAIL: failed to load nav file %s\n", nav_path);
        return 1;
    }

    /* 1. 验证共有 15 条指令 */
    if (table.count != 15) {
        fprintf(stderr, "FAIL: expected 15 entries, got %d\n", table.count);
        return 1;
    }

    /* 2. 检查 t=2.0 -> R */
    char c = nav_lookup(&table, 2.0);
    if (c != 'R') {
        fprintf(stderr, "FAIL: t=2.0 expected 'R', got '%c'\n", c ? c : '-');
        return 1;
    }

    /* 3. 检查 t=1.9 -> 无 (0) */
    c = nav_lookup(&table, 1.9);
    if (c != 0) {
        fprintf(stderr, "FAIL: t=1.9 expected none (0), got '%c'\n", c);
        return 1;
    }

    /* 4. 检查 t=t1 边界 -> 下一条/无 */
    /* 4a: t1 之后有空档 -> 无 (0) */
    /* entry 0 是 [2.0, 8.0) R, 下一条从 10.0 开始 */
    c = nav_lookup(&table, 8.0);
    if (c != 0) {
        fprintf(stderr, "FAIL: t=8.0 (entry 0 t1 boundary) expected none (0), got '%c'\n", c);
        return 1;
    }

    /* entry 12 是 [66.0, 72.0) L, 下一条从 84.0 开始 */
    c = nav_lookup(&table, 72.0);
    if (c != 0) {
        fprintf(stderr, "FAIL: t=72.0 expected none (0), got '%c'\n", c);
        return 1;
    }

    /* entry 14 (末条) 是 [90.0, 96.0) U, 之后无指令 */
    c = nav_lookup(&table, 96.0);
    if (c != 0) {
        fprintf(stderr, "FAIL: t=96.0 expected none (0), got '%c'\n", c);
        return 1;
    }

    /* 4b: t1 之后紧接下一条 -> 下一条指令 */
    /* entry 4 是 [38.0, 42.0) R, entry 5 是 [42.0, 44.0) R */
    c = nav_lookup(&table, 42.0);
    if (c != 'R') {
        fprintf(stderr, "FAIL: t=42.0 boundary expected 'R' (entry 5), got '%c'\n", c ? c : '-');
        return 1;
    }

    /* entry 7 是 [46.0, 48.0) R, entry 8 是 [48.0, 54.0) L */
    c = nav_lookup(&table, 48.0);
    if (c != 'L') {
        fprintf(stderr, "FAIL: t=48.0 boundary expected 'L' (entry 8), got '%c'\n", c ? c : '-');
        return 1;
    }

    /* 5. 检查 15 条指令全部能被查到 */
    for (int i = 0; i < table.count; i++) {
        /* 起点 t0 */
        char c_start = nav_lookup(&table, table.entries[i].t0);
        if (c_start != table.entries[i].dir) {
            fprintf(stderr, "FAIL: entry %d at t0=%.1f expected '%c', got '%c'\n",
                    i, table.entries[i].t0, table.entries[i].dir, c_start ? c_start : '-');
            return 1;
        }

        /* 中点 */
        double t_mid = (table.entries[i].t0 + table.entries[i].t1) * 0.5;
        char c_mid = nav_lookup(&table, t_mid);
        if (c_mid != table.entries[i].dir) {
            fprintf(stderr, "FAIL: entry %d at t_mid=%.1f expected '%c', got '%c'\n",
                    i, t_mid, table.entries[i].dir, c_mid ? c_mid : '-');
            return 1;
        }
    }

    /* 6. 异常测试：不存在的文件应返回 -1 */
    nav_table_t dummy;
    if (nav_load(&dummy, "non_existent_file.nav") != -1) {
        fprintf(stderr, "FAIL: non_existent file should return -1\n");
        return 1;
    }

    printf("PASS\n");
    return 0;
}
