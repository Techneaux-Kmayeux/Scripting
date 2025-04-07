# Automated SCCM Removal and Intune Sync Script
# Run this script as Administrator

# Function to log actions
function Write-Log {
    param ($message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "$timestamp : $message"
}

# Step 1: Uninstall SCCM silently
$sccmPath = "$env:WinDir\ccmsetup\ccmsetup.exe"
if (Test-Path $sccmPath) {
    Write-Log "Initiating silent SCCM uninstall..."
    Start-Process -FilePath $sccmPath -ArgumentList "/uninstall /silent" -Wait
    Write-Log "SCCM client uninstall completed."
}
else {
    Write-Log "SCCM setup executable not found. Skipping uninstall."
}

# Step 2: Cleanup residual directories
$folders = @(
    "$env:WinDir\CCM",
    "$env:WinDir\ccmsetup",
    "$env:WinDir\ccmcache"
)

foreach ($folder in $folders) {
    if (Test-Path $folder) {
        Write-Log "Removing folder: $folder"
        Remove-Item -Path $folder -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Log "Folder already removed: $folder"
    }
}

# Step 3: Cleanup residual registry keys
$registryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\CCM",
    "HKLM:\SOFTWARE\Microsoft\CCMSetup",
    "HKLM:\SOFTWARE\Microsoft\SMS"
)

foreach ($reg in $registryPaths) {
    if (Test-Path $reg) {
        Write-Log "Removing registry key: $reg"
        Remove-Item -Path $reg -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Log "Registry key already removed: $reg"
    }
}