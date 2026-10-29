# -*- coding: utf-8 -*-
"""离线评测：参考感知输出 vs 真值 与 判决测试用例（仅标准库）。

用法：
  python eval_ref.py --runs-dir <states根目录> --gt-dir <gt目录> \
      --testcases <testcases.csv> --out-md <报告.md> --out-csv <结果.csv> \
      [--pass-ratio 0.8] [--edge-trim 0.3] [--right-free|--no-right-free]

第一部分：对 states.csv 每一帧比较信号灯 / 车道线 / 自车运动，逐帧准确率与混淆矩阵。
第二部分：对 SIG / LANE 测试用例按时间窗做逐帧判决，算通过率。
"""

import argparse
import csv
import glob
import os
import sys
from collections import Counter, defaultdict
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decide_ref import decide_sig, decide_lane, line_class  # noqa: E402

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

SIGNAL_FIELDS = [("sig_left", "left"), ("sig_straight", "straight"), ("sig_right", "right")]
LANE_PAIRS = [("left_line", "ego_left_line", "left"), ("right_line", "ego_right_line", "right")]

SIG_STOP = {"red", "yellow"}
SIG_GO = {"green", "none", "off"}

LANE_MAP = {"左": "left", "直": "straight", "右": "right"}
SIDE_MAP = {"左": "left", "右": "right"}

CSV_COLUMNS = [
    "case_id", "video", "category", "lane_or_side", "command", "expected",
    "expected_code", "t_start", "t_end", "conf", "n_frames", "match_ratio",
    "status", "dominant_pred", "first_ok_s",
]


def norm(v):
    return (v or "").strip().lower()


def sig_stopgo(v):
    if v in SIG_STOP:
        return "STOP"
    if v in SIG_GO:
        return "GO"
    return v


def motion_class(v):
    if v == "stopped":
        return "stopped"
    if v in ("moving", "braking", "starting"):
        return "moving"
    return v


def pct(ok, n):
    return "-" if n == 0 else "%.1f%%" % (100.0 * ok / n)


class GT:
    def __init__(self, gt_dir):
        self.rows = defaultdict(lambda: defaultdict(list))
        for path in sorted(glob.glob(os.path.join(gt_dir, "*_timeline.csv"))):
            base = os.path.basename(path)
            if base.startswith("_") or base.startswith("111440"):
                continue
            with open(path, "r", encoding="utf-8-sig", newline="") as f:
                for r in csv.DictReader(f):
                    try:
                        t0 = float(r["t_start"])
                        t1 = float(r["t_end"])
                    except (KeyError, TypeError, ValueError):
                        continue
                    video = (r.get("video") or "").strip()
                    field = (r.get("field") or "").strip()
                    if not video or not field:
                        continue
                    self.rows[video][field].append(
                        (t0, t1, (r.get("value") or "").strip().lower(),
                         (r.get("conf") or "").strip().lower()))

    def query(self, video, field, t):
        best = None
        for r in self.rows.get(video, {}).get(field, []):
            if r[0] <= t <= r[1]:
                if best is None or r[0] >= best[0]:
                    best = r
        return best


def load_states(runs_dir):
    states = {}
    for sub in sorted(os.listdir(runs_dir)):
        p = os.path.join(runs_dir, sub, "states.csv")
        if os.path.isfile(p):
            with open(p, "r", encoding="utf-8-sig", newline="") as f:
                states[sub] = list(csv.DictReader(f))
    return states


def load_testcases(path):
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def expected_code(category, expected):
    e = expected or ""
    if category == "SIG":
        if "报警" in e:
            return "ALARM"
        if "停车" in e:
            return "STOP"
        if "通行" in e:
            return "GO"
    elif category == "LANE":
        if "报警" in e:
            return "ALARM"
        if "允许" in e:
            return "ALLOW"
        if "保持直行" in e:
            return "KEEP"
    return ""


class Acc:
    def __init__(self):
        self.sig = {"exact": [0, 0], "color": [0, 0], "stopgo": [0, 0]}
        self.lane = {"cls": [0, 0], "exact": [0, 0]}
        self.motion = [0, 0]


def bump(pair, ok):
    pair[1] += 1
    if ok:
        pair[0] += 1


