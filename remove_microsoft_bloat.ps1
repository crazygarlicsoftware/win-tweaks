#Requires -RunAsAdministrator
<#
  Removes optional Microsoft consumer software and disables related background
  features. Core Windows components, drivers, Microsoft Store, Edge/WebView,
  Defender, Search, Windows Update, Terminal, PowerShell, and user files stay.

  OneDrive data is never deleted. If a known folder is redirected into OneDrive,
  OneDrive removal is skipped unless -ForceOneDriveRemoval is supplied.
#>

[CmdletBinding()]
param(
    [switch]$ForceOneDriveRemoval
)

$ErrorActionPreference = 'Continue'
$script:CleanupFailed = $false

function Set-RegistryDword {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [int]$Value
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -Value $Value `
        -PropertyType DWord -Force | Out-Null
    Write-Host "  SET  $Path\$Name = $Value"
}

function Remove-AppxByName {
    param([Parameter(Mandatory)] [string]$Name)

    $found = $false
    $packages = @(Get-AppxPackage -AllUsers -Name $Name -ErrorAction SilentlyContinue)

    foreach ($package in ($packages | Sort-Object PackageFullName -Unique)) {
        $found = $true
        try {
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers `
                -ErrorAction Stop
            Write-Host "  REMOVED  $($package.Name)"
        }
        catch {
            # Some Windows builds reject -AllUsers for a package registered only
            # to the current account. Retry in the current user context.
            try {
                Remove-AppxPackage -Package $package.PackageFullName -ErrorAction Stop
                Write-Host "  REMOVED  $($package.Name) (current user)"
            }
            catch {
                Write-Warning "Could not remove $($package.PackageFullName): $($_.Exception.Message)"
                $script:CleanupFailed = $true
            }
        }
    }

    $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq $Name })

    foreach ($package in $provisioned) {
        $found = $true
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName `
                -AllUsers -ErrorAction Stop | Out-Null
            Write-Host "  DEPROVISIONED  $Name"
        }
        catch {
            Write-Warning "Could not deprovision $($package.PackageName): $($_.Exception.Message)"
            $script:CleanupFailed = $true
        }
    }

    if (-not $found) {
        Write-Host "  ABSENT  $Name"
    }
}

function Split-UninstallCommand {
    param([Parameter(Mandatory)] [string]$Command)

    if ($Command.Trim() -match '^"([^"]+)"\s*(.*)$') {
        return [pscustomobject]@{ FilePath = $Matches[1]; Arguments = $Matches[2] }
    }

    if ($Command.Trim() -match '^(\S+)\s*(.*)$') {
        return [pscustomobject]@{ FilePath = $Matches[1]; Arguments = $Matches[2] }
    }

    return $null
}

function Uninstall-DesktopApp {
    param(
        [Parameter(Mandatory)] [string]$DisplayName,
        [string]$AdditionalArguments = ''
    )

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $entries = @(Get-ItemProperty $uninstallRoots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -eq $DisplayName } |
        Sort-Object PSPath -Unique)

    if (-not $entries) {
        Write-Host "  ABSENT  $DisplayName"
        return
    }

    foreach ($entry in $entries) {
        $command = if ($entry.QuietUninstallString) {
            $entry.QuietUninstallString
        }
        else {
            $entry.UninstallString
        }

        if (-not $command) {
            Write-Warning "No uninstaller is registered for $DisplayName"
            $script:CleanupFailed = $true
            continue
        }

        $parts = Split-UninstallCommand -Command $command
        if (-not $parts -or -not (Test-Path -LiteralPath $parts.FilePath)) {
            Write-Warning "The registered uninstaller for $DisplayName is missing"
            $script:CleanupFailed = $true
            continue
        }

        $arguments = ($parts.Arguments + ' ' + $AdditionalArguments).Trim()
        Write-Host "  UNINSTALLING  $DisplayName"
        $process = Start-Process -FilePath $parts.FilePath -ArgumentList $arguments `
            -Wait -PassThru

        if ($process.ExitCode -notin @(0, 1605, 1614, 3010)) {
            Write-Warning "$DisplayName uninstall failed with exit code $($process.ExitCode)"
            $script:CleanupFailed = $true
        }
        else {
            Write-Host "  REMOVED  $DisplayName"
        }
    }
}

function Test-OneDriveKnownFolderRedirection {
    $shellFolders = Get-ItemProperty `
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' `
        -ErrorAction SilentlyContinue

    $knownFolders = @(
        $shellFolders.Desktop,
        $shellFolders.Personal,
        $shellFolders.'My Pictures'
    )

    foreach ($folder in $knownFolders) {
        if ($folder -and ([Environment]::ExpandEnvironmentVariables($folder) -match '\\OneDrive(?:\\|$)')) {
            return $true
        }
    }

    return $false
}

