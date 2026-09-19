# user\deploy\ —— 首次登录时下发给客户机的文件

这个目录下的文件由 iVentoy 内置的 HTTP 服务对外提供：

```
http://<iVentoy 服务器 IP>:16000/user/deploy/<路径>
```

## 目录要求

```
<iVentoy 解压目录>\user\deploy\
├── install-drivers.cmd      ← 本仓库提供，原样复制（客户端脚本）
├── tool_files.txt           ← 本仓库提供，原样复制（文件清单）
└── tool\                    ← 整个工具文件夹
    ├── DiskGenius.exe
    ├── OpenArk64.exe
    ├── xGate_202606251807.exe
    ├── wiztree_4_33_portable\
    └── Drvceo_Win10_Win11_x64_Lite\
```

客户端会把这整棵树还原到 **`C:\tool\`**，然后执行：

```
C:\tool\Drvceo_Win10_Win11_x64_Lite\start.bat
```

## `start.bat` 的内容与注意事项

当前内容是：

```bat
.\DrvCeo.exe /a
```

- `/a` 是**官方参数**：自动检测并安装驱动。官方文档在包内 `Res\Cmdline\zh_cn.txt`。
- 它用的是**相对路径** `.\DrvCeo.exe`，所以**工作目录必须是它所在的文件夹**，
  否则找不到程序。客户端脚本用 `start /D "<目录>" cmd /c start.bat` 保证了这一点。
  **你自己手动跑的时候也要先 `cd` 进那个目录。**
- 想连界面都不出现（真静默），在 `Drvceo.ini` 的 `[DrvCeoSet]` 节加 `Silence=on`。
  注意 `Drvceo.ini` 官方要求 **ANSI 编码**。

## 清单里只允许 ASCII 路径

**cmd.exe 按系统 OEM 代码页解析清单**，路径里一旦有中文或空格，客户端会生成
**乱码文件名**，或者干脆下载失败。所以清单里只保留匹配 `^[A-Za-z0-9._/\-]+$` 的路径。

> 注意：iVentoy 的 HTTP 服务**本身是支持中文路径的**（实测 `%E5%B9%B3...` 这类
> 百分号编码返回 206）。所以障碍不在服务端，而在**客户端的 cmd**——要让它创建中文
> 文件名，清单就得存成 GBK 编码，等于把"编码问题"从消除变成管理。
> 上一次因为编码问题（`%date%` + 中文注释）已经翻过车，所以这里选择**统一改成 ASCII 名字**。

**当前 `tool` 里所有文件都已是 ASCII，清单共 114 项。** 之前有两个文件不符合，已改名：

| 原名 | 新名 |
|---|---|
| `QI-ANXING Tianqing(10.7.0.2704平衡防御版).exe` | `QiAnXing-Tianqing-10.7.0.2704.exe` |
| `wiztree_4_33_portable\locale\How to Translate WizTree.txt` | `wiztree_4_33_portable\locale\How_to_Translate_WizTree.txt` |

**以后再往里放东西时，文件名请直接用 ASCII**（字母、数字、`.`、`_`、`-`），
否则它不会进清单，也就不会被传到客户机上。

## 什么时候必须重新生成清单

清单描述的是 `tool` 文件夹**当前**的内容。**只要增删了任何文件（包括新增 `start.bat`），
就必须重新生成**，否则客户端会漏文件——日志里会打印 `MISSING or EMPTY: ...`。

在 **`<iVentoy>\user\deploy\tool`** 目录下执行：

```powershell
$root = (Get-Location).Path
Get-ChildItem -Recurse -File |
  ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\','/') } |
  Where-Object   { $_ -match '^[A-Za-z0-9._/\-]+$' } |
  Sort-Object    | Set-Content -Encoding ASCII ..\tool_files.txt
```

生成结果必须是 **ASCII + CRLF**。

> 别用 `Compress-Archive` 之类的思路去打包再传——iVentoy 的 HTTP 是静态文件服务，
> 只能按文件取，不能取目录，也没有目录列表。所以这里用「清单 + 逐文件下载」。

## 目标与体积

| 项 | 值 |
|---|---|
| 清单当前内容 | 114 个文件，约 999 MB |
| 客户端目标目录 | `C:\tool\` |
| 未包含 | 无，114 个文件全部包含 |

这些全部在**局域网**内传输。首次登录时这段下载发生在**桌面出现之前**，
所以机器会在"正在准备桌面"停一会儿，属正常现象。

## 排查

客户机上：

```
C:\Windows\Temp\install-drivers.log      ← 脚本日志，逐文件结果都在里面
C:\Windows\Temp\install-drivers.cmd      ← 脚本本体，可手动重跑
C:\Windows\Temp\tool_files.txt           ← 实际用到的清单
C:\tool\                                 ← 还原出来的工具文件夹
```

手动重跑（注意要先 `cd` 进 DrvCeo 目录再跑 start.bat）：

```cmd
C:\Windows\Temp\install-drivers.cmd ^
  http://192.168.10.226:16000/user/deploy/tool_files.txt ^
  http://192.168.10.226:16000/user/deploy/tool

cd /d C:\tool\Drvceo_Win10_Win11_x64_Lite
start.bat
```

> ⚠️ 在 WSL 里验证时**不要用 `127.0.0.1`**——WSL 的 `127.0.0.1` 是 WSL 自己，不是 Windows。
> 用 Windows 主机地址，或者直接在 Windows 上用浏览器打开。
