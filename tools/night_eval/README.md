# FPGA 自适应夜间增强评估与测试集生成

## 1. 用途
评估 7 条白天视频每帧平均亮度 Y=(R+2G+B)/4 与 AUTO 状态机（连续 8 帧 <48 进夜间、>64 退出），验证无白昼误触发；生成夜间测试静态图集与 FPGA gamma=0.5 仿真对比图。

## 2. 运行命令
```bash
.venv_yolo/Scripts/python.exe tools/night_eval/luma_stats.py
.venv_yolo/Scripts/python.exe tools/night_eval/make_dark.py
```

## 3. 实测结果摘要
- **门槛判定**: GATE PASS（全 7 条视频共 8024 帧，最低帧亮度全高于 64 门槛，夜间误触发 0 次）。
- **白天视频亮度统计 (min / p5 / med / max / enters)**:
  - 112454 (106 帧): min=121, p5=121.0, med=122.0, max=123, enters=0
  - 112507 (1349 帧): min=98, p5=111.0, med=122.0, max=135, enters=0
  - 112739 (2776 帧): min=98, p5=109.0, med=114.0, max=145, enters=0
  - 113343 (655 帧): min=103, p5=105.0, med=120.0, max=132, enters=0
  - 113421 (392 帧): min=113, p5=115.0, med=126.0, max=133, enters=0
  - 113452 (431 帧): min=98, p5=101.0, med=107.0, max=112, enters=0
  - 113539 (2315 帧): min=96, p5=104.0, med=115.0, max=128, enters=0
- **暗化测试集 (out/dark/)**:
  - day_* (6 张 1080p Q92) / sim_gamma_* (12 张 960×540 FPGA gamma 增强对比图)
  - night25_* (6 张): Y 均值 24.73~24.82，gamma 增强后 Y 均值 75.32~76.08
  - night40_* (6 张): Y 均值 39.77~39.82，gamma 增强后 Y 均值 95.12~96.12
