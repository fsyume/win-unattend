<#
    ============================================================================
    iVentoy Windows 11 无人值守部署：首次登录后置脚本
    ============================================================================
    由 unattend.xml 里的 FirstLogonCommands 钩子在首次登录时启动。
    之所以通过 HTTP 从 iVentoy 服务器拉取：answer file 装不下负载，
    而 iVentoy 也不会往装好的系统里注入文件。

    【编码要求】本文件含中文注释，必须保存为 UTF-8 with BOM。
    Windows PowerShell 5.1 只有在检测到 BOM 时才按 UTF-8 解析，
    否则中文会乱码（注释乱码通常无害，但不要依赖这一点）。

    部署位置：<iVentoy 解压目录>\user\deploy\deploy.ps1
    访问地址：http://<iVentoy 服务器 IP>:16000/user/deploy/deploy.ps1

    执行顺序：
        1. 防重入检查
        2. 等待 iVentoy 服务器可连通
        3. 写完成标记，便于管理员事后查看
        4. 安装驱动包
        5. 安装软件（winget + 本地静默安装包）
        6. 改名与加域一步完成
        7. 可选：关闭自动登录这个后门
        8. 重启

    全部日志写入 C:\Windows\Temp\deploy.log
    ============================================================================
#>
[CmdletBinding()]
param(
    # 客户端 PXE 网卡 MAC，由 iVentoy 展开 $$VT_MAC_DASH_UPPER$$ 传入（11-22-33-AA-BB-CC）
    [string]$PxeMac = '',
    # iVentoy 服务器 IP，由 $$VT_SERVER_IP$$ 展开
    [string]$ServerIp = '',
    # iVentoy HTTP 端口，由 $$VT_HTTP_PORT$$ 展开
    [string]$ServerPort = '16000'
)

#region ----------------------------- 配置区 ---------------------------------
# 管理员通常需要改的东西都在这个块里。
$Cfg = @{

    # ---------- 计算机命名 ----------
    NamePrefix   = 'PC-'      # Windows 计算机名最长 15 字符，前缀别太长
    NameSource   = 'Serial'   # 'Serial' 用 BIOS 序列号，'Mac' 用 PXE 网卡 MAC
    SerialTail   = 10         # 清洗后取序列号的最后 N 位
    FallbackToMac = $true     # 序列号缺失或是垃圾值时，回退用 MAC

    # ---------- 加域 ----------
    JoinDomain         = $true
    DomainName         = 'corp.example.com'
    # 用专用账号，只在目标 OU 上委派"将计算机加入域"这一项权限。
    # 千万不要用 Domain Admin：本文件通过明文 HTTP 提供，
    # 装机 VLAN 上任何人都能读到。
    DomainJoinUser     = 'svc-joindeploy@corp.example.com'
    DomainJoinPassword = 'CHANGE-ME'
    TargetOU           = 'OU=Workstations,OU=Computers,DC=corp,DC=example,DC=com'

    # ---------- 驱动 ----------
    # 一个压缩包，里面是普通的 .inf 驱动目录树。
    # 放在 <iVentoy>\user\deploy\ 下；留空则跳过驱动安装。
    DriverZipName = 'drivers.zip'

    # ---------- 软件：winget ----------
    WingetIds = @(
        # 'Microsoft.PowerToys'
        # 'Mozilla.Firefox'
        # '7zip.7zip'
    )

    # ---------- 软件：本地静默安装包 ----------
    # 文件放在 <iVentoy>\user\deploy\ 下
    LocalInstallers = @(
        # @{ File = '7z2408-x64.exe'; Args = '/S' }
        # @{ File = 'vcredist_x64.exe'; Args = '/install /quiet /norestart' }
    )

    # ---------- 收尾 ----------
    # $false = 按你的要求保留自动登录。
    # $true = 生产环境更安全的做法：机器加域后，关掉自动登录并清除
    #         注册表里明文存储的本地管理员密码。
    DisableAutoLogon = $false
    RebootAtEnd      = $true
}

$LogFile = 'C:\Windows\Temp\deploy.log'
$RegRoot = 'HKLM:\SOFTWARE\ITDeploy'
#endregion ----------------------------------------------------------------

#region ----------------------------- 辅助函数 ------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
    try { Add-Content -LiteralPath $LogFile -Value $line -ErrorAction SilentlyContinue } catch { }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-TcpPort {
    param([string]$ComputerName, [int]$Port, [int]$TimeoutMs = 3000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne($TimeoutMs)) {
            $client.EndConnect($async)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Save-Url {
    param([string]$Url, [string]$Dest, [int]$Retries = 3)
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Write-Log "download ($i/$Retries) $Url -> $Dest"
            Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -TimeoutSec 300
            return $true
        } catch {
            Write-Log "download failed: $($_.Exception.Message)" 'WARN'
            Start-Sleep -Seconds 10
        }
    }
    return $false
}

