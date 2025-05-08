<#
.SYNOPSIS
    Hide or restore the ScreenConnect tray icon.

.DESCRIPTION
    - Without parameters, forces the icon OFF.
    - With -ShowIcon (or -Restore / -Unhide), puts the icon back ON.

.PARAMETER ShowIcon
    Switch.  If supplied, restores the tray icon instead of hiding it.

.EXAMPLE
    # Hide the icon (default behaviour)
    .\Toggle-SCTrayIcon.ps1

.EXAMPLE
    # Restore the icon
    .\Toggle-SCTrayIcon.ps1 -ShowIcon
#>

[CmdletBinding()]
param(
    [Alias('Restore','Unhide')]
    [switch]$ShowIcon
)

$flags       = 'ShowSystemTrayIcon','AccessShowSystemTrayIcon','SupportShowSystemTrayIcon'
$desiredVal  = if ($ShowIcon.IsPresent) { 'true' } else { 'false' }

Write-Verbose "Setting ScreenConnect tray–icon flags to '$desiredVal'"

Get-ChildItem 'C:\Program Files*\ScreenConnect Client*' -Directory -ErrorAction SilentlyContinue |
ForEach-Object {
    $cfg = Join-Path $_ 'system.config'
    if (-not (Test-Path $cfg)) { return }

    [xml]$xml = Get-Content $cfg -Raw

    # --- ensure <configSections> and UI section exist ------------------------
    $sections = $xml.configuration.configSections
    if (-not $sections) {
        $sections = $xml.CreateElement('configSections')
        $xml.configuration.PrependChild($sections) | Out-Null
    }

    if (-not $sections.SelectSingleNode("./section[@name='ScreenConnect.UserInterfaceSettings']")){
        $sec = $xml.CreateElement('section')
        $sec.SetAttribute('name','ScreenConnect.UserInterfaceSettings')
        $sec.SetAttribute('type','System.Configuration.ClientSettingsSection')
        $sections.AppendChild($sec) | Out-Null
    }

    $ui = $xml.SelectSingleNode('//ScreenConnect.UserInterfaceSettings')
    if (-not $ui) {
        $ui = $xml.CreateElement('ScreenConnect.UserInterfaceSettings')
        $xml.configuration.AppendChild($ui) | Out-Null
    }

    # --- write / update the three flags --------------------------------------
    foreach ($f in $flags) {
        $set = $ui.SelectSingleNode("./setting[@name='$f']")
        if (-not $set) {
            $set = $xml.CreateElement('setting')
            $set.SetAttribute('name',$f)
            $set.SetAttribute('serializeAs','String')
            $val = $xml.CreateElement('value')
            $set.AppendChild($val)        | Out-Null
            $ui.AppendChild($set)         | Out-Null
        }
        $set.value = $desiredVal
    }

    $xml.Save($cfg)
    Write-Verbose "Patched $cfg"
}

# --- restart the agent so changes take hold ----------------------------------
Get-Service 'ScreenConnect Client*' -ErrorAction SilentlyContinue |
    Restart-Service -Force -ErrorAction SilentlyContinue