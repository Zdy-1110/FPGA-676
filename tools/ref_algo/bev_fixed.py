# -*- coding: utf-8 -*-
"""FPGA 鸟瞰图（BEV）定点黄金模型（Bit-Accurate Model）。

48 位行表格式（每行 48 位，共 400 行，合计 2400 字节）：
  - [47:32] (16 位): y_q12_4 (uint16)，Q12.4 定点表示原图行坐标 y(v)，12 整数位 + 4 小数位，范围 [0.0, 4095.9375]。
  - [31:16] (16 位): x0_q12_4 (int16 补码)，Q12.4 定点表示，1 符号位 + 11 整数位 + 4 小数位，范围 [-2048.0, 2047.9375]。
  - [15:0]  (16 位): dx_q4_12 (uint16 无符号)，Q4.12 定点表示，4 整数位 + 12 小数位，范围 [0.0, 15.999755859375]。

插值与定点运算（双线性插值）：
  - 纵向坐标：y0 = y_q4 >> 4, y1 = y0 + 1；纵向插值系数 fy = (y_q4 & 0xF) << 2（4 位扩展至 6 位 [0, 60]）。
  - 水平坐标：x_val = (x0_q12_4 << 8) + u * dx_q4_12（保持 12 位小数精度）；x_int = x_val >> 12；
              水平插值系数 fx = ((x_val & 0xFFF) + 32) >> 6，限幅 [0, 64]。
  - 对原图 y0 与 y1 行分别做 2 抽头水平插值得到 p_top 与 p_bot（越界填 0，与 OpenCV borderValue=0 一致）。
  - 纵向插值：val = (p_top * (64 - fy) + p_bot * fy + 32) >> 6，截断至 [0, 255]。

UV 色度判定（近邻取样）：
  - UV 行坐标：uv_row = round(y / 2) = (y_q4 + 16) >> 5。
  - UV 列坐标：uv_col = round(x / 2) = (x_val + 4096) >> 13。
  - 直接提取近邻 UV 像素，不做插值。


脊线判据（Ridge）：
  - G(u) - max(G(u-6), G(u+6)) >= 18 且 G(u) >= 120。
  - 边界处理：u < 6 时 G(u-6)=255；u >= w-6 时 G(u+6)=255（与浮点参考一致，防止边界误触发）。

NV12 UV 色彩判据（与 HSV 等价）：
  - 黄线：U <= 104 且 V >= 136 且 (V - U) >= 36。
  - 白线：|U - 128| + |V - 128| <= 32（覆盖 99.4% 的 S <= 60 标线像素）。
  - 掩膜：mask_m = ridge & (yellow | white)，mask_y = ridge & yellow，mask_w = ridge & white。

列直方图：
  - 400 列计数，统计行范围 0~399，9 位饱和（0~511）。

DMA 回传打包格式（pack / unpack，40,800 字节）：
  - 0..19999 (20,000 字节): mask_m（或 mask_w），400 行 × 50 字节，大端位序（bit7 对应 u%8==0）。
  - 20000..39999 (20,000 字节): mask_y，400 行 × 50 字节，大端位序。
  - 40000..40799 (800 字节): hist，400 个 uint16（小端序）。
"""

import numpy as np


def make_row_table(vp, y_bot, y_top=None, W=1920, H=1080, w=400, h=400):
    """根据设计文档 §5.1 公式生成 400 行的行表 (y_q12_4, x0_q12_4, dx_q4_12)。"""
    vx, vy = float(vp[0]), float(vp[1])
    yb = float(y_bot)
    if y_top is None:
        yt = vy + max(0.05 * H, 0.3 * (yb - vy))
    else:
        yt = float(y_top)

    Db = float(yb - vy)
    Dt = float(yt - vy)
    HS = 0.75 * W

    table = []
    inv_Db = 1.0 / Db if Db != 0 else 1.0
    inv_Dt = 1.0 / Dt if Dt != 0 else 1.0
    diff_inv = inv_Dt - inv_Db

    for v in range(h):
        frac_v = 1.0 - float(v) / float(h - 1)
        denom = inv_Db + frac_v * diff_inv
        y_v = vy + (1.0 / denom if denom != 0 else 0.0)

        s_v = (y_v - vy) / Db if Db != 0 else 1.0
        x0_v = vx - HS * s_v
        dx_v = 2.0 * HS * s_v / float(w - 1)

        y_q4 = int(round(y_v * 16.0))
        x0_q4 = int(round(x0_v * 16.0))
        dx_q12 = int(round(dx_v * 4096.0))

        # 边界与溢出保护 (y_q4 为 16 位无符号，x0_q4 为 16 位补码，dx_q12 为 16 位无符号)
        y_q4 = max(0, min(65535, y_q4))
        x0_q4 = max(-32768, min(32767, x0_q4))
        dx_q12 = max(0, min(65535, dx_q12))

        table.append((y_q4, x0_q4, dx_q12))
    return table