function Get-TargetName {
    param([string]$Source, [string]$Mac, [string]$Prefix, [int]$SerialTail, [bool]$FallbackToMac)

    $suffix = ''

    if ($Source -eq 'Serial') {
        try {
            $serial = (Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop).SerialNumber
        } catch {
            $serial = ''
        }
        if ($serial) {
            $clean = ($serial -replace '[^0-9A-Za-z]', '').ToUpper()
            # 通用 OEM 固件不填真实序列号时给出的垃圾值
            $junk = @('', 'TOBEFILLEDBYOEM', 'SYSTEMSERIALNUMBER', 'NONE', 'NOTSPECIFIED',
                      'DEFAULTSTRING', '0', '0123456789', 'INVALID')
            if ($clean -and ($junk -notcontains $clean) -and $clean.Length -ge 4) {
                if ($clean.Length -gt $SerialTail) {
                    $clean = $clean.Substring($clean.Length - $SerialTail)
                }
                $suffix = $clean
            } else {
                Write-Log "serial '$serial' is unusable, falling back to MAC" 'WARN'
            }
        }
    }

    if (-not $suffix -and $FallbackToMac -and $Mac) {
        $suffix = ($Mac -replace '[^0-9A-Fa-f]', '').ToUpper()
    }
    if (-not $suffix) {
        $suffix = (Get-Random -Minimum 100000 -Maximum 999999).ToString()
        Write-Log 'no serial and no MAC available, using a random suffix' 'WARN'
    }

    $name = $Prefix + $suffix
    if ($name.Length -gt 15) { $name = $name.Substring(0, 15) }
    $name = $name.TrimEnd('-')
    return $name
}
#endregion ----------------------------------------------------------------

#region ------------------------------ 主流程 ---------------------------------
Write-Log '================ deploy.ps1 start ================'
Write-Log ("PxeMac=$PxeMac ServerIp=$ServerIp ServerPort=$ServerPort")

if (-not (Test-IsAdmin)) {
    Write-Log 'NOT running elevated. Driver install, rename and domain join will fail.' 'ERROR'
    Write-Log 'If this happens in testing, move the hook to a specialize-pass RunSynchronous command.' 'ERROR'
    return
}

# 防重入：后续的自动登录可能再次触发 FirstLogonCommands
if (Get-ItemProperty -Path $RegRoot -Name Done -ErrorAction SilentlyContinue) {
    Write-Log 'Marker found, this machine was already deployed. Nothing to do.'
    return
}

if (-not $ServerIp) {
    Write-Log 'ServerIp was not passed in, cannot resolve the iVentoy base URL' 'ERROR'
    return
}
$BaseUrl = 'http://{0}:{1}' -f $ServerIp, $ServerPort

try { Start-Transcript -Path 'C:\Windows\Temp\deploy-transcript.log' -Force | Out-Null } catch { }

# --- 1. 等待部署服务器可连通 -----------------------------------------------
if (-not (Test-TcpPort -ComputerName $ServerIp -Port ([int]$ServerPort))) {
    Write-Log "waiting up to 5 minutes for $ServerIp`:$ServerPort ..."
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort -ComputerName $ServerIp -Port ([int]$ServerPort)) { break }
        Start-Sleep -Seconds 10
    }
}
$serverUp = Test-TcpPort -ComputerName $ServerIp -Port ([int]$ServerPort)
if ($serverUp) { Write-Log "iVentoy server $ServerIp`:$ServerPort is reachable" }
else { Write-Log 'iVentoy server is NOT reachable, continuing with local-only steps' 'WARN' }

# --- 2. 驱动 ---------------------------------------------------------------
if ($Cfg.DriverZipName -and $serverUp) {
    $zip = Join-Path 'C:\Windows\Temp' $Cfg.DriverZipName
    $url = '{0}/user/deploy/{1}' -f $BaseUrl, $Cfg.DriverZipName
    if (Save-Url -Url $url -Dest $zip) {
        $dir = 'C:\Windows\Temp\drivers'
        try {
            if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
            Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
            $infCount = @(Get-ChildItem -Path $dir -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue).Count
            Write-Log "driver pack expanded, $infCount .inf files found"
            if ($infCount -gt 0) {
                $out = & pnputil.exe /add-driver "$dir\*.inf" /subdirs /install 2>&1
                Write-Log ("pnputil: " + ($out -join ' | '))
            }
        } catch {
            Write-Log "driver install failed: $($_.Exception.Message)" 'ERROR'
        }
    } else {
        Write-Log 'could not fetch the driver pack' 'WARN'
    }
} elseif ($Cfg.DriverZipName) {
    Write-Log 'skipping drivers: server unreachable' 'WARN'
}

