"""USB2.0 UVC 星光级摄像头（Sony IMX291，MJPG）Windows 验收脚本。

用途
----
在 Windows 11 上用 DirectShow 后端验收 USB2.0 UVC 摄像头：
- 枚举可用摄像头索引并读取默认参数；
- 测试 MJPG 指定分辨率下的实际帧率、帧间隔与亮度，自动判定 PASS/FAIL；
- 实时预览，叠加分辨率/实测帧率/亮度与中心十字线，支持截图和驱动属性对话框。

运行方式
--------
E:\\Project\\nesai2026\\.venv_yolo\\Scripts\\python.exe ^
    E:\\Project\\nesai2026\\tools\\cam_accept\\uvc_accept.py <子命令> [参数]

子命令示例
----------
列出摄像头：
    python tools\\cam_accept\\uvc_accept.py list
    python tools\\cam_accept\\uvc_accept.py list --max-index 8

亮处/暗处帧率测试（默认 1280x720@30，20 秒，自动曝光）：
    python tools\\cam_accept\\uvc_accept.py fps --index 0
    python tools\\cam_accept\\uvc_accept.py fps --index 0 --seconds 20 --out D:\\cam_test

手动曝光（DirectShow 曝光单位为 log2 秒，-5 约等于 1/32 s）：
    python tools\\cam_accept\\uvc_accept.py fps --index 0 --exposure -5
    python tools\\cam_accept\\uvc_accept.py fps --index 0 --width 1920 --height 1080 --fps 30 --seconds 1800

实时预览与截图（按 s 保存，按 q 或 Esc 退出）：
    python tools\\cam_accept\\uvc_accept.py preview --index 0
    python tools\\cam_accept\\uvc_accept.py preview --index 0 --dialog

样品验收流程
------------
① list 找到摄像头索引；
② 亮处 fps 测试 1280x720 20 秒，必须 PASS；
③ 关灯或用手捂住镜头留一条缝做暗处 fps 测试，必须 PASS（不 PASS 说明暗光自动降帧）；
④ preview --dialog：在属性对话框里看能否切到手动曝光、能否取消"低光补偿"，取消后重复第 ③ 步；
⑤ 红外滤光片检查：preview 时把电视遥控器对准镜头按键，画面里看到遥控器头部闪亮的紫白光点＝没有红外截止滤光片（不合格），看不到＝有滤光片；
⑥ 视场角：摄像头正对墙面，距离 D，在 preview 画面左右边缘对应的墙面位置做标记，量出宽度 W，水平视场角 = 2·atan(W/2D)，目标 90–120°；
⑦ 1920x1080 也测一次 fps，并连续运行 30 分钟（--seconds 1800）检查不断流、外壳温度。

只依赖 OpenCV、numpy 和 Python 标准库，全部使用 cv2.CAP_DSHOW 后端。
"""

import argparse
import csv
import json
import sys
import time
from collections import deque
from datetime import datetime
from pathlib import Path

import cv2
import numpy as np

BACKEND = cv2.CAP_DSHOW
MJPG = cv2.VideoWriter_fourcc(*"MJPG")
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_OUT_ROOT = SCRIPT_DIR / "out"


def fourcc_to_str(value):
    """把 OpenCV 返回的 FOURCC 数值解码为 4 字符字符串。"""
    try:
        value = int(value)
    except (TypeError, ValueError):
        return "????"
    chars = [chr((value >> (8 * i)) & 0xFF) for i in range(4)]
    text = "".join(ch if 32 <= ord(ch) < 127 else "." for ch in chars)
    return text


def open_capture(index, width, height, fps):
    """按 MJPG -> 宽 -> 高 -> fps 的顺序配置并打开摄像头。"""
    cap = cv2.VideoCapture(index, BACKEND)
    if not cap.isOpened():
        return None
    cap.set(cv2.CAP_PROP_FOURCC, MJPG)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    cap.set(cv2.CAP_PROP_FPS, fps)
    return cap


