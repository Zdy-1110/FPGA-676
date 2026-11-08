# FPGA 定点流式车道线检测模型测试向量说明文档 (RTL Testbench 对齐规范)

本文档定义了 `log/lane_fpga/vectors/` 下导出的 3 段硬件测试向量及逐帧、逐行比对基准规范。测试向量与 Python 定点流式黄金模型完全对齐，各段均在冷启动状态（上电复位，无历史跟踪，表决移位寄存器清零）下连续输入 60 帧图像数据。

---

## 一、测试向量概览

测试向量分为三段，各 60 帧（共 180 帧）：

| 向量段目录 | 源视频文件 | 帧号范围 | 视频时间戳(s) | 对应评测用例 | 场景特征与期望稳态行为 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `seg_A_solid` | `video_20260929_112507.mp4` | 285 ~ 344 | 9.50 ~ 11.47 | LANE-112507-02 | 白实线时段，左侧稳定判定为实线 |
| `seg_B_dashed` | `video_20260929_113343.mp4` | 60 ~ 119 | 2.00 ~ 3.97 | LANE-113343-03 | 白虚线时段，右侧稳定判定为虚线 |
| `seg_C_double_yellow` | `video_20260929_113539.mp4` | 1110 ~ 1169 | 37.00 ~ 38.97 | LANE-113539-04 | 双黄线时段，左侧稳定判定为双黄实线 |
| `seg_board` | 实板 dump (slot0_dump) | 24 帧 | 实机复现序列 | 实板调试 | 60Hz/30fps 重复采样序列，验证真实路面跟踪与 Run 上限 |
| `seg_recover` | 全黑 16 帧 + seg_board 24 帧 | 40 帧 | 故障恢复序列 | 跟踪恢复测试 | 验证连续丢失（12 帧全黑）后重装标称先验并迅速锁回真实车道线 |

### 请求表（Request Table）
每段 60 帧按固定时间表注入模拟 ADAS/MCU 变道请求：
- **第 0 ~ 19 帧**：无变道请求 (`req_cmd = "NONE"`, `req_force = 0`)。若自车压线偏离则输出 2 (ALARM)，否则输出 0 (KEEP)。
- **第 20 ~ 39 帧**：左转向灯请求 (`req_cmd = "TURN_LEFT"`, `req_force = 0`)。若目标车道线为虚线且未压线，输出 1 (ALLOW)；若压线输出 2 (ALARM)；若为实线则输出 0 (KEEP)。
- **第 40 ~ 59 帧**：强制左变道请求 (`req_cmd = "FORCE_LEFT"`, `req_force = 1`)。若目标车道线为虚线输出 1 (ALLOW)；实线或无有效线输出 2 (ALARM)。

---

## 二、文件格式与字段定义

每段测试目录下包含三个文件：
1. `frames.bin`: 原始图像二进制输入流
2. `rows.csv`: 逐行处理中间数据（光栅流式断点比对）
3. `frames.csv`: 逐帧定点统计量、拟合、滤波与判决（帧末比对）

### 1. `frames.bin` 二进制图像格式
- **尺寸**：60 帧 × 540 行 × 960 列。
- **存储格式**：每个像素 16-bit 无符号整数 (`uint16_t`, 小端序 `little-endian`)，全文件大小为 $60 \times 540 \times 960 \times 2 = 62,208,000$ 字节。
- **色彩排布**：标准光栅扫描顺序（先行后列），RGB565 编码：
  - `bit[15:11]`: R (5 位)
  - `bit[10:5]`:  G (6 位)
  - `bit[4:0]`:   B (5 位)

### 2. `rows.csv` 逐行候选点字段定义
每个文件包含 $60 \text{ 帧} \times 241 \text{ 行} = 14,460$ 行数据（$y \in [260, 500]$）：
- `frame`: 帧号 ($0 \sim 59$)，8 位整数。
- `y`: 画面行坐标 ($260 \sim 500$)，10 位无符号整数。
- `left_x`: 左侧接受进拟合的点 x 坐标（$0 \sim 959$），无接受点填 `-1`。10 位有符号整数。
- `left_hit`: 左侧该行是否有效命中（`1` 或 `0`），1 位布尔。
- `left_double`: 左侧该行是否检测到双线相伴 run（`1` 或 `0`），1 位布尔。
- `right_x`: 右侧接受进拟合的点 x 坐标（$0 \sim 959$），无接受点填 `-1`。10 位有符号整数。
- `right_hit`: 右侧该行是否有效命中（`1` 或 `0`），1 位布尔。
- `right_double`: 右侧该行是否检测到双线相伴 run（`1` 或 `0`），1 位布尔。