def export_row_table_hex(table, out_path=None):
    """将行表导出为 RTL 可加载的 hex 文本（每行 48 位，12 个十六进制字符）。"""
    lines = []
    for y_q4, x0_q4, dx_q12 in table:
        y_u16 = int(y_q4) & 0xFFFF
        x0_u16 = int(x0_q4) & 0xFFFF
        dx_u16 = int(dx_q12) & 0xFFFF
        word48 = (y_u16 << 32) | (x0_u16 << 16) | dx_u16
        lines.append(f"{word48:012x}\n")
    content = "".join(lines)
    if out_path is not None:
        with open(out_path, "w", encoding="ascii") as f:
            f.write(content)
    return content


def load_row_table_hex(hex_path_or_str):
    """从 hex 文本或文件中读取行表。"""
    if "\n" not in hex_path_or_str and len(hex_path_or_str) < 256:
        with open(hex_path_or_str, "r", encoding="ascii") as f:
            raw = f.read()
    else:
        raw = hex_path_or_str

    table = []
    for line in raw.strip().splitlines():
        line = line.strip()
        if not line:
            continue
        word48 = int(line, 16)
        dx_u16 = word48 & 0xFFFF
        x0_u16 = (word48 >> 16) & 0xFFFF
        y_u16 = (word48 >> 32) & 0xFFFF

        x0_q4 = x0_u16 if x0_u16 < 0x8000 else x0_u16 - 0x10000
        dx_q12 = dx_u16
        y_q4 = y_u16
        table.append((y_q4, x0_q4, dx_q12))
    return table


def bev_sample(Yplane, table, W=1920, H=1080, w=400, h=400, frac_bits=6):
    """双线性定点插值的鸟瞰图采样（水平与纵向均使用定点插值，四舍五入）。"""
    y_q4_arr = np.array([row[0] for row in table], dtype=np.int32)
    x0_q4 = np.array([row[1] for row in table], dtype=np.int32)
    dx_q12 = np.array([row[2] for row in table], dtype=np.int32)

    u = np.arange(w, dtype=np.int32)
    # x_val 为 Q?.12 定点累加器
    x_val = (x0_q4 << 8)[:, None] + u[None, :] * dx_q12[:, None]

    x_int = x_val >> 12
    frac12 = x_val & 0xFFF
    shift = 12 - frac_bits
    round_const = 1 << (shift - 1)
    fx = (frac12 + round_const) >> shift
    scale = 1 << frac_bits
    fx = np.clip(fx, 0, scale)

    # 纵向坐标分解：y0 = floor(y), y1 = y0 + 1, fy = (y_q4 & 0xF) << 2
    y0 = y_q4_arr >> 4
    y1 = y0 + 1
    fy = ((y_q4_arr & 0xF) << 2)[:, None]  # 4 位小数扩展到 6 位 [0, 60]

    yc0 = y0[:, None]
    yc1 = y1[:, None]

    # y0 行水平插值
    val00 = (x_int >= 0) & (x_int < W) & (yc0 >= 0) & (yc0 < H)
    val01 = (x_int + 1 >= 0) & (x_int + 1 < W) & (yc0 >= 0) & (yc0 < H)
    xi0 = np.clip(x_int, 0, W - 1)
    xi1 = np.clip(x_int + 1, 0, W - 1)
    yc0_c = np.clip(yc0, 0, H - 1)

    p00 = np.where(val00, Yplane[yc0_c, xi0], 0).astype(np.int32)
    p01 = np.where(val01, Yplane[yc0_c, xi1], 0).astype(np.int32)
    half = scale >> 1
    p_top = (p00 * (scale - fx) + p01 * fx + half) >> frac_bits

    # y1 行水平插值（越界取 0）
    val10 = (x_int >= 0) & (x_int < W) & (yc1 >= 0) & (yc1 < H)
    val11 = (x_int + 1 >= 0) & (x_int + 1 < W) & (yc1 >= 0) & (yc1 < H)
    yc1_c = np.clip(yc1, 0, H - 1)

    p10 = np.where(val10, Yplane[yc1_c, xi0], 0).astype(np.int32)
    p11 = np.where(val11, Yplane[yc1_c, xi1], 0).astype(np.int32)
    p_bot = (p10 * (scale - fx) + p11 * fx + half) >> frac_bits

    # 纵向插值
    val_y = (p_top * (scale - fy) + p_bot * fy + half) >> frac_bits
    return np.clip(val_y, 0, 255).astype(np.uint8)