def read_negotiated(cap):
    """读取实际协商的分辨率、FOURCC、帧率。"""
    return {
        "width": int(round(cap.get(cv2.CAP_PROP_FRAME_WIDTH))),
        "height": int(round(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))),
        "fourcc": fourcc_to_str(cap.get(cv2.CAP_PROP_FOURCC)),
        "fps": float(cap.get(cv2.CAP_PROP_FPS)),
    }


def make_out_dir(out_arg, index, width, height, tag=""):
    """创建并返回本次运行的输出目录。"""
    if out_arg:
        out_dir = Path(out_arg)
    else:
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        name = f"{stamp}_{tag}idx{index}_{width}x{height}"
        out_dir = DEFAULT_OUT_ROOT / name
    out_dir.mkdir(parents=True, exist_ok=True)
    return out_dir


def frame_brightness(frame):
    """返回灰度均值作为亮度指标。"""
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    return float(np.mean(gray))


def cmd_list(args):
    found = []
    for index in range(args.max_index + 1):
        cap = cv2.VideoCapture(index, BACKEND)
        try:
            if not cap.isOpened():
                continue
            info = read_negotiated(cap)
            found.append((index, info))
            print(
                f"索引={index}  默认分辨率={info['width']}x{info['height']}  "
                f"默认 FOURCC={info['fourcc']}  默认 FPS={info['fps']:.2f}"
            )
        finally:
            cap.release()

    if not found:
        print("未找到摄像头")
        return 2

    print(f"共找到 {len(found)} 个摄像头")
    return 0