def frame_stats(states, gt):
    per_video = {}
    total = Acc()
    conf_acc = defaultdict(Acc)
    sig_mat = Counter()
    lane_mat = Counter()
    motion_mat = Counter()

    for video in sorted(states):
        acc = Acc()
        for row in states[video]:
            try:
                t = float(row.get("t"))
            except (TypeError, ValueError):
                continue
            for field, _lane in SIGNAL_FIELDS:
                g = gt.query(video, field, t)
                if g is None:
                    continue
                gv = norm(g[2])
                if gv == "unknown":
                    continue
                pv = norm(row.get(field))
                ok = (pv == gv)
                bump(acc.sig["exact"], ok)
                bump(total.sig["exact"], ok)
                bump(conf_acc[norm(g[3])].sig["exact"], ok)
                if gv in ("red", "yellow", "green"):
                    oc = (pv == gv)
                    bump(acc.sig["color"], oc)
                    bump(total.sig["color"], oc)
                    bump(conf_acc[norm(g[3])].sig["color"], oc)
                os_ = (sig_stopgo(pv) == sig_stopgo(gv))
                bump(acc.sig["stopgo"], os_)
                bump(total.sig["stopgo"], os_)
                bump(conf_acc[norm(g[3])].sig["stopgo"], os_)
                sig_mat[(gv, pv)] += 1
            for pf, gf, _side in LANE_PAIRS:
                g = gt.query(video, gf, t)
                if g is None:
                    continue
                gv = norm(g[2])
                if gv == "unknown":
                    continue
                gc = line_class(gv)
                pv = norm(row.get(pf))
                pc = line_class(pv)
                oc = (pc == gc)
                oe = (pv == gv)
                bump(acc.lane["cls"], oc)
                bump(total.lane["cls"], oc)
                bump(conf_acc[norm(g[3])].lane["cls"], oc)
                bump(acc.lane["exact"], oe)
                bump(total.lane["exact"], oe)
                bump(conf_acc[norm(g[3])].lane["exact"], oe)
                lane_mat[(gc, pc)] += 1
            g = gt.query(video, "ego_motion", t)
            if g is not None:
                gm = motion_class(norm(g[2]))
                pm = motion_class(norm(row.get("ego_motion")))
                ok = (pm == gm)
                bump(acc.motion, ok)
                bump(total.motion, ok)
                bump(conf_acc[norm(g[3])].motion, ok)
                motion_mat[(gm, pm)] += 1
        per_video[video] = acc
    return per_video, total, conf_acc, sig_mat, lane_mat, motion_mat


def eval_cases(states, gt, testcases, right_free, pass_ratio, edge_trim):
    recs = []
    for tc in testcases:
        cat = (tc.get("category") or "").strip()
        video = (tc.get("video") or "").strip()
        rec = {
            "case_id": (tc.get("case_id") or "").strip(),
            "video": video,
            "category": cat,
            "lane_or_side": (tc.get("lane_or_side") or "").strip(),
            "command": (tc.get("command") or "").strip(),
            "expected": (tc.get("expected") or "").strip(),
            "expected_code": expected_code(cat, tc.get("expected")),
            "t_start": (tc.get("t_start") or "").strip(),
            "t_end": (tc.get("t_end") or "").strip(),
            "conf": (tc.get("conf") or "").strip(),
            "note": (tc.get("note") or "").strip(),
            "n_frames": "",
            "match_ratio": "",
            "status": "N/A",
            "dominant_pred": "",
            "first_ok_s": "",
        }
        if cat in ("SIG", "LANE"):
            if video not in states:
                rec["status"] = "NO_RUN"
                recs.append(rec)
                continue
            try:
                t0 = float(rec["t_start"])
                t1 = float(rec["t_end"])
            except ValueError:
                rec["status"] = "NO_FRAMES"
                recs.append(rec)
                continue
            if t1 - t0 >= 1.2:
                lo, hi = t0 + edge_trim, t1 - edge_trim
            else:
                lo, hi = t0, t1
            frames = []
            for r in states[video]:
                try:
                    ft = float(r.get("t"))
                except (TypeError, ValueError):
                    continue
                if lo <= ft <= hi:
                    frames.append((ft, r))
            frames.sort(key=lambda x: x[0])
            if not frames:
                rec["status"] = "NO_FRAMES"
                recs.append(rec)
                continue
            if cat == "SIG":
                lane = LANE_MAP.get(rec["lane_or_side"])
                force_go = (rec["command"] == "按键强制行驶")
                field = "sig_" + (lane or "")
                preds = [decide_sig(lane, fr.get(field), force_go, right_free) for _, fr in frames]
            else:
                side = SIDE_MAP.get(rec["lane_or_side"])
                force = rec["command"].startswith("强制")
                field = (side or "") + "_line"
                preds = [decide_lane(side, fr.get(field), force) for _, fr in frames]
            exp = rec["expected_code"]
            n = len(preds)
            correct = sum(1 for p in preds if p == exp)
            ratio = correct / n
            rec["n_frames"] = n
            rec["match_ratio"] = "%.4f" % ratio
            rec["status"] = "PASS" if ratio >= pass_ratio else "FAIL"
            rec["dominant_pred"] = Counter(preds).most_common(1)[0][0]
            for ft, p in zip([f[0] for f in frames], preds):
                if p == exp:
                    rec["first_ok_s"] = "%.3f" % (ft - lo)
                    break
        recs.append(rec)
    return recs