### 3. `frames.csv` 逐帧统计与判决字段定义
每行对应一帧，包含 46 列完整硬件内部寄存器状态：
- **公共请求与判决**：
  - `frame`: 帧号 ($0 \sim 59$)。
  - `req_cmd`: 输入请求命令字符串 (`NONE` / `TURN_LEFT` / `FORCE_LEFT`)。
  - `req_force`: 强制变道标志 (`0` 或 `1`)。
  - `decision`: 硬件最终输出指令编码：`0` = KEEP (保持), `1` = ALLOW (允许变道), `2` = ALARM (告警)。
- **左右两侧对称字段**（以 `left_` 为例，`right_` 相同）：
  - `left_n`: 帧累加命中行数，8 位无符号整数 ($0 \sim 241$)。
  - `left_sum_y`: 命中行累加和 $\sum y_{roi}$（$y_{roi} = y - 260$），16 位无符号整数。
  - `left_sum_yy`: 命中行平方累加和 $\sum y_{roi}^2$，24 位无符号整数。
  - `left_sum_x`: 命中点列坐标累加和 $\sum x$，18 位无符号整数。
  - `left_sum_xy`: 命中点坐标乘积累加和 $\sum (x \cdot y_{roi})$，26 位无符号整数。
  - `left_sum_xx`: 命中点列坐标平方累加和 $\sum x^2$，28 位无符号整数。
  - `left_raw_valid`: 本帧原始最小二乘拟合有效标志（`1` 或 `0`）。
  - `left_raw_a_q16`: 原始最小二乘斜率 $a$，32 位带符号定点数 (Q16)。
  - `left_raw_b_q4`: 原始最小二乘截距 $b$，24 位带符号定点数 (Q4)。
  - `left_ema_a_q16`: EMA 平滑后斜率，32 位带符号定点数 (Q16)。无跟踪填 `0`。
  - `left_ema_b_q4`: EMA 平滑后截距，24 位带符号定点数 (Q4)。无跟踪填 `0`。
  - `left_track_valid`: 跟踪器状态是否有效（`1` 或 `0`）。
  - `left_lost_cnt`: 连续丢失帧计数器（$0 \sim 12$）。
  - `left_solid_run`: 本帧近景 ROI 最长连续命中段长度，8 位无符号整数。
  - `left_solid_flag`: 本帧连续命中比例是否达标（`1` 或 `0`）。
  - `left_double_count`: 本帧双线相伴行总数，8 位无符号整数。
  - `left_double_flag`: 本帧双线行比例是否达标（`1` 或 `0`）。
  - `left_frame_type`: 本帧分类结果字符串 (`dashed` / `solid` / `double_yellow` / `none`)。
  - `left_voted_type`: 多数表决后输出类型字符串 (`dashed` / `solid` / `double_yellow` / `none`)。
  - `left_x_bot`: 底行 ($y=500$) 车道线预测 x 坐标整数（无有效线填 `-1`）。
  - `left_depart`: 自车是否压线/偏离左侧阈值标志（`1` 或 `0`）。

---

## 三、硬件定点运算与算法细节规范

### 1. RGB565 解包与 8 位扩展
对于 16 位像素 `pix`：
$$R_5 = (pix \gg 11) \ \& \ 0\text{x}1F, \quad G_6 = (pix \gg 5) \ \& \ 0\text{x}3F, \quad B_5 = pix \ \& \ 0\text{x}1F$$
扩展回 8 位（低位补 0 移位）：
$$R_q = R_5 \ll 3, \quad G_q = G_6 \ll 2, \quad B_q = B_5 \ll 3$$

### 2. 灰度通道与黄线通道合成
加法移位无乘法实现：
$$G = (R_q + (G_q \ll 1) + B_q) \gg 2$$
$$G_y = (R_q + G_q) \gg 1$$

### 3. 动态透视尺度 $d(y)$ 与搜索窗口 $W(y)$
令 $\Delta y = y_{bot} - y_{top} = 500 - 260 = 240$，$y_{roi} = y - 260 \in [0, 240]$：
$$d(y) = \text{div\_round}\big(d_{top} \cdot \Delta y + y_{roi} \cdot (d_{bot} - d_{top}), \ \Delta y\big)$$
$$W(y) = \text{div\_round}\big(W_{top} \cdot \Delta y + y_{roi} \cdot (W_{bot} - W_{top}), \ \Delta y\big)$$
其中带符号四舍五入整数除法 $\text{div\_round}(A, B)$ 硬件实现为：
$$\text{div\_round}(A, B) = \begin{cases} (A + (B \gg 1)) \ / \ B, & A \ge 0 \\ (A - (B \gg 1)) \ / \ B, & A < 0 \end{cases}$$