def cmd_fps(args):
    cap = open_capture(args.index, args.width, args.height, args.fps)
    if cap is None:
        print(f"打不开摄像头（索引 {args.index}）")
        return 2

    try:
        if args.exposure is not None:
            cap.set(cv2.CAP_PROP_AUTO_EXPOSURE, 0.25)
            cap.set(cv2.CAP_PROP_EXPOSURE, float(args.exposure))
            auto_read = cap.get(cv2.CAP_PROP_AUTO_EXPOSURE)
            exp_read = cap.get(cv2.CAP_PROP_EXPOSURE)
            print(
                f"曝光设置：请求 EXPOSURE={args.exposure}（log2 秒），"
                f"回读 AUTO_EXPOSURE={auto_read:.3f}，EXPOSURE={exp_read:.3f}"
            )
        else:
            print(
                f"曝光设置：保持自动（AUTO_EXPOSURE={cap.get(cv2.CAP_PROP_AUTO_EXPOSURE):.3f}）"
            )

        info = read_negotiated(cap)
        print(
            f"实际协商：{info['width']}x{info['height']}  "
            f"FOURCC={info['fourcc']}  FPS={info['fps']:.2f}"
        )

        for _ in range(30):
            cap.read()

        out_dir = make_out_dir(args.out, args.index, info["width"], info["height"])
        nominal_fps = float(args.fps)
        nominal_period = 1000.0 / nominal_fps
        n = 0
        first_frame = None
        mid_frame = None
        last_frame = None
        times = []
        brightness = []
        broken = False
        fail_start = None
        t_start = time.perf_counter()

        while True:
            now = time.perf_counter()
            if now - t_start >= args.seconds:
                break
            ok, frame = cap.read()
            now = time.perf_counter()
            if not ok or frame is None:
                if fail_start is None:
                    fail_start = now
                elif now - fail_start > 2.0:
                    broken = True
                    break
                time.sleep(0.005)
                continue
            fail_start = None
            if first_frame is None:
                first_frame = frame
            if mid_frame is None and now - t_start >= args.seconds / 2.0:
                mid_frame = frame
            last_frame = frame
            n += 1
            times.append(now)
            brightness.append(frame_brightness(frame))
    finally:
        cap.release()

    summary = {
        "index": args.index,
        "requested": {
            "width": args.width,
            "height": args.height,
            "fps": args.fps,
            "exposure": args.exposure,
        },
        "negotiated": info,
        "output_dir": str(out_dir),
        "valid_frames": n,
        "duration_s": args.seconds,
        "measured_fps": None,
        "max_dt_ms": None,
        "long_interval_count": None,
        "brightness_mean": None,
        "stream_broken": broken,
        "verdict": "FAIL",
        "reasons": [],
        "warnings": [],
    }

    if n >= 1:
        summary["brightness_mean"] = float(np.mean(brightness))
    if n >= 2:
        span = times[-1] - times[0]
        measured_fps = (n - 1) / span if span > 0 else 0.0
        dts = [(times[i] - times[i - 1]) * 1000.0 for i in range(1, n)]
        max_dt = max(dts)
        long_count = sum(1 for dt in dts if dt > 1.5 * nominal_period)
        summary["measured_fps"] = measured_fps
        summary["max_dt_ms"] = max_dt
        summary["long_interval_count"] = long_count

        if measured_fps < 0.95 * nominal_fps:
            summary["reasons"].append(
                f"实测帧率 {measured_fps:.2f} < 0.95×标称 {0.95 * nominal_fps:.2f}"
            )
        if max_dt > 3.0 * nominal_period:
            summary["reasons"].append(
                f"最大帧间隔 {max_dt:.1f} ms > 3×标称周期 {3.0 * nominal_period:.1f} ms"
            )
    else:
        summary["reasons"].append("有效帧数不足，无法统计帧率")

    if broken:
        summary["reasons"].append("读帧连续失败超过 2 秒，判定断流")

    if n == 0:
        summary["reasons"].append("没有读到任何有效帧")

    if info["width"] != args.width or info["height"] != args.height:
        summary["reasons"].append(
            f"实际分辨率 {info['width']}x{info['height']} "
            f"与请求 {args.width}x{args.height} 不符"
        )

    if info["fourcc"] != "MJPG":
        summary["warnings"].append(
            f"回读 FOURCC={info['fourcc']}，不是 MJPG"
            "（DirectShow 回读可能不可靠，请在属性对话框或设备管理器确认）"
        )

    summary["verdict"] = "PASS" if not summary["reasons"] else "FAIL"

    t0 = times[0] if times else 0.0
    csv_path = out_dir / "frames.csv"
    with open(csv_path, "w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["idx", "t_ms", "dt_ms", "brightness"])
        for i in range(n):
            t_ms = (times[i] - t0) * 1000.0
            dt_ms = 0.0 if i == 0 else (times[i] - times[i - 1]) * 1000.0
            writer.writerow([i, f"{t_ms:.3f}", f"{dt_ms:.3f}", f"{brightness[i]:.3f}"])

    if n >= 1:
        middle = mid_frame if mid_frame is not None else last_frame
        cv2.imwrite(str(out_dir / "first.png"), first_frame)
        cv2.imwrite(str(out_dir / "middle.png"), middle)
        cv2.imwrite(str(out_dir / "last.png"), last_frame)

    summary_path = out_dir / "summary.json"
    with open(summary_path, "w", encoding="utf-8") as fh:
        json.dump(summary, fh, ensure_ascii=False, indent=2)

    print("---- 汇总 ----")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"输出目录：{out_dir}")

    if summary["verdict"] == "PASS":
        print("PASS")
    else:
        print("FAIL")
        for reason in summary["reasons"]:
            print(f"原因：{reason}")

    for warning in summary["warnings"]:
        print(f"警告：{warning}")

    return 0 if summary["verdict"] == "PASS" else 1


