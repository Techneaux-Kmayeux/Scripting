# Define parameters
param (
    [string]$LogType = "Audit", # Options: "Audit" or "SignIn"
    [int]$Days = 30 # Default to the past 30 days
)

# Calculate date range
$EndDate = Get-Date
$StartDate = $EndDate.AddDays(-$Days)

# Connect to Microsoft Graph with required scopes
Connect-MgGraph -Scopes "AuditLog.Read.All"

# Function to retrieve logs
function Get-Logs {
    param (
        [string]$Type,
        [datetime]$Start,
        [datetime]$End
    )

    if ($Type -eq "Audit") {
        $Logs = Get-MgAuditLogDirectoryAudit -Filter "activityDateTime ge $($Start.ToString('o')) and activityDateTime le $($End.ToString('o'))"
    }
    elseif ($Type -eq "SignIn") {
        $Logs = Get-MgAuditLogSignIn -Filter "createdDateTime ge $($Start.ToString('o')) and createdDateTime le $($End.ToString('o'))"
    }
    else {
        Write-Error "Invalid log type specified. Use 'Audit' or 'SignIn'."
        return $null
    }
    return $Logs
}

# Retrieve logs
$RetrievedLogs = Get-Logs -Type $LogType -Start $StartDate -End $EndDate

# Save logs locally
if ($RetrievedLogs) {
    $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $FileName = "$LogType`Logs_$Timestamp.csv"
    $FilePath = Join-Path -Path (Get-Location) -ChildPath $FileName
    $RetrievedLogs | Export-Csv -Path $FilePath -NoTypeInformation
    Write-Output "Logs have been saved to $FilePath"
} else {
    Write-Output "No logs retrieved for the specified parameters."
}

# Disconnect from Microsoft Graph
Disconnect-MgGraph
