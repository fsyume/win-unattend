# iVentoy 部署 Windows 11 无人值守 — 实施手册

针对你的环境选定：**UEFI/GPT 客户端 + Windows 11 + 已有第三方 DHCP + 全自动装机（不含后置自动化）**。

> **当前范围说明**：现阶段只做「无人值守装完 Windows 11」，**不包含**改名 / 加域 / 装软件 / 推驱动。
> 后置脚本已被移除，原因和加回方法见 [第 5.3 节「已知缺口」](#53-已知缺口现阶段没做的部分)。

---

## 0. 方案总览

整体思路：**iVentoy 负责把 ISO 送到机器上，`unattend.xml` 负责回答全部安装问题**。全程无人干预，装完停在桌面。

```
客户端加电 (UEFI PXE)
        │
        ├─(1) 第三方 DHCP 只发 IP；iVentoy 以 ProxyNet 模式补 next-server/bootfile
        │
        ├─(2) iVentoy 送 iPXE loader → 显示启动菜单
        │      菜单超时 5s → 自动选「默认启动文件」= Windows 11 ISO
        │
        ├─(3) 依赖 ISO 内 boot.wim 自带的网卡驱动把 ISO 挂成本地盘
        │      （不做文件注入；万一真机报"缺少驱动"，见第 6 节补救）
        │
        └─(4) unattend.xml 生效：擦盘 → 建 GPT 分区 → 装 WIM
               → 启用内置 Administrator → 自动登录进桌面（结束）
```

四个「自动化开关」缺一个就会停在某处等人点：

| 开关 | 位置 | 不配的后果 |
|---|---|---|
| 菜单默认超时时间 | 参数设置 | 卡在启动菜单 |
| 设为默认启动文件 | 镜像管理 | 超时后走列表第 1 个 ISO |
| 自动安装脚本 | 镜像管理 | 到分区/OOBE 全部手点 |
| 脚本选择超时时间 | 镜像管理 | 卡在"选哪个安装脚本" |

---

## 1. 文件清单

```
<iVentoy 解压目录>\
├── iso\                                 ← 放 Windows 11 ISO（可软链接）
└── user\
    └── scripts\
        └── unattend.xml                 ← 【本仓库 unattend.xml 放这里】
```

本仓库只有三个文件：`unattend.xml`（answer file）、`README.md`（本文档）、`.gitignore`。
后置脚本 `deploy.ps1` 和注入负载 `VentoyAutoRun.bat` 已按你的要求删除，
需要时可以从 git 历史里取回（见第 5.3 节）。

**命名铁律**（官方明确要求）：iVentoy 解压路径、`iso` 目录下的目录名和 ISO 文件名、脚本名，**都不能有中文或空格**。

---

## 2. 步骤一：iVentoy 服务端

1. 用 **1.0.43 或更新**版本。理由：1.0.43 起"自动启动失败会回退到手动模式，页面不再整体退出"；1.0.43 还修了 wimboot 模式启动 Windows 时自动安装脚本不生效的 BUG（这正是你要用的功能）。
2. 下载 win64（或 linux64）包，解压到**无中文无空格**的路径。
3. ISO 放进 `iso\`。不想占空间就软链接：
   ```
   mklink D:\iventoy\iso\Win11.iso  E:\download\Win11_24H2_x64.iso
   ln -s /opt/iso/Win11.iso /opt/iventoy/iso/Win11.iso
   ```
4. 启动：
   - Windows：双击 exe，会自动开浏览器；也可注册为开机自启动服务（官方文档《注册 Windows 服务开机自启动》）。
   - Linux：`sudo bash iventoy.sh start`；自启动用 `sudo bash iventoy.sh -R start`（`-R` = 按上次参数启动，前提是先手动成功启动过一次）。
5. 浏览器用 **Chrome 或 Firefox**（官方只测了这两个），访问 `http://127.0.0.1:26000`。

> 端口备忘：管理界面 **26000**、HTTP 服务 **16000**、NBD **10809**。
> 客户端要能访问 16000（iVentoy 用它把 ISO 内容传给客户端），防火墙上要放通。

---

## 3. 步骤二：和第三方 DHCP 共存（你环境的关键点）

### 3.1 先确认对方的 DHCP 会不会响应 PXE 请求

有些 DHCP 会直接过滤掉 PXE 阶段的请求。判定方法（官方给了两种）：

- **抓包**：客户端同网段 PC 上 Wireshark 过滤 `dhcp`，能看到 DHCP Offer 就是响应了。
- **看客户端屏幕**：
  - 打印 `PXE-E53`、`No boot filename` 或已拿到 IP → **响应了 PXE**，需要按下面配。
  - 长时间卡在获取 IP，最后 `PXE-E51` → **不响应 PXE**，可以当它不存在，直接用 iVentoy 内置 DHCP。

### 3.2 选模式：优先 `ProxyNet`

| 模式 | 适用 | 第三方 DHCP 要改什么 |
|---|---|---|
| **`ProxyNet`** ✅ 推荐 | iVentoy 与 DHCP **在不同机器**，同 VLAN | **什么都不用改** |
| `Proxy` | iVentoy 与 DHCP 跑在**同一台机器** | 不用改 |
| `External` | ProxyNet 不满足时 | 配 `next-server`=<iVentoy IP>、`bootfile`=`iventoy_loader_16000` |
| `ExternalNet` | iVentoy 与 DHCP **跨 VLAN** | 必须能按 DHCP 报文动态下发 bootfile，要求很高 |

你的情况（路由器/域控/核心交换机上的 DHCP，iVentoy 另跑一台）= **`ProxyNet`**。

原理：ProxyNet 下 iVentoy 仍然起内部 DHCP，但**不发 IP**，只在 67 和 4011 端口补 `next-server`/`bootfile` 选项，所以不会和你的 DHCP 抢地址池。官方明确写"优先使用 ProxyNet 模式"。

操作：`参数配置` → DHCP 服务器模式 → `ProxyNet`。此时主界面的 IP 地址池填不填都不影响客户端拿地址（地址由你的 DHCP 发）。

> ⚠️ 如果交换机开了 **DHCP Snooping**，需要把 iVentoy 服务器所在端口设为 **trusted**，否则它的 ProxyDHCP 应答会被丢弃，表现为客户端拿到 IP 但拿不到 bootfile。

### 3.3 备选：改用 `External` 模式

如果 ProxyNet 在你的网络里不通，就走 External，此时在 DHCP 服务器上配：

```
option 066 (Next Server)  = <iVentoy 服务器 IP>
option 067 (Bootfile Name) = iventoy_loader_16000
```

注意末尾的 `16000` 必须和 iVentoy 的 HTTP 端口一致（改了端口这里也要改）。`External` 模式下第三方 DHCP 不需要区分 BIOS/UEFI —— iVentoy 会旁听 DHCP 报文自己判断架构，然后返回正确的启动文件。

Windows Server DHCP 图形界面里就是"作用域选项 → 066 启动服务器主机名 / 067 启动文件名"。**不要**在这台 DHCP 上同时保留别的 067。

---

## 4. 步骤三：界面配置（把四个开关打开）

`参数设置` 页：
- **菜单默认超时时间** = `5`（0 = 永不超时）
- **DHCP 服务器模式** = `ProxyNet`
- 勾选 **ByPass HW Check**（跳过 Win11 的 RAM/TPM/SecureBoot/CPU 检查）
- 勾选 **ByPass NRO**（跳过联网账户要求）

> ⚠️ **TPM/安全启动绕过不在 `unattend.xml` 里**。勾选框的作用是在 WinPE 里往注册表写
> `HKLM\SYSTEM\Setup\LabConfig\BypassRAMCheck / BypassTPMCheck / BypassSecureBootCheck / BypassCPUCheck`
> 和 `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE\BypassNRO`。
> 也就是说：把这份 answer file 拿去走 U 盘安装，或者忘了勾这个框，在不满足硬件要求的机器上
> Win11 会直接停在"这台电脑不满足运行 Windows 11 的要求"。
>
> 另外，**本方案不依赖 `Bypass NRO`**：本地账户是通过微软有文档支持的 `UserAccounts` 元素创建的，
> 所以即使 24H2/25H2 把 `bypassnro` 移除或改掉，装机流程也不会因此断掉。

`镜像管理` 页，选中 Win11 ISO：
- 点 **设为默认启动文件**
- 自动安装脚本点 **新增** → 选 `unattend.xml`（位于 `user/scripts/`）
- 设置 **默认自动脚本编号**（从 1 开始，0 = 不使用自动安装）
- 设置 **脚本选择超时时间** 为非 0 值
- ~~设置 **注入文件**~~ —— 当前方案不做文件注入，这一项**留空**

> 界面上的脚本路径以 UI 实际提示为准（官方示例脚本放在 `user/scripts/example` 下）。

### 安全启动（如果客户端 BIOS 开着 Secure Boot）

iVentoy 1.0.40+ 支持，**仅 X86_64 客户机**，三种模式：

| 模式 | 优点 | 代价 |
|---|---|---|
| `Not Supported` | 兼容性最好 | 必须进 BIOS 关掉 Secure Boot |
| `Standard` | 客户端零操作 | **中文菜单 / GrubBoot / UEFI 分辨率锁定 / 启动密码 全部不可用** |
| `ByPass` | 功能齐全 | 每台机器**首次**需手动导入一次 Key |

批量装机建议：**先在 BIOS 统一关掉 Secure Boot** 走 `Not Supported`（工位机通常可批量设置），或者接受一次性的 Key 导入走 `ByPass`。部分机型 BIOS 还需先使能 UEFI CA。

---

## 5. 步骤四：改 answer file 里的 EDIT ME

### 5.1 `unattend.xml`（搜索 `EDIT ME`）

| 位置 | 改成 |
|---|---|
| `/IMAGE/NAME` 的 `Windows 11 Pro` | 你镜像里**准确的版本名**（见下方"中文 ISO 陷阱"） |
| `AutoLogon` 的 `<Value>` | Administrator 的密码 |
| `UserAccounts` 的 `<Value>` | 同上，两处必须一致 |

> **"注册给谁"的四个字段已全部删除**（`RegisteredOwner`、`RegisteredOrganization`、
> `UserData` 里的 `FullName`、`Organization`）。它们只是展示性元数据——`systeminfo`、
> 注册表 `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion`、资产清点工具会读，
> 不影响激活、授权、计算机名或加域。
> 需要时按 README 里 `unattend.xml` 的注释加回来即可（注意 `FullName` / `Organization`
> **不支持空值**，要留就必须填内容）。
>
> ⚠️ **`<AcceptEula>true</AcceptEula>` 绝对不能删** —— 没有它 Setup 会弹出许可条款页面，
> 全自动流程就断了。
>
> ⚠️ **`<ProductKey>` 也不能删**。它的官方定义是 "Specifies the Windows image to install during
> Windows Setup"，既决定装哪个版本，也是**唯一能跳过「产品密钥」页的元素**。
> 当前填的是微软官方公开的 KMS 客户端通用密钥（Windows 11 Pro，`W269N-...`），
> 它**只选版本、不具备激活功能**，属于公开信息，放在明文 HTTP 提供的文件里没有泄露风险。
> 想换成别的版本，改 `<Key>` 即可，XML 注释里列了 Pro / Pro N / Home / Enterprise / Education 五个。
> 真正的激活仍然靠 KMS / ADBA / 数字许可证。
>
> **千万不要把真实的 MAK 零售密钥填进去** —— 那才是有泄露风险的。

**中文 ISO 陷阱（务必看）**：非英文版 Windows 安装介质的映像 **Name 通常是本地化的**。中文版 ISO 用 `dism /Get-WimInfo` 查出来的"名称"很可能是 `Windows 11 专业版` 而不是 `Windows 11 Pro`。必须**照 dism 原样抄**。

而一旦这个值含中文，`unattend.xml` 就不能再保持我交付时的纯 ASCII 形态了。二选一：

- **(a)** 把 `unattend.xml` 另存为 **UTF-8 带 BOM**；
- **(b)** 改用索引，文件名保持 ASCII：
  ```xml
  <Key>/IMAGE/INDEX</Key>
  <Value>5</Value>
  ```
  代价是索引和具体 ISO 绑定，换 ISO 要重新确认（`dism /Get-WimInfo` 里第几个是专业版）。

查准确值的命令（在有 Windows 的机器上挂载 ISO 后执行）：

```cmd
dism /Get-WimInfo /WimFile:D:\sources\install.wim
```

新镜像可能是 `install.esd`，把文件名换掉即可。

**分区布局**：默认是 `EFI 300MB + MSR 16MB + Windows(占满剩余)` 三分区。
- 为什么这样最稳：`<Extend>true</Extend>` 的分区必须**最后创建**，所以 OS 分区放最后；不建独立恢复分区，WinRE 落在 `C:\Windows` 里，也顺带避开了 Windows 11 25H2/26H2 把恢复分区切成 500MB 后累积更新报 `0x80070643` 的老问题。
- 如果你想要独立 1GB WinRE 分区：`unattend.xml` 里有一段注释掉的备用 `<DiskConfiguration>`，整块替换，并把 `<InstallTo><PartitionID>` 从 `3` 改成 `4`。要点是恢复分区必须在**最前面**（用 `TypeID de94bba4-06d1-4d40-a16a-bfd50179d6ac`），Windows 分区才能继续 `Extend` 吃满剩余空间。

**自动分区 + 自动选盘**：分区本身是 `unattend.xml` 里的 `<DiskConfiguration>` 全自动完成的（擦盘 → 建 GPT → 格式化 → 装 WIM，全程无提示）。选哪块盘由 iVentoy 变量决定，当前用的是**容量最接近 200GB 的那块盘**：

```xml
<DiskID>$$VT_WINDOWS_DISK_CLOSEST_200$$</DiskID>
```

这个变量在 `<DiskConfiguration><Disk><DiskID>` 和 `<InstallTo><DiskID>` 两处都写了，同一台客户机上两次展开结果一致，所以不会错位。

可替换的三种选盘策略（官方变量表，**只能用于 Windows unattend.xml**）：

| 变量 | 选中的盘 |
|---|---|
| `$$VT_WINDOWS_DISK_CLOSEST_200$$` | 容量最接近 200GB 的盘 ← **当前使用** |
| `$$VT_WINDOWS_DISK_1ST_NONUSB$$` | 第一个非 USB 盘 |
| `$$VT_WINDOWS_DISK_MAX_SIZE$$` | 容量最大的盘 |

`XXX` 可以换成任意数值，比如 `$$VT_WINDOWS_DISK_CLOSEST_500$$`。**注意只能用一个，没有"或"逻辑。**

> ⚠️ **两个必须知道的坑**
>
> **1. `_CLOSEST_` / `_MAX_SIZE` 不排除 USB 盘。** 官方变量表里只有 `_1ST_NONUSB` 明确写了"非 USB"。
> 也就是说，如果机器上插着一块大容量 U 盘或移动固态，它参与容量比较并可能胜出，然后被**擦掉**。
> **装机时务必拔掉所有可移动存储。**
>
> **2. 比较的是 Windows 报出来的容量，即 GiB 但显示成 GB。** 标称 200GB 的盘在 diskpart 里显示约 `186 GB`，
> 标称 256GB 的约 `238 GB`。填 200 仍然能正确区分这两者（`|186-200| = 14` 比 `|238-200| = 38` 更近），
> 所以不用把 200 改成 186。但如果你的机器上同时存在标称 200GB 和 240GB 的盘，两者都离 200 不远，
> 建议先在一台机器上确认实际数值再决定填多少。
>
> **怎么确认真实数值**：本方案不做文件注入，所以没有 `X:\VentoyAutoRun.log` 可看。
> 直接看 iVentoy 主界面的**设备列表**（会显示每台客户端的磁盘信息），或者最快的方式——
> 在 Windows 安装界面按 `Shift+F10` 调出 cmd，敲：
>
> ```
> diskpart
> list disk
> exit
> ```
>
> 每块盘的准确 GB 数和磁盘号一目了然，据此把 `_CLOSEST_XXX` 调到你要的值。
> 建议在第一台真机上把这一步固化进验收流程。

**擦盘保护**：`<WillWipeDisk>true</WillWipeDisk>` 不可逆。选盘为什么不写死 `DiskID=0`——多控制器服务器上枚举顺序和你以为的不一样，写死 0 很可能擦错盘。用"最接近 200GB"这种**按属性选**的方式，换固件、换控制器、换机型都不需要改 answer file。**首次测试请物理拔掉所有数据盘。**

### 5.2 为什么直接用内置 Administrator（文档依据）

本方案不创建自建账户，直接启用并使用内置 Administrator。这不是猜的，微软文档写得很明确：

- **[AdministratorPassword](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-useraccounts-administratorpassword)**：
  > "By default, the built-in administrator account is disabled in all default clean installations.
  > You can enable the built-in administrator account during unattended installations,
  > **by setting the AutoLogon/Username to Administrator**. This enables the built-in administrator
  > account, even if a password is not specified in the AdministratorPassword setting."

  即：**真正启用该账户的是 `AutoLogon` 的 `Username=Administrator`**，
  `AdministratorPassword` 只负责设密码。两者分工不同，缺一不可。

- **[AutoLogon](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-shell-setup-autologon)**：
  > "In Windows 10, if you configure AutoLogon, the OS will **skip the user account creation phase during OOBE**."

  这正是我们要的效果。同页还规定 **"LogonCount must be specified if AutoLogon is used"**，
  所以 `LogonCount` 不能省。

⚠️ **不要额外去显式启用内置 Administrator**。同一份文档警告：

> "It is not necessary to explicitly enable the built-in Administrator account ... 
> **Doing so can prevent the image or device from entering the Out-Of-Box Experience (OOBE) successfully.**"

也就是说，**别再加 `net user Administrator /active:yes` 这类步骤**。本 answer file 曾经加过一条
`Microsoft-Windows-Deployment` 的 `RunSynchronous` 做这件事，已按文档删除。

⚠️ 还有一条**官方建议我们没有照做**，知悉即可：同一篇《AutoLogon》建议在这种场景下
（用内置或既有账户自动登录）**再用 unattend 至少创建一个 Administrators 组成员账户**，
以便自动登录结束后设备仍可管理。本方案没有自建账户——内置 Administrator 本身就是管理员，
可管理性没问题，但这确实偏离了官方建议。想照做就把 `LocalAccounts` 块加回来。

### 5.3 已知缺口（现阶段没做的部分）

删掉后置脚本后，下面这些**不会自动完成**。装机前请确认你能接受：

| 能力 | 现状 | 影响 |
|---|---|---|
| **自动命名** | ❌ 没有 | `unattend.xml` 不设 `<ComputerName>`，Windows 自己生成 `DESKTOP-XXXXXXX` 之类的随机名。想按序列号/MAC 命名必须加后置脚本 |
| **加入域** | ❌ 没有 | 装完是工作组机器，需手动加域 |
| **装软件 / 打驱动包** | ❌ 没有 | 只能手动装，或用其它手段（组策略、SCCM、Intune）在加域后推 |
| **关闭自动登录** | ❌ 没有 | 自动登录保持开启，`Winlogon\DefaultPassword` 里明文存着 Administrator 的密码 |
| 全自动装完 Win11 + 启用 Administrator + 自动登录 | ✅ 有 | 这是当前方案的全部内容 |

**为什么不设 `ComputerName`**：写死一个固定名字会让所有机器同名，在同网段或同域里直接冲突。而用 iVentoy 的 MAC 变量也拼不出合法名字——Windows 计算机名最长 15 字符，带连字符的 MAC 本身就有 17 字符。

**以后想加回后置自动化**：脚本已从仓库删除，但完整内容在 git 历史里，可以取回：

```bash
git show 948160a:user/deploy/deploy.ps1          > deploy.ps1
git show 948160a:user/injection/VentoyAutoRun.bat > VentoyAutoRun.bat
```

同时需要改回 `unattend.xml` 两处：
1. 加回 `FirstLogonCommands` 钩子（同样在 `git show 948160a:unattend.xml` 里）；
2. 把 `<LogonCount>` 从 `1` 调回 `3`——因为那个脚本结尾会重启，1 次自动登录不够，第二次开机会停在锁屏。

第 6 节的缺驱动补救方案同理，需要重新做注入包。

---

## 6. 步骤五：缺驱动的补救方案（**当前不做，备用**）

> **当前方案已明确不使用文件注入**：`unattend.xml` 里没有 `Microsoft-Windows-PnpCustomizationsWinPE` 组件，
> iVentoy 界面的「注入文件」也留空。装机完全依赖 ISO 内 `boot.wim` 自带的网卡驱动。
>
> 本节保留为**逃生路线**：真机万一撞上"缺少驱动"，照这里做即可恢复，不需要重新设计流程。

### 6.1 为什么会有这个报错

iVentoy 通过 PXE 启动后，要在 WinPE 里用**网卡驱动**把服务器上的 ISO 挂成本地盘再跑 `setup.exe`。`boot.wim` 里没有你这台机器网卡的驱动，就会弹"缺少计算机所需的介质驱动程序"——**那不是缺硬盘驱动，是缺网卡驱动 + 挂不到 ISO 源**。

⚠️ **在 Hyper-V 上测不出这个问题**：Hyper-V 虚拟网卡的驱动是 `boot.wim` 自带的，无论做不做注入都能装成功。**必须上真机才能验证**，而且不同机型的网卡型号差异很大。

### 6.2 万一撞上了，三步恢复

1. **把组件加回 `unattend.xml`**（放在 `windowsPE` 阶段、`Microsoft-Windows-Setup` 之前）：

   ```xml
   <component name="Microsoft-Windows-PnpCustomizationsWinPE"
              processorArchitecture="amd64"
              publicKeyToken="31bf3856ad364e35"
              language="neutral"
              versionScope="nonSxS"
              xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"
              xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
     <DriverPaths>
       <PathAndCredentials wcm:action="add" wcm:keyValue="1">
         <Path>X:\drivers</Path>
       </PathAndCredentials>
     </DriverPaths>
   </component>
   ```

2. **打注入包**：注入负载的文件已从仓库删除，先取回来（见 5.3 节），
   把 `VentoyAutoRun.bat` 和 `drivers\` 一起打包成**一个** `.7z`，
   在 `镜像管理` 里设为该 ISO 的**注入文件**。`drivers\` **即使为空也要留在压缩包里**——路径必须存在。
   - `VentoyAutoRun.bat` 会在 `winpeshl.exe` 之前自动执行：用 `drvload` + `pnputil` 把 `X:\drivers`
     里的驱动装进当前 WinPE，并把 `ipconfig /all`、网卡 PnP 列表、`list disk` 写进 `X:\VentoyAutoRun.log`。
   - 不想用它也行：自己写个批处理做同样的事，或者干脆靠下面的第 3 步收集驱动 +
     `unattend.xml` 的 `DriverPaths` 让 Setup 自己加载（多数情况下这样就够）。

3. **收集驱动**（要解压成 `.inf` 结构，不是厂商的 `.exe` 安装包）：
   Intel 网卡驱动完整包、Broadcom NetXtreme、Mellanox WinOF-2、Realtek `rt640x64.inf`、
   Marvell/Aquantia `aqnic`。服务器和笔记本差异很大，建议一次收全。

### 6.3 现场定位这个报错

按 `Shift+F10` 调出 cmd：

```
ipconfig /all
```

- 看不到 MAC 与 iVentoy 页面对应的网卡 → **就是缺网卡驱动**，回到 6.2。
- 能看到网卡但仍报错 → `type X:\Windows\System32\ventoy\vtoype.log`，把日志发给作者。

---

## 7. 步骤六：单机验证（**必做，不要直接批量**）

找一台和量产机同型号的机器，物理断开其他硬盘：

1. 确认 BIOS：**UEFI 模式、CSH/Legacy 关闭**、Secure Boot 按第 4 节决定开或关。
2. 客户端设 PXE 启动，观察：
   - 拿到 IP → 出现 iVentoy 菜单 → 5 秒后自动进入 Win11 ISO。
   - 菜单没自动走 → 菜单超时没设或设成了 0。
   - 出现"选自动安装脚本"界面停住 → 脚本选择超时时间还是 0。
3. 进入分区阶段应**无提示直接开始**。若弹出分区界面 → `unattend.xml` 没被识别，检查是否放对目录、是否设成默认脚本。
   - 若在分区阶段报 answer file 解析失败：优先怀疑 `$$VT_...$$` 没有被替换。iVentoy 只在**被当作自动安装脚本**处理的文件上做变量扩展，所以这通常意味着路径/默认脚本编号没配对，而不是变量语法写错了。注意 HTTP 直接下 `user/scripts/unattend.xml` 拿到的是**未展开**的原文，不能用来验证。
4. 装完应自动登录进桌面，**流程到此结束**（没有后置脚本，不会再自动重启）。
5. 验收清单：

| 检查项 | 命令 / 位置 |
|---|---|
| 分区是 GPT + EFI + MSR | 磁盘管理，或 `diskpart` → `list partition` |
| 系统语言/区域是中文 | 设置 → 时间和语言 |
| 装到了预期的盘 | 装机时按 `Shift+F10` → `diskpart` → `list disk` 核对容量与磁盘号 |
| Windows 版本正确 | `winver`，或 `dism /online /get-currentedition` |
| 内置 Administrator 已启用 | `net user Administrator`，看"帐户启用"是否为 Yes |
| Administrator 密码可登录 | 注销后用 `root123` 登录（或按下面那条重启验证） |
| 自动登录生效 | 重启一次，应无需输密码直接进桌面 |
| 中文注释没把 answer file 弄坏 | 装机过程中没有出现"无法分析或处理无人应答文件" |

> 计算机名会是 `DESKTOP-XXXXXXX` 这类随机名——这是当前方案的预期行为，不是故障，详见 5.3 节。

6. 单机跑通后，**再**逐步放开并发。注意免费版上限。

---

## 8. 步骤七：批量与授权

- **免费版最多 20 个客户端**：判定依据是 iVentoy 主界面 `设备列表` 里的设备数量，到达 20 后不再服务新客户端。绕过方式只有"关掉 iVentoy 重开 + 换一批 IP 池"。**商用被禁止**，批量生产环境要买专业版。
- **专业版 299 元**（大版本一次性，1.x 周期内有效）：客户端数量无限制、可商用。License 绑定**服务端母机**机器码（一个 License 最多 2 个机器码，绑定后不可解绑），客户机数量不受限。建议先用免费版把流程跑通再绑机器码。
- 并发时 iVentoy 是单台服务器同时供 ISO / HTTP / SMB，网卡和磁盘 IO 是瓶颈；建议装机的机器和 iVentoy 服务器之间走千兆以上、别跨 WAN。

---

## 9. 安全注意事项（务必看）

有一个凭据会**以明文经过网络**：

- `unattend.xml` 里的 Administrator 密码（当前是 `root123`）—— 明文写在文件里，且 iVentoy 的
  HTTP 服务把 `user/` 目录直接对外开放（`http://<IP>:16000/user/...`），同网段任何人 `curl` 就能拿到。

⚠️ **当前配置是本方案里安全性最差的一档**，三者叠加：内置 Administrator（攻击者第一个尝试的账户名）
+ 自动登录（无需任何人输入密码就进桌面）+ 弱密码 `root123`，而且这个仓库是**公开**的，
密码直接写在公网可见的文件里。**仅适合实验环境**。任何真实部署前至少要改密码，
并考虑关掉自动登录。

（之前 `deploy.ps1` 里的加域账号密码也是同样的暴露方式，该脚本已删除，所以这个风险点消失了。）

缓解措施：

- **装机期间隔离**：把 PXE 装机放在独立 VLAN / 临时交换机上进行，装完拔线。
- **给密码设有效期**：把它当成一次性口令，量产完成后统一改密。
- **别把真实密码提交进 git** —— 仓库是公开的，`unattend.xml` 是被跟踪文件，改完再 commit 就等于公开泄露。
  真实凭据要么最后一步才填、要么用 `.gitignore` 里预留的本地覆盖文件。
- iVentoy 管理界面 26000 端口不要暴露到非装机网段。
- 未来如果要加回自动加域，更彻底的做法是**离线加域**（`djoin` 生成 blob，用 unattend 的
  `Microsoft-Windows-UnattendedJoin` 走离线加域），完全不传凭据，代价是每台机器要先预生成 blob。

---

## 10. 排错速查表

| 现象 | 原因 / 处理 |
|---|---|
| 客户端卡在获取 IP，最后 `PXE-E51` | 第三方 DHCP 不响应 PXE → 改用 iVentoy 内置 DHCP；或交换机 DHCP Snooping 拦了 ProxyDHCP（端口设 trusted） |
| 拿到 IP 但 `PXE-E53 / No boot filename` | DHCP 响应了 PXE 但没给 bootfile → 切到 `ProxyNet`（或 `External` 并配 066/067） |
| 客户端直接挂死 | 送错了架构的启动文件 → 用 `ProxyNet`/`External` 让 iVentoy 自己判断；`ExternalNet` 下检查 bootfile 的 `_bios`/`_uefi` 后缀 |
| 启动菜单停住不自动走 | 菜单默认超时时间 = 0 |
| 停在"选择自动安装脚本" | 脚本选择超时时间 = 0 |
| 分区界面弹出来了 | `unattend.xml` 没生效：路径/默认脚本编号/是否放在 `user/scripts` |
| **停在「产品密钥」页** | `UserData` 里缺 `ProductKey`。`/IMAGE/NAME` 只负责在 WIM 里挑映像，**跳不过密钥页**。本仓库已加入微软公开的 KMS 客户端通用密钥来选版本（见 5.1 节） |
| 开机先出现「语言/键盘」选择页 | 说明 `unattend.xml` **完全没被读到**。此时改 answer file 内容没用，先查：文件是否复制到 `user\scripts\`、是否设为默认自动脚本、脚本选择超时是否为 0 |
| **报"无法分析或处理无人参与应答文件"** | **编码问题**：`unattend.xml` 丢了 UTF-8 BOM（多见于用编辑器另存为 ANSI/GBK，或用了不保留 BOM 的工具）。用 VS Code 确认右下角是 `UTF-8 with BOM` |
| 报"缺少计算机所需的介质驱动程序" | **网卡驱动**问题（Hyper-V 测不出来，只有真机会遇到）→ 见第 6 节补救：`Shift+F10` + `ipconfig /all` 确认 |
| 装到一半卡住、报无法应用映像 | 分区布局与固件不匹配（UEFI 用了 MBR 布局），或 `INSTALL/NAME` 版本名写错 |
| 装到错误的盘 / 擦错盘 | 别写死 `DiskID=0`；`_CLOSEST_`/`_MAX_SIZE` **不排除 USB 盘**，装机拔掉所有可移动存储；首次测试物理拔掉数据盘 |
| 装完发现所有机器同名 | 不会发生：当前不设 `<ComputerName>`，Windows 会生成随机名。如果哪天你手动设了固定名，就会撞名 |
| **装完停在锁屏，自动登录没生效** | 九成是 `AutoLogon` 与 `AdministratorPassword` 两处密码**不一致**（改密码时只改了一处）。这两处必须完全相同 |
| OOBE 没走完 / 卡在 OOBE 或直接报错 | 检查是否有人额外加了 `net user Administrator /active:yes` 之类的显式启用步骤——微软文档说明这可能导致设备无法正常进入 OOBE。启用账户应当只靠 `AutoLogon` 的 `Username=Administrator` |
| 报密码不符合密码策略 | `root123` 只有 7 位、仅小写字母+数字（2 类字符）。单机默认策略不要求复杂度，所以正常能过；但若环境里下发了复杂度策略，Setup 会在这里失败。届时改成大小写+数字+符号的组合 |
| UEFI 启动 Windows 花屏 | 1.0.25 已修，用最新版；菜单里也可设分辨率 |
| 安全启动过不去 | 见第 4 节三种模式；个别机型要先使能 BIOS 的 UEFI CA |
| 改动不生效 | iVentoy 修改配置后需重新"刷新镜像列表"；改了 `unattend.xml` 后确认没有旧副本残留 |

---

## 11. 参考（官方文档）

- [iVentoy 使用说明](https://www.iventoy.com/cn/doc_start.html)
- [操作系统全自动安装](https://www.iventoy.com/cn/doc_unattend_install.html)
- [自动安装脚本 / 变量扩展](https://www.iventoy.com/cn/doc_autoinstall.html)
- [配合第三方 DHCP Server](https://www.iventoy.com/cn/doc_ext_dhcp.html) ｜ [确认外部 DHCP 支持 PXE](https://www.iventoy.com/cn/doc_ext_dhcp_resp.html)
- [HTTP 路径说明](https://www.iventoy.com/cn/doc_http_url.html)
- [文件注入](https://www.iventoy.com/cn/doc_injection.html) ｜ [VentoyAutoRun.bat](https://www.iventoy.com/cn/doc_inject_autorun.html)
- [启动 Windows 时缺少驱动错误](https://www.iventoy.com/cn/doc_win_driver.html)
- [安全启动支持说明](https://www.iventoy.com/cn/sboot.html)
- [Windows 11 ByPass 说明](https://www.iventoy.com/cn/doc_win11_bypass.html)
- [关于 WinPE](https://www.iventoy.com/cn/doc_winpe.html) ｜ [版本说明（免费/专业）](https://www.iventoy.com/cn/doc_edition.html)
