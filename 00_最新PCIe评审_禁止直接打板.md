# PCIe 延长板评审入口 — Rev C 设计包已完成；制造与实测放行仍有前置条件

## 当前最终版本：Rev C 正电源隔离延长板设计完成

**请以 Rev C 为当前方案；后面的 A/B 记录仅是旧评审历史，不再是交付板。最终文件包已生成并完成校验。**

- [最终完整交付 ZIP（含 EDA、Gerber、钻孔、BOM/CPL、接线/装配/制造说明、原厂资料与审计）](E:/Project/nesai2026/delivery/PCIE_POWER_ISOLATOR_X4_REV_C_RELEASE_2026-10-03.zip)
- [最终 EDA 工程](E:/Project/nesai2026/design/PCIE_POWER_ISOLATOR_X4_REV_C/PCIE_POWER_ISOLATOR_X4_REV_C_FINAL.epro)
- [交付包 README](E:/Project/nesai2026/delivery/PCIE_POWER_ISOLATOR_X4_REV_C_RELEASE_2026-10-03/README.md)
- [Gerber/钻孔制造 ZIP](E:/Project/nesai2026/delivery/PCIE_POWER_ISOLATOR_X4_REV_C_RELEASE_2026-10-03/MANUFACTURING/GERBER_PCIE_POWER_ISOLATOR_X4_REV_C.zip)
- [制造规格与 CAM 签核要求](E:/Project/nesai2026/delivery/PCIE_POWER_ISOLATOR_X4_REV_C_RELEASE_2026-10-03/MANUFACTURING/FABRICATION_SPEC.md)
- [接线与首板验收流程](E:/Project/nesai2026/delivery/PCIE_POWER_ISOLATOR_X4_REV_C_RELEASE_2026-10-03/MANUFACTURING/WIRING_AND_ACCEPTANCE.md)
- [Gerber 顶层预览](E:/Project/nesai2026/delivery/PCIE_POWER_ISOLATOR_X4_REV_C_RELEASE_2026-10-03/PREVIEW/GERBER_PREVIEW_TOP.png)
- [接线图](E:/Project/nesai2026/delivery/PCIE_POWER_ISOLATOR_X4_REV_C_RELEASE_2026-10-03/PREVIEW/WIRING_DIAGRAM.png)

Rev C 四层 55×54mm；PCIe x4 信号直通、两层内层保留 GND 参考；隔断 RK→FPGA 正电源转发，**公共 GND 保留**，不是全链路电气隔离。EDA 原理图/PCB DRC 错误均 0；独立原生静态核验 23/23 PASS；生产 Gerber ZIP 含 11 个 Gerber 图层与 PTH/NPTH 两类完整钻孔文件。

**这表示最终 CAD/制造输入已经交付，不表示 PCB 已生产或整机已通过电测。不能用普通 FPC/FFC 排线替代 PCIe 柔性延长件；推荐采购字段见包内参考。送板前必须由工厂书面确认 85/100Ω 叠层、金手指硬金与倒角、卡厚/键宽公差和连接器机械配合。首板前必须实测 FPGA BANK L4 本地 3.3V 取电域与原板 PERST# 上拉来源，按验收说明检查反灌、复位和链路。**

原理图手册所记参考时钟球位仍有 F11/E11 与 F13/E13 资料冲突；未上 PCIe 主机/未训练链路、未测阻抗/眼图。没有下单、烧录或擦除 FPGA。本轮完成的是可供 CAM 审核的工程样板设计包，不是免审核的默认直投板文件。

---

### 历史记录：2026-10-03 A/B 评审版本（已由 Rev C 替代）

2026-10-03：本次新增 **A 直通与 B 条件 lane 重映射** 两版 PCB、对应原理图，已在嘉立创 EDA 中实际导入、检查并导出。

- [两版设计说明和工程链接](E:/Project/nesai2026/design/PCIE_EXT_DUAL_A_STRAIGHT_B_REMAP_REVIEW/README.md)
- [完整真实 EDA 导出工程](E:/Project/nesai2026/design/PCIE_EXT_DUAL_A_STRAIGHT_B_REMAP_REVIEW/PCIE_EXT_DUAL_A_STRAIGHT_B_REMAP_REVIEW_EDA.epro)
- [两版 PCB 接线对照](E:/Project/nesai2026/design/PCIE_EXT_DUAL_A_STRAIGHT_B_REMAP_REVIEW/两方案PCB对照_仅评审.png)
- [检查结果](E:/Project/nesai2026/design/PCIE_EXT_DUAL_A_STRAIGHT_B_REMAP_REVIEW/actual_validation.json)

两版不是“正确/错误代码”两种判决，也不保证二选一必通。官方例程未改动。两版均断开跨板电源、保留公共 GND，SB1 复位默认 OPEN；**原理图 DRC 各 0，PCB DRC 各仍有 6 项键槽间距违规**，时钟球位/最终 lane 映射/断电信号容限/阻抗与机械配合仍未放行。

此前 Rev B 评审仍保留：[原 Rev B 说明](E:/Project/nesai2026/design/PCIE_EXT_RK3568_PANGO_REV_B_REVIEW/README.md)。文中“已核实”等标题不能作为制造或上电依据。

## 2026-10-03：实物已接入，只读JTAG成功

- [本轮进展入口](E:/Project/nesai2026/review/hardware_connected_20261003/README_本轮进展.md)。
- 实测PG2L100H，ID `0x00602899`，Status `0x00180c80`，DONE=0；未烧写/擦除/复位。
- 两版PCB各六条卡键间距问题仍未获机械/制造批准，原EDA工程未改，**仍禁止直接打板或插接上电**。
- PERST候选只完成分析/概念图；不是已集成或已验证成品。
