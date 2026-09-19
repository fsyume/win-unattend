# iVentoy 部署 Windows 11 无人值守 — 实施手册

> ⚠️ 以下内容为 AI 生成，注意甄别。
>
> 适用范围：**UEFI/GPT 客户端 + Windows 11 + 已有第三方 DHCP + 全自动装机**。
> **不包含**改名 / 加域 / 装软件 / 推驱动（后置脚本已移除，见 [已知缺口](#已知缺口)）。

目录： [环境](#环境快照) · [流程](#流程) · [文件清单](#文件清单) · [1 服务端](#1-服务端) ·
[2 DHCP](#2-与第三方-dhcp-共存) · [3 界面配置](#3-界面配置四个开关) · [4 answer file](#4-unattendxml) ·
[5 驱动钩子](#5-首次登录装驱动) · [6 缺驱动补救](#6-缺驱动补救备用) · [7 验收](#7-单机验收) ·
[8 授权](#8-批量与授权) · [9 安全](#9-安全必读) · [10 排错](#10-排错速查) · [11 遗留问题](#11-遗留问题) · [参考](#参考)

---

## 环境快照

下表是**实测通过**的环境。换机器、换版本时对照更新，省得排查时搞不清"当时是什么环境"。

| 项 | 值 |
|---|---|
| iVentoy | **1.0.43**（Windows x64，**免费版**），主程序 `iVentoy_64.exe` |
| 解压路径 | `C:\Users\cyk\Downloads\iventoy-1.0.43-win64-free\iventoy-1.0.43\` |
| 端口 | 管理界面 `26000`、HTTP `16000`（**客户端要能访问**，用来传 ISO 内容）、NBD `10809` |
| 自动安装脚本 | `<iVentoy>\user\scripts\unattend.xml`（**25589 字节**） |
| 当前上线镜像 | `zh-cn_windows_11_consumer_editions_version_25h2_updated_sep_2026_x64_dvd_cb71b7e8.iso`（9.12 GB，consumer 多版本） |
| 目标版本 | Windows 11 Pro（`/IMAGE/NAME` = `Windows 11 Pro`，该镜像里是索引 4） |
| 授权 | 免费版最多 20 客户端、禁止商用（见 [8 授权](#8-批量与授权)） |
| 状态 | ✅ 已端到端实测通过 |

**已验证的完整链路**（每一环都有日志证据，不是推断）：

| 环节 | 证据 |
|---|---|
| 下发 answer file + 变量展开 | 客户端 `ventoy.log`：`SaveBuffer2File <ventoy\autoinstall_1> len:25589`、`UnattendVarExpand` → `X:\Unattend.xml` |
| 全自动装机 → 自动登录 | 中途无需人工介入 |
| 首次登录钩子 | 脚本落到 `C:\Windows\Temp\install-drivers.cmd` |
| 按清单取回 tool | `install-drivers.log`：`download finished: ok=114 bad=0` |
| 启动驱动安装 | 同上：`launching start.bat in C:\tool\...` + `launched, script exits` |
| DrvCeo 运行 | 手动复现确认；Hyper-V 无驱动可装故很快退出，看起来像没跑 |

> **判断客户端拿到哪一版脚本**：客户端每次引导会把日志回传到
> `<iVentoy>\log\client\<客户端IP>.zip`，解压看 `client_info\ventoy.log` 里
> `len:` 的数字，**必须等于你磁盘上 `unattend.xml` 的字节数**。
>
> ⚠️ **不要用服务端 `log\log.txt` 判断客户端有没有请求过文件**——iVentoy
> **只记失败的 `user/` 请求（404），成功的下载一条都不记**。"日志里没有"推不出"客户端没请求"。

---

## 流程

```
客户端加电 (UEFI PXE)
 ├ (1) 第三方 DHCP 只发 IP；iVentoy 以 ProxyNet 补 next-server/bootfile
 ├ (2) 送 iPXE loader → 菜单超时 5s → 自动选「默认启动文件」= Win11 ISO
 ├ (3) 靠 ISO 内 boot.wim 自带网卡驱动把 ISO 挂成本地盘（不做文件注入）
 ├ (4) unattend.xml：擦盘 → GPT 分区 → 装 WIM → 启用内置 Administrator → 自动登录
 └ (5) 首次登录 FirstLogonCommands：拉 install-drivers.cmd → 下载 tool → 跑 start.bat
        （驱动总裁保留图形界面，需现场人员确认，不是全自动）
```

**四个自动化开关，缺一个就停在某处等人点**：

| 开关 | 位置 | 不配的后果 |
|---|---|---|
| 菜单默认超时时间 | 参数设置 | 卡在启动菜单 |
| 设为默认启动文件 | 镜像管理 | 超时后走列表第 1 个 ISO |
| 自动安装脚本 | 镜像管理 | 分区 / OOBE 全部手点 |
| 脚本选择超时时间 | 镜像管理 | 卡在"选哪个安装脚本" |

---

## 文件清单

仓库只有 6 个文件；两个 `README.md` 是文档，其余按下面位置投放：

```
本仓库                                →  <iVentoy 解压目录>\
├── unattend.xml                      →  user\scripts\unattend.xml
└── user\deploy\                                  ← 首次登录下发给客户机
    ├── install-drivers.cmd           →  user\deploy\install-drivers.cmd
    ├── tool_files.txt                →  user\deploy\tool_files.txt   （清单 114 项）
    └── (tool\)                       →  user\deploy\tool\            （约 999 MB，不进 git）

iso\                                  ← 放 Windows 11 ISO（可软链接）
```

**命名铁律**（官方要求）：iVentoy 解压路径、`iso` 目录名与 ISO 文件名、脚本名，**都不能有中文或空格**。

`iso\` 里另外两个文件与本方案无关：

| 文件 | 说明 |
|---|---|
| `Win11_25H2_Pro_Chinese_Simplified_x64_v2.iso` | **已弃用**。China Only 专供版（`EDITIONID=ProfessionalCountrySpecific`），没有公开通用密钥，`NAME` 也不是 `Windows 11 Pro`，正是当初卡住的根因 |
| `FirPE-V1.9.2.iso` | PE 维护盘 |

---

## 1. 服务端

- 用 **1.0.43 或更新**。1.0.43 起"自动启动失败会回退到手动模式，页面不再整体退出"，并修掉 wimboot 模式启动 Windows 时自动安装脚本不生效的 BUG（正是本方案要用的功能）。
- 解压到**无中文无空格**路径；ISO 放进 `iso\`，不想占空间就软链接：
  ```cmd
  mklink D:\iventoy\iso\Win11.iso E:\download\Win11_24H2_x64.iso     :: Windows
  ln -s /opt/iso/Win11.iso /opt/iventoy/iso/Win11.iso                # Linux
  ```
- 启动：Windows 双击 exe；Linux `sudo bash iventoy.sh start`（自启动用 `-R`，前提是先手动成功启动过一次）。
- 浏览器用 **Chrome 或 Firefox**（官方只测过这两个），访问 `http://127.0.0.1:26000`。
- 防火墙放通 **16000**。

## 2. 与第三方 DHCP 共存

**先确认对方的 DHCP 会不会响应 PXE 请求**：

- 抓包：同网段 PC 上 Wireshark 过滤 `dhcp`，能看到 Offer 就是响应了。
- 看客户端屏幕：`PXE-E53` / `No boot filename` / 已拿到 IP → **响应了 PXE**，按下面配；
  长时间卡在获取 IP 最后 `PXE-E51` → **不响应 PXE**，可当它不存在，直接用 iVentoy 内置 DHCP。

| 模式 | 适用场景 | 第三方 DHCP 要改什么 |
|---|---|---|
| **`ProxyNet`** ✅ 推荐 | iVentoy 与 DHCP **不同机器**，同 VLAN | **什么都不用改** |
| `Proxy` | 两者跑在**同一台机器** | 不用改 |
| `External` | ProxyNet 不满足时 | 配 `next-server`=iVentoy IP、`bootfile`=`iventoy_loader_16000` |
| `ExternalNet` | 跨 VLAN | 须能按 DHCP 报文动态下发 bootfile，要求很高 |

你的情况（路由器/域控/核心交换机上的 DHCP + iVentoy 另跑一台）= **`ProxyNet`**。
原理：iVentoy 仍起内部 DHCP，但**不发 IP**，只在 67 / 4011 端口补 `next-server`/`bootfile`，不抢地址池。

`External` 模式下在 DHCP 上配 `option 066` = iVentoy IP、`option 067` = `iventoy_loader_16000`
（末尾 `16000` 必须和 HTTP 端口一致；**不要**同时保留别的 067）。此模式无需区分 BIOS/UEFI——
iVentoy 旁听 DHCP 报文自行判断架构。

> ⚠️ 交换机开了 **DHCP Snooping** 时，要把 iVentoy 所在端口设为 **trusted**，否则 ProxyDHCP 应答被丢弃，
> 表现为"客户端拿到 IP 但拿不到 bootfile"。

## 3. 界面配置（四个开关）

**参数设置**页：

- **菜单默认超时时间** = `5`（0 = 永不超时）
- **DHCP 服务器模式** = `ProxyNet`
- 勾选 **ByPass HW Check**、**ByPass NRO**

> ⚠️ **TPM/安全启动绕过不在 `unattend.xml` 里**。勾选框的作用是在 WinPE 里写
> `HKLM\SYSTEM\Setup\LabConfig\Bypass*Check` 和 `...\OOBE\BypassNRO`。
> 拿这份 answer file 走 U 盘安装、或忘了勾，不满足硬件要求的机器会停在"不满足运行 Windows 11 的要求"。
> 另外**本方案不依赖 `Bypass NRO`**：账户是靠有文档支持的 `AutoLogon`/`UserAccounts` 建的，
> 即使 24H2/25H2 改掉 `bypassnro` 也不会断。

**镜像管理**页，选中 Win11 ISO：

- 点 **设为默认启动文件**
- 自动安装脚本 **新增** → 选 `unattend.xml`，设置 **默认自动脚本编号**（从 1 开始，0 = 不使用）
- **脚本选择超时时间** 设为非 0
- **注入文件留空**（当前方案不做注入）

**Secure Boot（客户端 BIOS 开着时）**——iVentoy 1.0.40+ 支持，**仅 X86_64 客户机**：

| 模式 | 说明 |
|---|---|
| `Not Supported` | 兼容性最好，但必须进 BIOS 关掉 Secure Boot ← **批量装机推荐** |
| `Standard` | 客户端零操作，但中文菜单 / GrubBoot / UEFI 分辨率 / 启动密码全部不可用 |
| `ByPass` | 功能齐全，每台**首次**需手动导入一次 Key |

部分机型 BIOS 还需先使能 UEFI CA。

## 4. `unattend.xml`

### 必改的三处（文件里搜 `EDIT ME`）

| 位置 | 改成 |
|---|---|
| `/IMAGE/NAME` 的 `Windows 11 Pro` | 你镜像里**准确的 Name**（`dism /Get-WimInfo`） |
| `AutoLogon` 的 `<Value>` | Administrator 密码 |
| `AdministratorPassword` 的 `<Value>` | 同上，**两处必须完全一致** |

**不能删的两个元素**：

- `<AcceptEula>true</AcceptEula>` —— 没有它 Setup 会弹许可条款页，全自动就断了。
- `<ProductKey>` —— 官方定义是"指定要安装的 Windows 映像"，既决定装哪个版本，也是**唯一能跳过「产品密钥」页的元素**。当前填的是微软公开的 KMS 客户端通用密钥（只选版本、不激活），属公开信息。**千万不要填真实 MAK 零售密钥**，那才有泄露风险。真正的激活仍靠 KMS / ADBA / 数字许可证。

"注册给谁"的四个字段（`RegisteredOwner`、`RegisteredOrganization`、`UserData` 的 `FullName`/`Organization`）
已全部删除——它们只是展示性元数据，不影响激活、授权、计算机名或加域。

### 镜像选择：用 NAME，不要用 INDEX

**NAME 写错会"大声失败"，INDEX 写错会"静默装错版本"。** 当前 consumer 镜像的真实列表：

```
1 | Windows 11 Home                ← 家庭版！
2 | Windows 11 Home Single Language
3 | Windows 11 Education
4 | Windows 11 Pro                 ← 专业版
5 | Windows 11 Pro Education
6 | Windows 11 Pro for Workstations
```

写死 `INDEX=1` 会一路"成功"地装上家庭版，还与 ProductKey 的专业版密钥矛盾——**它不报错，只装错**。

换 ISO 时这样确认：

```cmd
dism /Get-WimInfo /WimFile:D:\sources\install.wim      :: 没有 wim 就用 install.esd
```

取输出的 **「名称 / Name」** 原样填入。注意：

- 要的是 **Name**，不是安装界面显示的 DISPLAYNAME（consumer 镜像上是「Windows 11 专业版」）
- 非英文介质上 Name **可能**被本地化（China Only 那张就是），必须照抄
- 一旦该值含中文，`unattend.xml` 必须存成 **UTF-8 带 BOM**（本文件已经是）

### 分区与选盘

默认布局：`EFI 300MB + MSR 16MB + Windows(占满剩余)`。
`<Extend>true</Extend>` 的分区必须**最后创建**，所以 OS 分区放最后；不建独立恢复分区，
WinRE 落在 `C:\Windows`，顺带避开 25H2/26H2 把恢复分区切成 500MB 后累积更新报 `0x80070643` 的老问题。
（想要独立 1GB WinRE 分区：文件里有一段注释掉的备用 `<DiskConfiguration>`，整块替换并把
`<InstallTo><PartitionID>` 从 `3` 改成 `4`；要点是恢复分区必须在**最前面**。）

选盘由 iVentoy 变量决定，当前用**容量最接近 200GB 的那块盘**，在
`<DiskConfiguration><Disk><DiskID>` 和 `<InstallTo><DiskID>` 两处都写，同机两次展开一致：

```xml
<DiskID>$$VT_WINDOWS_DISK_CLOSEST_200$$</DiskID>
```

可替换策略（**只能用于 Windows unattend.xml，且只能用一个，没有"或"逻辑**）：

| 变量 | 选中的盘 |
|---|---|
| `$$VT_WINDOWS_DISK_CLOSEST_200$$` | 容量最接近 200GB ← **当前使用**（`XXX` 可换成任意数值） |
| `$$VT_WINDOWS_DISK_1ST_NONUSB$$` | 第一个非 USB 盘 |
| `$$VT_WINDOWS_DISK_MAX_SIZE$$` | 容量最大的盘 |

> ⚠️ **两个坑**
>
> **1. `_CLOSEST_` / `_MAX_SIZE` 不排除 USB 盘。** 插着的大容量 U 盘或移动固态可能胜出，然后**被擦掉**。
> **装机时务必拔掉所有可移动存储。**
>
> **2. 比较的是 Windows 报出来的容量**：GiB 但显示成 GB。标称 200GB 的盘显示约 `186 GB`，256GB 的约 `238 GB`。
> 填 200 仍能区分两者（`|186-200|=14` 比 `|238-200|=38` 更近），不用改成 186。
> 但若机器上同时有标称 200GB 和 240GB 的盘，建议先在一台机器上确认实际值再定。
>
> 怎么确认：iVentoy 主界面**设备列表**会显示客户端磁盘信息；或在安装界面按 `Shift+F10` 调出 cmd：
> ```
> diskpart
> list disk
> exit
> ```
> 建议把这一步固化进第一台真机的验收流程。

**擦盘保护**：`<WillWipeDisk>true</WillWipeDisk>` **不可逆**。不写死 `DiskID=0` 是因为多控制器
服务器上枚举顺序和你想的不一样，写死 0 很可能擦错盘；按"最接近 200GB"这种**属性**选盘，
换固件、换控制器、换机型都不用改 answer file。**首次测试请物理拔掉所有数据盘。**

### ⚠️ 改完 `unattend.xml` 必须重启 iVentoy

**iVentoy 把自动安装脚本缓存在内存里，只在服务启动时读一次。** 之后你怎么改磁盘上的文件它都不看——
文件是新的，下发的却是旧的。**可怕之处是它不报错**：装机一切正常，只是改动完全没生效。

实证（客户端回传的 `ventoy.log`）：磁盘上是 `25353` 字节，客户端却收到 `21290` 字节（改动前的大小）。

正确做法：① 改文件 → ② **重启 iVentoy**（或界面里把该脚本**删除**再**重新新增**，并把默认编号/超时设回去）
→ ③ 客户端重新 PXE 引导 → ④ 按开头那条 `len:` 校验下发的是哪一版。

### 为什么直接用内置 Administrator

- **真正启用该账户的是 `AutoLogon` 的 `Username=Administrator`**；`AdministratorPassword` 只负责设密码。
  两者分工不同，缺一不可（Microsoft 文档《AdministratorPassword》原文如此）。
- `AutoLogon` 会让 OOBE **跳过账户创建阶段**；文档要求用 AutoLogon 时**必须**指定 `LogonCount`（当前 `1`）。
- ⚠️ **不要额外显式启用内置 Administrator**（别加 `net user Administrator /active:yes`）。文档警告
  "Doing so can prevent the image or device from entering the OOBE successfully"。本文件曾有一条
  `RunSynchronous` 干这事，已按文档删除。
- 官方还建议在这种场景额外创建一个 Administrators 组成员账户以便后续管理。本方案没建——
  内置 Administrator 本身就是管理员，可管理性没问题，但确实偏离官方建议。想照做就把 `LocalAccounts` 块加回来。

## 5. 首次登录装驱动

`unattend.xml` 的 `FirstLogonCommands` 在首次登录时做两件事：

1. 从 iVentoy 服务器下载 `install-drivers.cmd`
2. 执行它，并传入清单和 tool 目录的 URL

命令带 **`--retry 20 --retry-delay 10 --retry-connrefused --retry-all-errors`**：首次登录那一刻网络
可能还没就绪，裸 curl 会静默失败，而重试逻辑本来写在脚本里——脚本恰恰是这一步要下载的东西，永远生效不了。
脚本缺失时改写 `C:\Windows\Temp\install-drivers-failed.txt` 留面包屑，不再无声失败。

**为什么用 `FirstLogonCommands` 而不是 `$OEM$\SetupComplete.cmd`**：微软文档写明后者
"This setting is disabled when using OEM product keys, except on Enterprise editions"——
OEM 品牌机（固件带密钥）上会被**直接跳过**，而目标机大概率正是这类机器。
权限方面文档保证"管理员首次登录时这些命令以 **elevated** 运行"，我们用 Administrator 自动登录，天然满足。

**服务器侧准备**（放进 `<iVentoy>\user\deploy\`）：

| 文件 | 说明 |
|---|---|
| `install-drivers.cmd` | 本仓库提供，原样复制 |
| `tool_files.txt` | 本仓库提供，原样复制（清单，**114 项**） |
| `tool\` | 整个工具文件夹，**约 999 MB** |

客户端把整棵树还原到 **`C:\tool\`**，然后执行 `C:\tool\Drvceo_Win10_Win11_x64_Lite\start.bat`
（内容 `.\DrvCeo.exe /a`，`/a` 是官方参数：自动检测并安装驱动）。
`.\DrvCeo.exe` 是相对路径，所以**工作目录必须是它所在文件夹**，脚本用 `start /D` 保证；
你手动跑也要先 `cd` 进去。

**为什么逐文件下载**：iVentoy 的 HTTP 是静态文件服务，**只能按文件取，不能取目录，也没有目录列表**。
所以清单在服务器侧预先列好，脚本按清单拉回来并保持目录结构。

⚠️ **清单只允许 ASCII 路径**（约定 `^[A-Za-z0-9._/\-]+$`）。iVentoy 的 HTTP **本身支持中文路径**
（实测百分号编码返回 206），障碍在**客户端的 cmd.exe 按 OEM 代码页解析清单**——中文/空格会变成
乱码文件名甚至下载失败。要创建中文名就得把清单存成 GBK，等于把"编码问题"从消除变成管理；
本项目已因编码翻过两次车（`%date%` 乱码、多字节注释破坏 `goto`），所以选择统一 ASCII 命名。
**以后再往里放文件，文件名直接用 ASCII**，否则不会进清单、也就到不了客户机。

⚠️ **只要增删了 `tool` 里的任何文件（包括新增 `start.bat`）就必须重新生成清单**，
否则客户端漏文件（日志打印 `MISSING or EMPTY`），418MB 的 `QiAnXing-Tianqing-*.exe` 曾因此漏传。
生成命令见 `user/deploy/README.md`（结果必须是 ASCII + CRLF）。

**驱动总裁的三个注意点**：

1. **客户机必须能上公网**。当前驱动包只有主程序和 `Res\`，**没有离线驱动库**（`Res\Config.ini` 写着
   `type=Lite2` 但同目录已无 `Win10x64\`），它会去 `drvceoup.sysceo.cn` 联网取驱动；只通局域网就会失败。
2. **可能被改浏览器主页**。**量产前务必在一台机器上验证**主页和默认搜索。
3. **企业合规**：对驱动版本有要求时，建议改用厂商驱动包 + `pnputil` 推，而不是让它自己联网挑。

想全自动（静默）：**别用社区传的 `/S`，用官方参数**——`-a` 自动安装、`-d` 装完删除自身及离线包、
`-stopbs` 过滤显卡/USB3.X/磁盘控制器、`-noauto` 部署环境不自动装、`-PeLoad` PE 下静默加载
（详见包内 `Res\Cmdline\zh_cn.txt`）。更彻底的是 `Drvceo.ini` 的 `[DrvCeoSet]`：

```ini
Silence=on           ; 全静默，隐藏窗体（无人值守关键开关）
Time=30              ; 自动安装倒计时秒数
DesktopRestart=on    ; 装完自动重启
Dupdrv=off           ; 关闭部署后首次进桌面触发联网更新
ToolUpdate=off       ; 不检测程序更新
```

`Drvceo.ini` 官方要求 **ANSI 编码**。注意若它装完自动重启，`LogonCount=1` 会让机器停在锁屏。

## 6. 缺驱动补救（备用）

> 当前方案**不做文件注入**（`unattend.xml` 里没有 `PnpCustomizationsWinPE`，界面「注入文件」留空），
> 完全依赖 ISO 内 `boot.wim` 自带的网卡驱动。本节是**逃生路线**。

报"缺少计算机所需的介质驱动程序"时，缺的**不是硬盘驱动，是网卡驱动**——WinPE 挂不到 ISO 源。
⚠️ **Hyper-V 测不出来**（虚拟网卡驱动是 `boot.wim` 自带的），只有真机会遇到，且机型差异很大。

三步恢复：

1. 把 `Microsoft-Windows-PnpCustomizationsWinPE` 组件加回 `unattend.xml`（放在 `windowsPE` 阶段、
   `Microsoft-Windows-Setup` 之前），`DriverPaths` 指向 `X:\drivers`。
2. 打注入包：注入负载已从仓库删除，先取回（见 [遗留问题](#11-遗留问题) 里的 git 命令），
   把 `VentoyAutoRun.bat` 和 `drivers\` 打成**一个** `.7z`，在镜像管理里设为该 ISO 的注入文件。
   `drivers\` **即使为空也要留在包里**——路径必须存在。
3. 收集驱动（要解压成 `.inf` 结构，不是厂商 `.exe` 安装包）：Intel 网卡完整包、Broadcom NetXtreme、
   Mellanox WinOF-2、Realtek `rt640x64.inf`、Marvell/Aquantia `aqnic`。

现场定位：按 `Shift+F10` 执行 `ipconfig /all`。看不到与 iVentoy 页面对应的网卡 → 就是缺网卡驱动；
能看到网卡但仍报错 → `type X:\Windows\System32\ventoy\vtoype.log` 发作者。

## 7. 单机验收

**必做，不要直接批量。** 找一台和量产机同型号的机器，物理断开其他硬盘：

1. BIOS 确认：**UEFI 模式**、CSM/Legacy 关闭、Secure Boot 按第 3 节决定。
2. 客户端 PXE 启动，观察：拿到 IP → 出现菜单 → 5 秒后自动进 Win11 ISO。
   菜单不走 = 超时没设或为 0；停在"选自动安装脚本" = 脚本选择超时为 0。
3. 分区阶段应**无提示直接开始**。弹出分区界面 = `unattend.xml` 没生效（查路径 / 默认脚本编号 / 是否在 `user/scripts`）。
   报 answer file 解析失败时**优先怀疑 `$$VT_...$$` 没被替换**——iVentoy 只在**被当作自动安装脚本**处理的文件上做变量扩展，
   所以通常是路径/编号没配对，而不是变量语法写错。HTTP 直接下 `user/scripts/unattend.xml` 拿到的是**未展开**原文，不能用来验证。
4. 装完自动登录进桌面即结束（无后置脚本，不会再自动重启）。

| 检查项 | 命令 / 位置 |
|---|---|
| 分区是 GPT + EFI + MSR | 磁盘管理，或 `diskpart` → `list partition` |
| 装到了预期的盘 | `Shift+F10` → `diskpart` → `list disk` 核对容量与磁盘号 |
| Windows 版本正确 | `winver` 或 `dism /online /get-currentedition` |
| 内置 Administrator 已启用 | `net user Administrator`（"帐户启用"是 Yes） |
| 密码可登录 / 自动登录生效 | 注销后用密码登录；再重启一次，应无需输密码进桌面 |
| 系统语言/区域是中文 | 设置 → 时间和语言 |
| 中文注释没弄坏 answer file | 全程没出现"无法分析或处理无人参与应答文件" |
| 首次登录拉起驱动总裁 | 登录后自动弹出界面；日志 `C:\Windows\Temp\install-drivers.log` |
| 驱动装完无副作用 | 检查浏览器主页 / 默认搜索（见第 5 节） |

> 计算机名是 `DESKTOP-XXXXXXX` 这类随机名，属预期行为不是故障（见 [已知缺口](#已知缺口)）。
> 单机跑通后再逐步放开并发，注意免费版上限。

### 已知缺口

后置脚本删除后，下面这些**不会自动完成**：

| 能力 | 现状 | 影响 |
|---|---|---|
| 自动命名 | ❌ | 不设 `<ComputerName>`，Windows 生成随机名 |
| 加入域 | ❌ | 装完是工作组机器 |
| 打驱动 | ⚠️ 半自动 | 自动弹出驱动总裁，但需人工确认 |
| 装软件 | ❌ | 手动装，或加域后用组策略 / SCCM / Intune 推 |
| 关闭自动登录 | ❌ | `Winlogon\DefaultPassword` 里明文存着密码 |
| 全自动装完 Win11 + 启用 Administrator + 自动登录 | ✅ | 装完即进桌面 |
| 首次登录拉起驱动总裁 | ✅ | 保留图形界面 |

**为什么不设 `ComputerName`**：写死会让所有机器同名、同网段直接冲突；用 iVentoy 的 MAC 变量也拼不出合法名——
Windows 计算机名最长 15 字符，带连字符的 MAC 本身 17 字符。

**想加回后置自动化**：脚本在 git 历史里，可取回并从已跟踪文件移除：

```bash
git show 948160a:user/deploy/deploy.ps1          > deploy.ps1
git show 948160a:user/injection/VentoyAutoRun.bat > VentoyAutoRun.bat
```

同时改回 `unattend.xml` 两处：① 加回 `FirstLogonCommands` 钩子（内容同上 git 命令）；
② 把 `<LogonCount>` 从 `1` 调回 `3`——那个脚本结尾会重启，1 次自动登录不够，第二次开机会停在锁屏。

## 8. 批量与授权

- **免费版最多 20 个客户端**：依据是主界面 `设备列表` 的设备数，到 20 后不再服务新客户端。
  绕过方式只有"关掉重开 + 换 IP 池"。**禁止商用**，批量生产要买专业版。
- **专业版 299 元**（大版本一次性，1.x 内有效）：客户端数无限制、可商用。License 绑**服务端母机**
  机器码（最多 2 个，绑定后不可解绑），客户机数量不受限。建议先用免费版跑通再绑机器码。
- 并发时单台服务器同时供 ISO / HTTP / SMB，网卡和磁盘 IO 是瓶颈；建议与客户机之间走千兆以上、别跨 WAN。

## 9. 安全（必读）

有凭据**明文经过网络**：`unattend.xml` 里的 Administrator 密码（当前 `root123`）明文写在文件里，
且 iVentoy 的 HTTP 把 `user/` 直接对外开放（`http://<IP>:16000/user/...`），同网段 `curl` 就能拿到。

⚠️ **当前配置是本方案安全性最差的一档**：内置 Administrator（攻击者第一个尝试的账户名）
+ 自动登录（无需输密码就进桌面）+ 弱密码 `root123`，而且仓库**公开**，密码直接写在公网可见的文件里。
**仅适合实验环境**，任何真实部署前至少要改密码，并考虑关掉自动登录。

缓解：装机期间用独立 VLAN / 临时交换机并装完拔线；把密码当一次性口令，量产完统一改密；
**别把真实密码提交进 git**（`.gitignore` 里预留了本地覆盖文件）；26000 不要暴露到非装机网段。
未来若要加回自动加域，更彻底的做法是**离线加域**（`djoin` 生成 blob + `Microsoft-Windows-UnattendedJoin`），
完全不传凭据，代价是每台机器要先预生成 blob。

## 10. 排错速查

| 现象 | 原因 / 处理 |
|---|---|
| 卡在获取 IP，最后 `PXE-E51` | 第三方 DHCP 不响应 PXE → 用 iVentoy 内置 DHCP；或 DHCP Snooping 拦了 ProxyDHCP（端口设 trusted） |
| 拿到 IP 但 `PXE-E53 / No boot filename` | 响应了 PXE 但没给 bootfile → 切 `ProxyNet`；或 `External` 并配 066/067 |
| 客户端直接挂死 | 送错架构的启动文件 → 用 `ProxyNet`/`External` 让 iVentoy 自己判断；`ExternalNet` 下检查 bootfile 的 `_bios`/`_uefi` 后缀 |
| 启动菜单停住不自动走 | 菜单默认超时时间 = 0 |
| 停在"选择自动安装脚本" | 脚本选择超时时间 = 0 |
| 分区界面弹出来了 | `unattend.xml` 没生效：路径 / 默认脚本编号 / 是否放在 `user/scripts` |
| 开机先出现"语言/键盘"选择页 | answer file **完全没被读到**，改内容没用，先查上面三条 |
| 报"无法分析或处理无人参与应答文件" | **编码问题**：丢了 UTF-8 BOM（编辑器另存为 ANSI/GBK，或用不保留 BOM 的工具）。VS Code 右下角应为 `UTF-8 with BOM` |
| 卡在"选择要安装的版本" | `/IMAGE/NAME` 与镜像里的 Name 不匹配，Setup 回退到交互选择。用 `dism /Get-WimInfo` 照抄 |
| 装出来的版本不是专业版 | 用了 `/IMAGE/INDEX` 且写错——多版本 ISO 上索引 1 是**家庭版**，专业版是 4 |
| 停在「产品密钥」页 | 缺 `ProductKey`（它才是唯一能跳过密钥页的元素）；或密钥与镜像版本对不上 |
| 报"缺少计算机所需的介质驱动程序" | **网卡驱动**，Hyper-V 测不出来 → 第 6 节，`Shift+F10` + `ipconfig /all` |
| 装到错误的盘 / 擦错盘 | 别写死 `DiskID=0`；`_CLOSEST_`/`_MAX_SIZE` **不排除 USB 盘**；装机拔掉可移动存储；首次测试拔数据盘 |
| 装到一半卡住、报无法应用映像 | 分区布局与固件不匹配（UEFI 用了 MBR），或 `INSTALL/NAME` 版本名写错 |
| **改了 `unattend.xml` 但客户端行为完全没变** | **iVentoy 缓存脚本内容**，只在启动时读一次 → 必须重启（或删除脚本再新增）。本项目踩过最深的坑 |
| 装完停在锁屏，自动登录没生效 | 九成是 `AutoLogon` 与 `AdministratorPassword` 两处密码不一致 |
| OOBE 没走完 / 卡在 OOBE / 直接报错 | 有人加了 `net user Administrator /active:yes` 之类的显式启用步骤（见第 4 节） |
| 报密码不符合密码策略 | `root123` 只有 7 位、2 类字符。单机默认策略能过；环境下发了复杂度策略时会失败，改成大小写+数字+符号 |
| **装完没弹出驱动总裁** | 看 `C:\Windows\Temp\install-drivers.log`。**没这个文件**说明第 1 条命令就没跑起来 → 查 16000 端口通不通、`user\deploy\` 下有没有 `install-drivers.cmd` |
| 驱动脚本报下载失败 | `user\deploy\` 下缺 `tool_files.txt` 或 `tool\`，或文件不在清单里。浏览器打开该 URL 可直接验证 |
| 日志出现 `MISSING or EMPTY` | `tool` 增删了文件但没重新生成清单 |
| 驱动总裁装不出驱动 | 它需要**公网**，客户机只通局域网时会失败 |
| 装完发现所有机器同名 | 不会发生：当前不设 `<ComputerName>`，Windows 生成随机名 |
| UEFI 启动 Windows 花屏 | 1.0.25 已修，用最新版；菜单里也可设分辨率 |
| 安全启动过不去 | 见第 3 节三种模式；个别机型要先使能 BIOS 的 UEFI CA |
| 改动不生效 | iVentoy 改配置后需重新"刷新镜像列表"；改了 `unattend.xml` 后确认没有旧副本残留 |

## 11. 遗留问题

**1. `Windows.old` 为什么存在？（未查清）**

answer file 里写了 `<WillWipeDisk>true</WillWipeDisk>`，**如果生效磁盘会被清空，不该留下 `Windows.old`**。
它却一直在，意味着**分区那一步可能没按预期执行**，是潜在安全问题（给带数据的机器装机时磁盘可能不被清空）。

不过 `<WillShowUI>OnError</WillShowUI>` 只在**出错时才弹 UI**，而实测全程无提示地自动走完，
说明分区配置很可能确实生效了——所以更可能是**早期某次未擦盘安装的历史残留**，
或者是**装完之后 Windows 功能更新**产生的（特性更新同样会生成 `Windows.old`）。

**下次在真机上装机时留意**：有没有出现「你想将 Windows 安装在哪里」的分区选择页？
再对比 `C:\Windows.old\Windows\System32\ntoskrnl.exe` 的时间和版本与当前系统是否一致。
若出现分区页，查 `C:\Windows\Panther\setuperr.log`。
想做决定性验证：先在目标盘建个第二分区放个标记文件，装完看标记是否消失。

**2. 日志时间戳不精确（纯影响可读性）**

`install-drivers.log` 里所有 `ok:` 行显示同一时间，因为批处理的 `for` 循环里 `%time%` 只在**进入循环时展开一次**，
要显示真实时间得用延迟展开 `!time!`。**这一条故意没改**——脚本是实测通过的，为一个纯显示问题改动它、
还要再花一轮装机验证，不划算。等下次因功能需要改这个脚本时顺手修掉。

**3. 两处数字不一致（未改）**

`README.md` 第 5 节曾写「`tool_files.txt`（112 行）」「`tool\`（约 599 MB）」，而实际清单是 **114 项 / ~999 MB**。
纯笔误，不影响任何东西，暂留。

## 参考

- [iVentoy 使用说明](https://www.iventoy.com/cn/doc_start.html) ·
  [操作系统全自动安装](https://www.iventoy.com/cn/doc_unattend_install.html) ·
  [自动安装脚本 / 变量扩展](https://www.iventoy.com/cn/doc_autoinstall.html)
- [配合第三方 DHCP Server](https://www.iventoy.com/cn/doc_ext_dhcp.html) ·
  [确认外部 DHCP 支持 PXE](https://www.iventoy.com/cn/doc_ext_dhcp_resp.html)
- [HTTP 路径说明](https://www.iventoy.com/cn/doc_http_url.html) ·
  [文件注入](https://www.iventoy.com/cn/doc_injection.html) ·
  [VentoyAutoRun.bat](https://www.iventoy.com/cn/doc_inject_autorun.html) ·
  [启动 Windows 时缺少驱动错误](https://www.iventoy.com/cn/doc_win_driver.html)
- [安全启动支持说明](https://www.iventoy.com/cn/sboot.html) ·
  [Windows 11 ByPass 说明](https://www.iventoy.com/cn/doc_win11_bypass.html) ·
  [关于 WinPE](https://www.iventoy.com/cn/doc_winpe.html) ·
  [版本说明（免费/专业）](https://www.iventoy.com/cn/doc_edition.html)