### 4. 脊线比对与车道像素判定
单行在移位寄存器抽头处（抽头间距 $d(y)$，总延时 $2d(y) \le 28$ 拍）：
$$R_w = G(x) - \max\big(G(x - d(y)), \ G(x + d(y))\big)$$
$$R_y = G_y(x) - \max\big(G_y(x - d(y)), \ G_y(x + d(y))\big)$$
像素点分类：
- **白色车道线像素**：$(R_w \ge white\_\delta) \ \& \ (G(x) \ge white\_g\_min)$
- **黄色车道线像素**：$(R_q \ge yellow\_r\_min) \ \& \ (G_q \ge yellow\_g\_min) \ \& \ (B_q + yellow\_b\_diff \le \min(R_q, G_q)) \ \& \ (R_y \ge yellow\_\delta)$

连续像素 Run 宽度约束：$w_{min} \le lens \le w_{max}$，其中 $w_{max} = \text{round}(1.5 \cdot d(y) + 2.0)$。
Run 中心坐标：$x_{cand} = d(y) + \big((start + end - 1) \gg 1\big)$。

### 5. 帧末最小二乘与定点除法解算
行列消隐期解算分子分母：
$$D = n \cdot S_{yy} - S_y^2$$
$$N_a = n \cdot S_{xy} - S_x \cdot S_y$$
$$N_b = S_x \cdot S_{yy} - S_y \cdot S_{xy}$$
当 $D > 0$ 时求取定点商：
$$a_{q16} = \text{div\_round}(N_a \ll 16, \ D)$$
$$b_{q4} = \text{div\_round}(N_b \ll 4, \ D)$$

**RMS 校验无开方整数化**：
$$SSE = S_{xx} - \big((a_{q16} \cdot S_{xy}) \gg 16\big) - \big((b_{q4} \cdot S_x) \gg 4\big)$$
$$SSE \le n \cdot (rms\_max^2) \quad (\text{当 } rms\_max=16.0 \text{ 时，} rms\_max^2 = 256)$$
结合斜率符号约束 ($a_{left} < 0, a_{right} > 0$) 及画面范围校验即得 `raw_valid`。

### 6. 定点 EMA 平滑滤波与丢失后标称先验重装（Reseed Prior）
- **正常有效帧 EMA 更新**：
  平滑系数 $\alpha = 1/2$ (`ema_alpha_shift = 1`)：
  $$a_{smooth} \Leftarrow a_{smooth} + \big((a_{q16} - a_{smooth}) \gg 1\big)$$
  $$b_{smooth} \Leftarrow b_{smooth} + \big((b_{q4} - b_{smooth}) \gg 1\big)$$
  $invalid\_count \Leftarrow 0$，$valid \Leftarrow 1$。
- **丢失重装标称先验规则**：
  当单帧拟合无效（`raw_valid == 0`）时，$invalid\_count \Leftarrow invalid\_count + 1$。
  当连续丢失帧数达到阈值（$invalid\_count \ge k_{lost\_frames} = 12$）的那一刻，**立即重新装入标称先验**，使状态重回跟踪态，避免进入无先验冷启动而在纹理路面永久失锁：
  - $valid \Leftarrow 1$
  - $invalid\_count \Leftarrow 0$
  - 左侧标称先验定点值：
    - $a_{smooth, q16} = \text{round}(init\_a\_left \cdot 65536) = \text{round}(-0.95 \cdot 65536) = -62259$ (`0xFFFF0CE5`)
    - $b_{smooth, q4} = \text{round}(init\_b\_left \cdot 16) = \text{round}(400.0 \cdot 16) = 6400$ (`0x00001900`)
  - 右侧标称先验定点值：
    - $a_{smooth, q16} = \text{round}(init\_a\_right \cdot 65536) = \text{round}(0.90 \cdot 65536) = 58982$ (`0x0000E666`)
    - $b_{smooth, q4} = \text{round}(init\_b\_right \cdot 16) = \text{round}(560.0 \cdot 16) = 8960$ (`0x00002300`)
  - **重要约束**：$history\_types$（32/24 帧滑动表决历史队列）**保持不变，不得清空**。若配置中无标称先验，则保留原冷启动逻辑（$valid \Leftarrow 0$）。

### 7. 虚实比例与 24 帧滑动多数表决
- **实线连续段比例判定**：
  $$solid\_run \cdot 1000 \ge eval\_n\_rows \cdot 250$$
- **双黄线行数比例判定**：
  $$double\_count \cdot 1000 \ge n\_rows \cdot 250$$
- **24 帧滑动窗口表决**：
  统计窗口中 $N_{solid}$（含 solid 与 double_yellow）、$N_{dash}$、与 $N_{double}$。
  - 若 $N_{solid} + N_{dash} == 0 \implies \text{"none"}$
  - 若 $N_{solid} \ge N_{dash}$（**平局判实线**）：
    若 $(N_{double} \ll 1) > N_{solid}$，表决为 $\text{"double\_yellow"}$；否则表决为 $\text{"solid"}$。
  - 否则表决为 $\text{"dashed"}$。

---

## 四、全局参数字典（取自 params.json）

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
