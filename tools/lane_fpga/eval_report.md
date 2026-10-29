# FPGA 定点流式车道线模型评测报告

- 评测时间：2026-10-28 12:25:12
- 总用例数：32，通过数：16，通过率：50.0%
- 对比基线（ref_algo H_pair）：17/32 通过（53.1%）
- 最终评估状态：FPGA 定点模型通过数 16/32 (50.0%)

## 一、全局参数配置

```json
{
  "w": 960,
  "h": 540,
  "y_top": 260,
  "y_bot": 500,
  "x_c": 480,
  "ego_x": 480,
  "d_top": 3,
  "d_bot": 14,
  "white_delta": 18,
  "white_g_min": 120,
  "yellow_r_min": 130,
  "yellow_g_min": 120,
  "yellow_b_diff": 20,
  "yellow_delta": 14,
  "w_max_mult": 1.5,
  "w_max_add": 2.0,
  "w_min": 1,
  "w_pred_top": 12,
  "w_pred_bot": 40,
  "double_mult": 2.0,
  "double_gap_min": 3,
  "n_min": 25,
  "rms_max": 16.0,
  "q_a": 16,
  "q_b": 4,
  "ema_alpha_shift": 1,
  "k_lost_frames": 12,
  "gap_tol": 0,
  "solid_y_top": 260,
  "solid_run_ratio": 0.25,
  "double_ratio_thr": 0.25,
  "vote_window": 24,
  "depart_margin": 60,
  "init_a_left": -0.95,
  "init_b_left": 400.0,
  "init_a_right": 0.9,
  "init_b_right": 560.0
}
```

## 二、32 个 LANE 用例逐用例评测明细及与 ref_algo 对比

