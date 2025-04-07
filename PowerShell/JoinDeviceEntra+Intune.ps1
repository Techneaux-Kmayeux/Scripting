###############################################################################
# This script ensures a device is joined to Entra ID (Azure AD) and enrolled in
# Intune (MDM). It will:
#   1. Check for (and create if missing) the Entra join Scheduled Task.
#   2. Check for (and create if missing) the Intune enrollment Scheduled Task.
#   3. Run each task sequentially, verifying success.
#   4. If SCCM is detected, advise the user to run the SCCM Killer script.
###############################################################################

# Define task paths & names
$EntraTaskPath  = "\Microsoft\Windows\Workplace Join"
$EntraTaskName  = "Automatic-Device-Join"
$IntuneTaskPath = "\Microsoft\Windows\EnterpriseMgmt"
$IntuneTaskName = "MDM Enrollment"

###############################################################################
# Helper: Check if a scheduled task exists
###############################################################################
function Test-ScheduledTask {
    param(
        [string]$TaskPath,
        [string]$TaskName
    )
    $found = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    return ($null -ne $found)
}

###############################################################################
# Helper: Create the Entra ID join task
###############################################################################
function New-EntraIDJoinTask {
    $action = New-ScheduledTaskAction -Execute "C:\Windows\System32\dsregcmd.exe" -Argument "/join"
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskPath $EntraTaskPath -TaskName $EntraTaskName -Action $action -Trigger $trigger -RunLevel Highest -Description "Automatically joins the device to Entra ID."
}

###############################################################################
# Helper: Create the Intune enrollment task
###############################################################################
function New-IntuneEnrollmentTask {
    $action = New-ScheduledTaskAction -Execute "C:\Windows\System32\deviceenroller.exe" -Argument "/c /AutoEnrollMDM"
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskPath $IntuneTaskPath -TaskName $IntuneTaskName -Action $action -Trigger $trigger -RunLevel Highest -Description "Automatically enrolls the device in Intune."
}

###############################################################################
# 1. Check/Create Entra ID Join Task
###############################################################################
if (-not (Test-ScheduledTask -TaskPath $EntraTaskPath -TaskName $EntraTaskName)) {
    Write-Host "Entra ID join task not found. Creating..."
    New-EntraIDJoinTask
} else {
    Write-Host "Entra ID join task already exists."
}

###############################################################################
# 2. Check/Create Intune Enrollment Task
###############################################################################
if (-not (Test-ScheduledTask -TaskPath $IntuneTaskPath -TaskName $IntuneTaskName)) {
    Write-Host "Intune enrollment task not found. Creating..."
    New-IntuneEnrollmentTask
} else {
    Write-Host "Intune enrollment task already exists."
}

###############################################################################
# 3. Run and Verify Entra ID Join
###############################################################################
Write-Host "Running Entra ID join task..."
Start-ScheduledTask -TaskPath $EntraTaskPath -TaskName $EntraTaskName

Write-Host "Waiting 60 seconds for Entra ID join to complete..."
Start-Sleep -Seconds 60

$dsregStatus = dsregcmd /status
if ($dsregStatus -match "AzureAdJoined\s*:\s*YES") {
    Write-Host "Device successfully joined to Entra ID."
} else {
    Write-Host "Entra ID join failed or not detected. Please check manually."
    exit 1
}

###############################################################################
# 4. Run and Verify Intune Enrollment
###############################################################################
Write-Host "Running Intune enrollment task..."
Start-ScheduledTask -TaskPath $IntuneTaskPath -TaskName $IntuneTaskName

Write-Host "Waiting 60 seconds for Intune enrollment to complete..."
Start-Sleep -Seconds 60

$mdmStatus = dsregcmd /status
# Note: "MDM: Microsoft Intune" is typical, but environment strings can vary
if ($mdmStatus -match "MDM\s*:\s*Microsoft Intune") {
    Write-Host "Device successfully enrolled in Intune."
} else {
    Write-Host "Intune enrollment failed or not detected. Please check manually."
    exit 2
}

###############################################################################
# 5. Check for SCCM and advise user
###############################################################################
$SCCMClientPath = Join-Path $env:WinDir "CCM\ccmexec.exe"
if (Test-Path $SCCMClientPath) {
    Write-Warning "SCCM Client was found. Please run the SCCM Killer script to finalize Intune rollout."
} else {
    Write-Host "No SCCM client detected."
}