def bev_sample_nv12(Yplane, UVplane, table, W=1920, H=1080, w=400, h=400, frac_bits=6):
    """从 NV12 图像采样 BEV：Y 平面做双线性定点插值，UV 色度做近邻映射（不做插值）。

    UV 平面规格：尺寸 (H//2, W)，连续存放 U, V, U, V... 或独立 U, V 平面。
    """
    # 1. 亮度 Y 平面双线性插值
    bev_y = bev_sample(Yplane, table, W=W, H=H, w=w, h=h, frac_bits=frac_bits)

    # 2. 色度 UV 平面近邻取样（不做插值，节省硬件资源）
    if UVplane is None:
        bev_u = np.full((h, w), 128, dtype=np.uint8)
        bev_v = np.full((h, w), 128, dtype=np.uint8)
        return bev_y, bev_u, bev_v

    y_q4_arr = np.array([row[0] for row in table], dtype=np.int32)
    x0_q4 = np.array([row[1] for row in table], dtype=np.int32)
    dx_q12 = np.array([row[2] for row in table], dtype=np.int32)

    u_idx = np.arange(w, dtype=np.int32)
    x_val = (x0_q4 << 8)[:, None] + u_idx[None, :] * dx_q12[:, None]

    # 最近邻 UV 行列坐标：uv_row = round(y / 2), uv_col = round(x / 2)
    uv_row = ((y_q4_arr + 16) >> 5)[:, None]
    uv_col = (x_val + 4096) >> 13

    valid_uv = (uv_col >= 0) & (uv_col < W // 2) & (uv_row >= 0) & (uv_row < H // 2)
    c_x = np.clip(uv_col * 2, 0, W - 2)
    c_y = np.clip(uv_row, 0, (H // 2) - 1)

    if isinstance(UVplane, (tuple, list)):
        u_in, v_in = UVplane[0], UVplane[1]
        if u_in.shape == Yplane.shape:
            # 独立全分辨率 U/V
            c_y_full = np.clip(uv_row * 2, 0, H - 1)
            bev_u = np.where(valid_uv, u_in[c_y_full, c_x], 128).astype(np.uint8)
            bev_v = np.where(valid_uv, v_in[c_y_full, c_x], 128).astype(np.uint8)
        else:
            # 独立半分辨率 U/V (H//2, W//2)
            c_x_half = np.clip(uv_col, 0, (W // 2) - 1)
            bev_u = np.where(valid_uv, u_in[c_y, c_x_half], 128).astype(np.uint8)
            bev_v = np.where(valid_uv, v_in[c_y, c_x_half], 128).astype(np.uint8)
    elif hasattr(UVplane, "ndim") and UVplane.ndim == 2 and UVplane.shape[1] == W:
        # 标准 NV12：(H//2, W)，U 在偶数列，V 在奇数列
        bev_u = np.where(valid_uv, UVplane[c_y, c_x], 128).astype(np.uint8)
        bev_v = np.where(valid_uv, UVplane[c_y, c_x + 1], 128).astype(np.uint8)
    elif hasattr(UVplane, "ndim") and UVplane.ndim == 3 and UVplane.shape[2] == 2:
        c_x_half = np.clip(uv_col, 0, (W // 2) - 1)
        bev_u = np.where(valid_uv, UVplane[c_y, c_x_half, 0], 128).astype(np.uint8)
        bev_v = np.where(valid_uv, UVplane[c_y, c_x_half, 1], 128).astype(np.uint8)
    else:
        bev_u = np.full((h, w), 128, dtype=np.uint8)
        bev_v = np.full((h, w), 128, dtype=np.uint8)

    return bev_y, bev_u, bev_v



def ridge(bev, bev_u=None, bev_v=None, ridge_d=6, ridge_delta=18, y_min=120,
          u_max_yel=104, v_min_yel=136, dv_min_yel=36, uv_diff_w=32):
    """纯定点整数提取脊线并按色彩划分为掩膜。

    返回:
      bev_m: 标线掩膜 (yellow | white)，bool 数组 400x400
      bev_y: 黄线掩膜 (yellow)，bool 数组 400x400
      bev_w: 白线掩膜 (white)，bool 数组 400x400
    """
    h, w = bev.shape
    d = int(ridge_d)
    G = bev.astype(np.int16)

    # 边界填 255，防止在图像边界误触发脊线（与浮点参考一致）
    Gl = np.full_like(G, 255)
    Gr = np.full_like(G, 255)
    if 0 < d < w:
        Gl[:, d:] = G[:, :w - d]
        Gr[:, :w - d] = G[:, d:]

    max_neighbor = np.maximum(Gl, Gr)
    R = G - max_neighbor
    ridge_mask = (R >= int(ridge_delta)) & (G >= int(y_min))

    if bev_u is not None and bev_v is not None:
        u = bev_u.astype(np.int16)
        v = bev_v.astype(np.int16)
        # 黄线判据：U 偏低、V 偏高、V - U 显著
        is_yellow = (u <= u_max_yel) & (v >= v_min_yel) & ((v - u) >= dv_min_yel)
        # 白线判据：接近无彩色中心 (128, 128)
        du = np.abs(u - 128)
        dv = np.abs(v - 128)
        is_white = (du + dv <= uv_diff_w)

        bev_y = ridge_mask & is_yellow
        bev_w = ridge_mask & is_white
        bev_m = bev_y | bev_w
    else:
        # 若未提供色度信息，则默认全部作为标线掩膜，黄线为空
        bev_y = np.zeros_like(ridge_mask, dtype=bool)
        bev_w = ridge_mask
        bev_m = ridge_mask

    return bev_m, bev_y, bev_w


def histogram(mask, rows_frac=1.0):
    """计算 400 列的列直方图计数（9 位饱和，范围 0..511）。"""
    h, w = mask.shape
    h0 = int(h * (1.0 - float(rows_frac)))
    sub = mask[h0:, :]
    hist = np.clip(sub.sum(axis=0), 0, 511).astype(np.uint16)
    return hist


def pack(mask_m, mask_y, hist):
    """按 DMA 回传字节格式打包两张掩膜与列直方图（共 40,800 字节）。

    格式：
      - 0..19999 (20,000 字节): mask_m，400 行 × 50 字节，大端位序 (bit7=u%8==0)。
      - 20000..39999 (20,000 字节): mask_y，400 行 × 50 字节，大端位序。
      - 40000..40799 (800 字节): hist，400 个 uint16（小端序）。
    """
    m_bytes = np.packbits(mask_m.astype(np.uint8), axis=-1, bitorder="big").tobytes()
    y_bytes = np.packbits(mask_y.astype(np.uint8), axis=-1, bitorder="big").tobytes()
    h_bytes = np.asarray(hist, dtype="<u2").tobytes()
    return m_bytes + y_bytes + h_bytes


def unpack(buf):
    """解包 DMA 回传字节流，恢复 mask_m, mask_y, hist。"""
    buf = bytes(buf)
    if len(buf) != 40800:
        raise ValueError(f"Packed buffer size must be 40800 bytes, got {len(buf)}")

    m_bytes = buf[:20000]
    y_bytes = buf[20000:40000]
    h_bytes = buf[40000:40800]

    mask_m = np.unpackbits(np.frombuffer(m_bytes, dtype=np.uint8), bitorder="big").reshape(400, 400) > 0
    mask_y = np.unpackbits(np.frombuffer(y_bytes, dtype=np.uint8), bitorder="big").reshape(400, 400) > 0
    hist = np.frombuffer(h_bytes, dtype="<u2").copy()
    return mask_m, mask_y, hist

