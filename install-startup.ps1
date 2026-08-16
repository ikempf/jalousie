<#
.SYNOPSIS
    Registers accordion.ahk to start elevated at logon, with no UAC prompt.

.DESCRIPTION
    Creates a Scheduled Task ("accordion") that runs the script at logon with
    highest privileges. This is what lets it manage windows owned by elevated
    processes (UIPI) without prompting you at every login -- the Startup folder
    cannot do that.

    Must be run from an ELEVATED PowerShell.

.EXAMPLE
    .\install-startup.ps1
    .\install-startup.ps1 -DelaySeconds 30
    .\install-startup.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    # Path to the script. Defaults to accordion.ahk next to this installer.
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'accordion.ahk'),

    # AutoHotkey v2 interpreter.
    [string]$AhkPath = 'C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe',

    # Name of the scheduled task.
    [string]$TaskName = 'accordion',

    # Wait this long after logon before starting, so the shell is up first.
    [int]$DelaySeconds = 15,

    # Remove the task instead of creating it.
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Elevated)) {
    Write-Error @"
This must run from an elevated PowerShell.

  Right-click the Start button -> "Terminal (Admin)", then:
    cd '$PSScriptRoot'
    .\$(Split-Path $PSCommandPath -Leaf)$(if ($Uninstall) { ' -Uninstall' })
"@
    exit 1
}

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
        Write-Host "The running instance is untouched -- quit it with Ctrl+Alt+Win+Q."
    } else {
        Write-Host "No scheduled task named '$TaskName'. Nothing to do."
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $AhkPath)) {
    Write-Error "AutoHotkey not found at '$AhkPath'. Install AHK v2, or pass -AhkPath."
    exit 1
}
if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Error "Script not found at '$ScriptPath'. Pass -ScriptPath."
    exit 1
}

$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$AhkPath    = (Resolve-Path -LiteralPath $AhkPath).Path

$action = New-ScheduledTaskAction -Execute $AhkPath `
                                  -Argument "`"$ScriptPath`"" `
                                  -WorkingDirectory (Split-Path $ScriptPath -Parent)

$user    = "$env:USERDOMAIN\$env:USERNAME"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
if ($DelaySeconds -gt 0) { $trigger.Delay = "PT${DelaySeconds}S" }

# Interactive logon type: the task needs a desktop to manipulate windows on.
$principal = New-ScheduledTaskPrincipal -UserId $user `
                                        -LogonType Interactive `
                                        -RunLevel Highest

# Defaults that matter: never time the task out (it runs all session), don't
# refuse to start on battery, don't stop when unplugged, ignore a second logon.
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -DontStopOnIdleEnd `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName `
                       -Action $action `
                       -Trigger $trigger `
                       -Principal $principal `
                       -Settings $settings `
                       -Description 'Keyboard-driven accordion window manager (accordion.ahk)' `
                       -Force | Out-Null

Write-Host "Registered scheduled task '$TaskName'." -ForegroundColor Green
Write-Host "  interpreter : $AhkPath"
Write-Host "  script      : $ScriptPath"
Write-Host "  trigger     : at logon for $user$(if ($DelaySeconds) { ", after ${DelaySeconds}s" })"
Write-Host "  privileges  : highest (no UAC prompt at logon)"
Write-Host ""
Write-Host "Start it now without logging out:  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Remove it later:                   .\$(Split-Path $PSCommandPath -Leaf) -Uninstall"
