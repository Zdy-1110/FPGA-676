# FPGA 仿真环境（Questa Altera FPGA Starter Edition）

本目录是 2026 嵌赛选题3（紫光同创 PG2L100H / 盘古100Pro+）的 HDL 仿真工作区。
本目录的 smoke 工程用于确认仿真工具链可用。

---

## 1. 概述

仿真链路已经完整跑通：PDS 2025.2 官方 GTP/VOP 器件库 + Questa Altera Starter FPGA Edition，
license 有效到 2027-10-02，并且用真实 Pango 原语（GRS/LUT4/DFF/BUFG）做了端到端自检。

---

## 2. 已安装的东西

| 项 | 值 |
|---|---|
| 仿真器 | Questa – Altera FPGA Starter Edition 2025.3（`<Questa 安装目录>\questa_fse\win64`） |
| 安装包 | `<下载目录>\QuestaSetup-26.1.1.130-windows.exe`（sha1 `aa01ffbd5afe0966d316071180075dcf834f200b`） |
| License 文件 | `<Questa 安装目录>\license\LR-XXXXXX_License.dat` |
| License 绑定 | host `A0852775EACC`（本机 TAP 网卡「以太网 8」的 MAC），Host Type = NIC ID |
| License 产品 | Non-Commercial Software SW-QUESTA（feature 名 `intelqsimstarter`），1 seat，到期 2027-10-02 |
| Altera 订单号 | 订单 `L-XXXXXX`；license 记录 `LR-XXXXXX` |
| License 来源 | Altera SSLC 门户 <https://licensing.altera.com/sslc/s/> → 注册邮箱收到的附件 |
| PDS | PDS 2025.2-ads，`<PDS 安装目录>` |
| Pango 仿真库产物 | `<仿真库目录>`（由 `compile_simlib` 编译生成，见第 5 节） |
| 路径联接 | `<无空格盘符>:\pango_pds` → `<PDS 安装目录>`（junction，绕开空格路径，见坑 3） |

---

## 3. 必须知道的两个坑

### 坑 1：Questa 认的是 `SALT_LICENSE_SERVER`，不是 `LM_LICENSE_FILE`

Altera 的邮件里写的是"设 `LM_LICENSE_FILE`"，但这一版本的 Questa 不读它。
实测：只设 `LM_LICENSE_FILE` 会报
`Unable to checkout a license. Make sure your license file environment variable (SALT_LICENSE_SERVER) is set correctly`。

正确做法是把 `SALT_LICENSE_SERVER` 指向 license 文件本身：

```
SALT_LICENSE_SERVER = <Questa 安装目录>\license\LR-XXXXXX_License.dat
```

（已写入用户级环境变量。`LM_LICENSE_FILE` / `MGLS_LICENSE_FILE` 也一并设了，按 Altera 官方说明保留，但真正起作用的是 `SALT_LICENSE_SERVER`。）

诊断命令：

```
<Questa 安装目录>\questa_fse\win64\lmutil.exe lmdiag -c "<Questa 安装目录>\license\LR-XXXXXX_License.dat" intelqsimstarter
```

正常应输出 `This is the correct node for this node-locked license`。

### 坑 2：Questa 无法在含中文的路径下建库

工程目录含中文时，Questa 建仿真库会失败：

```
init_dbinfo() DATABASE ERROR: (sqlite3_open <仓库根目录>/.../work/_lib.qdb): unable to open database file
** Fatal: (vlog-9) Problem while writing internal... 
```

`work/` 下 `_info`、`_opt` 建得出来，但 `_lib.qdb` 建不出来，编译直接失败。

解决办法：用 `subst` 把工程目录映射成一个 ASCII 盘符，从盘符进。

```
subst X: "<仓库根目录>"
```

映射后走 `X:\fpga_sim\...` 一切正常。可放一个开机自动映射脚本：

```
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\map-chisai-x.cmd
    @echo off
    subst X: "<仓库根目录>" >nul 2>&1
```

> 注意：目录联接（`mklink /J`）无效——Windows 会把联接解析回真实路径，Questa 看到的还是中文路径。只有 `subst`（盘符映射）有效。

## 4. 冒烟工程