| 用例ID | 视频 | 时间窗(s) | 方向 | 指令 | 期望 | FPGA预测 | 匹配率 | FPGA结果 | ref_algo结果 | 说明 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| LANE-112507-01 | 112507 | [1.00, 9.50] | left | 左转向 | ALLOW | KEEP | 34.9% | `FAIL` | PASS | 虚线 |
| LANE-112507-02 | 112507 | [9.50, 12.50] | left | 左转向 | KEEP | KEEP | 100.0% | **PASS** | FAIL | 线=white_solid |
| LANE-112507-03 | 112507 | [9.50, 12.50] | left | 强制左变道 | ALARM | ALARM | 100.0% | **PASS** | FAIL | 线=white_solid 强制压线 |
| LANE-112507-04 | 112507 | [15.00, 19.50] | left | 左转向 | ALLOW | KEEP | 22.0% | `FAIL` | FAIL | 虚线 |
| LANE-112507-05 | 112507 | [19.50, 23.00] | left | 左转向 | KEEP | ALLOW | 27.3% | `FAIL` | PASS | 线=white_solid |
| LANE-112507-06 | 112507 | [19.50, 23.00] | left | 强制左变道 | ALARM | ALLOW | 27.3% | `FAIL` | PASS | 线=white_solid 强制压线 |
| LANE-112507-07 | 112507 | [26.00, 30.00] | left | 左转向 | ALLOW | KEEP | 24.3% | `FAIL` | PASS | 虚线 |
| LANE-112507-08 | 112507 | [36.00, 38.50] | left | 左转向 | KEEP | KEEP | 100.0% | **PASS** | PASS | 线=white_solid |
| LANE-112507-09 | 112507 | [36.00, 38.50] | left | 强制左变道 | ALARM | ALARM | 100.0% | **PASS** | PASS | 线=white_solid 强制压线 |
| LANE-112507-10 | 112507 | [43.00, 45.00] | left | 左转向 | ALLOW | ALLOW | 100.0% | **PASS** | PASS | 虚线 |
| LANE-112507-11 | 112507 | [1.00, 9.50] | right | 右转向 | ALLOW | KEEP | 30.3% | `FAIL` | PASS | 虚线 |
| LANE-112507-12 | 112507 | [9.50, 12.50] | right | 右转向 | KEEP | KEEP | 100.0% | **PASS** | FAIL | 线=white_solid |
| LANE-112507-13 | 112507 | [9.50, 12.50] | right | 强制右变道 | ALARM | ALARM | 100.0% | **PASS** | FAIL | 线=white_solid 强制压线 |
| LANE-112507-14 | 112507 | [15.00, 19.50] | right | 右转向 | ALLOW | ALLOW | 53.4% | `FAIL` | FAIL | 虚线 |
| LANE-112507-15 | 112507 | [19.50, 23.00] | right | 右转向 | KEEP | KEEP | 87.5% | **PASS** | PASS | 线=white_solid |
| LANE-112507-16 | 112507 | [19.50, 23.00] | right | 强制右变道 | ALARM | ALARM | 87.5% | **PASS** | PASS | 线=white_solid 强制压线 |
| LANE-112507-17 | 112507 | [26.00, 35.00] | right | 右转向 | ALLOW | KEEP | 40.7% | `FAIL` | PASS | 虚线 |
| LANE-112507-18 | 112507 | [36.00, 38.50] | right | 右转向 | KEEP | ALLOW | 31.0% | `FAIL` | PASS | 线=white_solid |
| LANE-112507-19 | 112507 | [36.00, 38.50] | right | 强制右变道 | ALARM | ALLOW | 31.0% | `FAIL` | PASS | 线=white_solid 强制压线 |
| LANE-113343-01 | 113343 | [0.00, 8.00] | left | 左转向 | KEEP | KEEP | 100.0% | **PASS** | FAIL | 线=yellow_solid |
| LANE-113343-02 | 113343 | [0.00, 8.00] | left | 强制左变道 | ALARM | ALARM | 100.0% | **PASS** | FAIL | 线=yellow_solid 强制压线 |
| LANE-113343-03 | 113343 | [0.00, 8.00] | right | 右转向 | ALLOW | KEEP | 28.7% | `FAIL` | PASS | 虚线 |
| LANE-113452-01 | 113452 | [0.00, 5.00] | left | 左转向 | ALLOW | KEEP | 0.0% | `FAIL` | PASS | 虚线 |
| LANE-113539-01 | 113539 | [0.00, 5.00] | left | 左转向 | KEEP | KEEP | 86.5% | **PASS** | FAIL | 线=yellow_solid |
| LANE-113539-02 | 113539 | [0.00, 5.00] | left | 强制左变道 | ALARM | ALARM | 86.5% | **PASS** | FAIL | 线=yellow_solid 强制压线 |
| LANE-113539-03 | 113539 | [0.00, 5.00] | right | 右转向 | ALLOW | ALLOW | 82.0% | **PASS** | PASS | 虚线 |
| LANE-113539-04 | 113539 | [37.00, 47.00] | left | 左转向 | KEEP | KEEP | 85.9% | **PASS** | FAIL | 线=double_yellow |
| LANE-113539-05 | 113539 | [37.00, 47.00] | left | 强制左变道 | ALARM | ALARM | 85.9% | **PASS** | FAIL | 线=double_yellow 强制压线 |
| LANE-113539-06 | 113539 | [54.00, 60.00] | left | 左转向 | KEEP | KEEP | 52.1% | `FAIL` | FAIL | 线=double_yellow |
| LANE-113539-07 | 113539 | [54.00, 60.00] | left | 强制左变道 | ALARM | ALARM | 52.1% | `FAIL` | FAIL | 线=double_yellow 强制压线 |
| LANE-113539-08 | 113539 | [37.00, 47.00] | right | 右转向 | ALLOW | KEEP | 33.2% | `FAIL` | PASS | 虚线 |
| LANE-113539-09 | 113539 | [54.00, 60.00] | right | 右转向 | ALLOW | ALLOW | 66.9% | `FAIL` | FAIL | 虚线 |

## 三、FPGA 模型与 ref_algo 结论不同用例分析

共有 21 个用例的判定结果发生变化：

