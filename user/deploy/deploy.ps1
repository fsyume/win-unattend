<#
    ============================================================================
    iVentoy Windows 11 unattended deployment - post-install script
    ============================================================================
    Runs at first logon, started by the FirstLogonCommands hook in
    unattend.xml. It is downloaded over HTTP from the iVentoy server, because
    an answer file cannot carry a payload and iVentoy does not inject files
    into the installed OS.

    Deploy to:  <iVentoy>\user\deploy\deploy.ps1
    Served as:  http://<iVentoy-IP>:16000/user/deploy/deploy.ps1

    Ordered as:
        1. guard against re-run
        2. wait until the iVentoy server answers
        3. drop a marker so an admin can see what happened
        4. install driver pack
        5. install software (winget + local silent installers)
        6. rename + join domain in one operation
        7. optionally close the auto-logon back door
        8. reboot

    Everything is logged to C:\Windows\Temp\deploy.log
    ============================================================================
#>
[CmdletBinding()]
param(
    # PXE NIC MAC, expanded from $$VT_MAC_DASH_UPPER$$ by iVentoy (11-22-33-AA-BB-CC)
    [string]$PxeMac = '',
    # iVentoy server IP, expanded from $$VT_SERVER_IP$$
    [string]$ServerIp = '',
    # iVentoy HTTP port, expanded from $$VT_HTTP_PORT$$
    [string]$ServerPort = '16000'
)

#region ----------------------------- CONFIG ---------------------------------
# Everything an admin normally needs to touch lives in this block.
$Cfg = @{

    # ---------- computer naming ----------
    NamePrefix   = 'PC-'      # Windows name limit is 15 chars, so keep it short
    NameSource   = 'Serial'   # 'Serial' = BIOS service tag, 'Mac' = PXE NIC MAC
    SerialTail   = 10         # keep the last N chars of the sanitised serial
    FallbackToMac = $true     # if the serial is missing or junk, use the MAC

    # ---------- domain join ----------
    JoinDomain         = $true
    DomainName         = 'corp.example.com'
    # Use a dedicated account that ONLY has "join computers to the domain"
    # delegated on the target OU. Never use a Domain Admin here: this file is
    # served over plain HTTP and readable by anyone on the deployment VLAN.
    DomainJoinUser     = 'svc-joindeploy@corp.example.com'
    DomainJoinPassword = 'CHANGE-ME'
    TargetOU           = 'OU=Workstations,OU=Computers,DC=corp,DC=example,DC=com'

    # ---------- drivers ----------
    # Zip that contains a plain folder tree of .inf drivers.
    # Placed in <iVentoy>\user\deploy\ ; leave empty to skip.
    DriverZipName = 'drivers.zip'

    # ---------- software: winget ----------
    WingetIds = @(
        # 'Microsoft.PowerToys'
        # 'Mozilla.Firefox'
        # '7zip.7zip'
    )

    # ---------- software: local silent installers ----------
    # Files placed in <iVentoy>\user\deploy\
    LocalInstallers = @(
        # @{ File = '7z2408-x64.exe'; Args = '/S' }
        # @{ File = 'vcredist_x64.exe'; Args = '/install /quiet /norestart' }
    )

    # ---------- finishing ----------
    # $false keeps the auto-logon enabled as requested.
    # $true is the safer production default: it removes the stored local admin
    # password from the registry once the machine is domain joined.
    DisableAutoLogon = $false
    RebootAtEnd      = $true
}

$LogFile = 'C:\Windows\Temp\deploy.log'
$RegRoot = 'HKLM:\SOFTWARE\ITDeploy'
#endregion ------------------------------------------------------------------

#region ----------------------------- HELPERS --------------------------------
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
            # Junk values that generic OEM firmware reports instead of a real tag
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
#endregion ------------------------------------------------------------------

#region ------------------------------ MAIN -----------------------------------
Write-Log '================ deploy.ps1 start ================'
Write-Log ("PxeMac=$PxeMac ServerIp=$ServerIp ServerPort=$ServerPort")

if (-not (Test-IsAdmin)) {
    Write-Log 'NOT running elevated. Driver install, rename and domain join will fail.' 'ERROR'
    Write-Log 'If this happens in testing, move the hook to a specialize-pass RunSynchronous command.' 'ERROR'
    return
}

# idempotence guard - FirstLogonCommands can fire again on a later auto-logon
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

# --- 1. wait for the deployment server -------------------------------------
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

# --- 2. drivers -------------------------------------------------------------
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

# --- 3. software: winget ----------------------------------------------------
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

# --- 4. software: local silent installers -----------------------------------
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

# --- 5. rename + join domain ------------------------------------------------
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
                NewName    = $targetName      # name is applied at join time
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

# --- 6. close the auto-logon back door --------------------------------------
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

# --- 7. marker + reboot -----------------------------------------------------
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
#endregion ------------------------------------------------------------------
