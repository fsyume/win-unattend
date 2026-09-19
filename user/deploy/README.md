# user\deploy\ —— 首次登录时下发给客户机的文件

这个目录下的文件由 iVentoy 内置的 HTTP 服务对外提供：

```
http://<iVentoy 服务器 IP>:16000/user/deploy/<路径>
```

## 目录要求

```
<iVentoy 解压目录>\user\deploy\
├── install-drivers.cmd          ← 本仓库提供，原样复制
├── drvceo_files.txt             ← 本仓库提供，原样复制（驱动包的文件清单）
└── tool\
    └── Drvceo_Win10_Win11_x64_Lite\   ← 驱动总裁整包（下面说怎么来）
```

## 驱动总裁整包

`unattend.xml` 里写死的两个地址是：

```
http://$$VT_SERVER_IP$$:$$VT_HTTP_PORT$$/user/deploy/drvceo_files.txt
http://$$VT_SERVER_IP$$:$$VT_HTTP_PORT$$/user/deploy/tool/Drvceo_Win10_Win11_x64_Lite
```

所以要保证：

| 要求 | 说明 |
|---|---|
| 目录名必须是 `Drvceo_Win10_Win11_x64_Lite` | 想改名就同步改 `unattend.xml` 里那处 URL |
| **包内路径不能有中文或空格** | iVentoy 的硬性要求，也会让 URL 拼接出错 |
| `DrvCeo.exe` 必须在包根目录 | 脚本最后启动的就是它 |

### 为什么是「逐文件下载」而不是下载一个压缩包

**iVentoy 的 HTTP 是静态文件服务，只能按文件取，不能取目录，也没有目录列表。**
所以清单 `drvceo_files.txt` 在服务器侧预先列好，客户端脚本按清单一个个拉回来，
并保持原来的目录结构，最终还原到客户机的 `C:\DrvCeo\`。

### 清单怎么来的 / 什么时候要重新生成

清单是**从这个目录的实际内容生成的**，所以只要你增删了这个包里的文件，就必须重新生成，
否则客户端会漏文件（日志里会打印 `MISSING or EMPTY: ...`）。

当前清单对应：**44 个文件、约 40.6 MB**（只有主程序和 `Res\`，不含离线驱动库）。

在 Windows PowerShell 里，进到 `Drvceo_Win10_Win11_x64_Lite` 目录后执行：

```powershell
Get-ChildItem -Recurse -File |
  ForEach-Object { $_.FullName.Substring((Get-Location).Path.Length + 1).Replace('\','/') } |
  Sort-Object | Set-Content -Encoding ASCII ..\..\drvceo_files.txt
```

生成的必须是 **ASCII / CRLF**；**路径里有中文或空格的文件不要放进来**。

## 关于离线驱动库

`Res\Config.ini` 里写的是 `type=Lite2`，这个包本来是**带离线驱动库**的版本，
正常情况下同目录还应有一个 `Win10x64\`（3.8 G 左右，装显卡/声卡/网卡等驱动）。

**如果那个目录被删掉了**，驱动总裁就退化成联网模式，靠 `drvceoup.sysceo.cn`
去下载驱动——所以客户机必须能上公网。当前部署环境满足这一条，所以没问题。

## 静默与参数：看官方文档，不要凭猜

官方说明就在包内，ANSI 编码：

```
tool\Drvceo_Win10_Win11_x64_Lite\Res\Cmdline\zh_cn.txt
```

命令行参数：

| 参数 | 作用 |
|---|---|
| `-a` | 自动检测并安装驱动（**部署环境无需加参数将自动安装**） |
| `-d` | 部署环境删除驱动总裁本身及离线驱动包 |
| `-i` | 自定义安装指定驱动 |
| `-stopbs` | 过滤显卡、USB3.X、磁盘控制器驱动 |
| `-noauto` | 部署环境不自动安装驱动 |
| `-PeLoad` | PE 环境下静默加载驱动到目标系统 |

`Drvceo.ini` 的 `[DrvCeoSet]` 节：

```ini
Silence=on           ; 全静默自动安装驱动，隐藏软件窗体（无人值守的关键开关）
Time=30              ; 自动安装倒计时秒数，默认 15
DesktopRestart=on    ; 桌面环境装完自动重启
Dupdrv=off           ; 关闭"部署后首次进桌面触发联网更新驱动"
ToolUpdate=off       ; 不检测程序更新
ShowMsgBox=off       ; 不弹提示框
Desktoplnk=off       ; 不创建桌面快捷方式
DiskdrvInstall=on    ; 默认安装磁盘控制器驱动
```

注意 `Drvceo.ini` 必须是 **ANSI 编码**（官方要求），别存成 UTF-8。

**当前 `unattend.xml` 的做法是【不加任何参数】**，保留图形界面由现场人员确认。
想改成全自动，就在 `Drvceo.ini` 里加 `Silence=on`（比给脚本加 `-a` 更彻底）。

## 排查

客户机上：

```
C:\Windows\Temp\install-drivers.log      ← 脚本日志，逐文件下载结果都在里面
C:\Windows\Temp\install-drivers.cmd      ← 脚本本体，可手动重跑
C:\Windows\Temp\drvceo_files.txt         ← 实际用到的清单
C:\DrvCeo\                               ← 还原出来的驱动总裁
```

手动重跑（把两个地址换成实际服务器 IP）：

```cmd
C:\Windows\Temp\install-drivers.cmd ^
  http://192.168.10.226:16000/user/deploy/drvceo_files.txt ^
  http://192.168.10.226:16000/user/deploy/tool/Drvceo_Win10_Win11_x64_Lite
```

> ⚠️ 在 WSL 里验证时**不要用 `127.0.0.1`**——WSL 的 `127.0.0.1` 是 WSL 自己，
> 不是 Windows。要么用 Windows 主机地址，要么直接在 Windows 上用浏览器打开。
