<#
.SYNOPSIS
    Creates/Updates two scheduled tasks for Entra ID Join and Intune Enrollment, with custom triggers.

.DESCRIPTION
    1) Entra ID Join Task:
        - dsregcmd /join
        - Triggers:
            a) At Log On of any user, repeats every 1 hour for 1 day
            b) On event (Log: Microsoft-Windows-User Device Registration/Admin,
                        Source: Microsoft-Windows-User Device Registration,
                        Event ID: 4096), repeats every 1 hour for 1 day
    2) Intune Enrollment Task:
        - deviceenroller.exe /c /AutoEnrollMDMUsingAADDeviceCredential
        - Trigger:
            a) One-time start (in near future), repeats every 5 minutes for 1 day

    After creation, the script starts the Entra join task, checks dsregcmd /status,
    then starts the Intune task, checks enrollment. Adjust intervals and durations as needed.

#>

[CmdletBinding()]
param()

###############################################################################
# SETTINGS
###############################################################################
$EntraTaskPath      = "\Microsoft\Windows\Workplace Join"
$EntraTaskName      = "Automatic-Device-Join"

$IntuneTaskPath     = "\Microsoft\Windows\EnterpriseMgmt"
$IntuneTaskName     = "MDM-Enrollment"

# The dsregcmd command for Entra ID join:
$EntraCommand       = "C:\Windows\System32\dsregcmd.exe"
$EntraArguments     = "/join"

# The Intune enrollment command:
$IntuneCommand      = "C:\Windows\System32\deviceenroller.exe"
$IntuneArguments    = "/c /AutoEnrollMDMUsingAADDeviceCredential"

###############################################################################
# HELPER: Test if Scheduled Task exists
###############################################################################
function Test-ScheduledTask {
    param(
        [Parameter(Mandatory=$true)] [string]$TaskPath,
        [Parameter(Mandatory=$true)] [string]$TaskName
    )
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
    return ($null -ne $task)
}

###############################################################################
# HELPER: Create/Update Entra ID Join Task
###############################################################################
function Ensure-EntraIDJoinTask {
    if (Test-ScheduledTask -TaskPath $EntraTaskPath -TaskName $EntraTaskName) {
        Write-Host "Entra ID join task [$EntraTaskPath\$EntraTaskName] already exists."
        return
    }

    Write-Host "Creating Entra ID join task [$EntraTaskPath\$EntraTaskName]..."

    # ACTION
    $action = New-ScheduledTaskAction -Execute $EntraCommand -Argument $EntraArguments

    # TRIGGERS:
    # 1) AtLogOn trigger, repeats every 1 hour for 1 day
    $logonTrigger = New-ScheduledTaskTrigger -AtLogOn `
        -RepetitionInterval (New-TimeSpan -Hours 1) `
        -RepetitionDuration (New-TimeSpan -Days 1)

    # 2) OnEvent trigger: Microsoft-Windows-User Device Registration/Admin, EventID = 4096
    #    repeats every 1 hour for 1 day
    $eventTrigger = New-ScheduledTaskTrigger -Once `
        -Log "Microsoft-Windows-User Device Registration/Admin" `
        -Source "Microsoft-Windows-User Device Registration" `
        -EventId 4096 `
        -RepetitionInterval (New-TimeSpan -Hours 1) `
        -RepetitionDuration (New-TimeSpan -Days 1)

    # Combine triggers
    $triggers = @($logonTrigger, $eventTrigger)

    # PRINCIPAL: run as SYSTEM
    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    # BUILD & REGISTER
    $taskDefinition = New-ScheduledTask -Action $action -Principal $principal -Trigger $triggers
    Register-ScheduledTask -TaskPath $EntraTaskPath -TaskName $EntraTaskName -InputObject $taskDefinition | Out-Null

    Write-Host "Created Entra ID join task [$EntraTaskPath\$EntraTaskName]."
}

###############################################################################
# HELPER: Create/Update Intune Enrollment Task
###############################################################################
function Ensure-IntuneMDMTask {
    if (Test-ScheduledTask -TaskPath $IntuneTaskPath -TaskName $IntuneTaskName) {
        Write-Host "Intune enrollment task [$IntuneTaskPath\$IntuneTaskName] already exists."
        return
    }

    Write-Host "Creating Intune enrollment task [$IntuneTaskPath\$IntuneTaskName]..."

    # ACTION
    $action = New-ScheduledTaskAction -Execute $IntuneCommand -Argument $IntuneArguments

    # TRIGGER: One time (a couple minutes from now), repeat every 5 mins for 1 day
    $onceTrigger = New-ScheduledTaskTrigger -Once `
        -At (Get-Date).AddMinutes(2) `
        -RepetitionInterval (New-TimeSpan -Minutes 5) `
        -RepetitionDuration (New-TimeSpan -Days 1)

    # PRINCIPAL: run as SYSTEM
    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    # BUILD & REGISTER
    $taskDefinition = New-ScheduledTask -Action $action -Principal $principal -Trigger $onceTrigger
    Register-ScheduledTask -TaskPath $IntuneTaskPath -TaskName $IntuneTaskName -InputObject $taskDefinition | Out-Null

    Write-Host "Created Intune enrollment task [$IntuneTaskPath\$IntuneTaskName]."
}

###############################################################################
# 1. Ensure both tasks
###############################################################################
Ensure-EntraIDJoinTask
Ensure-IntuneMDMTask

###############################################################################
# 2. Run Entra ID Join Task & Verify
###############################################################################
Write-Host "Starting Entra ID join task: [$EntraTaskPath\$EntraTaskName]..."
Start-ScheduledTask -TaskPath $EntraTaskPath -TaskName $EntraTaskName

Write-Host "Waiting 60 seconds for Entra join to complete..."
Start-Sleep -Seconds 60

$dsregStatus = dsregcmd /status
if ($dsregStatus -match "AzureAdJoined\s*:\s*YES") {
    Write-Host "Device successfully joined to Entra ID (Azure AD)."
} else {
    Write-Warning "Entra ID join not confirmed. Check dsregcmd /status manually."
}

###############################################################################
# 3. Run Intune Enrollment Task & Verify
###############################################################################
Write-Host "Starting Intune enrollment task: [$IntuneTaskPath\$IntuneTaskName]..."
Start-ScheduledTask -TaskPath $IntuneTaskPath -TaskName $IntuneTaskName

Write-Host "Waiting 60 seconds for Intune enrollment to complete..."
Start-Sleep -Seconds 60

# Check dsregcmd /status for MDM reference, e.g. "MDM : Microsoft Intune"
$mdmStatus = dsregcmd /status
if ($mdmStatus -match "MDM\s*:\s*Microsoft Intune") {
    Write-Host "Device successfully enrolled in Intune."
} else {
    Write-Warning "Intune enrollment not confirmed. Check dsregcmd /status manually."
}

Write-Host "Script complete."