# -*- coding: utf-8 -*-
"""板端评测运行脚本：调用 eval_ref.py 或执行独立评测生成报告。

功能：
  1. 默认对 runs_dir 调用 eval_ref.py 产出用例判决与逐帧准确率报告到 out_md。
  2. 若指定 --skip-low 或 --standalone，执行轻量独立评测（逐秒对齐 GT 区间）：
     - SIG：按左/直/右分别统计 exact（精确一致）与 stop/go（停走一致）一致率
     - LANE：按左右线 dashed/solid/none 分类准确率
     - --skip-low：忽略真值标注中 conf=low 的区间
"""

import argparse
import csv
import glob
import os
import subprocess
import sys
from collections import defaultdict
from datetime import datetime

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

SIG_STOP = {"red", "yellow"}
SIG_GO = {"green", "none", "off"}


def norm(v):
    return (v or "").strip().lower()


def sig_stopgo(v):
    nv = norm(v)
    if nv in SIG_STOP:
        return "STOP"
    if nv in SIG_GO:
        return "GO"
    return nv


def line_class(line_type):
    lt = norm(line_type)
    if lt in {"white_dashed", "yellow_dashed", "dashed"}:
        return "dashed"
    if lt in {"white_solid", "yellow_solid", "double_yellow", "solid"}:
        return "solid"
    return "none"


def motion_class(v):
    nv = norm(v)
    if nv == "stopped":
        return "stopped"
    if nv in ("moving", "braking", "starting"):
        return "moving"
    return nv


def pct(ok, n):
    return "-" if n == 0 else f"{100.0 * ok / n:.1f}%"


class StandaloneGT:
    def __init__(self, gt_dir, skip_low=False):
        self.rows = defaultdict(lambda: defaultdict(list))
        self.skip_low = skip_low
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
                    conf = norm(r.get("conf"))
                    if not video or not field:
                        continue
                    if self.skip_low and conf == "low":
                        continue
                    val = norm(r.get("value"))
                    self.rows[video][field].append((t0, t1, val, conf))

    def query(self, video, field, t):
        best = None
        for r in self.rows.get(video, {}).get(field, []):
            if r[0] <= t <= r[1]:
                if best is None or r[0] >= best[0]:
                    best = r
        return best


def load_states(runs_dir):
    states = {}
    if not os.path.isdir(runs_dir):
        return states
    for sub in sorted(os.listdir(runs_dir)):
        p = os.path.join(runs_dir, sub, "states.csv")
        if os.path.isfile(p):
            with open(p, "r", encoding="utf-8-sig", newline="") as f:
                states[sub] = list(csv.DictReader(f))
    return states


def run_standalone_eval(states, gt, skip_low):
    """逐秒对齐 GT 区间统计：SIG(左/直/右 exact 与 stopgo)、LANE(左/右 cls)、MOTION。"""
    results = {}
    total_stats = {
        "sig_left_exact": [0, 0], "sig_left_stopgo": [0, 0],
        "sig_straight_exact": [0, 0], "sig_straight_stopgo": [0, 0],
        "sig_right_exact": [0, 0], "sig_right_stopgo": [0, 0],
        "lane_left_cls": [0, 0], "lane_right_cls": [0, 0],
        "motion": [0, 0]
    }

    def bump(pair, ok):
        pair[1] += 1
        if ok:
            pair[0] += 1

    for video, rows in sorted(states.items()):
        vstats = {
            "sig_left_exact": [0, 0], "sig_left_stopgo": [0, 0],
            "sig_straight_exact": [0, 0], "sig_straight_stopgo": [0, 0],
            "sig_right_exact": [0, 0], "sig_right_stopgo": [0, 0],
            "lane_left_cls": [0, 0], "lane_right_cls": [0, 0],
            "motion": [0, 0]
        }
        for r in rows:
            try:
                t = float(r.get("t"))
            except (TypeError, ValueError):
                continue

            # 1. SIG
            for d in ("left", "straight", "right"):
                field = f"sig_{d}"
                g = gt.query(video, field, t)
                if g is not None:
                    gv = g[2]
                    if gv not in ("unknown", ""):
                        pv = norm(r.get(field))
                        exact_ok = (pv == gv)
                        stopgo_ok = (sig_stopgo(pv) == sig_stopgo(gv))
                        bump(vstats[f"sig_{d}_exact"], exact_ok)
                        bump(total_stats[f"sig_{d}_exact"], exact_ok)
                        bump(vstats[f"sig_{d}_stopgo"], stopgo_ok)
                        bump(total_stats[f"sig_{d}_stopgo"], stopgo_ok)

            # 2. LANE
            for pf, gf, k in (("left_line", "ego_left_line", "lane_left_cls"),
                              ("right_line", "ego_right_line", "lane_right_cls")):
                g = gt.query(video, gf, t)
                if g is not None:
                    gv = g[2]
                    if gv not in ("unknown", ""):
                        gc = line_class(gv)
                        pc = line_class(r.get(pf))
                        cls_ok = (pc == gc)
                        bump(vstats[k], cls_ok)
                        bump(total_stats[k], cls_ok)

            # 3. MOTION
            g = gt.query(video, "ego_motion", t)
            if g is not None:
                gv = g[2]
                if gv not in ("unknown", ""):
                    gm = motion_class(gv)
                    pm = motion_class(r.get("ego_motion"))
                    mot_ok = (pm == gm)
                    bump(vstats["motion"], mot_ok)
                    bump(total_stats["motion"], mot_ok)

        results[video] = vstats

    return results, total_stats