- **LANE-112507-01** (112507): ref_algo=PASS -> FPGA=FAIL (期望: ALLOW, 预测: KEEP, 匹配率: 34.9%, 备注: 虚线)
- **LANE-112507-02** (112507): ref_algo=FAIL -> FPGA=PASS (期望: KEEP, 预测: KEEP, 匹配率: 100.0%, 备注: 线=white_solid)
- **LANE-112507-03** (112507): ref_algo=FAIL -> FPGA=PASS (期望: ALARM, 预测: ALARM, 匹配率: 100.0%, 备注: 线=white_solid 强制压线)
- **LANE-112507-05** (112507): ref_algo=PASS -> FPGA=FAIL (期望: KEEP, 预测: ALLOW, 匹配率: 27.3%, 备注: 线=white_solid)
- **LANE-112507-06** (112507): ref_algo=PASS -> FPGA=FAIL (期望: ALARM, 预测: ALLOW, 匹配率: 27.3%, 备注: 线=white_solid 强制压线)
- **LANE-112507-07** (112507): ref_algo=PASS -> FPGA=FAIL (期望: ALLOW, 预测: KEEP, 匹配率: 24.3%, 备注: 虚线)
- **LANE-112507-11** (112507): ref_algo=PASS -> FPGA=FAIL (期望: ALLOW, 预测: KEEP, 匹配率: 30.3%, 备注: 虚线)
- **LANE-112507-12** (112507): ref_algo=FAIL -> FPGA=PASS (期望: KEEP, 预测: KEEP, 匹配率: 100.0%, 备注: 线=white_solid)
- **LANE-112507-13** (112507): ref_algo=FAIL -> FPGA=PASS (期望: ALARM, 预测: ALARM, 匹配率: 100.0%, 备注: 线=white_solid 强制压线)
- **LANE-112507-17** (112507): ref_algo=PASS -> FPGA=FAIL (期望: ALLOW, 预测: KEEP, 匹配率: 40.7%, 备注: 虚线)
- **LANE-112507-18** (112507): ref_algo=PASS -> FPGA=FAIL (期望: KEEP, 预测: ALLOW, 匹配率: 31.0%, 备注: 线=white_solid)
- **LANE-112507-19** (112507): ref_algo=PASS -> FPGA=FAIL (期望: ALARM, 预测: ALLOW, 匹配率: 31.0%, 备注: 线=white_solid 强制压线)
- **LANE-113343-01** (113343): ref_algo=FAIL -> FPGA=PASS (期望: KEEP, 预测: KEEP, 匹配率: 100.0%, 备注: 线=yellow_solid)
- **LANE-113343-02** (113343): ref_algo=FAIL -> FPGA=PASS (期望: ALARM, 预测: ALARM, 匹配率: 100.0%, 备注: 线=yellow_solid 强制压线)
- **LANE-113343-03** (113343): ref_algo=PASS -> FPGA=FAIL (期望: ALLOW, 预测: KEEP, 匹配率: 28.7%, 备注: 虚线)
- **LANE-113452-01** (113452): ref_algo=PASS -> FPGA=FAIL (期望: ALLOW, 预测: KEEP, 匹配率: 0.0%, 备注: 虚线)
- **LANE-113539-01** (113539): ref_algo=FAIL -> FPGA=PASS (期望: KEEP, 预测: KEEP, 匹配率: 86.5%, 备注: 线=yellow_solid)
- **LANE-113539-02** (113539): ref_algo=FAIL -> FPGA=PASS (期望: ALARM, 预测: ALARM, 匹配率: 86.5%, 备注: 线=yellow_solid 强制压线)
- **LANE-113539-04** (113539): ref_algo=FAIL -> FPGA=PASS (期望: KEEP, 预测: KEEP, 匹配率: 85.9%, 备注: 线=double_yellow)
- **LANE-113539-05** (113539): ref_algo=FAIL -> FPGA=PASS (期望: ALARM, 预测: ALARM, 匹配率: 85.9%, 备注: 线=double_yellow 强制压线)
- **LANE-113539-08** (113539): ref_algo=PASS -> FPGA=FAIL (期望: ALLOW, 预测: KEEP, 匹配率: 33.2%, 备注: 虚线)

## 四、未通过用例归因分析

- **LANE-112507-01** (112507): 期望 ALLOW, 实际主要预测 KEEP, 匹配率 34.9%, 标注: 虚线
- **LANE-112507-04** (112507): 期望 ALLOW, 实际主要预测 KEEP, 匹配率 22.0%, 标注: 虚线
- **LANE-112507-05** (112507): 期望 KEEP, 实际主要预测 ALLOW, 匹配率 27.3%, 标注: 线=white_solid
- **LANE-112507-06** (112507): 期望 ALARM, 实际主要预测 ALLOW, 匹配率 27.3%, 标注: 线=white_solid 强制压线
- **LANE-112507-07** (112507): 期望 ALLOW, 实际主要预测 KEEP, 匹配率 24.3%, 标注: 虚线
- **LANE-112507-11** (112507): 期望 ALLOW, 实际主要预测 KEEP, 匹配率 30.3%, 标注: 虚线
- **LANE-112507-14** (112507): 期望 ALLOW, 实际主要预测 ALLOW, 匹配率 53.4%, 标注: 虚线
- **LANE-112507-17** (112507): 期望 ALLOW, 实际主要预测 KEEP, 匹配率 40.7%, 标注: 虚线
- **LANE-112507-18** (112507): 期望 KEEP, 实际主要预测 ALLOW, 匹配率 31.0%, 标注: 线=white_solid
- **LANE-112507-19** (112507): 期望 ALARM, 实际主要预测 ALLOW, 匹配率 31.0%, 标注: 线=white_solid 强制压线
- **LANE-113343-03** (113343): 期望 ALLOW, 实际主要预测 KEEP, 匹配率 28.7%, 标注: 虚线
- **LANE-113452-01** (113452): 期望 ALLOW, 实际主要预测 KEEP, 匹配率 0.0%, 标注: 虚线
- **LANE-113539-06** (113539): 期望 KEEP, 实际主要预测 KEEP, 匹配率 52.1%, 标注: 线=double_yellow
- **LANE-113539-07** (113539): 期望 ALARM, 实际主要预测 ALARM, 匹配率 52.1%, 标注: 线=double_yellow 强制压线
- **LANE-113539-08** (113539): 期望 ALLOW, 实际主要预测 KEEP, 匹配率 33.2%, 标注: 虚线
- **LANE-113539-09** (113539): 期望 ALLOW, 实际主要预测 ALLOW, 匹配率 66.9%, 标注: 虚线