def draw_overlay(frame, fps_value, brightness_value, width, height):
    """在画面上叠加参数、中心十字线。"""
    vis = frame.copy()
    h, w = vis.shape[:2]
    cv2.line(vis, (w // 2, 0), (w // 2, h - 1), (0, 255, 0), 1)
    cv2.line(vis, (0, h // 2), (w - 1, h // 2), (0, 255, 0), 1)

    lines = [
        f"Resolution: {width}x{height}",
        f"Measured FPS: {fps_value:.1f}",
        f"Brightness: {brightness_value:.1f}",
    ]
    y = 24
    for text in lines:
        cv2.putText(vis, text, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                    (0, 0, 0), 3, cv2.LINE_AA)
        cv2.putText(vis, text, (10, y), cv2.FONT_HERSHEY_SIMPLEX, 0.6,
                    (0, 255, 255), 1, cv2.LINE_AA)
        y += 26
    return vis


def cmd_preview(args):
    cap = open_capture(args.index, args.width, args.height, args.fps)
    if cap is None:
        print(f"打不开摄像头（索引 {args.index}）")
        return 2

    if args.dialog:
        cap.set(cv2.CAP_PROP_SETTINGS, 1)

    out_dir = make_out_dir(args.out, args.index, args.width, args.height, tag="preview_")
    info = read_negotiated(cap)
    print(
        f"实际协商：{info['width']}x{info['height']}  "
        f"FOURCC={info['fourcc']}  FPS={info['fps']:.2f}"
    )
    print(f"输出目录：{out_dir}")
    print("按 s 保存当前帧，按 q 或 Esc 退出")

    recent = deque()
    fail_start = None
    exit_code = 0
    try:
        while True:
            ok, frame = cap.read()
            now = time.perf_counter()
            if not ok or frame is None:
                if fail_start is None:
                    fail_start = now
                elif now - fail_start > 2.0:
                    print("读帧连续失败超过 2 秒，预览中止")
                    exit_code = 1
                    break
                time.sleep(0.005)
                continue
            fail_start = None

            recent.append(now)
            while recent and now - recent[0] > 1.0:
                recent.popleft()
            if len(recent) >= 2 and recent[-1] > recent[0]:
                fps_value = (len(recent) - 1) / (recent[-1] - recent[0])
            else:
                fps_value = 0.0
            brightness_value = frame_brightness(frame)

            vis = draw_overlay(
                frame, fps_value, brightness_value, info["width"], info["height"]
            )
            cv2.imshow("UVC Preview (s: save, q/Esc: quit)", vis)

            key = cv2.waitKey(1) & 0xFF
            if key in (ord("q"), 27):
                break
            if key == ord("s"):
                stamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:-3]
                path = out_dir / f"snapshot_{stamp}.png"
                if cv2.imwrite(str(path), frame):
                    print(f"已保存：{path}")
                else:
                    print(f"保存失败：{path}")
    finally:
        cap.release()
        cv2.destroyAllWindows()

    return exit_code


def build_parser():
    parser = argparse.ArgumentParser(
        description="USB2.0 UVC 摄像头（Sony IMX291，MJPG）Windows 验收脚本",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_list = sub.add_parser("list", help="枚举 DirectShow 摄像头索引")
    p_list.add_argument("--max-index", type=int, default=8,
                        help="最大尝试索引，默认 8")
    p_list.set_defaults(func=cmd_list)

    p_fps = sub.add_parser("fps", help="MJPG 帧率与亮度测试")
    p_fps.add_argument("--index", type=int, required=True, help="摄像头索引")
    p_fps.add_argument("--width", type=int, default=1280, help="请求宽度，默认 1280")
    p_fps.add_argument("--height", type=int, default=720, help="请求高度，默认 720")
    p_fps.add_argument("--fps", type=float, default=30.0, help="标称帧率，默认 30")
    p_fps.add_argument("--seconds", type=float, default=20.0,
                       help="采集时长（秒），默认 20")
    p_fps.add_argument("--out", default=None, help="输出目录")
    p_fps.add_argument("--exposure", type=float, default=None,
                       help="手动曝光值（DirectShow 为 log2 秒，如 -5）")
    p_fps.set_defaults(func=cmd_fps)

    p_prev = sub.add_parser("preview", help="实时预览、截图与属性对话框")
    p_prev.add_argument("--index", type=int, required=True, help="摄像头索引")
    p_prev.add_argument("--width", type=int, default=1280, help="请求宽度，默认 1280")
    p_prev.add_argument("--height", type=int, default=720, help="请求高度，默认 720")
    p_prev.add_argument("--fps", type=float, default=30.0, help="请求帧率，默认 30")
    p_prev.add_argument("--dialog", action="store_true",
                        help="打开驱动属性对话框")
    p_prev.add_argument("--out", default=None, help="截图输出目录")
    p_prev.set_defaults(func=cmd_preview)

    return parser


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
