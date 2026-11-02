"""解析板端 A/B 日志（/tmp/ab_<vid>_<mode>.log），按 GT 用例窗口算车道线虚实通过数。

用法:
  py -3 tools/board_eval/score_ab_lane_20261103.py <log_dir>
log 文件名须为 ab_<vid>_fpga.log / ab_<vid>_bucket.log。
判定口径与 tools/lane_fpga/exp_temporal_20261102.py 一致：窗口去掉两端 0.3 s，
逐帧 80% 以上匹配即用例通过；ALLOW 期望 solid=0，KEEP/ALARM 期望 solid=1。
"""
import csv
import os
import re
import sys
from collections import defaultdict

TESTCASES = os.path.join(os.path.dirname(__file__), "..", "..",
                         "video_review", "gt", "out", "testcases.csv")
LINE = re.compile(r"eval t=([0-9.]+) .*?ll=(\d+),(\d+) rl=(\d+),(\d+)")


def expected_code(e):
    e = e or ""
    if "报警" in e:
        return "ALARM"
    if "允许" in e:
        return "ALLOW"
    if "保持直行" in e:
        return "KEEP"
    return ""


def load_cases():
    out = []
    with open(TESTCASES, encoding="utf-8-sig", newline="") as f:
        for r in csv.DictReader(f):
            if (r.get("category") or "").strip() != "LANE":
                continue
            out.append(r)
    return out


def load_log(path, video):
    ts, l, r = [], [], []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = LINE.search(line)
            if not m:
                continue
            ts.append(float(m.group(1)))
            l.append((int(m.group(2)), int(m.group(3))))
            r.append((int(m.group(4)), int(m.group(5))))
    return ts, l, r


def main():
    logdir = sys.argv[1] if len(sys.argv) > 1 else "/tmp"
    cases = load_cases()
    videos = sorted({c["video"] for c in cases})
    logs = {}
    for v in videos:
        for mode in ("fpga", "bucket"):
            p = os.path.join(logdir, f"ab_{v}_{mode}.log")
            if os.path.exists(p):
                logs[(v, mode)] = load_log(p, v)
            else:
                print(f"缺日志: {p}")

    for mode in ("fpga", "bucket"):
        d = s = dt = st = 0
        per = defaultdict(lambda: [0, 0, 0, 0])
        rows = []
        for c in cases:
            v = c["video"]
            if (v, mode) not in logs:
                continue
            ts, l, r = logs[(v, mode)]
            side = l if c["lane_or_side"] == "左" else r
            t0, t1 = float(c["t_start"]), float(c["t_end"])
            lo, hi = (t0 + 0.3, t1 - 0.3) if t1 - t0 >= 1.2 else (t0, t1)
            idx = [i for i, t in enumerate(ts) if lo <= t <= hi]
            exp = expected_code(c["expected"])
            force = c["command"].startswith("强制")
            if not idx:
                rows.append((c["case_id"], v, side is l and "L" or "R", exp, "-", 0.0, False, 0))
                continue
            solid = [side[i][1] for i in idx]
            preds = ["ALLOW" if x == 0 else ("ALARM" if force else "KEEP") for x in solid]
            ratio = sum(1 for p in preds if p == exp) / len(preds)
            ok = ratio >= 0.8
            if exp == "ALLOW":
                dt += 1
                d += ok
                per[v][0] += ok
                per[v][1] += 1
            else:
                st += 1
                s += ok
                per[v][2] += ok
                per[v][3] += 1
            rows.append((c["case_id"], v, c["lane_or_side"], exp, preds[0], ratio, ok, len(idx)))
        print(f"\n===== mode={mode}: D={d}/{dt} S={s}/{st} Bal={(d/max(dt,1)+s/max(st,1)):.4f} 总={d+s}/{dt+st}")
        for v in sorted(per):
            p = per[v]
            print(f"  {v}: D={p[0]}/{p[1]} S={p[2]}/{p[3]}")
        if mode == "bucket":
            bad = [r for r in rows if not r[6]]
            print("  未通过用例:")
            for r in bad:
                print(f"    {r[0]:14s} {r[1]} {r[2]} 期望={r[3]} 首帧判={r[4]} 匹配率={r[5]*100:.0f}% 帧数={r[7]}")


if __name__ == "__main__":
    main()