```
fpga_sim/smoke/         纯 Verilog 计数器的自检 tb（不依赖 Pango 库）
fpga_sim/pango_prim/    用 Pango 真实原语的自检 tb
```

运行方式（在对应目录下）：

```bat
vlib work
vlog counter.v tb_counter.v          :: 或 tb_pango_prim.v
vsim -c -do "run -all; quit -f" tb_counter
```

两者都应打印 `==== SIM PASS / PANGO PRIM SIM PASS ====`。

`pango_prim` 里的原语取自 PDS 安装目录的明文 GTP 模型：

```
<PDS 安装目录>\arch\vendor\pango\verilog\simulation\
```

其中 `GTP_*.v`（397 个明文）+ `INT_*.v` 是可直接编译的行为模型；
`simulation\modelsim10.2c\` 下还有 10138 个加密模型（`.vp`/`.svp`，用于 DDR/PCIe 等复杂 IP）。

Pango 的硬性要求：testbench 里必须例化全局复位模块，实例名必须叫 `GRS_INST`，
否则 `GTP_DFF` 等模型里的 `GRS_INST.GRSNET` 引用会直接报错。
`GRS_N = 1'b1` 表示不复位：

```verilog
GTP_GRS GRS_INST (.GRS_N(1'b1));
```

---

## 5. 在 PDS 里用这个仿真器

PDS 支持的外部仿真器是 ModelSim / QuestaSim（Univista 只支持 Linux）。PDS 不预置编译好的器件库，
需要自己用 `Tools → Compile Simulation Libraries` 编译，产出两个库：

- `usim` —— GTP 前仿真库  → 已编好，`<仿真库目录>\usim`
- `vsim` —— VOP 后仿真库  → 已编好，`<仿真库目录>\vsim`

等价的 Tcl 命令（可用 `pds_shell -file xxx.tcl` 无界面批跑）：

```tcl
compile_simlib -Simulator {QuestaSim Simulator} \
               -family {Logos2} \
               -language {Verilog} \
               -library {ALL} \
               -directory {<仿真库目录>} \
               -simulator_exec_path {<Questa 安装目录>/questa_fse/win64}
```

> - `-family` 填器件系列名，PG2L100H 属于 `Logos2`。
> - `-directory` 必须是 ASCII 路径（中文路径会踩坑 2）。
> - PDS 工程里没有"全局登记仿真器路径"这回事；仿真器型号和库位置是每个工程在
>   `Project Setting → Simulation` 里选的，仿真器可执行文件路径只在编译库时传一次。

### 5.1 实测结果

`compile_simlib` 跑完后 `<仿真库目录>` 里是：

| 内容 | 说明 |
|---|---|
| `usim` | logos2 GTP 前仿库，明文 409 个模块 + 92 个加密模型，约 16 MB（`_lib.qdb`/`.qpg` 格式） |
| `vsim` | VOP 后仿库，327 个明文 + 92 个加密模型 |
| `adc_e2` `ddc_e2` `ddrs` `ddrs_dft` `dll_e2` `hsstlp_lane` `hsstlp_pll` `iolhr_dft` `ipal_e2` `ipal_e5` `iserdes_e2` `mipi_dphy_rx_e1` `mipi_dphy_tx_e1` `oserdes_e2` `pciegen2` `sensor_e2` `ppm` | Logos2 的复杂模块库（DDR/PCIe/MIPI/SERDES 等），由 `verilog/ListDir/Logos2/CommonLib_List.txt` 决定要编哪些 |
| `modelsim.ini` | 上述所有库的 `vmap` 映射，PDS 与手工仿真都靠它 |

整目录约 57 MB。验证方式：在 `fpga_sim/pango_prim/` 下只编译 testbench，让原语全部从库里解析——

```
vlog -ini <仿真库目录>/modelsim.ini tb_pango_prim.v
vsim -ini <仿真库目录>/modelsim.ini -c -L usim -do "run -all; quit -f" tb_pango_prim
```

结果 `==== PANGO PRIM SIM PASS ====`，说明编译出的 usim 库可用。

> `work/`、`transcript` 这类都是可随时重建的构建产物，删了不影响；重跑一次 `vlib/vlog/vsim` 就回来。

