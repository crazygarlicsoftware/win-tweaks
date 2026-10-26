#Requires -RunAsAdministrator
<#
  Removes optional Dell SupportAssist software from a Dell Latitude 5400.

  Deliberately preserved hardware support:
    - Dell PointStick driver
    - Dell Free Fall Data Protection
    - Waves/Realtek audio components
    - Intel storage and graphics components
#>

$ErrorActionPreference = 'SilentlyContinue'
$script:RebootRequired = $false
$script:CleanupFailed = $false

function Invoke-Uninstaller {
    param($Entry)

    $acceptableExitCodes = @(0, 1605, 1614, 3010)
    $displayName = $Entry.DisplayName
    $exitCode = $null

    # MSI entries sometimes advertise /I even though the same product code can
    # be removed with /X. Calling msiexec directly gives us a reliable exit code.
    if ($Entry.WindowsInstaller -eq 1 -or $Entry.UninstallString -match '(?i)msiexec(?:\.exe)?') {
        $productCode = $Entry.PSChildName
        if ($productCode -notmatch '^\{[0-9A-Fa-f-]{36}\}$' -and
            $Entry.UninstallString -match '\{[0-9A-Fa-f-]{36}\}') {
            $productCode = $Matches[0]
        }

        if ($productCode -match '^\{[0-9A-Fa-f-]{36}\}$') {
            Write-Host "  UNINSTALLING  $displayName ($productCode)"
            $process = Start-Process -FilePath 'msiexec.exe' `
                -ArgumentList @('/x', $productCode, '/qn', '/norestart') `
                -Wait -PassThru
            $exitCode = $process.ExitCode
        }
    }
    elseif ($Entry.QuietUninstallString) {
        $command = $Entry.QuietUninstallString.Trim()
        if ($command -match '^"([^"]+)"\s*(.*)$') {
            $executable = $Matches[1]
            $arguments = $Matches[2]
        }
        elseif ($command -match '^(\S+)\s*(.*)$') {
            $executable = $Matches[1]
            $arguments = $Matches[2]
        }

        if ($executable) {
            Write-Host "  UNINSTALLING  $displayName"
            $process = Start-Process -FilePath $executable `
                -ArgumentList $arguments -Wait -PassThru
            $exitCode = $process.ExitCode
        }
    }

    if ($null -eq $exitCode) {
        Write-Warning "No silent uninstaller was available for $displayName"
        return $false
    }

    if ($exitCode -notin $acceptableExitCodes) {
        Write-Warning "$displayName uninstall failed with exit code $exitCode"
        return $false
    }

    if ($exitCode -eq 3010) {
        Write-Host "  REMOVED  $displayName (reboot required)"
        $script:RebootRequired = $true
    }
    else {
        Write-Host "  REMOVED  $displayName"
    }

    return $true
}

Write-Host "`n=== Removing Optional Dell SupportAssist Software ===`n"

# These services belong to SupportAssist, not to Dell hardware drivers. Stop
# and disable them first so the uninstallers can remove their files cleanly.
$supportAssistServices = @('SupportAssistAgent', 'DellTechHub')
foreach ($serviceName in $supportAssistServices) {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($service) {
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        Set-Service -Name $serviceName -StartupType Disabled -ErrorAction SilentlyContinue
        Write-Host "  DISABLED  $($service.DisplayName)"
    }
}

# TechHub launches child processes that can survive after its Windows service
# stops and keep SupportAssist files locked. Match only this optional stack;
# do not touch DellFFDPWmiService or any other hardware-driver process.
Get-Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessName -like 'Dell.TechHub*' -or
        $_.ProcessName -like 'SupportAssist*'
    } |
    ForEach-Object {
        Write-Host "  STOPPING  $($_.ProcessName)"
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }

# Remove the Store app for existing users and its provisioned copy for future
# users. Absence is success, which keeps this script safe to run repeatedly.
$supportAssistPackages = Get-AppxPackage -AllUsers -Name 'DellInc.DellSupportAssistforPCs' `
    -ErrorAction SilentlyContinue
foreach ($package in $supportAssistPackages) {
    try {
        Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
        Write-Host "  REMOVED  $($package.Name) Store app"
    }
    catch {
        Write-Warning "Could not remove $($package.PackageFullName): $($_.Exception.Message)"
        $script:CleanupFailed = $true
    }
}

$provisionedPackages = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -eq 'DellInc.DellSupportAssistforPCs' }
foreach ($package in $provisionedPackages) {
    try {
        Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName `
            -AllUsers -ErrorAction Stop | Out-Null
        Write-Host "  DEPROVISIONED  $($package.DisplayName)"
    }
    catch {
        Write-Warning "Could not deprovision $($package.PackageName): $($_.Exception.Message)"
        $script:CleanupFailed = $true
    }
}

# Query uninstall registry keys instead of Win32_Product, which is slow and can
# unexpectedly repair MSI packages. Only the optional SupportAssist stack is
# selected; PointStick, Free Fall Protection, Waves audio, and drivers stay.
$uninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

$supportAssistEntries = Get-ItemProperty $uninstallRoots -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -match '^Dell (SupportAssist(?: .*)?|TechHub)$' } |
    Sort-Object @{ Expression = { $_.WindowsInstaller -eq 1 } }, DisplayName

$uninstallSucceeded = $true
foreach ($entry in $supportAssistEntries) {
    if (-not (Invoke-Uninstaller -Entry $entry)) {
        $uninstallSucceeded = $false
        $script:CleanupFailed = $true
    }
}

# Successful uninstallers normally delete these services. Remove registrations
# left behind by older SupportAssist releases; on failure they remain disabled.
if ($uninstallSucceeded) {
    foreach ($serviceName in $supportAssistServices) {
        if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
            & sc.exe delete $serviceName | Out-Null
            Write-Host "  REMOVED  leftover service $serviceName"
        }
    }
}

if ($script:CleanupFailed) {
    Write-Warning 'Dell cleanup completed with one or more failures.'
    exit 1
}
elseif ($script:RebootRequired) {
    Write-Host "`n=== Done. Reboot required to finish removal. ===`n"
}
else {
    Write-Host "`n=== Done. Optional Dell software has been removed. ===`n"
}