def md_table(headers, rows):
    out = ["| " + " | ".join(headers) + " |",
           "| " + " | ".join(["---"] * len(headers)) + " |"]
    for r in rows:
        out.append("| " + " | ".join(str(c) for c in r) + " |")
    return "\n".join(out)


def render_standalone_md(args, states, results, total_stats):
    L = []
    L.append("# 板端感知离线评测报告（独立评测模式）")
    L.append("")
    L.append(f"- 生成时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    L.append(f"- runs-dir：{args.runs_dir}")
    L.append(f"- gt-dir：{args.gt_dir}")
    L.append(f"- skip-low：{args.skip_low}（{'已忽略' if args.skip_low else '未忽略'} conf=low 真值区间）")
    L.append(f"- 已加载视频：{', '.join(sorted(states)) or '无'}")
    L.append("")

    L.append("## 一、信号灯逐方向准确率（按左/直/右分别统计）")
    L.append("")
    sig_headers = ["video", "左转Exact", "左转StopGo", "直行Exact", "直行StopGo", "右转Exact", "右转StopGo"]
    rows = []
    for v in sorted(results) + ["总计"]:
        s = total_stats if v == "总计" else results[v]
        rows.append([
            v,
            f"{s['sig_left_exact'][0]}/{s['sig_left_exact'][1]} ({pct(*s['sig_left_exact'])})",
            f"{s['sig_left_stopgo'][0]}/{s['sig_left_stopgo'][1]} ({pct(*s['sig_left_stopgo'])})",
            f"{s['sig_straight_exact'][0]}/{s['sig_straight_exact'][1]} ({pct(*s['sig_straight_exact'])})",
            f"{s['sig_straight_stopgo'][0]}/{s['sig_straight_stopgo'][1]} ({pct(*s['sig_straight_stopgo'])})",
            f"{s['sig_right_exact'][0]}/{s['sig_right_exact'][1]} ({pct(*s['sig_right_exact'])})",
            f"{s['sig_right_stopgo'][0]}/{s['sig_right_stopgo'][1]} ({pct(*s['sig_right_stopgo'])})",
        ])
    L.append(md_table(sig_headers, rows))
    L.append("")

    L.append("## 二、车道线左右线分类准确率（dashed / solid / none）")
    L.append("")
    lane_headers = ["video", "左线类型一致", "右线类型一致", "综合一致"]
    rows = []
    for v in sorted(results) + ["总计"]:
        s = total_stats if v == "总计" else results[v]
        l_ok, l_tot = s["lane_left_cls"]
        r_ok, r_tot = s["lane_right_cls"]
        tot_ok = l_ok + r_ok
        tot_n = l_tot + r_tot
        rows.append([
            v,
            f"{l_ok}/{l_tot} ({pct(l_ok, l_tot)})",
            f"{r_ok}/{r_tot} ({pct(r_ok, r_tot)})",
            f"{tot_ok}/{tot_n} ({pct(tot_ok, tot_n)})",
        ])
    L.append(md_table(lane_headers, rows))
    L.append("")

    L.append("## 三、自车运动准确率（moving / stopped）")
    L.append("")
    mot_headers = ["video", "运动一致", "准确率"]
    rows = []
    for v in sorted(results) + ["总计"]:
        s = total_stats if v == "总计" else results[v]
        m = s["motion"]
        rows.append([v, f"{m[0]}/{m[1]}", pct(*m)])
    L.append(md_table(mot_headers, rows))
    L.append("")

    return "\n".join(L) + "\n"


def print_standalone_summary(total_stats):
    sl_e, sl_s = total_stats["sig_left_exact"], total_stats["sig_left_stopgo"]
    ss_e, ss_s = total_stats["sig_straight_exact"], total_stats["sig_straight_stopgo"]
    sr_e, sr_s = total_stats["sig_right_exact"], total_stats["sig_right_stopgo"]
    ll_c, lr_c = total_stats["lane_left_cls"], total_stats["lane_right_cls"]
    mot = total_stats["motion"]

    lane_tot_ok = ll_c[0] + lr_c[0]
    lane_tot_n = ll_c[1] + lr_c[1]

    print("\n[独立评测指标统计]")
    print(f"  SIG 左转: Exact={pct(*sl_e)} ({sl_e[0]}/{sl_e[1]}) | StopGo={pct(*sl_s)} ({sl_s[0]}/{sl_s[1]})")
    print(f"  SIG 直行: Exact={pct(*ss_e)} ({ss_e[0]}/{ss_e[1]}) | StopGo={pct(*ss_s)} ({ss_s[0]}/{ss_s[1]})")
    print(f"  SIG 右转: Exact={pct(*sr_e)} ({sr_e[0]}/{sr_e[1]}) | StopGo={pct(*sr_s)} ({sr_s[0]}/{sr_s[1]})")
    print(f"  LANE: 左线={pct(*ll_c)} | 右线={pct(*lr_c)} | 综合={pct(lane_tot_ok, lane_tot_n)}")
    print(f"  MOTION: {pct(*mot)} ({mot[0]}/{mot[1]})")


def main():
    root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    default_runs = os.path.join(root_dir, "tools", "board_eval", "out")
    default_gt = os.path.join(root_dir, "video_review", "gt")
    default_cases = os.path.join(root_dir, "video_review", "gt", "out", "testcases.csv")
    default_out_md = os.path.join(root_dir, "tools", "board_eval", "out", "report.md")
    default_out_csv = os.path.join(root_dir, "tools", "board_eval", "out", "report.csv")

    parser = argparse.ArgumentParser(description="板端评测执行器 (调用 eval_ref.py 或执行独立评测)")
    parser.add_argument("--runs-dir", default=default_runs, help=f"states 根目录 (默认: {default_runs})")
    parser.add_argument("--gt-dir", default=default_gt, help=f"真值目录 (默认: {default_gt})")
    parser.add_argument("--testcases", default=default_cases, help=f"用例文件路径 (默认: {default_cases})")
    parser.add_argument("--out-md", default=default_out_md, help=f"输出报告 Markdown (默认: {default_out_md})")
    parser.add_argument("--out-csv", default=default_out_csv, help=f"输出用例结果 CSV (默认: {default_out_csv})")
    parser.add_argument("--pass-ratio", type=float, default=0.8, help="通过阈值 (默认: 0.8)")
    parser.add_argument("--edge-trim", type=float, default=0.3, help="两端裁切秒数 (默认: 0.3)")
    parser.add_argument("--skip-low", action="store_true", help="忽略 conf=low 的真值区间（启用独立评测模式）")
    parser.add_argument("--standalone", action="store_true", help="强制使用独立评测模式")

    args = parser.parse_args()

    states = load_states(args.runs_dir)
    if not states:
        print(f"[ERROR] 未在 {args.runs_dir} 发现任何有效 <vid>/states.csv", file=sys.stderr)
        return 1

    os.makedirs(os.path.dirname(os.path.abspath(args.out_md)), exist_ok=True)
    os.makedirs(os.path.dirname(os.path.abspath(args.out_csv)), exist_ok=True)

    use_standalone = args.standalone or args.skip_low

    if not use_standalone:
        eval_ref_py = os.path.join(root_dir, "tools", "ref_algo", "eval_ref.py")
        if os.path.isfile(eval_ref_py) and os.path.isfile(args.testcases):
            cmd = [
                sys.executable, eval_ref_py,
                "--runs-dir", args.runs_dir,
                "--gt-dir", args.gt_dir,
                "--testcases", args.testcases,
                "--out-md", args.out_md,
                "--out-csv", args.out_csv,
                "--pass-ratio", str(args.pass_ratio),
                "--edge-trim", str(args.edge_trim),
            ]
            print(f"调用参考评测: {' '.join(cmd)}")
            proc = subprocess.run(cmd)
            if proc.returncode == 0:
                # 同时附带打印独立分项指标供直观参考
                gt = StandaloneGT(args.gt_dir, skip_low=False)
                res, tot = run_standalone_eval(states, gt, skip_low=False)
                print_standalone_summary(tot)
                return 0
            print("[WARN] eval_ref.py 运行失败，切换至独立评测模式...", file=sys.stderr)

    # 独立评测模式 (逐秒对齐 GT 区间)
    print(f"运行独立评测模式 (skip_low={args.skip_low})...")
    gt = StandaloneGT(args.gt_dir, skip_low=args.skip_low)
    results, total_stats = run_standalone_eval(states, gt, skip_low=args.skip_low)

    md_content = render_standalone_md(args, states, results, total_stats)
    with open(args.out_md, "w", encoding="utf-8") as f:
        f.write(md_content)

    # 输出 CSV 结果
    with open(args.out_csv, "w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f)
        w.writerow(["video", "sig_left_exact", "sig_left_stopgo",
                    "sig_straight_exact", "sig_straight_stopgo",
                    "sig_right_exact", "sig_right_stopgo",
                    "lane_left_cls", "lane_right_cls", "motion"])
        for v in sorted(results):
            s = results[v]
            w.writerow([
                v,
                pct(*s["sig_left_exact"]), pct(*s["sig_left_stopgo"]),
                pct(*s["sig_straight_exact"]), pct(*s["sig_straight_stopgo"]),
                pct(*s["sig_right_exact"]), pct(*s["sig_right_stopgo"]),
                pct(*s["lane_left_cls"]), pct(*s["lane_right_cls"]),
                pct(*s["motion"]),
            ])

    print_standalone_summary(total_stats)
    print(f"独立评测完成，报告已生成至 {args.out_md}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
