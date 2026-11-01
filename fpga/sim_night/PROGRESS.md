# 夜间增强 (cam18) 开发进度

- [x] 1. 确认像素格式、slot0 像素数、0x800/0x820 位分配、跨时钟域机制
- [x] 2. 备份 rt_disp_top.v 和 rt_ext_regs.v 为 *.bak_20261101
- [x] 3. 编写 gen_gamma.py，生成 LUT 文本及 Verilog 查找表代码
- [x] 4. 实现 rt_night.v（亮度统计、AUTO迟滞状态机、Gamma处理单元）
- [x] 5. 修改 rt_ext_regs.v（0x800[11:10] mode输出、0x820 bit3/bit[11:4] 状态更新、0x838 固件版本更新为 0x20261101）
- [x] 6. 修改 rt_disp_top.v（集成处理点 a 和处理点 b，车道线/斑马线走增强流，统计 u_disp_stats 及四路合成显示保持原始流；同步延迟配对信号 act_x/act_y 1 拍）
- [x] 7. 编写 gen_case4_data.py、tb_rt_night.v 和 run.do，运行 4 个测试用例验证通过（NIGHT_TB PASS）
- [x] 8. 进行 vlog 编译语法检查与整体验收
