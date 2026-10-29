# ADAS 交通信号灯识别 (tl_det) C 模块测试与评测报告

## 一、模块定位与参数配置

`tl_det.h` 与 `tl_det.c` 为纯 C99 模块，只依赖 libc/libm，不依赖 OpenCV/NumPy 等第三方库。

1. **输入与输出范围**：
   - 本模块仅负责信号灯检测与滤波输出（`sig_left, sig_straight, sig_right, raw_left, raw_straight, raw_right, n_lights, lights`）。
   - **车道线列不产出**：输出 CSV 中 `left_line/right_line` 为空串，`left_cov/right_cov` 为 0。
   - **自车运动列为外部输入回显**：`ego_motion/motion_score` 仅用于回显外部传入的自车运动状态，带 `--ref` 时来自参考 CSV 输入回显；不带 `--ref` 时默认回显 `moving`。
2. **参数配置方式**：
   - `tl_det.c` 中的 `tl_params_default()` 将 `params.json` 中 `tl` 节的所有参数硬编码定义为编译期静态常量初值，与 Python 参考算法口径完全一致。
   - 算法执行时所有阈值（HSV 范围、滤波尺寸、面积/宽高比阈值、时序参数等）均从传入的 `tl_params_t` 结构体读取；嵌入式板端部署时不读取外部 JSON 文件。

---

## 二、逐帧一致率对比（C vs Python `E_r45`，共 7 段，2678 帧）

测试环境：WSL Ubuntu-22.04（ELF 二进制通过 `zig cc -target x86_64-linux-gnu -O2 -std=c99` 编译）。
测试脚本：`tools/adas/host_test/run_host_test.sh`、`tools/adas/host_test/compare.py`。

### 表 1：检测级 RAW (瞬时检测关联结果) 逐帧一致率（独立感知，无需外部状态）

| Video ID | 评估帧数 | RAW 一致帧数 | RAW 一致率 |
| :---: | :---: | :---: | :---: |
| **112454** | 36 | 36 | 100.00% |
| **112507** | 450 | 450 | 100.00% |
| **112739** | 926 | 926 | 100.00% |
| **113343** | 219 | 219 | 100.00% |
| **113421** | 131 | 131 | 100.00% |
| **113452** | 144 | 144 | 100.00% |
| **113539** | 772 | 772 | 100.00% |
| **总计** | **2678** | **2678** | **100.00%** |

*结论*：纯 C 视觉检测管线（HSV 查表、形态学、连通域标记、形状判定及 associate）与 Python 参考代码逐像素、逐帧完全一致，检测级一致率达 100.00%。

---

### 表 2：滤波后 SIG 逐帧一致率对比（共享 ego_motion 输入 vs 独立无参考输入）

时序滤波逻辑中，自车静止（`ego_stopped`）会阻止红灯超时清零（保持当前状态），自车行驶（`moving`）时超过 2.0 s 未检测到灯头则重置为 `none`。

| Video ID | 评估帧数 | 共享 `--ref` ego_motion 模式 | 独立运行模式（无 `--ref`，默认 moving） |
| :---: | :---: | :---: | :---: |
| **112454** | 36 | 36 / 36 (100.00%) | 36 / 36 (100.00%) |
| **112507** | 450 | 450 / 450 (100.00%) | 450 / 450 (100.00%) |
| **112739** | 926 | 926 / 926 (100.00%) | 858 / 926 (**92.66%**) |
| **113343** | 219 | 219 / 219 (100.00%) | 212 / 219 (**96.80%**) |
| **113421** | 131 | 131 / 131 (100.00%) | 131 / 131 (100.00%) |
| **113452** | 144 | 144 / 144 (100.00%) | 144 / 144 (100.00%) |
| **113539** | 772 | 772 / 772 (100.00%) | 772 / 772 (100.00%) |
| **总计** | **2678** | **2678 / 2678 (100.00%)** | **2603 / 2678 (97.20%)** |

*差异说明*：
- 在 112739（68 帧差异）和 113343（7 帧差异）中，车辆在路口长时间等待红灯，若无自车停止信号输入，信号灯在 2.0 s 丢失后按行驶逻辑衰减为 `none`，导致 75 帧时序保持不一致。
- 给定相同 `ego_motion` 输入时，滤波状态迁移与 Python 100% 对齐。

---

## 三、SIG 用例评测结果（`eval_ref.py`）

| 运行模式 | SIG 用例总数 | 参评数 | PASS | FAIL | SIG 通过率 |
| :---: | :---: | :---: | :---: | :---: | :---: |
| **带 `--ref` (共享运动状态)** | 69 | 69 | **63** | 6 | **91.3%** |
| **无 `--ref` (独立 C 运行)** | 69 | 69 | **63** | 6 | **91.3%** |

*结论*：无论是否接入外部自车静止状态，测试用例时间窗内的有效识别率均满足判决要求，SIG 通过数均为 **63 / 69**（指标要求 ≥63/69）。

---

## 四、编译结果与运行耗时

1. **编译测试**：
   - Linux 目标：`zig cc -target x86_64-linux-gnu -O2 -std=c99 -Wall -Wextra -I tools/adas tools/adas/tl_det.c tools/adas/host_test/tl_host_main.c -o tools/adas/host_test/tl_host_main`，**0 warning, 0 error**。
   - Windows 语法检查：`zig cc -O2 -std=c99 -Wall -Wextra -I tools/adas tools/adas/tl_det.c tools/adas/host_test/tl_host_main.c -o tools/adas/host_test/tl_host_main.exe`，**0 warning, 0 error**。
2. **运行耗时**：
   - 7 段共 2678 帧全量运行（无参考组）总用时 **186 s**（含 ffmpeg 软解 1080p BGR24 开销，平均约 14.4 fps；C 算法检测本身单帧仅约 4~6 ms）。
   - 脚本 `run_host_test.sh`、`compare.py`、`eval_ref.py` 退出码均为 0。

---

## 五、交给板上 `usb_feed` 集成说明

1. **头文件与源文件**：`tools/adas/tl_det.h`，`tools/adas/tl_det.c`。
2. **参数初始化**：调用 `tl_params_default(&params)`，板端无需解析 JSON 配置文件。
3. **接口调用**：
   - `tl_detect(bgr, 1920, 1080, &params, boxes, max_boxes)`：输入图像，输出检测框。
   - `tl_associate(boxes, n_boxes, raw)`：输出当前帧瞬时 `[left, straight, right]`。
   - `tl_filter_update(&filt, raw, ego_stopped, sig)`：输入瞬时决策和运动模块计算的 `ego_stopped`，输出时序稳定状态。
4. **内存与外部依赖**：单帧无任何 `malloc/free`，仅依赖标准 C 库与数学库。