Write-Host "`n=== Stopping Optional Microsoft Background Apps ===`n"

$processPatterns = @(
    'Copilot*',
    'OneDrive*',
    'ms-teams*',
    'Teams*',
    'WidgetService*',
    'Widgets*',
    'PhoneExperienceHost*',
    'GameBar*',
    'XboxPcApp*',
    'Clipchamp*'
)

foreach ($pattern in $processPatterns) {
    Get-Process -Name $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "  STOPPING  $($_.ProcessName)"
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "`n=== Removing Copilot ===`n"

Uninstall-DesktopApp -DisplayName 'Copilot' -AdditionalArguments '--force-uninstall'
Remove-AppxByName -Name 'Microsoft.Copilot'

Set-RegistryDword `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' `
    -Name 'TurnOffWindowsCopilot' -Value 1
Set-RegistryDword `
    -Path 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' `
    -Name 'TurnOffWindowsCopilot' -Value 1
Set-RegistryDword `
    -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
    -Name 'ShowCopilotButton' -Value 0

$copilotShortcuts = @(
    (Join-Path $env:USERPROFILE 'Desktop\Copilot.lnk'),
    (Join-Path $env:PUBLIC 'Desktop\Copilot.lnk'),
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Copilot.lnk')
)
foreach ($shortcut in $copilotShortcuts) {
    if (Test-Path -LiteralPath $shortcut) {
        Remove-Item -LiteralPath $shortcut -Force
        Write-Host "  REMOVED  Copilot shortcut"
    }
}

Write-Host "`n=== Removing OneDrive ===`n"

if ((Test-OneDriveKnownFolderRedirection) -and -not $ForceOneDriveRemoval) {
    Write-Warning 'A known folder is redirected into OneDrive. OneDrive was not uninstalled.'
    Write-Warning 'Move or download those files first, or rerun with -ForceOneDriveRemoval.'
    $script:CleanupFailed = $true
}
else {
    Uninstall-DesktopApp -DisplayName 'Microsoft OneDrive'

    Remove-ItemProperty `
        -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' `
        -Name 'OneDrive' -Force -ErrorAction SilentlyContinue

    Get-ScheduledTask -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -like 'OneDrive*' } |
        Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue

    # Do not remove $env:OneDrive or any other user-data folder.
    Set-RegistryDword `
        -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' `
        -Name 'DisableFileSyncNGSC' -Value 1
}

Write-Host "`n=== Removing Optional Microsoft Consumer Apps ===`n"

$optionalApps = @(
    'Clipchamp.Clipchamp',
    'Microsoft.BingNews',
    'Microsoft.BingWeather',
    'Microsoft.GamingApp',
    'Microsoft.GetHelp',
    'Microsoft.MicrosoftOfficeHub',
    'Microsoft.MicrosoftSolitaireCollection',
    'Microsoft.OutlookForWindows',
    'Microsoft.PowerAutomateDesktop',
    'Microsoft.Windows.DevHome',
    'Microsoft.WindowsFeedbackHub',
    'Microsoft.Xbox.TCUI',
    'Microsoft.XboxGamingOverlay',
    'Microsoft.XboxIdentityProvider',
    'Microsoft.XboxSpeechToTextOverlay',
    'Microsoft.YourPhone',
    'Microsoft.ZuneMusic',
    'MicrosoftCorporationII.QuickAssist',
    'Microsoft.WidgetsPlatformRuntime',
    'MicrosoftWindows.Client.WebExperience',
    'MSTeams'
)

foreach ($app in $optionalApps) {
    Remove-AppxByName -Name $app
}

Write-Host "`n=== Disabling Widgets and Game Capture ===`n"

Set-RegistryDword `
    -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' `
    -Name 'AllowNewsAndInterests' -Value 0
Set-RegistryDword `
    -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' `
    -Name 'TaskbarDa' -Value 0
Set-RegistryDword `
    -Path 'HKCU:\System\GameConfigStore' `
    -Name 'GameDVR_Enabled' -Value 0
Set-RegistryDword `
    -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' `
    -Name 'AppCaptureEnabled' -Value 0

if ($script:CleanupFailed) {
    Write-Warning 'Microsoft consumer-app cleanup completed with one or more failures.'
    exit 1
}

Write-Host "`n=== Done. Sign out and back in (or reboot) to finish cleanup. ===`n"