# --- 3. 软件：winget -------------------------------------------------------
if ($Cfg.WingetIds.Count -gt 0) {
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        foreach ($id in $Cfg.WingetIds) {
            Write-Log "winget install $id"
            try {
                $out = & winget.exe install --id $id --silent --exact `
                    --accept-package-agreements --accept-source-agreements `
                    --disable-interactivity 2>&1
                Write-Log ("winget: " + ($out -join ' | '))
            } catch {
                Write-Log "winget failed for $id : $($_.Exception.Message)" 'ERROR'
            }
        }
    } else {
        Write-Log 'winget.exe not found (LTSC / Enterprise N images often lack it)' 'WARN'
    }
}

# --- 4. 软件：本地静默安装包 -----------------------------------------------
foreach ($pkg in $Cfg.LocalInstallers) {
    if (-not $serverUp) { Write-Log "skipping $($pkg.File): server unreachable" 'WARN'; continue }
    $dest = Join-Path 'C:\Windows\Temp' $pkg.File
    $url = '{0}/user/deploy/{1}' -f $BaseUrl, $pkg.File
    if (Save-Url -Url $url -Dest $dest) {
        Write-Log "installing $($pkg.File) $($pkg.Args)"
        try {
            $p = Start-Process -FilePath $dest -ArgumentList $pkg.Args -Wait -PassThru
            Write-Log "$($pkg.File) exit code $($p.ExitCode)"
        } catch {
            Write-Log "install failed for $($pkg.File): $($_.Exception.Message)" 'ERROR'
        }
    }
}

# --- 5. 改名 + 加域 --------------------------------------------------------
$cs = Get-CimInstance -ClassName Win32_ComputerSystem
$targetName = Get-TargetName -Source $Cfg.NameSource -Mac $PxeMac `
    -Prefix $Cfg.NamePrefix -SerialTail $Cfg.SerialTail -FallbackToMac $Cfg.FallbackToMac
Write-Log "target computer name: $targetName (current: $($cs.Name))"

if ($Cfg.JoinDomain) {
    if ($cs.PartOfDomain -and $cs.Domain -ieq $Cfg.DomainName) {
        Write-Log "already joined to $($Cfg.DomainName), renaming only"
        try {
            Rename-Computer -NewName $targetName -Force -ErrorAction Stop
            Write-Log 'rename requested'
        } catch {
            Write-Log "rename failed: $($_.Exception.Message)" 'ERROR'
        }
    } else {
        try {
            $sec  = ConvertTo-SecureString $Cfg.DomainJoinPassword -AsPlainText -Force
            $cred = New-Object System.Management.Automation.PSCredential($Cfg.DomainJoinUser, $sec)
            $p = @{
                DomainName = $Cfg.DomainName
                Credential = $cred
                NewName    = $targetName      # 名字在加入域的这一刻生效
                Restart    = $false
                ErrorAction = 'Stop'
            }
            if ($Cfg.TargetOU) { $p['OUPath'] = $Cfg.TargetOU }
            Add-Computer @p
            Write-Log "joined $($Cfg.DomainName) as $targetName"
        } catch {
            Write-Log "domain join failed: $($_.Exception.Message)" 'ERROR'
            Write-Log 'Renaming locally instead so the machine is still identifiable.' 'WARN'
            try { Rename-Computer -NewName $targetName -Force -ErrorAction Stop } catch {
                Write-Log "fallback rename failed: $($_.Exception.Message)" 'ERROR'
            }
        }
    }
} else {
    try {
        Rename-Computer -NewName $targetName -Force -ErrorAction Stop
        Write-Log 'rename requested (domain join disabled)'
    } catch {
        Write-Log "rename failed: $($_.Exception.Message)" 'ERROR'
    }
}

# --- 6. 关掉自动登录这个后门 -----------------------------------------------
if ($Cfg.DisableAutoLogon) {
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    try {
        Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon' -Value '0' -Type String -ErrorAction Stop
        Remove-ItemProperty -Path $winlogon -Name 'DefaultPassword' -ErrorAction SilentlyContinue
        Write-Log 'auto-logon disabled and stored password removed'
    } catch {
        Write-Log "could not disable auto-logon: $($_.Exception.Message)" 'WARN'
    }
}

# --- 7. 写标记 + 重启 ------------------------------------------------------
try {
    New-Item -Path $RegRoot -Force | Out-Null
    Set-ItemProperty -Path $RegRoot -Name 'Done'      -Value 1            -Type DWord
    Set-ItemProperty -Path $RegRoot -Name 'HostName'  -Value $targetName  -Type String
    Set-ItemProperty -Path $RegRoot -Name 'Timestamp' -Value (Get-Date -Format 's') -Type String
    Write-Log 'completion marker written'
} catch {
    Write-Log "could not write marker: $($_.Exception.Message)" 'WARN'
}

try { Stop-Transcript | Out-Null } catch { }
Write-Log '================ deploy.ps1 end ================'

if ($Cfg.RebootAtEnd) {
    Write-Log 'rebooting in 60 seconds'
    & shutdown.exe /r /t 60 /c "iVentoy deployment finished, restarting" /f
}
#endregion ----------------------------------------------------------------
