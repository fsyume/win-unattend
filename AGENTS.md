# AGENTS.md — 在本仓库工作前先读这个

## 这是什么仓库

iVentoy 无人值守部署 Windows 11 的**文档 + 配置仓库**：没有代码、没有构建、没有测试、没有 CI。
产物是三个要投放进 iVentoy 解压目录的文件，加上两份说明文档。

| 文件 | 作用 | 投放位置 |
|---|---|---|
| `unattend.xml` | answer file（自动装机） | `<iVentoy>\user\scripts\` |
| `user/deploy/install-drivers.cmd` | 首次登录时在客户机跑的批处理 | `<iVentoy>\user\deploy\` |
| `user/deploy/tool_files.txt` | 工具目录清单（114 项） | `<iVentoy>\user\deploy\` |
| `README.md` | 实施手册（主文档） | — |
| `user/deploy/README.md` | deploy 目录说明 | — |

`tool\` 目录、Windows ISO、驱动包等二进制由 `.gitignore` 排除，**不在仓库里**。这决定了
"哪些事能在本地验证"——见下文。

## 硬性编码规则（违反任何一条都会静默失败）

| 文件 | 必须 | 为什么 |
|---|---|---|
| `unattend.xml` | **UTF-8 with BOM** | 丢 BOM → Setup 报"无法分析或处理无人参与应答文件" |
| `install-drivers.cmd` | **纯 ASCII** | cmd.exe 按 OEM 代码页解析 bat，非 ASCII 注释会让它解析 `goto`/`call` 时错位，输出也乱码。**中文写进 README，不要写进脚本注释** |
| `tool_files.txt` | **ASCII + CRLF**，每行匹配 `^[A-Za-z0-9._/-]+$` | 客户端 cmd 按 OEM 代码页读清单，中文/空格会变成乱码文件名 |
| `*.md` | UTF-8（无 BOM） | — |

命名一律 **ASCII、无空格**：iVentoy 解压路径、`iso` 目录名与 ISO 文件名、脚本名、`tool\` 里所有文件名。
（`Drvceo.ini` 官方要求 **ANSI** —— 不在本仓库，但改它时别忘了。）

## 改一处就要同步改多处

同一批事实在 `README.md`、`user/deploy/README.md`、`unattend.xml` 的注释里重复出现
（文件数、体积、字节数、路径、方案说明）。**改完必须 grep 确认没有漏改**——
本项目已经因此留下过「112 行 / 599 MB」与「114 项 / 999 MB」自相矛盾的旧数字。

改 `unattend.xml` 时额外注意三点：

1. iVentoy **把自动安装脚本缓存在内存里，只在服务启动时读一次**。改完必须重启 iVentoy，
   否则客户端拿到的还是旧内容，而且**不报错**。
2. **字节数变了要跟着更新文档**：客户端回传日志里的 `len:` 是校验"客户端拿到哪一版"的唯一手段，
   README 里记着当前值（`25589`）。改动后要同步更新，并提醒用户装机时重新确认。
3. 改动等于**作废上一轮装机验证**。README 明确写着脚本处于"实测通过"状态，
   所以除非有功能理由，不要为了措辞或纯显示问题去动它——
   `%time%` 那个日志时间戳问题是**故意不修**的（见 README「遗留问题」）。

## 不要做这些（有文档依据或已踩过坑）

- 不要加 `net user Administrator /active:yes` 或任何显式启用内置 Administrator 的步骤——
  微软文档警告会导致设备无法正常进入 OOBE。启用靠 `AutoLogon` 的 `Username=Administrator`。
- 不要用 `/IMAGE/INDEX` 选映像——多版本 ISO 上索引 1 是**家庭版**，写错会**静默装错**。用 `/IMAGE/NAME`。
- 不要往 `ProductKey` 填真实 MAK / 零售密钥（当前是公开的 KMS 通用密钥，只选版本不激活）。
- 不要删 `AcceptEula`、`ProductKey`。
- 不要把 `DiskID` 写死成 `0`；`_CLOSEST_` / `_MAX_SIZE` 变量**不排除 USB 盘**。
- 不要往 `tool\` 或清单里引入中文/空格文件名——要支持就得把清单存成 GBK，
  等于把编码问题从"消除"变成"管理"。
- 不要用服务端 `log\log.txt` 判断客户端是否请求过文件（它**只记 404**，成功的下载一条不记）。
- 不要提交二进制或真实凭据；`.gitignore` 已排除，别用 `-f` 绕过。
- `root123` 是**故意保留**的实验密码（用户已明确表示无所谓）。不要"顺手"改掉它，也不必为它提安全修复。
- `deploy.ps1` / `VentoyAutoRun.bat` 在 `git 948160a` 里，是**故意**从当前范围移除的。不要自行恢复。

## 能验证什么、不能验证什么

没有 CI。能在 shell 里自动查的只有格式类问题，改完请跑一遍：

```sh
cd ~/dsh/dsh-iventoy

# 编码与行尾
file unattend.xml user/deploy/tool_files.txt user/deploy/install-drivers.cmd

# BOM 必须是 efbbbf
head -c 3 unattend.xml | xxd

# 脚本必须无任何非 ASCII 字节（无输出 = 通过）
LC_ALL=C grep -n $'[\x80-\xff]' user/deploy/install-drivers.cmd

# 清单每行必须是纯 ASCII 路径（CR 必须先去掉，否则每行都会误报）
tr -d '\r' < user/deploy/tool_files.txt | LC_ALL=C grep -nv '^[A-Za-z0-9._/-]*$'

# 与文档记录的数值比对
wc -c unattend.xml                  # 应为 25589（改了就要同步改 README）
grep -c "" user/deploy/tool_files.txt   # 应为 114
```

**做不到的**：`tool\` 和 ISO 不在仓库里，所以"清单与真实文件是否一一对应"、"装机流程是否还跑得通"
**都无法在本地验证**，只能真机/虚拟机跑一轮（README「单机验收」一节）。
需要这类结论时，明确告诉用户"这需要一次装机验证"，**不要凭推断声称已验证**。

## 提交风格

看 `git log`：**标题是英文祈使句，正文用段落解释"为什么"以及这次改动推翻了什么**；
不用 `fix:` / `feat:` 前缀，也不用 bullet 堆砌。文档是中文、提交信息是英文，保持这个分工。
提交前 `git status` 应为空，且没有夹带二进制。

推送：本环境**没有任何 GitHub 凭据**（无 credential helper、无 `gh`、无 `~/.ssh`），
`git push` 必然失败。不要反复重试，把待推送的提交列给用户，让他自己推。

## 遗留问题（别擅自"修复"，先问）

README「遗留问题」一节记着三件事：`Windows.old` 成因未查清、日志时间戳不精确（故意不修）、
旧数字未回改。它们都是**已知且被接受**的状态，动手前先和用户确认。