### 5.2 坑 3：PDS 装在带空格的路径下，`compile_simlib` 会自己编译失败

PDS 生成的 `msim_pango.tcl` 里有这两行：

```tcl
vlog -incr "<PDS 安装目录>/arch/vendor/pango/verilog/simulation/*.v" -work usim
vlog -incr "<PDS 安装目录>/arch/vendor/pango/verilog/simulation/modelsim10.2c/*.vp" -work usim
```

`vlog` 处理这个通配路径时会把路径按空格切开，报
`Failed to open design unit file "{D:/Program`，于是 `usim` / `vsim` 两个主库编不出来，
复杂模块库反而是好的。

绕过办法：造一个无空格的路径联接（这里失败的是参数解析、不是路径解析，所以 junction 有效）：

```
mklink /J <无空格盘符>:\pango_pds "<PDS 安装目录>"
```

然后自己按 `msim_pango.tcl` 的清单重跑那 4 条命令（文件清单先用 `ls | sed` 生成成无空格绝对路径）：

```
cd <无空格盘符>:/pango_pds/arch/vendor/pango/verilog/simulation
vlog -incr -f <仿真库目录>/usim_v.f  -work usim     # simulation/*.v
vlog -incr -f <仿真库目录>/usim_vp.f -work usim     # simulation/modelsim10.2c/*.vp
vlog -incr -f <仿真库目录>/vsim_v.f  -work vsim     # bsim/*.v
vlog -incr -f <仿真库目录>/vsim_vp.f -work vsim     # bsim/modelsim10.2c/*.vp
```

（命令要在 `<仿真库目录>` 下执行，让 vlog 找到那个 `modelsim.ini`。）

> 根治办法是把 PDS 装到不含空格的路径（例如 `<无空格目录>\PDS_2025.2`）。目前用 junction 绕过即可，
> 注意这与工程目录中文路径的坑性质不同：中文路径坑是 Questa 内部处理不了，
> junction 无效；空格坑是命令行参数被切分，junction 有效。

---

### 5.3 坑 4：单机版 license 一次只允许一个 Questa 会话

`LR-XXXXXX_License.dat` 是 `uncounted nodelocked`（不计数、绑主机）授权，同一时刻只允许一个 Questa 会话。
GUI 开着的时候，命令行 vsim 和 PDS 的仿真都会失败，报：

```
** Error: License checkout has been disallowed because
only one session is allowed to run on an uncounted nodelocked
license and an instance of QuestaSim is already running with a
nodelocked license on this machine.
```

这不是 license 坏了——先看有没有别的 Questa 在跑。占用者通常是：

- Questa 图形界面：窗口标题 `Questa Altera Starter FPGA Edition-64 2025.3`
- 残留进程 `vish.exe`（Tcl shell）和它的子进程 `vlm.exe`（Questa 的许可管理器，真正握着 license 的是它）

排查命令（注意进程名是 `vish`/`vlm`，不是 `vsim`，用 `vsim` 过滤会漏）：

```powershell
Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like '<Questa 安装目录>*' } |
  ForEach-Object { '{0} {1} {2}' -f $_.ProcessId, $_.Name, $_.ExecutablePath }
```

确认某个会话确实是你不要的（比如脚本被管道提前掐断留下的僵尸），才杀掉：

```powershell
Stop-Process -Id <vish的pid> -Force      # vlm 是 vish 的子进程，会跟着走
```

> 注意：别用 `taskkill`，Git Bash 会把 `/PID` 转义成路径导致命令失效，只能用 PowerShell 的 `Stop-Process`。
>
> 同理，用管道跑脚本仿真（`vsim ... | head`）时，`head` 提前退出会掐断 vsim，可能留下僵尸占着 license——建议整个输出都读干净，或重定向到文件。

---

## 6. License 到期提醒

`LR-XXXXXX_License.dat` 到期日 2027-10-02（维护期同样到 2027-10）。
续期走同一个 Altera SSLC 门户，订单 `L-XXXXXX` 下重新 Generate 即可，不需要换机器。

---

> 注意：Questa Altera Starter Edition 有容量限制（代码行数/性能），
> 顶层设计加 Pango 库一起仿真时如果报容量超限，就得换完整版 Questa 或把仿真粒度拆小。
