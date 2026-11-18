#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Installs Windows Exporter for CPU, memory, disk and network monitoring.
.EXAMPLE
.\install-windows-exporter.ps1 -PrometheusIP "172.16.17.10"
.NOTES
Run on the Windows VM being monitored, in elevated PowerShell.
Uses the official MSI and pinned SHA256. Does not modify Prometheus targets.
An existing exporter installation is left untouched.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({
        $address = $null
        if (-not [System.Net.IPAddress]::TryParse($_, [ref]$address)) {
            throw "Supply the new Prometheus VM's IPv4 or IPv6 address."
        }
        $true
    })]
    [string]$PrometheusIP,

    [ValidateRange(1, 65535)]
    [int]$Port = 9182
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Version = '0.32.1'
$Collectors = 'cpu,memory,logical_disk,net,os,system'
$WorkDir = $null
$LogPath = $null
$PreviousTls = [Net.ServicePointManager]::SecurityProtocol

try {
    if ($env:OS -ne 'Windows_NT') { throw 'This installer requires Windows.' }
    if (Get-Service -Name 'windows_exporter' -ErrorAction SilentlyContinue) {
        throw 'windows_exporter already exists. No changes made. Review or uninstall the existing installation before using this fresh-install script.'
    }
    if (Get-Service -Name 'wmi_exporter' -ErrorAction SilentlyContinue) {
        throw 'Legacy wmi_exporter exists. Review its migration before installing Windows Exporter.'
    }
    $NativeArch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $NativeArch = $env:PROCESSOR_ARCHITEW6432 }
    switch ($NativeArch.ToUpperInvariant()) {
        'AMD64' {
            $Arch = 'amd64'
            $ExpectedHash = '8e1ade6a2fbcdeb4774c300b598667cd7888246be8fcc4b586d11b3680433981'
        }
        'ARM64' {
            $Arch = 'arm64'
            $ExpectedHash = 'fb5fe27adee598d38015b7e5d619da75a805114c58af5946cdcc7151b5ff0e09'
        }
        default { throw "Unsupported Windows architecture: $NativeArch" }
    }
    if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) {
        throw "TCP port $Port is already in use."
    }

    Write-Host '[1/5] Downloading official Windows Exporter MSI'
    [Net.ServicePointManager]::SecurityProtocol = $PreviousTls -bor [Net.SecurityProtocolType]::Tls12
    $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ('windows-exporter-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $WorkDir | Out-Null
    $FileName = "windows_exporter-$Version-$Arch.msi"
    $MsiPath = Join-Path $WorkDir $FileName
    $Url = "https://github.com/prometheus-community/windows_exporter/releases/download/v$Version/$FileName"
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $MsiPath -TimeoutSec 300

    Write-Host '[2/5] Verifying pinned SHA256'
    $ActualHash = (Get-FileHash -LiteralPath $MsiPath -Algorithm SHA256).Hash
    if ($ActualHash -ne $ExpectedHash) { throw 'MSI checksum mismatch. Installation cancelled.' }

    Write-Host '[3/5] Installing service and source-scoped firewall exception'
    $LogPath = Join-Path $env:TEMP ('windows-exporter-install-' + [guid]::NewGuid().ToString('N') + '.log')
    $Arguments = @(
        '/i', ('"{0}"' -f $MsiPath), '/qn', '/norestart',
        '/L*v', ('"{0}"' -f $LogPath),
        "ENABLED_COLLECTORS=$Collectors",
        "LISTEN_PORT=$Port",
        "REMOTE_ADDR=$PrometheusIP",
        'ADDLOCAL=ALL'
    )
    $Process = Start-Process -FilePath 'msiexec.exe' -ArgumentList $Arguments -Wait -PassThru
    if ($Process.ExitCode -notin @(0, 3010)) {
        throw "MSI failed with exit code $($Process.ExitCode). See $LogPath"
    }
    if ($Process.ExitCode -eq 3010) { Write-Warning 'Windows reports that a reboot is required; this script will not reboot.' }

    Write-Host '[4/5] Starting service'
    Set-Service -Name 'windows_exporter' -StartupType Automatic
    Start-Service -Name 'windows_exporter'
    (Get-Service -Name 'windows_exporter').WaitForStatus(
        [System.ServiceProcess.ServiceControllerStatus]::Running,
        [TimeSpan]::FromSeconds(30)
    )

    Write-Host '[5/5] Verifying CPU, memory, disk and network metrics'
    $Verified = $false
    $LastIssue = ''
    for ($Attempt = 1; $Attempt -le 12; $Attempt++) {
        try {
            $Response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/metrics" -TimeoutSec 15
            $Metrics = [string]$Response.Content
            $Missing = @()
            foreach ($Prefix in @('windows_cpu_', 'windows_memory_', 'windows_logical_disk_', 'windows_net_')) {
                if ($Metrics -notmatch ('(?m)^' + [regex]::Escape($Prefix))) { $Missing += $Prefix }
            }
            if ($Response.StatusCode -eq 200 -and $Missing.Count -eq 0) {
                $Verified = $true
                break
            }
            $LastIssue = 'Missing metric families: ' + ($Missing -join ', ')
        }
        catch { $LastIssue = $_.Exception.Message }
        Start-Sleep -Seconds 2
    }
    if (-not $Verified) {
        throw "Installed, but metrics verification failed: $LastIssue. Inspect the windows_exporter service and Windows Event Viewer."
    }

    Write-Host ''
    Write-Host 'Windows Exporter installation complete.' -ForegroundColor Green
    Write-Host "Metrics: http://THIS_WINDOWS_VM_IP:$Port/metrics"
    Write-Host "On the monitoring VM, add THIS_WINDOWS_VM_IP:$Port to prometheus/targets/windows.json."
    Write-Host 'Prometheus file discovery reloads that target file automatically.'
    Write-Host "MSI log: $LogPath"
    Write-Host "The MSI firewall exception allows Prometheus IP $PrometheusIP."
    Write-Warning 'Existing broad firewall rules, disabled firewall profiles or domain policy can affect access. Verify reachability from the monitoring VM and restrict the host/cloud firewall accordingly.'
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    if ($LogPath) { Write-Host "Installer log (if created): $LogPath" }
    exit 1
}
finally {
    [Net.ServicePointManager]::SecurityProtocol = $PreviousTls
    if ($WorkDir -and (Test-Path -LiteralPath $WorkDir)) {
        Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
