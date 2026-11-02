# -*- coding: utf-8 -*-
"""时序车道线分类器对比实验与留一交叉验证 (2026-11-02)。

严格以均衡分 (Balanced Score = D/12 + S/20) 为主指标，防止退化为全判实线的平凡解。
只读取缓存 tools/lane_fpga/cache_runstat_20261102/runstat.npz，
严格复用 eval.py 的用例定义与判决口径。
所有算法只依赖 FPGA BAR1 实际暴露的每帧定点量（0x8F4, 0x8E8, 0x8D0/0x8DC）。
"""

import os
import sys
import csv
from collections import deque
import numpy as np

CACHE_PATH = os.path.join(os.path.dirname(__file__), "cache_runstat_20261102", "runstat.npz")
TESTCASES_PATH = r"E:\Project\nesai2026\video_review\gt\out\testcases.csv"
VIDEOS = ["112507", "113343", "113452", "113539"]


def load_lane_testcases():
    cases = []
    with open(TESTCASES_PATH, "r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            if (r.get("category") or "").strip() == "LANE":
                cases.append(r)
    return cases


def expected_code(expected):
    e = expected or ""
    if "报警" in e:
        return "ALARM"
    if "允许" in e:
        return "ALLOW"
    if "保持直行" in e:
        return "KEEP"
    return ""


def prepare_cases(testcases, cache):
    """预计算评测区间索引，大幅加速批量参数扫描。"""
    prepared = []
    for tc in testcases:
        vid = tc["video"]
        t0 = float(tc["t_start"])
        t1 = float(tc["t_end"])
        side = "l" if tc["lane_or_side"] == "左" else "r"
        exp = expected_code(tc["expected"])
        force = tc["command"].startswith("强制")
        lo, hi = (t0 + 0.3, t1 - 0.3) if t1 - t0 >= 1.2 else (t0, t1)
        times = cache[f"{vid}_times"]
        idx = np.where((times >= lo) & (times <= hi))[0]
        prepared.append({
            "case_id": tc["case_id"],
            "video": vid,
            "side": side,
            "exp": exp,
            "force": force,
            "idx": idx,
            "note": tc["note"],
        })
    return prepared


def evaluate_maps(voted_maps, case_list, filter_vids=None):
    """评估一组每帧预测类型图，输出 D/12, S/20 与均衡分 Bal = D/12 + S/20。"""
    d_pass, s_pass = 0, 0
    d_tot, s_tot = 0, 0
    per_vid = {v: {"D": [0, 0], "S": [0, 0]} for v in VIDEOS}

    for item in case_list:
        vid = item["video"]
        if filter_vids is not None and vid not in filter_vids:
            continue
        side = item["side"]
        exp = item["exp"]
        force = item["force"]
        idx = item["idx"]

        is_dashed_case = (exp == "ALLOW")
        if is_dashed_case:
            d_tot += 1
            per_vid[vid]["D"][1] += 1
        else:
            s_tot += 1
            per_vid[vid]["S"][1] += 1

        preds = voted_maps[(vid, side)][idx]
        d_preds = ["ALLOW" if p == 1 else ("ALARM" if force else "KEEP") for p in preds]
        correct = sum(1 for p in d_preds if p == exp)
        ratio = correct / len(d_preds) if len(d_preds) > 0 else 0.0

        if ratio >= 0.8:
            if is_dashed_case:
                d_pass += 1
                per_vid[vid]["D"][0] += 1
            else:
                s_pass += 1
                per_vid[vid]["S"][0] += 1

    d_rate = d_pass / d_tot if d_tot else 0.0
    s_rate = s_pass / s_tot if s_tot else 0.0
    balanced_score = d_rate + s_rate
    total_pass = d_pass + s_pass
    total_cases = d_tot + s_tot

    return d_pass, d_tot, s_pass, s_tot, balanced_score, total_pass, total_cases, per_vid


# =========================================================================
# 分类器构建函数
# =========================================================================

def build_baseline_maps(cache):
    """分类器 (a): 基线复现（单帧 61 门限 + 24 帧滑动多数表决）。"""
    maps = {}
    for vid in VIDEOS:
        for s in ["l", "r"]:
            maps[(vid, s)] = cache[f"{vid}_voted_type_{s}"]
    return maps


def build_trivial_maps(cache, force_solid=True):
    """平凡参考解：全判实线 (force_solid=True) 或 全判虚线 (force_solid=False)。"""
    maps = {}
    target = 2 if force_solid else 1
    for vid in VIDEOS:
        for s in ["l", "r"]:
            N = len(cache[f"{vid}_times"])
            maps[(vid, s)] = np.full(N, target, dtype=np.uint8)
    return maps


def run_sliding_stat(cache, W=10, th_min=10, th_mean=35):
    """分类器 (b): 滑窗统计（窗口内 max_consec 最小值与均值）。"""
    maps = {}
    for vid in VIDEOS:
        for s in ["l", "r"]:
            mcs = cache[f"{vid}_max_consec_{s}"]
            valids = cache[f"{vid}_valid_{s}"]
            N = len(mcs)
            voted = np.zeros(N, dtype=np.uint8)
            buf = deque(maxlen=W)
            sum_val = 0
            for i in range(N):
                if not valids[i]:
                    voted[i] = 0
                    buf.clear()
                    sum_val = 0
                    continue
                val = int(mcs[i])
                if len(buf) == W:
                    sum_val -= buf[0]
                buf.append(val)
                sum_val += val
                cur_min = min(buf)
                cur_mean = sum_val / len(buf)
                if cur_min >= th_min and cur_mean >= th_mean:
                    voted[i] = 2  # solid
                else:
                    voted[i] = 1  # dashed
            maps[(vid, s)] = voted
    return maps


def run_double_suppress(cache, th_dbl=70, th_mc_dbl=40, k_dbl=4, th_solid=50, solid_vote_req=12):
    """分类器 (d): 双黄抑制改进（限左侧、double_cnt 持续且 max_consec 高）。"""
    maps = {}
    for vid in VIDEOS:
        for s in ["l", "r"]:
            mcs = cache[f"{vid}_max_consec_{s}"]
            dbls = cache[f"{vid}_double_cnt_{s}"]
            valids = cache[f"{vid}_valid_{s}"]
            N = len(mcs)
            voted = np.zeros(N, dtype=np.uint8)
            hist = deque(maxlen=24)
            dbl_hist = deque(maxlen=24)
            for i in range(N):
                if not valids[i]:
                    voted[i] = 0
                    hist.append(0)
                    dbl_hist.append(0)
                    continue
                is_dbl_frame = 1 if (s == "l" and dbls[i] >= th_dbl and mcs[i] >= th_mc_dbl) else 0
                dbl_hist.append(is_dbl_frame)
                is_solid_frame = 1 if (mcs[i] >= th_solid) else 0

                is_dbl = (sum(dbl_hist) >= k_dbl)
                if is_dbl:
                    raw = 3
                elif is_solid_frame:
                    raw = 2
                else:
                    raw = 1
                hist.append(raw)

                n_dbl = sum(1 for x in hist if x == 3)
                n_sol = sum(1 for x in hist if x == 2)
                if (n_dbl + n_sol) >= solid_vote_req:
                    voted[i] = 3 if n_dbl > n_sol else 2
                else:
                    voted[i] = 1
            maps[(vid, s)] = voted
    return maps


def run_asym_leaky_bucket(cache, th_l=35, thr_l=30, th_r=75, thr_r=70):
    """分类器 (e): 左右非对称漏桶状态分类器（最高均衡分推荐方案）。

    仅需 6 个定点参数，单帧 O(1) 状态。
    左侧：th_l=35, thr_l=30, up=5, dn=3
    右侧：th_r=75, thr_r=70, up=3, dn=5
    """
    maps = {}
    for vid in VIDEOS:
        # 左侧
        mcs_l = cache[f"{vid}_max_consec_l"]
        valids_l = cache[f"{vid}_valid_l"]
        N = len(mcs_l)
        vl = np.zeros(N, dtype=np.uint8)
        sc_l = 0
        for i in range(N):
            if not valids_l[i]:
                sc_l = 0
                vl[i] = 0
                continue
            if int(mcs_l[i]) >= th_l:
                sc_l = min(100, sc_l + 5)
            else:
                sc_l = max(0, sc_l - 3)
            vl[i] = 2 if sc_l >= thr_l else 1
        maps[(vid, "l")] = vl

        # 右侧
        mcs_r = cache[f"{vid}_max_consec_r"]
        valids_r = cache[f"{vid}_valid_r"]
        vr = np.zeros(N, dtype=np.uint8)
        sc_r = 0
        for i in range(N):
            if not valids_r[i]:
                sc_r = 0
                vr[i] = 0
                continue
            if int(mcs_r[i]) >= th_r:
                sc_r = min(100, sc_r + 3)
            else:
                sc_r = max(0, sc_r - 5)
            vr[i] = 2 if sc_r >= thr_r else 1
        maps[(vid, "r")] = vr

    return maps


# =========================================================================
# 留一交叉验证 (LOOCV)
# =========================================================================

def run_loocv(cache, case_list, builder_fn, param_grid):
    """4 段视频留一交叉验证 (以均衡分为目标：3 段选参，1 段测试)。"""
    test_d_total = 0
    test_s_total = 0
    fold_details = []

    for test_vid in VIDEOS:
        train_vids = [v for v in VIDEOS if v != test_vid]

        best_train_bal = -1.0
        best_param = None
        best_maps = None

        for p in param_grid:
            maps = builder_fn(cache, **p)
            dp, dt, sp, st, bal, tot_p, tot_c, _ = evaluate_maps(maps, case_list, filter_vids=train_vids)
            if bal > best_train_bal:
                best_train_bal = bal
                best_param = p
                best_maps = maps

        # 在测试视频上验证
        te_dp, te_dt, te_sp, te_st, te_bal, te_tot, te_tot_c, _ = evaluate_maps(
            best_maps, case_list, filter_vids=[test_vid]
        )
        test_d_total += te_dp
        test_s_total += te_sp
        fold_details.append({
            "test_vid": test_vid,
            "train_score": f"Bal={best_train_bal:.4f}",
            "test_score": f"D={te_dp}/{te_dt}, S={te_sp}/{te_st}, Bal={te_bal:.4f}",
            "best_param": best_param,
        })

    loocv_bal = test_d_total / 12.0 + test_s_total / 20.0
    return test_d_total, test_s_total, loocv_bal, fold_details


def main():
    if not os.path.exists(CACHE_PATH):
        print(f"Error: Cache not found at {CACHE_PATH}", file=sys.stderr)
        sys.exit(1)

    cache = np.load(CACHE_PATH)
    testcases = load_lane_testcases()
    case_list = prepare_cases(testcases, cache)
    print(f"Loaded {len(case_list)} LANE testcases (12 Dashed, 20 Solid) across {len(VIDEOS)} videos.")

    # -------------------------------------------------------------
    # 0. 平凡解参考
    # -------------------------------------------------------------
    print("\n" + "=" * 65)
    print("【平凡解参考标尺】")
    ts_maps = build_trivial_maps(cache, force_solid=True)
    dp, dt, sp, st, bal, tot_p, tot_c, _ = evaluate_maps(ts_maps, case_list)
    print(f"  平凡解·全判实线: D={dp}/{dt} ({dp/dt*100:.1f}%), S={sp}/{st} ({sp/st*100:.1f}%), 均衡分={bal:.4f}, 总通过={tot_p}/{tot_c}")

    td_maps = build_trivial_maps(cache, force_solid=False)
    dp, dt, sp, st, bal, tot_p, tot_c, _ = evaluate_maps(td_maps, case_list)
    print(f"  平凡解·全判虚线: D={dp}/{dt} ({dp/dt*100:.1f}%), S={sp}/{st} ({sp/st*100:.1f}%), 均衡分={bal:.4f}, 总通过={tot_p}/{tot_c}")

    # -------------------------------------------------------------
    # (a) 基线复现
    # -------------------------------------------------------------
    print("\n" + "=" * 65)
    base_maps = build_baseline_maps(cache)
    dp, dt, sp, st, bal, tot_p, tot_c, pv = evaluate_maps(base_maps, case_list)
    print(f"(a) 基线复现 (Baseline):")
    print(f"    D={dp}/{dt} ({dp/dt*100:.1f}%), S={sp}/{st} ({sp/st*100:.1f}%), 均衡分={bal:.4f}, 总通过={tot_p}/{tot_c}")
    pv_str = " | ".join(f"{v}: D={pv[v]['D'][0]}/{pv[v]['D'][1]}, S={pv[v]['S'][0]}/{pv[v]['S'][1]}" for v in VIDEOS)
    print(f"    分段指标: {pv_str}")
    if tot_p != 16:
        print(f"FATAL: Baseline failed to reproduce 16/32! Got {tot_p}/32", file=sys.stderr)
        sys.exit(1)

    # -------------------------------------------------------------
    # (b) 滑窗统计扫描
    # -------------------------------------------------------------
    print("\n" + "=" * 65)
    print("(b) 滑窗统计分类器参数扫描 (Sliding Window Stats):")
    b_grid = [
        {"W": 10, "th_min": 10, "th_mean": 30},
        {"W": 10, "th_min": 10, "th_mean": 35},
        {"W": 10, "th_min": 15, "th_mean": 35},
        {"W": 10, "th_min": 15, "th_mean": 40},
        {"W": 16, "th_min": 10, "th_mean": 35},
        {"W": 16, "th_min": 15, "th_mean": 35},
        {"W": 20, "th_min": 10, "th_mean": 35},
        {"W": 24, "th_min": 15, "th_mean": 35},
    ]
    b_results = []
    for p in b_grid:
        maps = run_sliding_stat(cache, **p)
        dp, dt, sp, st, bal, tot_p, tot_c, pv = evaluate_maps(maps, case_list)
        b_results.append((bal, dp, dt, sp, st, tot_p, p, pv))
    b_results.sort(key=lambda x: x[0], reverse=True)
    best_b = b_results[0]
    print(f"    最佳均衡分配置: {best_b[6]}")
    print(f"    D={best_b[1]}/{best_b[2]} ({best_b[1]/best_b[2]*100:.1f}%), S={best_b[3]}/{best_b[4]} ({best_b[3]/best_b[4]*100:.1f}%), 均衡分={best_b[0]:.4f}, 总通过={best_b[5]}/{tot_c}")

    # -------------------------------------------------------------
    # (d) 双黄抑制改进扫描
    # -------------------------------------------------------------
    print("\n" + "=" * 65)
    print("(d) 双黄抑制改进参数扫描 (Double Yellow Suppress):")
    d_grid = [
        {"th_dbl": 61, "th_mc_dbl": 40, "k_dbl": 4, "th_solid": 50, "solid_vote_req": 12},
        {"th_dbl": 70, "th_mc_dbl": 40, "k_dbl": 4, "th_solid": 50, "solid_vote_req": 12},
        {"th_dbl": 70, "th_mc_dbl": 50, "k_dbl": 4, "th_solid": 50, "solid_vote_req": 12},
        {"th_dbl": 80, "th_mc_dbl": 40, "k_dbl": 4, "th_solid": 50, "solid_vote_req": 12},
        {"th_dbl": 61, "th_mc_dbl": 40, "k_dbl": 4, "th_solid": 55, "solid_vote_req": 12},
        {"th_dbl": 70, "th_mc_dbl": 50, "k_dbl": 6, "th_solid": 55, "solid_vote_req": 12},
    ]
    d_results = []
    for p in d_grid:
        maps = run_double_suppress(cache, **p)
        dp, dt, sp, st, bal, tot_p, tot_c, pv = evaluate_maps(maps, case_list)
        d_results.append((bal, dp, dt, sp, st, tot_p, p, pv))
    d_results.sort(key=lambda x: x[0], reverse=True)
    best_d = d_results[0]
    print(f"    最佳均衡分配置: {best_d[6]}")
    print(f"    D={best_d[1]}/{best_d[2]} ({best_d[1]/best_d[2]*100:.1f}%), S={best_d[3]}/{best_d[4]} ({best_d[3]/best_d[4]*100:.1f}%), 均衡分={best_d[0]:.4f}, 总通过={best_d[5]}/{tot_c}")

    # -------------------------------------------------------------
    # (e) 左右非对称漏桶状态分类器扫描（主推荐方案）
    # -------------------------------------------------------------
    print("\n" + "=" * 65)
    print("(e) 左右非对称漏桶状态分类器参数扫描 (Asymmetric Leaky Bucket):")
    e_grid = [
        {"th_l": 35, "thr_l": 30, "th_r": 75, "thr_r": 70},
        {"th_l": 35, "thr_l": 35, "th_r": 75, "thr_r": 70},
        {"th_l": 35, "thr_l": 30, "th_r": 70, "thr_r": 70},
        {"th_l": 35, "thr_l": 30, "th_r": 80, "thr_r": 70},
        {"th_l": 40, "thr_l": 30, "th_r": 75, "thr_r": 70},
        {"th_l": 40, "thr_l": 30, "th_r": 80, "thr_r": 70},
    ]
    e_results = []
    for p in e_grid:
        maps = run_asym_leaky_bucket(cache, **p)
        dp, dt, sp, st, bal, tot_p, tot_c, pv = evaluate_maps(maps, case_list)
        e_results.append((bal, dp, dt, sp, st, tot_p, p, pv))
    e_results.sort(key=lambda x: x[0], reverse=True)
    best_e = e_results[0]
    print(f"    最佳均衡分配置: {best_e[6]}")
    print(f"    D={best_e[1]}/{best_e[2]} ({best_e[1]/best_e[2]*100:.1f}%), S={best_e[3]}/{best_e[4]} ({best_e[3]/best_e[4]*100:.1f}%), 均衡分={best_e[0]:.4f}, 总通过={best_e[5]}/{tot_c}")
    pv = best_e[7]
    pv_str = " | ".join(f"{v}: D={pv[v]['D'][0]}/{pv[v]['D'][1]}, S={pv[v]['S'][0]}/{pv[v]['S'][1]}" for v in VIDEOS)
    print(f"    分段指标: {pv_str}")

    # -------------------------------------------------------------
    # 留一交叉验证 (LOOCV) 对推荐方案 (e)
    # -------------------------------------------------------------
    print("\n" + "=" * 65)
    print("留一视频交叉验证 (LOOCV - 4 折轮换，目标为均衡分):")

    loocv_d, loocv_s, loocv_bal, folds = run_loocv(cache, case_list, run_asym_leaky_bucket, e_grid)
    print(f"  [推荐方案 e - 非对称漏桶] LOOCV 测试段:")
    print(f"  测试段汇总: D={loocv_d}/12 ({loocv_d/12*100:.1f}%), S={loocv_s}/20 ({loocv_s/20*100:.1f}%), 均衡分={loocv_bal:.4f}, 总通过={loocv_d+loocv_s}/32")
    for f in folds:
        print(f"    测试视频 {f['test_vid']}: 训练得分 {f['train_score']}, 测试得分 {f['test_score']}, 选定参数 {f['best_param']}")

    print("\n" + "=" * 65)
    print("ALL EXPERIMENTS COMPLETED SUCCESSFULLY.")
    sys.exit(0)


if __name__ == "__main__":
    main()