def md_table(headers, rows):
    out = ["| " + " | ".join(headers) + " |",
           "| " + " | ".join(["---"] * len(headers)) + " |"]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out)


def render_md(args, states, gt, per_video, total, conf_acc,
              sig_mat, lane_mat, motion_mat, recs, missing):
    L = []
    L.append("# 参考感知 / 判决离线评测报告")
    L.append("")
    L.append("- 生成时间：%s" % datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    L.append("- runs-dir：%s" % args.runs_dir)
    L.append("- gt-dir：%s" % args.gt_dir)
    L.append("- testcases：%s" % args.testcases)
    L.append("- pass-ratio：%s；edge-trim：%s；right_free：%s"
             % (args.pass_ratio, args.edge_trim, args.right_free))
    L.append("- 已加载运行结果视频：%s" % (", ".join(sorted(states)) or "无"))
    if missing:
        L.append("- **缺少运行结果**：%s" % ", ".join(missing))
    L.append("")

    L.append("## 一、测试用例汇总")
    L.append("")
    cats = ["SIG", "LANE"]
    rows = []
    for cat in cats + ["合计"]:
        sel = [r for r in recs if (cat == "合计" and r["category"] in cats) or r["category"] == cat]
        c = Counter(r["status"] for r in sel)
        passed, failed = c.get("PASS", 0), c.get("FAIL", 0)
        participated = passed + failed
        rows.append([cat, len(sel), participated, passed, failed,
                     c.get("NO_FRAMES", 0), c.get("NO_RUN", 0),
                     pct(passed, participated)])
    L.append(md_table(["category", "总数", "参评数", "PASS", "FAIL",
                       "NO_FRAMES", "NO_RUN", "通过率"], rows))
    L.append("")

    L.append("### 按视频通过率（SIG+LANE）")
    L.append("")
    rows = []
    videos = sorted({r["video"] for r in recs if r["category"] in cats})
    for v in videos + ["合计"]:
        sel = [r for r in recs if r["category"] in cats and (v == "合计" or r["video"] == v)]
        p = sum(1 for r in sel if r["status"] == "PASS")
        f = sum(1 for r in sel if r["status"] == "FAIL")
        n = p + f
        if v != "合计" or sel:
            rows.append([v, len(sel), p, f, pct(p, n)])
    L.append(md_table(["video", "总数", "PASS", "FAIL", "通过率"], rows))
    L.append("")

    L.append("### 按 conf 通过率（SIG+LANE）")
    L.append("")
    rows = []
    for cf in ["high", "mid", "low"]:
        sel = [r for r in recs if r["category"] in cats and r["conf"] == cf]
        p = sum(1 for r in sel if r["status"] == "PASS")
        f = sum(1 for r in sel if r["status"] == "FAIL")
        n = p + f
        rows.append([cf, len(sel), p, f, pct(p, n)])
    L.append(md_table(["conf", "总数", "PASS", "FAIL", "通过率"], rows))
    L.append("")

    L.append("### FAIL 用例清单（按 match_ratio 升序）")
    L.append("")
    fails = [r for r in recs if r["status"] == "FAIL"]
    fails.sort(key=lambda r: float(r["match_ratio"]))
    if not fails:
        L.append("无 FAIL 用例。")
    else:
        rows = []
        for r in fails:
            try:
                t0 = float(r["t_start"])
                t1 = float(r["t_end"])
                if t1 - t0 >= 1.2:
                    win = "[%.2f, %.2f]" % (t0 + args.edge_trim, t1 - args.edge_trim)
                else:
                    win = "[%.2f, %.2f]" % (t0, t1)
            except ValueError:
                win = "-"
            rows.append([r["case_id"], win, r["expected_code"],
                         r["dominant_pred"], r["match_ratio"], r["note"]])
        L.append(md_table(["case_id", "窗口", "期望", "dominant_pred",
                           "match_ratio", "note"], rows))
    L.append("")

    L.append("## 二、第一部分：逐帧状态准确率")
    L.append("")

    L.append("### 信号灯逐帧准确率")
    L.append("")
    rows = []
    for v in sorted(per_video) + ["总计"]:
        a = total if v == "总计" else per_video[v]
        e, c, s = a.sig["exact"], a.sig["color"], a.sig["stopgo"]
        rows.append([v, "%d/%d (%s)" % (e[0], e[1], pct(*e)),
                     "%d/%d (%s)" % (c[0], c[1], pct(*c)),
                     "%d/%d (%s)" % (s[0], s[1], pct(*s))])
    L.append(md_table(["video", "精确一致", "颜色一致(真值红/黄/绿)",
                       "停走一致"], rows))
    L.append("")

    L.append("### 车道线逐帧准确率")
    L.append("")
    rows = []
    for v in sorted(per_video) + ["总计"]:
        a = total if v == "总计" else per_video[v]
        c, e = a.lane["cls"], a.lane["exact"]
        rows.append([v, "%d/%d (%s)" % (c[0], c[1], pct(*c)),
                     "%d/%d (%s)" % (e[0], e[1], pct(*e))])
    L.append(md_table(["video", "类型一致(虚线/实线/无)", "精确类型一致"], rows))
    L.append("")

    L.append("### 自车运动逐帧准确率")
    L.append("")
    rows = []
    for v in sorted(per_video) + ["总计"]:
        a = total if v == "总计" else per_video[v]
        m = a.motion
        rows.append([v, "%d/%d (%s)" % (m[0], m[1], pct(*m))])
    L.append(md_table(["video", "运动一致"], rows))
    L.append("")

    L.append("### 按真值 conf 统计")
    L.append("")
    rows = []
    for cf in ["high", "mid", "low"]:
        a = conf_acc.get(cf, Acc())
        rows.append([
            cf,
            pct(*a.sig["exact"]), pct(*a.sig["color"]), pct(*a.sig["stopgo"]),
            pct(*a.lane["cls"]), pct(*a.lane["exact"]),
            pct(*a.motion),
        ])
    L.append(md_table(["conf", "信号精确", "信号颜色", "信号停走",
                       "车道线类型", "车道线精确", "运动"], rows))
    L.append("")

    def mat_rows(counter):
        gts = sorted({k[0] for k in counter})
        preds = sorted({k[1] for k in counter})
        head = ["真值\\预测"] + preds + ["合计"]
        body = []
        for g in gts:
            row = [g]
            tot = 0
            for p in preds:
                val = counter.get((g, p), 0)
                row.append(val)
                tot += val
            row.append(tot)
            body.append(row)
        return md_table(head, body)

    L.append("### 混淆矩阵：信号灯（真值 x 预测，精确值）")
    L.append("")
    L.append(mat_rows(sig_mat))
    L.append("")
    L.append("### 混淆矩阵：车道线（真值 x 预测，类型）")
    L.append("")
    L.append(mat_rows(lane_mat))
    L.append("")
    L.append("### 混淆矩阵：自车运动（真值 x 预测）")
    L.append("")
    L.append(mat_rows(motion_mat))
    L.append("")
    return "\n".join(L) + "\n"


def main():
    ap = argparse.ArgumentParser(description="参考感知离线评测")
    ap.add_argument("--runs-dir", default=r"E:\Project\nesai2026\video_review\ref_runs")
    ap.add_argument("--gt-dir", default=r"E:\Project\nesai2026\video_review\gt")
    ap.add_argument("--testcases", default=r"E:\Project\nesai2026\video_review\gt\out\testcases.csv")
    ap.add_argument("--out-md", required=True)
    ap.add_argument("--out-csv", required=True)
    ap.add_argument("--pass-ratio", type=float, default=0.8)
    ap.add_argument("--edge-trim", type=float, default=0.3)
    ap.add_argument("--right-free", dest="right_free", action="store_true")
    ap.add_argument("--no-right-free", dest="right_free", action="store_false")
    ap.set_defaults(right_free=True)
    args = ap.parse_args()

    gt = GT(args.gt_dir)
    states = load_states(args.runs_dir)
    testcases = load_testcases(args.testcases)

    tc_videos = {(t.get("video") or "").strip() for t in testcases
                 if (t.get("category") or "").strip() in ("SIG", "LANE")}
    missing = sorted(v for v in tc_videos if v and v not in states)

    per_video, total, conf_acc, sig_mat, lane_mat, motion_mat = frame_stats(states, gt)
    recs = eval_cases(states, gt, testcases, args.right_free,
                      args.pass_ratio, args.edge_trim)

    os.makedirs(os.path.dirname(os.path.abspath(args.out_csv)), exist_ok=True)
    os.makedirs(os.path.dirname(os.path.abspath(args.out_md)), exist_ok=True)
    with open(args.out_csv, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(CSV_COLUMNS)
        for r in recs:
            w.writerow([r.get(c, "") for c in CSV_COLUMNS])

    md = render_md(args, states, gt, per_video, total, conf_acc,
                   sig_mat, lane_mat, motion_mat, recs, missing)
    with open(args.out_md, "w", encoding="utf-8", newline="") as f:
        f.write(md)

    cats = ("SIG", "LANE")
    passed = sum(1 for r in recs if r["category"] in cats and r["status"] == "PASS")
    failed = sum(1 for r in recs if r["category"] in cats and r["status"] == "FAIL")
    print("评测完成：SIG+LANE PASS=%d FAIL=%d；报告 %s" % (passed, failed, args.out_md))
    if missing:
        print("缺少运行结果：%s" % ", ".join(missing))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
