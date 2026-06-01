#Requires -RunAsAdministrator
<#
  Disables Windows "You're almost done setting up your PC" / OOBE continuation prompts
  and other built-in nags that block or delay login.
#>

$ErrorActionPreference = 'SilentlyContinue'

function Set-RegistryValue {
    param($Path, $Name, $Value, $Type = 'DWord')
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
    Write-Host "  SET  $Path\$Name = $Value"
}

Write-Host "`n=== Disabling OOBE / Setup Continuation Prompts ===`n"

# "You're almost done setting up your PC" / SCOOBE (Second Chance Out-of-Box Experience)
Set-RegistryValue `
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement' `
    'ScoobeSystemSettingEnabled' 0

# "Let's finish setting up your device" shown after login
Set-RegistryValue `
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
    'SoftLandingEnabled' 0

# Windows Welcome Experience ("See what's new after updates")
Set-RegistryValue `
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
    'SubscribedContent-310093Enabled' 0

# "Suggest ways I can finish setting up my device to get more out of Windows"
Set-RegistryValue `
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
    'SubscribedContent-338389Enabled' 0

# Spotlight / lock screen ads
Set-RegistryValue `
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
    'RotatingLockScreenOverlayEnabled' 0

Set-RegistryValue `
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
    'SubscribedContent-338388Enabled' 0

# "Tips and suggestions when I use Windows"
Set-RegistryValue `
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
    'SubscribedContent-338387Enabled' 0

# Disable OOBE privacy setup page for this machine (admin)
Set-RegistryValue `
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' `
    'DisablePrivacyExperience' 1

# Disable "Get even more out of Windows" Start menu nag
Set-RegistryValue `
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
    'SubscribedContent-353698Enabled' 0

# Disable Start menu suggested apps
Set-RegistryValue `
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
    'SystemPaneSuggestionsEnabled' 0

Set-RegistryValue `
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
    'OemPreInstalledAppsEnabled' 0

Set-RegistryValue `
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
    'PreInstalledAppsEnabled' 0

Set-RegistryValue `
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' `
    'SilentInstalledAppsEnabled' 0

Write-Host "`n=== Removing Edge Desktop Shortcut ===`n"

foreach ($path in @("$env:USERPROFILE\Desktop\Microsoft Edge.lnk", "C:\Users\Public\Desktop\Microsoft Edge.lnk")) {
    if (Test-Path $path) {
        Remove-Item $path -Force
        Write-Host "  REMOVED  $path"
    }
}

Write-Host "`n=== Done. Sign out and back in (or reboot) for changes to take effect. ===`n"
