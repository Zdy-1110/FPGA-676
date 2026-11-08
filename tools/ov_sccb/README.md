# OV5640 运行时 SCCB 配置工具 (ov_sccb)

## 1. 寄存器定义 (FPGA BAR1 0xf0204000)
- 0x838：FPGA 固件版本，最低要求 >= `0x20261106` (cam23+)。
- 0x8F8（写）：`(reg_addr[15:0] << 8) | data[7:0]`；空闲时接受命令，读回最近接受值。
- 0x8FC（读）：
  - bit 0: `busy`（SCCB 传输中）
  - bit 1: `last_nack`（上一笔从机未应答）
  - bit 2: `cfg_done`（上电配置已完成）
  - bit 3: `overrun`（忙态写丢弃，写任意值清零）
  - bit [15:8]: `nack_cnt`（从机 NACK 计数）
  - bit [31:16]: `done_cnt`（成功/完成笔数累加）

## 2. 部署路径
- 脚本部署路径：`/userdata/quad/ov_sccb.sh`
- 配置调优文件：`/userdata/quad/ov5640_tune.txt`

## 3. 使用方法
```sh
ov_sccb.sh [-b BAR1] [-n] (-f FILE | REG VAL [REG VAL ...])
```
- `-b BAR1`：指定 FPGA BAR1 基地址（默认 `0xf0204000`）。
- `-n`：演练模式 (dry-run)，仅打印解析结果而不实际写寄存器。
- `-f FILE`：从文件批量读取，支持 `REG VAL` 与 `sleep_ms N` 行。
- `REG VAL`：直接命令行传入一笔或多笔十六进制寄存器与值。

## 4. 退出码
- `0`：全部写入成功，无 NACK。
- `1`：参数错误、文件不存在或内容格式错误（且一笔都不写入）。
- `2`：硬件握手轮询超时（busy 未回 0 或 done_cnt 未递增）。
- `3`：写入完成，但存在至少 1 笔 NACK。
- `4`：FPGA 固件版本过低（< `0x20261106`）。
