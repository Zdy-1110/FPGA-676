# PCIe 中间件 CEM x4 触点映射（已核实）

> 核实方式：子智能体对 `F:\OK3588-C资料\底板原理图\OK3588-C V1.2_A(更新日期_20240123）.pdf` 第 20 页（P45 PCIe3.0 x4 插槽）做逐脚矢量坐标复核（引脚线/网标/NC 叉标全部对位），证据等级：本地PDF复核。此前草稿脚本（make_pcie_interposer.py）的映射整体后移了 2 个触点，以本表为准。

## 权威触点表（x4 卡边，64 触点）

| # | A 侧 | B 侧 |
|---|---|---|
| 1 | PRSNT1#（插槽侧接地） | +12V |
| 2 | +12V | +12V |
| 3 | +12V | +12V |
| 4 | GND | GND |
| 5 | TCK → NC | SMCLK → NC |
| 6 | TDI → NC | SMDAT → NC |
| 7 | TDO → NC | GND |
| 8 | TMS → NC | +3.3V |
| 9 | +3.3V | JTAG_TRST → NC |
| 10 | +3.3V | 3.3VAUX（OK3588 上与 3.3V 短接） |
| 11 | PERST# | WAKE# |
| 12 | GND | CLKREQ#（符号名 RSVD1） |
| 13 | REFCLK+ | GND |
| 14 | REFCLK- | PET0+ |
| 15 | GND | PET0- |
| 16 | PER0+ | GND |
| 17 | PER0- | PRSNT2_X1（x1 卡检测；x4 卡悬空） |
| 18 | GND | GND |
| 19 | RSVD2 → NC | PET1+ |
| 20 | GND | PET1- |
| 21 | PER1+ | GND |
| 22 | PER1- | GND |
| 23 | GND | PET2+ |
| 24 | GND | PET2- |
| 25 | PER2+ | GND |
| 26 | PER2- | GND |
| 27 | GND | PET3+ |
| 28 | GND | PET3- |
| 29 | PER3+ | GND |
| 30 | PER3- | RSVD2 → NC |
| 31 | GND | PRSNT2_X2（x4 卡检测） |
| 32 | RSVD3 → NC | GND |

另有 B 侧第 33 触点 = 连接器屏蔽/固定脚（GND）。

## 对中间件设计的直接结论

1. **P1（主机卡边）↔ P2（卡槽）同名触点 1:1 直通**：REFCLK(A13/A14)、PERST#(A11)、全部 PET/PER 对（B14/15、B19/20、B23/24、B27/28 ↔ A16/17、A21/22、A25/26、A29/30）。
2. **P1 卡边必须短接 A1 ↔ B31**（x4 卡存在检测），否则 OK3588 侧 `PCIE30X4_PRSNT_L` 判无卡。
3. **电源全隔离**：A2/A3/B1/B2/B3(12V)、A9/A10/B8(3.3V)、B10(3.3VAUX) 全部 NC、无铜。注意 OK3588 的 B10 与 3.3V 在主板内部已短接，更不能贯通。
4. **NC 触点**：A5–A8(JTAG)、A19、A32、B5、B6、B9、B30；B17 在 x4 卡上必须悬空（主机用于 x1 检测）。
5. **WAKE#(B11)**：默认 DNI/测试点；**CLKREQ#(B12)**：盘古无此信号，NC/测试点。
6. 方向：B 侧=主机发送→卡接收；A 侧=卡发送→主机接收。中间件不换 lane、不换极性、不加 AC 耦合（主机端已串 220nF）。

## P2 卡槽器件（已放置进嘉立创 Pcie 工程）

- 型号：UMAX **91613-110141D**（立创编号 **C1509727**），PCIe 4.0 夹板式(Straddle-Mount) 64PIN(X4) 显卡插座，带耳 Cap，触点镀金 15μ"，合高 7.4mm，SMD P=1mm，库存 2429。
- 图纸：`https://datasheet.lcsc.com/datasheet/pdf/9b773d8973c761affc92121f963cbfbe.pdf?productCode=C1509727`（3 页纯矢量无文本层，焊盘/排距/板厚需人工读图，不得臆造）。

## 盘古侧仍需上电前实测（PADS 二进制无法闭环）

- PADS `.sch` 仅能提取网名清单（PCIE_CLKP/CLKN、PCIE_PERST、PCIE_12V、PCIE_PRSNT、Q3_REFCLKP/N、HSSTREFCLK0/1_QL3 均在册），**无引脚级连接数据**；`.pcb` 无 PCIe 网名。
- 手册口径：`PCIE_REFCLK_P/N = F13/E13`（=J1 pin32/34，HSSTREFCLK1）；此前会话记录的"例程 fdc 约束 F11/E11、perst=G24"**在资料包中未找到出处**（fdc 内只有 LED 约束和虚拟时钟）。冲突可能不存在，但首上电前仍须万用表/网表实测参考时钟连续性。
- `PCIE_12V` 与 `12V_IN`/`DC12V` 是三个独立网名 → 弱推断金手指 12V 与板载 12V 之间至少隔有元件（非直连回灌），未证实；维持双电源独立供电原则。
- `PCIE_PRSNT` 接法未知；中间件不并接盘古端 PRSNT 网络。