## 五、RTL 硬件资源估计（PG2L100H 实现方案）

按本定点流式模型在 FPGA (Pango PG2L100H) 上的硬件实现结构，资源消耗估算如下：

### 1. 数据通路与算子分配
| 算法模块 | 操作类型 | 位宽与配置 | 资源类型 | 估计数量 | 说明 |
| --- | --- | --- | --- | --- | --- |
| 窗口 0 预处理 | RGB565 解包 + 移位加法 | 8 位数据流 | 查找表 (LUT) | ~80 LUTs | 无乘法器，加法移位完成 (r+2g+b)>>2 与 (r+g)>>1 |
| 逐行移位缓冲 | 行内局部脊线采样 | 8 位宽，深度 28 | 寄存器 / 移位寄存器 | ~224 FFs | 单行最大 d=14，仅需 2d=28 拍流水线寄存器，**无需 BRAM 行缓冲** |
| 脊线比对与分类 | 减法器与比较器 | 8~10 位比较 | LUT & FF | ~160 LUTs | 计算 R_w, R_y 及白/黄阈值比较 |
| 游程 (Run) 统计 | 计数器与边缘检测 | 10 位计数器 | LUT & FF | ~120 LUTs | 检测连续 Run 起止，求取中心 x=(start+end)>>1 |
| 动态候选与双线 | 绝对值差与窗口比对 | 10 位减法与比较器 | LUT & FF | ~200 LUTs | |x-x_pred|<=W(y) 动态窗口滤波，双线间距比对 |
| 帧累加器 (每侧 6 个) | 累加寄存器 | n(8b), Sy(16b), Syy(24b), Sx(18b), Sxy(26b), Sxx(28b) | 寄存器 (FFs) | ~240 FFs | 双侧共 12 个累加器，逐行实时更新 |
| 帧末最小二乘求解 | 乘法运算 | 28b × 16b / 18b × 16b | 专用 DSP (APM) | 4 个 18×18 DSP | 行末消隐期 (V-Blank) 复用解算分子分母 |
| 帧末定点除法 | 整数除法器 (商与余数) | 36 位被除数 ÷ 24 位除数 | 时序除法器 (Radix-4) | ~400 LUTs, 0 DSP | 利用垂直消隐期 (数百个时钟周期) 进行多拍迭代求解，无需单周期大除法器 |
| EMA 平滑与跟踪表决 | 移位累加与滑动窗口 | 16 位 Q16 / 4 位 Q4 | LUT & 32 位移位寄存器 | ~150 LUTs, 100 FFs | 双侧 EMA 与 32 帧环形队列多数表决 |

### 2. 总体资源占用概算 (PG2L100H)
- **LUTs (查找表)**: 约 1,800 ~ 2,200 个 (占 PG2L100H 约 2% 逻辑资源)
- **Registers (触发器)**: 约 1,200 ~ 1,500 个 (占总触发器约 1.5%)
- **Block RAM (DRM/BRAM)**: **0 个** (完全不需要整帧缓存或行缓存，纯光栅流式流水线)
- **DSP (APM99)**: 4 个 (占芯片 240 个 DSP 的 1.6%)
- **系统时钟**: 148.5 MHz 时序极为充裕（纯前向简单流水线），易于通过时序收敛。
