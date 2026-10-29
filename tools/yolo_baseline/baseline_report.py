import argparse
import csv
import json
import os
from collections import defaultdict
from datetime import datetime

HIST_BUCKETS = ["<8", "8-16", "16-32", "32-64", ">=64"]
REPORT_CLASSES = ["person", "rider", "car", "bus", "truck", "tl_ref"]
ALL_CLASSES = ["person", "rider", "car", "bus", "truck", "tl_ref", "other_ref"]


def build_parser():
    p = argparse.ArgumentParser(description="Generate Chinese Markdown baseline report")
    p.add_argument("--a", required=True, help="full-video 640 run out-dir")
    p.add_argument("--b", default=None, help="snapshot-only 1280 run out-dir")
    p.add_argument("--timeline", default=None, help="timeline CSV")
    p.add_argument("--iou", type=float, default=0.5)
    p.add_argument("--out", required=True, help="output markdown path")
    return p


def load_summary(run_dir):
    with open(os.path.join(run_dir, "summary.json"), "r", encoding="utf-8") as f:
        return json.load(f)


def load_detections(run_dir):
    path = os.path.join(run_dir, "detections.csv")
    rows = []
    with open(path, "r", encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            rows.append({
                "frame": int(r["frame"]),
                "t": float(r["t"]),
                "proj_cls": r["proj_cls"],
                "src": r["src"],
                "conf": float(r["conf"]),
                "x1": float(r["x1"]),
                "y1": float(r["y1"]),
                "x2": float(r["x2"]),
                "y2": float(r["y2"]),
                "h640": float(r["h640"]),
            })
    return rows


def pct(num, den):
    if den <= 0:
        return "—"
    return f"{100.0 * num / den:.1f}%"


def fmt_num(x, digits=1):
    return f"{x:.{digits}f}"


def section1(lines, label, run_dir, summary):
    lines.append(f"### {label}：`{run_dir}`")
    lines.append("")
    lines.append("| 参数 | 值 |")
    lines.append("| --- | --- |")
    lines.append(f"| imgsz | {summary['imgsz']} |")
    lines.append(f"| frames_total | {summary['frames_total']} |")
    lines.append(f"| frames_inferred | {summary['frames_inferred']} |")
    lines.append(f"| infer_ms_mean | {summary['infer_ms_mean']} |")
    lines.append(f"| infer_ms_p95 | {summary['infer_ms_p95']} |")
    lines.append("")
    lines.append("| 类别 | boxes | frames_with | frames_with/frames_inferred | mean_per_frame | "
                 + " | ".join(f"h640 {b}" for b in HIST_BUCKETS) + " |")
    lines.append("| --- | --- | --- | --- | --- | " + " | ".join("---" for _ in HIST_BUCKETS) + " |")
    fi = summary["frames_inferred"]
    for c in ALL_CLASSES:
        d = summary["classes"][c]
        hist = d["h640_hist"]
        row = (f"| {c} | {d['boxes']} | {d['frames_with']} | "
               f"{pct(d['frames_with'], fi)} | {d['mean_per_frame']} | "
               + " | ".join(str(hist.get(b, 0)) for b in HIST_BUCKETS) + " |")
        lines.append(row)
    lines.append("")
    raw = summary.get("raw_coco_counts", {})
    lines.append("原始 COCO 框数：" + "，".join(f"{k} {v}" for k, v in raw.items()))
    lines.append("")


def iou(a, b):
    ix1 = max(a["x1"], b["x1"])
    iy1 = max(a["y1"], b["y1"])
    ix2 = min(a["x2"], b["x2"])
    iy2 = min(a["y2"], b["y2"])
    iw = max(0.0, ix2 - ix1)
    ih = max(0.0, iy2 - iy1)
    inter = iw * ih
    if inter <= 0:
        return 0.0
    area_a = max(0.0, a["x2"] - a["x1"]) * max(0.0, a["y2"] - a["y1"])
    area_b = max(0.0, b["x2"] - b["x1"]) * max(0.0, b["y2"] - b["y1"])
    union = area_a + area_b - inter
    return inter / union if union > 0 else 0.0


def hist_index(h640):
    if h640 < 8:
        return 0
    if h640 < 16:
        return 1
    if h640 < 32:
        return 2
    if h640 < 64:
        return 3
    return 4


def section2(lines, a_dir, b_dir, sa, sb, dets_a, dets_b, iou_thr):
    lines.append("## 2 640 对 1280 分辨率对照")
    lines.append("")
    common = sorted(set(sa["snap_frames"]) & set(sb["snap_frames"]))
    lines.append(f"a/b 快照帧交集：{len(common)} 帧（" +
                 (", ".join(str(x) for x in common) if common else "无") + "）")
    lines.append("")

    def group(rows):
        g = defaultdict(lambda: defaultdict(list))
        for d in rows:
            if d["frame"] in common:
                g[d["frame"]][d["proj_cls"]].append(d)
        return g

    ga = group(dets_a)
    gb = group(dets_b)

    lines.append("| 类别 | n_b | 匹配数 | a 相对 b 的召回率 | n_a | a 独有框数 |")
    lines.append("| --- | --- | --- | --- | --- | --- |")
    bucket_rows = []
    for c in REPORT_CLASSES:
        n_b = 0
        n_a = 0
        matches = 0
        b_bucket_n = [0] * 5
        b_bucket_m = [0] * 5
        for fr in common:
            bs = gb[fr].get(c, [])
            as_ = ga[fr].get(c, [])
            n_b += len(bs)
            n_a += len(as_)
            pairs = []
            for bi, bb in enumerate(bs):
                b_bucket_n[hist_index(bb["h640"])] += 1
                for ai, aa in enumerate(as_):
                    v = iou(aa, bb)
                    if v >= iou_thr:
                        pairs.append((v, ai, bi))
            pairs.sort(key=lambda x: -x[0])
            used_a = set()
            used_b = set()
            for v, ai, bi in pairs:
                if ai in used_a or bi in used_b:
                    continue
                used_a.add(ai)
                used_b.add(bi)
                matches += 1
                b_bucket_m[hist_index(bs[bi]["h640"])] += 1
        lines.append(f"| {c} | {n_b} | {matches} | {pct(matches, n_b)} | {n_a} | {n_a - matches} |")
        bucket_rows.append((c, b_bucket_n, b_bucket_m))
    lines.append("")
    lines.append("按 1280（b）框的 h640 分桶：")
    lines.append("")
    lines.append("| 类别 | h640 桶 | n_b | 匹配数 |")
    lines.append("| --- | --- | --- | --- |")
    for c, bn, bm in bucket_rows:
        for k, b in enumerate(HIST_BUCKETS):
            lines.append(f"| {c} | {b} | {bn[k]} | {bm[k]} |")
    lines.append("")
    lines.append("以 1280 结果作参照，只反映缩到 640 造成的漏检，不是相对真值的绝对召回率。")
    lines.append("")


def section3(lines, a_dir, sa, dets_a, timeline_path):
    lines.append("## 3 危险事件区间检出情况")
    lines.append("")
    video_path = sa["video"]
    width = sa["width"]
    height = sa["height"]
    fps = sa["fps"]
    total = sa["frames_total"]
    by_frame = defaultdict(list)
    for d in dets_a:
        by_frame[d["frame"]].append(d)

    rows = []
    with open(timeline_path, "r", encoding="utf-8-sig", newline="") as f:
        for r in csv.DictReader(f):
            if r.get("field") != "hazard":
                continue
            v = (r.get("video") or "").strip()
            if v and v not in video_path:
                continue
            rows.append(r)

    lines.append("| value | t_start–t_end | conf | 帧数 | 命中帧比例 | 最大 h640 |")
    lines.append("| --- | --- | --- | --- | --- | --- |")
    for r in rows:
        value = r["value"]
        t0 = float(r["t_start"])
        t1 = float(r["t_end"])
        if value in ("ped_in_path", "ped_crossing_near"):
            targets = {"person", "rider"}
        elif value in ("lead_close", "cut_in", "obstacle_in_lane"):
            targets = {"car", "bus", "truck"}
        else:
            targets = set()
        frames = [fr for fr in range(total) if t0 <= fr / fps <= t1]
        hit = 0
        max_h = None
        for fr in frames:
            found = False
            for d in by_frame.get(fr, []):
                if d["proj_cls"] not in targets:
                    continue
                cx = (d["x1"] + d["x2"]) / 2.0
                if width / 3.0 <= cx <= 2.0 * width / 3.0 and d["y2"] >= 0.4 * height:
                    found = True
                    if max_h is None or d["h640"] > max_h:
                        max_h = d["h640"]
            if found:
                hit += 1
        lines.append(f"| {value} | {t0:.1f}–{t1:.1f} | {r.get('conf', '')} | {len(frames)} | "
                     f"{pct(hit, len(frames))} | {fmt_num(max_h) if max_h is not None else '—'} |")
    if not rows:
        lines.append("| （无匹配的 hazard 行） | — | — | — | — | — |")
    lines.append("")


def section4(lines, sa, dets_a):
    lines.append("## 4 按 5 秒分段的平均目标数")
    lines.append("")
    fps = sa["fps"]
    total = sa["frames_total"]
    step = max(1, int(round(5.0 * fps)))
    counts = defaultdict(lambda: defaultdict(int))
    for d in dets_a:
        seg = d["frame"] // step
        counts[seg][d["proj_cls"]] += 1

    lines.append("| 区间 | " + " | ".join(REPORT_CLASSES) + " |")
    lines.append("| --- | " + " | ".join("---" for _ in REPORT_CLASSES) + " |")
    for seg_start in range(0, total, step):
        seg = seg_start // step
        n_frames = min(step, total - seg_start)
        if n_frames <= 0:
            continue
        cells = []
        for c in REPORT_CLASSES:
            cells.append(f"{counts[seg].get(c, 0) / n_frames:.2f}")
        lines.append(f"| {seg_start / fps:.0f}–{(seg_start + n_frames) / fps:.0f}s | "
                     + " | ".join(cells) + " |")
    lines.append("")


def main():
    args = build_parser().parse_args()
    sa = load_summary(args.a)
    dets_a = load_detections(args.a)
    sb = load_summary(args.b) if args.b else None
    dets_b = load_detections(args.b) if args.b else None

    lines = []
    lines.append("# COCO yolo11n 基线报告")
    lines.append("")
    lines.append(f"- a 目录（全片 640）：`{args.a}`")
    if args.b:
        lines.append(f"- b 目录（仅快照帧 1280）：`{args.b}`")
    else:
        lines.append("- b 目录：未提供")
    lines.append(f"- 生成时间：{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    lines.append("")
    lines.append("## 1 运行概况")
    lines.append("")
    section1(lines, "A（全片 640）", args.a, sa)
    if args.b:
        section1(lines, "B（仅快照帧 1280）", args.b, sb)

    if args.b:
        section2(lines, args.a, args.b, sa, sb, dets_a, dets_b, args.iou)

    if args.timeline:
        section3(lines, args.a, sa, dets_a, args.timeline)

    section4(lines, sa, dets_a)

    lines.append("## 5 COCO 无法覆盖的目标类")
    lines.append("")
    lines.append("以下四类目标在 COCO 中没有对应类别，当前基线必然漏检，需层 B 标注后训练：")
    lines.append("")
    lines.append("- tricycle（三轮车）")
    lines.append("- cone（锥桶）")
    lines.append("- barrier（水马/围挡）")
    lines.append("- speed_limit（限速牌）")
    lines.append("")
    lines.append("## 6 人工抽查")
    lines.append("")
    lines.append("（待人工填写）")
    lines.append("")

    out_path = args.out
    parent = os.path.dirname(os.path.abspath(out_path))
    os.makedirs(parent, exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))
    print(f"[done] report written: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
