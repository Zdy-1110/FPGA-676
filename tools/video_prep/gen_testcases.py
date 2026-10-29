#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate test cases from hand-written event-timeline ground truth.

Reads every ``*_timeline.csv`` under ``--gt`` (files starting with ``_`` are
ignored), validates them, then emits ``testcases.csv`` and ``testcases.md``
under ``--out`` according to the signal / lane-change / navigation / hazard /
speed-limit rules described in the project spec.

Standard library only.
"""
import argparse
import csv
import glob
import os
import sys

COLUMNS = ["video", "t_start", "t_end", "field", "value", "conf", "note"]

FIELD_VALUES = {
    "sig_left": {"red", "yellow", "green", "off", "none", "unknown"},
    "sig_straight": {"red", "yellow", "green", "off", "none", "unknown"},
    "sig_right": {"red", "yellow", "green", "off", "none", "unknown"},
    "junction": {"approach", "at_stop_line", "crossing", "none"},
    "ego_motion": {"moving", "braking", "stopped", "starting"},
    "ego_left_line": {"white_dashed", "white_solid", "yellow_solid",
                      "double_yellow", "curb", "none", "unknown"},
    "ego_right_line": {"white_dashed", "white_solid", "yellow_solid",
                       "double_yellow", "curb", "none", "unknown"},
    "lane_change": {"left", "right"},
    "nav_maneuver": {"left", "right", "straight", "uturn",
                     "keep_left", "keep_right"},
    "hazard": {"ped_in_path", "ped_crossing_near", "lead_close",
               "obstacle_in_lane", "cut_in"},
    "comment": None,
    "nav_dist_m": "number",
    "speed_limit": "number",
}

CONF_ORDER = {"high": 0, "mid": 1, "low": 2}

LANE_DEF = [("sig_left", "左", "LED0"), ("sig_straight", "直", "LED1"),
            ("sig_right", "右", "LED2")]
SOLID_LINES = {"white_solid", "yellow_solid", "double_yellow", "curb"}
JUNCTION_ACTIVE = {"approach", "at_stop_line", "crossing"}
# 只有路口内部（crossing）不考变道；路口前的实线段正是"实线禁止变道"的主要考点
JUNCTION_BLOCKERS = {"crossing"}
MIN_SPAN = 0.5  # 短于该时长（秒）的交集不生成区间用例
DIR_NAME = {"left": "左", "right": "右", "straight": "直",
            "uturn": "掉头", "keep_left": "靠左", "keep_right": "靠右"}


class Row(object):
    __slots__ = ("video", "t_start", "t_end", "field", "value", "conf",
                 "note", "lineno", "path")

    def __init__(self, **kw):
        for k, v in kw.items():
            setattr(self, k, v)


def fmt_time(v):
    s = "%.2f" % v
    s = s.rstrip("0")
    if s.endswith("."):
        s += "0"
    return s


def intersect(a, b):
    s = max(a[0], b[0])
    e = min(a[1], b[1])
    if s <= e:
        return (s, e)
    return None


def subtract(interval, blockers):
    segs = [interval]
    for bs, be in blockers:
        nxt = []
        for s, e in segs:
            inter = intersect((s, e), (bs, be))
            if inter is None:
                nxt.append((s, e))
            else:
                if s < inter[0]:
                    nxt.append((s, inter[0]))
                if inter[1] < e:
                    nxt.append((inter[1], e))
        segs = nxt
    return segs


def parse_number(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def load_and_validate(gt_dir, lenient):
    """Return (rows, errors, files_ok)."""
    paths = sorted(glob.glob(os.path.join(gt_dir, "*_timeline.csv")))
    paths = [p for p in paths if not os.path.basename(p).startswith("_")]
    rows = []
    errors = []
    if not paths:
        errors.append("%s: 未找到 *_timeline.csv" % gt_dir)
    for path in paths:
        try:
            with open(path, "r", newline="", encoding="utf-8-sig") as fh:
                reader = csv.reader(fh)
                header = next(reader, None)
                if header is None:
                    errors.append("%s:1: 空文件" % path)
                    continue
                header = [h.strip() for h in header]
                if header != COLUMNS:
                    errors.append("%s:1: 列名不匹配，期望 %s，实际 %s"
                                  % (path, ",".join(COLUMNS),
                                     ",".join(header)))
                    continue
                for i, raw in enumerate(reader, start=2):
                    if not raw or all(c.strip() == "" for c in raw):
                        continue
                    if len(raw) > len(COLUMNS):
                        errors.append("%s:%d: 列数过多（%d>%d）"
                                      % (path, i, len(raw), len(COLUMNS)))
                        continue
                    raw = raw + [""] * (len(COLUMNS) - len(raw))
                    rec = dict(zip(COLUMNS, [c.strip() for c in raw]))
                    _validate_record(path, i, rec, errors)
                    if errors and errors[-1].startswith("%s:%d:" % (path, i)):
                        continue
                    ts = parse_number(rec["t_start"])
                    te = parse_number(rec["t_end"])
                    rows.append(Row(video=rec["video"], t_start=ts, t_end=te,
                                    field=rec["field"], value=rec["value"],
                                    conf=rec["conf"], note=rec["note"],
                                    lineno=i, path=path))
        except OSError as exc:
            errors.append("%s:0: 无法读取 (%s)" % (path, exc))
    return rows, errors


def _validate_record(path, lineno, rec, errors):
    def bad(reason):
        errors.append("%s:%d: %s" % (path, lineno, reason))

    if rec["field"] not in FIELD_VALUES:
        bad("未知 field '%s'" % rec["field"])
        return
    if rec["conf"] not in CONF_ORDER:
        bad("非法 conf '%s'（应为 high/mid/low）" % rec["conf"])
    ts = parse_number(rec["t_start"])
    te = parse_number(rec["t_end"])
    if ts is None:
        bad("t_start 非数字 '%s'" % rec["t_start"])
    if te is None:
        bad("t_end 非数字 '%s'" % rec["t_end"])
    if ts is not None and te is not None and ts > te:
        bad("t_start>t_end (%s>%s)" % (fmt_time(ts), fmt_time(te)))
    allowed = FIELD_VALUES[rec["field"]]
    if allowed == "number":
        if parse_number(rec["value"]) is None:
            bad("field '%s' 的 value 应为数字，实际 '%s'"
                % (rec["field"], rec["value"]))
    elif allowed is not None and rec["value"] not in allowed:
        bad("field '%s' 的 value 非法 '%s'" % (rec["field"], rec["value"]))


class Generator(object):
    def __init__(self, rows, opts):
        self.rows = rows
        self.opts = opts
        self.video_order = []
        for r in rows:
            if r.video not in self.video_order:
                self.video_order.append(r.video)
        self.by_video = {}
        for r in rows:
            self.by_video.setdefault(r.video, []).append(r)
        self.cases = []
        self.counters = {}
        self.uncovered = {}
        self.basis_rows = {}

    def _next_id(self, cat, video):
        key = (cat, video)
        self.counters[key] = self.counters.get(key, 0) + 1
        return "%s-%s-%02d" % (cat, video, self.counters[key])

    def _min_conf(self, rows):
        return max(rows, key=lambda r: CONF_ORDER[r.conf]).conf

    def add(self, cat, video, t_start, t_end, lane_or_side, command,
            expected, basis, note):
        case = {
            "case_id": self._next_id(cat, video),
            "video": video,
            "t_start": fmt_time(t_start),
            "t_end": fmt_time(t_end),
            "category": cat,
            "lane_or_side": lane_or_side,
            "command": command,
            "expected": expected,
            "basis": ";".join(str(r.lineno) for r in basis),
            "conf": self._min_conf(basis),
            "note": note,
        }
        self.cases.append(case)
        for r in basis:
            self.basis_rows[id(r)] = r
        return case

    def mark_uncovered(self, video, t_start, t_end, reason, basis):
        self.uncovered.setdefault(video, []).append(
            (fmt_time(t_start), fmt_time(t_end), reason,
             ";".join(str(r.lineno) for r in basis)))

    def select(self, video, field):
        return [r for r in self.by_video.get(video, []) if r.field == field]

    # ---- rule A: signal lights ------------------------------------------
    def gen_signal(self):
        for video in self.video_order:
            junctions = self.select(video, "junction")
            for j in junctions:
                if j.value not in JUNCTION_ACTIVE:
                    continue
                jiv = (j.t_start, j.t_end)
                for field, lane, led in LANE_DEF:
                    use_field = field
                    right_free = self.opts.right_free
                    if lane == "右" and not right_free:
                        use_field = "sig_straight"
                    for s in self.select(video, use_field):
                        inter = intersect(jiv, (s.t_start, s.t_end))
                        if inter is None or inter[1] - inter[0] < MIN_SPAN:
                            continue
                        basis = [j, s]
                        val = s.value
                        if val in ("red", "yellow"):
                            self.add("SIG", video, inter[0], inter[1], lane,
                                     "无/停止", "停车，不亮方向灯",
                                     basis, "灯=%s" % val)
                            self.add("SIG", video, inter[0], inter[1], lane,
                                     "按键强制行驶",
                                     "报警（LED3/红色叠加）",
                                     basis, "灯=%s 强制通过" % val)
                        elif val == "green":
                            self.add("SIG", video, inter[0], inter[1], lane,
                                     "行驶",
                                     "通行，亮%s方向LED（%s）并叠加箭头"
                                     % (lane, led), basis, "灯=green")
                        elif val == "none":
                            if lane == "右" and right_free:
                                self.add("SIG", video, inter[0], inter[1],
                                         lane, "行驶",
                                         "右转不受灯控，通行（LED2）",
                                         basis, "口径待组委会确认")
                            else:
                                self.mark_uncovered(
                                    video, inter[0], inter[1],
                                    "%s灯头=none（无对应规则）" % lane, basis)
                        else:  # unknown / off
                            self.mark_uncovered(
                                video, inter[0], inter[1],
                                "%s灯=%s" % (lane, val), basis)

    # ---- rule B: lane change --------------------------------------------
    def gen_lane_change(self):
        for video in self.video_order:
            movings = [r for r in self.select(video, "ego_motion")
                       if r.value == "moving"]
            blockers = [r for r in self.select(video, "junction")
                        if r.value in JUNCTION_BLOCKERS]
            for m in movings:
                blks = [(b.t_start, b.t_end) for b in blockers
                        if intersect((m.t_start, m.t_end),
                                     (b.t_start, b.t_end)) is not None]
                segs = subtract((m.t_start, m.t_end), blks)
                if not segs:
                    self.mark_uncovered(video, m.t_start, m.t_end,
                                        "moving 区间被路口占满", [m])
                    continue
                for side, field, led in (("左", "ego_left_line", "LED0"),
                                         ("右", "ego_right_line", "LED2")):
                    for ln in self.select(video, field):
                        for seg in segs:
                            inter = intersect(seg, (ln.t_start, ln.t_end))
                            if inter is None or inter[1] - inter[0] < MIN_SPAN:
                                continue
                            basis = [m, ln]
                            if ln.value == "white_dashed":
                                self.add("LANE", video, inter[0], inter[1],
                                         side, "%s转向" % side,
                                         "允许%s变道（%s/%s箭头）"
                                         % (side, led, side), basis,
                                         "虚线")
                            elif ln.value in SOLID_LINES:
                                self.add("LANE", video, inter[0], inter[1],
                                         side, "%s转向" % side,
                                         "保持直行（LED1）", basis,
                                         "线=%s" % ln.value)
                                self.add("LANE", video, inter[0], inter[1],
                                         side, "强制%s变道" % side,
                                         "报警", basis, "线=%s 强制压线"
                                         % ln.value)
                            else:
                                self.mark_uncovered(
                                    video, inter[0], inter[1],
                                    "%s车道线=%s" % (side, ln.value), basis)

    # ---- rule C: navigation ---------------------------------------------
    def gen_nav(self):
        for video in self.video_order:
            dists = self.select(video, "nav_dist_m")
            for m in self.select(video, "nav_maneuver"):
                dist_rows = [d for d in dists if d.t_start == m.t_start]
                if dist_rows:
                    dist = parse_number(dist_rows[0].value)
                    basis = [m, dist_rows[0]]
                else:
                    dist = None
                    basis = [m]
                note = ""
                expected = "提示%s方向（转向灯/LED）" % DIR_NAME[m.value]
                if dist is None:
                    note = "缺少同时刻 nav_dist_m"
                elif dist <= self.opts.nav_near:
                    expected += "，距离%sm≤%sm，进入对应转向车道" % (
                        fmt_time(dist), fmt_time(self.opts.nav_near))
                    note = "near"
                self.add("NAV", video, m.t_start, m.t_end,
                         DIR_NAME[m.value], "按导航行驶", expected, basis, note)

    # ---- rule D: hazard --------------------------------------------------
    def gen_hazard(self):
        table = {
            "ped_in_path": "刹车/停车 + 报警",
            "obstacle_in_lane": "刹车/停车 + 报警",
            "lead_close": "碰撞提醒",
            "cut_in": "碰撞提醒",
            "ped_crossing_near": "减速提醒",
        }
        for video in self.video_order:
            for h in self.select(video, "hazard"):
                self.add("HAZARD", video, h.t_start, h.t_end, h.value,
                         "危险处置", table[h.value], [h], h.note)

    # ---- rule E: speed limit --------------------------------------------
    def gen_speed(self):
        for video in self.video_order:
            for s in self.select(video, "speed_limit"):
                self.add("SPEED", video, s.t_start, s.t_end, "",
                         "按限速行驶",
                         "记录限速值%s，车速（按键/参数模拟）超过时超速提醒"
                         % fmt_time(parse_number(s.value)), [s], s.note)

    def run(self):
        self.gen_signal()
        self.gen_lane_change()
        self.gen_nav()
        self.gen_hazard()
        self.gen_speed()
        return self.cases


def write_csv(path, cases):
    fields = ["case_id", "video", "t_start", "t_end", "category",
              "lane_or_side", "command", "expected", "basis", "conf", "note"]
    with open(path, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        for c in cases:
            w.writerow(c)


def write_md(path, cases, gen):
    order = gen.video_order
    lines = ["# 测试用例（由 gen_testcases.py 生成）", ""]
    for video in order:
        vcases = [c for c in cases if c["video"] == video]
        lines.append("## 视频 %s（%d 条）" % (video, len(vcases)))
        lines.append("")
        lines.append("| case_id | t_start | t_end | category | lane_or_side | "
                     "command | expected | conf | note | basis |")
        lines.append("|---|---|---|---|---|---|---|---|---|---|")
        for c in sorted(vcases, key=lambda x: float(x["t_start"])):
            lines.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |"
                         % (c["case_id"], c["t_start"], c["t_end"],
                            c["category"], c["lane_or_side"], c["command"],
                            c["expected"], c["conf"], c["note"], c["basis"]))
        un = gen.uncovered.get(video, [])
        if un:
            lines.append("")
            lines.append("**未覆盖区间（%d）**：" % len(un))
            lines.append("")
            for s, e, reason, basis in un:
                lines.append("- [%s, %s] %s (basis: %s)" % (s, e, reason, basis))
        lines.append("")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def print_stats(gen, cases):
    print("=== 统计 ===")
    for video in gen.video_order:
        vcases = [c for c in cases if c["video"] == video]
        cats = {}
        for c in vcases:
            cats[c["category"]] = cats.get(c["category"], 0) + 1
        low = sum(1 for c in vcases if c["conf"] == "low")
        un = gen.uncovered.get(video, [])
        cat_str = ", ".join("%s=%d" % (k, cats[k]) for k in sorted(cats))
        print("[%s] 用例=%d {%s} conf_low=%d 未覆盖=%d"
              % (video, len(vcases), cat_str, low, len(un)))
        for s, e, reason, basis in un:
            print("    未覆盖 [%s, %s] %s (basis: %s)" % (s, e, reason, basis))
    total = len(cases)
    total_low = sum(1 for c in cases if c["conf"] == "low")
    print("TOTAL 用例=%d conf_low=%d" % (total, total_low))


def main():
    ap = argparse.ArgumentParser(
        description="Generate test cases from *_timeline.csv ground truth.")
    ap.add_argument("--gt", required=True, help="ground-truth directory")
    ap.add_argument("--out", required=True, help="output directory")
    ap.add_argument("--lenient", action="store_true",
                    help="warn on validation errors instead of failing")
    ap.add_argument("--right-free", dest="right_free", action="store_true")
    ap.add_argument("--no-right-free", dest="right_free",
                    action="store_false")
    ap.add_argument("--nav-near", type=float, default=150.0,
                    help="navigation near distance in meters (default 150)")
    ap.set_defaults(right_free=True)
    args = ap.parse_args()

    gt_dir = os.path.abspath(args.gt)
    out_dir = os.path.abspath(args.out)

    rows, errors = load_and_validate(gt_dir, args.lenient)
    for err in errors:
        sys.stderr.write(err + "\n")
    if errors and not args.lenient:
        sys.stderr.write("校验失败：%d 处错误（使用 --lenient 可忽略）\n"
                         % len(errors))
        return 2
    if errors:
        sys.stderr.write("警告：%d 处错误已被 --lenient 忽略\n" % len(errors))

    os.makedirs(out_dir, exist_ok=True)
    gen = Generator(rows, args)
    cases = gen.run()
    csv_path = os.path.join(out_dir, "testcases.csv")
    md_path = os.path.join(out_dir, "testcases.md")
    write_csv(csv_path, cases)
    write_md(md_path, cases, gen)
    print_stats(gen, cases)
    print("已写出：%s" % csv_path)
    print("已写出：%s" % md_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
