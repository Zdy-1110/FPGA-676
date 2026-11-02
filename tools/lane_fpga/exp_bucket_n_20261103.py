"""0x8F4(max_consec/double_cnt) 在板上读回恒为 0（RTL 捕获时序问题），改用 FPGA 已正确暴露的
每帧点数 n_l/n_r（0x8E8[15:8]=r_n, [7:0]=l_n）做 RK 端漏桶线型判定，并用同一套 32 用例评测。

用法: py -3 tools/lane_fpga/exp_bucket_n_20261103.py
"""
import itertools
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import exp_temporal_20261102 as E  # noqa: E402  (复用用例准备与评测函数)

CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "cache_runstat_20261102", "runstat.npz")


def bucket_from_feature(cache, feat, th_l, thr_l, th_r, thr_r, up_l, dn_l, up_r, dn_r):
    """feat: 'n' 用点数, 'mc' 用 max_consec。返回 {(vid, side): per-frame type}"""
    maps = {}
    for vid in E.VIDEOS:
        for side in ("l", "r"):
            f = cache[f"{vid}_{'max_consec' if feat == 'mc' else feat}_{side}"]
            v = cache[f"{vid}_valid_{side}"]
            th = th_l if side == "l" else th_r
            thr = thr_l if side == "l" else thr_r
            up = up_l if side == "l" else up_r
            dn = dn_l if side == "l" else dn_r
            out = np.zeros(len(f), dtype=np.uint8)
            score = 0
            for i in range(len(f)):
                if not v[i]:
                    score = 0
                    out[i] = 0
                    continue
                score = min(100, score + up) if int(f[i]) >= th else max(0, score - dn)
                out[i] = 2 if score >= thr else 1
            maps[(vid, side)] = out
    return maps


def main():
    cache = np.load(CACHE)
    cases = E.prepare_cases(E.load_lane_testcases(), cache)

    # 参考：mc 版（离线最佳，用于确认评测口径）
    m = bucket_from_feature(cache, "mc", 35, 30, 75, 70, 5, 3, 3, 5)
    r = E.evaluate_maps(m, cases)
    print(f"[参考] mc 版: D={r[0]}/{r[1]} S={r[2]}/{r[3]} Bal={r[4]:.4f} 总={r[5]}/{r[6]}")

    # 先看 n 的分布，选候选门限
    for vid in E.VIDEOS[:1]:
        for side in ("l", "r"):
            f = cache[f"{vid}_n_{side}"]
            print(f"  {vid} n_{side}: min={f.min()} p25={np.percentile(f,25):.0f} "
                  f"median={np.percentile(f,50):.0f} p75={np.percentile(f,75):.0f} max={f.max()}")

    best = None
    for th_l, th_r in itertools.product((90, 110, 130, 150), (90, 110, 130, 150)):
        for thr_l, thr_r in itertools.product((20, 30, 40), (40, 55, 70)):
            for up, dn in ((4, 2), (5, 3), (6, 3)):
                m = bucket_from_feature(cache, "n", th_l, thr_l, th_r, thr_r, up, dn, up, dn)
                d, dt, s, st, bal, tot, _tc, _pv = E.evaluate_maps(m, cases)
                key = (bal, d, s)
                if best is None or key > best[0]:
                    best = (key, dict(th_l=th_l, th_r=th_r, thr_l=thr_l, thr_r=thr_r,
                                      up=up, dn=dn), (d, dt, s, st, bal, tot))
    (bal, d, s), params, res = best
    print(f"[n 版最佳] D={res[0]}/{res[1]} S={res[2]}/{res[3]} Bal={res[4]:.4f} 总={res[5]}/32")
    print("  参数:", params)

    # 最佳方案的留一视频交叉验证（参数固定，只看各测试段）
    print("[n 版分段]")
    for vid in E.VIDEOS:
        r = E.evaluate_maps(bucket_from_feature(cache, "n", params["th_l"], params["thr_l"],
                                                params["th_r"], params["thr_r"],
                                                params["up"], params["dn"],
                                                params["up"], params["dn"]),
                            cases, filter_vids={vid})
        print(f"  {vid}: D={r[0]}/{r[1]} S={r[2]}/{r[3]} Bal={r[4]:.3f}")


if __name__ == "__main__":
    main()
