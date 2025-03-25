<#
.SYNOPSIS
    Performs a hard match for each user in On-Prem AD to Azure AD by setting the OnPremisesImmutableId using Microsoft Graph.

.DESCRIPTION
    - Retrieves on-premises AD users (Get-ADUser).
    - Constructs an Azure AD UPN from the on-prem UPN and the provided PrimaryDomain.
    - Converts the on-prem AD ObjectGUID to a Base64 string (ImmutableID).
    - Retrieves all Azure AD users once and builds a dictionary for fast lookups.
    - If the primary guess UPN isn’t found, attempts fallback UPN patterns (using first name, etc.) and verifies via name match.
    - Updates the matching Azure AD user’s OnPremisesImmutableId.
    - Logs successes and failures to CSV (with domain discrepancy included at the top if any).
    - Produces a trimmed orphan report with four columns: (GivenName, OnPremImmutableId, Surname, UPN).

.NOTES
    - Requires: ActiveDirectory and Microsoft Graph modules.
    - Run with an account that can install modules and authenticate to Graph.
    - Test thoroughly in a non-production environment.
#>

param(
    [string]$FailureCsvPath       = "C:\Techneaux\HardLinkScript\HardMatchFailures.csv",
    [string]$SuccessCsvPath       = "C:\Techneaux\HardLinkScript\HardMatchSuccessLog.csv",
    [string]$OrphanReportCsvPath  = "C:\Techneaux\HardLinkScript\AzureNotInAD.csv",
    [int]$MaxUsers                = 20,
    [bool]$FullSend               = $false,
    [string]$PrimaryDomain        = $null,
    [string]$MSOLDomain           = $null
)

###############################################################################
# 1. Validate required parameters
###############################################################################
if (-not $PrimaryDomain) {
    Write-Host "ERROR: You MUST include the Org's Primary Domain. Example: -PrimaryDomain techneaux.com"
    exit 1
}

###############################################################################
# 2. Install Microsoft.Graph module if needed
###############################################################################
try {
    Install-Module Microsoft.Graph -ErrorAction Ignore -Scope CurrentUser
}
catch {
    Write-Host "ERROR: Microsoft Graph Module Failed to Install. Troubleshoot manually then re-run script."
    exit 2
}

###############################################################################
# 3. Import required modules
###############################################################################
Write-Host "Importing required modules (if not already loaded)..."
Import-Module ActiveDirectory
Import-Module Microsoft.Graph.Users

###############################################################################
# 4. Connect to Microsoft Graph
###############################################################################
try {
    Write-Host "Attempting to Connect to MgGraph. Be ready to authenticate with GA credentials..."
    Connect-MgGraph -Scopes "User.ReadWrite.All","Directory.ReadWrite.All"
}
catch {
    Write-Host "ERROR: Failed to Connect to MgGraph. Troubleshoot manually then re-run."
    exit 3
}

###############################################################################
# 5. Verify PrimaryDomain against tenant’s default domain
###############################################################################
try {
    # Retrieve organization info; the VerifiedDomains property contains the default domain.
    $org = Get-MgOrganization -ErrorAction Stop
    $defaultDomain = ($org.VerifiedDomains | Where-Object { $_.IsDefault -eq $true }).Name
}
catch {
    Write-Host "ERROR: Could not retrieve organization domain information."
    exit 5
}

$domainDiscrepancy = ""
if ($PrimaryDomain.ToLower() -ne $defaultDomain.ToLower()) {
    Write-Host "WARNING: The PrimaryDomain you provided ('$PrimaryDomain') does not match the tenant's default domain ('$defaultDomain')."
    $response = Read-Host "Would you like to continue? (Y/N)"
    if ($response -notin @("Y","y")) {
        Write-Host "User opted to exit due to domain mismatch."
        exit 6
    }
    else {
        Write-Host "Continuing execution. Discrepancy logged."
        $domainDiscrepancy = "User provided PrimaryDomain ('$PrimaryDomain') does not match tenant default domain ('$defaultDomain')."
    }
}
else {
    Write-Host "PrimaryDomain matches the tenant default domain: $PrimaryDomain"
}

###############################################################################
# 6. Ensure directories for CSV files exist
###############################################################################
$successDirectory = [System.IO.Path]::GetDirectoryName($SuccessCsvPath)
$failureDirectory = [System.IO.Path]::GetDirectoryName($FailureCsvPath)
$orphanDirectory  = [System.IO.Path]::GetDirectoryName($OrphanReportCsvPath)

foreach ($dir in @($successDirectory, $failureDirectory, $orphanDirectory)) {
    if (-not (Test-Path $dir)) {
        Write-Host "Directory $dir does not exist. Creating..."
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}

###############################################################################
# 7. Retrieve On-Prem AD users
###############################################################################
if ($FullSend) {
    Write-Host "FULL SEND: Retrieving ALL On-Prem AD users..."
    $OnPremUsers = Get-ADUser -Filter * -Properties UserPrincipalName, ObjectGUID, GivenName, Surname, MiddleName, Initials, Enabled
}
else {
    Write-Host "Retrieving up to $MaxUsers On-Prem AD users..."
    $OnPremUsers = Get-ADUser -Filter * -Properties UserPrincipalName, ObjectGUID, GivenName, Surname, MiddleName, Initials, Enabled |
        Select-Object -First $MaxUsers
}

###############################################################################
# 8. Retrieve all Azure AD users once and build a dictionary for fast lookup
###############################################################################
Write-Host "Retrieving all Azure AD users..."
try {
    $AllAzureUsers = Get-MgUser -All -Property "GivenName","Surname","OnPremisesImmutableId","UserPrincipalName"
}
catch {
    Write-Host "ERROR: Failed to retrieve Azure AD users. Exiting."
    exit 4
}

$AzureUsersByUPN = @{}
foreach ($u in $AllAzureUsers) {
    if ($u.UserPrincipalName) {
        $AzureUsersByUPN[$u.UserPrincipalName.ToLower()] = $u
    }
}

###############################################################################
# 9. Prepare a collection to store output results and track processed UPNs
###############################################################################
$Results = @()
$ProcessedUPNs = @()  # Will only store final matched UPNs

###############################################################################
# 10. Process each On-Prem AD user
###############################################################################
foreach ($user in $OnPremUsers) {

    # Skip if no UPN exists
    if (-not $user.UserPrincipalName) {
        Write-Warning "Skipping user $($user.SamAccountName) - no UPN found."
        continue
    }
    
    # Gather on-prem name details
    $onPremFirstName = $user.GivenName
    $onPremLastName  = $user.Surname
    $onPremMiddle    = $user.MiddleName

    # Build a primary guess for the Azure AD UPN
    $localPart       = $user.UserPrincipalName.Split('@')[0]
    $primaryGuessUPN = "$localPart@$PrimaryDomain"
    
    # Try initial lookup
    $azureUser = $AzureUsersByUPN[$primaryGuessUPN.ToLower()]
    $finalMatchedUPN = $null

    if ($azureUser) {
        # Found via primary guess
        $finalMatchedUPN = $primaryGuessUPN
    }
    else {
        # Attempt fallback patterns if we have a first/last name
        if ($onPremFirstName -and $onPremLastName) {
            $candidateUPNs = @()
            $candidateUPNs += "$onPremFirstName@$PrimaryDomain"
            if ($onPremFirstName.Length -ge 1 -and $onPremLastName.Length -ge 1) {
                $candidateUPNs += ("{0}{1}@{2}" -f $onPremFirstName.Substring(0,1), $onPremLastName, $PrimaryDomain)
            }
            if ($onPremMiddle -and $onPremMiddle.Length -ge 1 -and $onPremFirstName.Length -ge 1 -and $onPremLastName.Length -ge 1) {
                $candidateUPNs += ("{0}{1}{2}@{3}" -f $onPremFirstName.Substring(0,1), $onPremMiddle.Substring(0,1), $onPremLastName, $PrimaryDomain)
            }
            if ($onPremLastName.Length -ge 1) {
                $candidateUPNs += ("{0}{1}@{2}" -f $onPremFirstName, $onPremLastName.Substring(0,1), $PrimaryDomain)
            }
            $candidateUPNs += ("{0}.{1}@{2}" -f $onPremFirstName, $onPremLastName, $PrimaryDomain)

            foreach ($candidate in $candidateUPNs | Where-Object { $_ }) {
                Write-Verbose "Trying fallback UPN: $candidate"
                $potentialUser = $AzureUsersByUPN[$candidate.ToLower()]
                if ($potentialUser) {
                    # Verify name match
                    if ($potentialUser.GivenName -eq $onPremFirstName -and $potentialUser.Surname -eq $onPremLastName) {
                        Write-Verbose "Found matching Azure AD user via fallback UPN: $candidate"
                        $azureUser       = $potentialUser
                        $finalMatchedUPN = $candidate
                        break
                    }
                }
            }
        }
    }

    # If still no match, log failure
    if (-not $azureUser) {
        $Results += [pscustomobject]@{
            OnPremUser         = $user.UserPrincipalName
            AzureADUser        = $primaryGuessUPN
            Status             = "FAILED"
            Reason             = "User not found in Azure AD"
            OnPremEnabled      = $user.Enabled
            NewID              = [System.Convert]::ToBase64String($user.ObjectGUID.ToByteArray())
            PreviousID         = $null
            DomainDiscrepancy  = $domainDiscrepancy
        }
        Write-Warning "FAILED: $($user.UserPrincipalName) => $primaryGuessUPN : No match in Azure AD"
        continue
    }
    
    # We have a match: add the final UPN to $ProcessedUPNs
    $ProcessedUPNs += $finalMatchedUPN.ToLower()

    # Convert the on-prem AD ObjectGUID to a Base64 string
    $immutableId = [System.Convert]::ToBase64String($user.ObjectGUID.ToByteArray())

    # Retrieve previous OnPremisesImmutableId
    $priorId = $azureUser.OnPremisesImmutableId

    # Attempt to update
    try {
        Update-MgUser -UserId $finalMatchedUPN -OnPremisesImmutableId $immutableId -ErrorAction Stop

        $Results += [pscustomobject]@{
            OnPremUser         = $user.UserPrincipalName
            AzureADUser        = $finalMatchedUPN
            Status             = "SUCCESS"
            Reason             = ""
            OnPremEnabled      = $user.Enabled
            NewID              = $immutableId
            PreviousID         = $priorId
            DomainDiscrepancy  = $domainDiscrepancy
        }
        
        Write-Host "SUCCESS: Set OnPremisesImmutableId for $($user.UserPrincipalName) => $finalMatchedUPN"
    }
    catch {
        $Results += [pscustomobject]@{
            OnPremUser         = $user.UserPrincipalName
            AzureADUser        = $finalMatchedUPN
            Status             = "FAILED"
            Reason             = $_.Exception.Message
            OnPremEnabled      = $user.Enabled
            NewID              = $immutableId
            PreviousID         = $priorId
            DomainDiscrepancy  = $domainDiscrepancy
        }
        Write-Warning "FAILED: $($user.UserPrincipalName) => $finalMatchedUPN : $($_.Exception.Message)"
    }
}

###############################################################################
# 11. Cross-reference: Identify Azure users not present in on-prem AD
###############################################################################
$OrphanedAzureUsers = @()
foreach ($key in $AzureUsersByUPN.Keys) {
    if (-not ($ProcessedUPNs -contains $key)) {
        # This user was never matched
        $OrphanedAzureUsers += $AzureUsersByUPN[$key]
    }
}

if ($OrphanedAzureUsers.Count -gt 0) {
    Write-Host "`nFound $($OrphanedAzureUsers.Count) Azure AD user(s) that were NOT present in on-prem AD."
    
    # Prepend domain discrepancy if any
    if ($domainDiscrepancy) {
        "DomainDiscrepancy: $domainDiscrepancy" | Out-File $OrphanReportCsvPath
        # Then export the orphans with the 4 columns you specified
        $OrphanedAzureUsers |
            Select-Object `
                GivenName,
                @{Name="OnPremImmutableId"; Expression = { $_.OnPremisesImmutableId }},
                Surname,
                @{Name="UPN"; Expression = { $_.UserPrincipalName }} |
            Export-Csv -Path $OrphanReportCsvPath -NoTypeInformation -Append
    }
    else {
        # No discrepancy – just export
        $OrphanedAzureUsers |
            Select-Object `
                GivenName,
                @{Name="OnPremImmutableId"; Expression = { $_.OnPremisesImmutableId }},
                Surname,
                @{Name="UPN"; Expression = { $_.UserPrincipalName }} |
            Export-Csv -Path $OrphanReportCsvPath -NoTypeInformation
    }
    
    Write-Host "A CSV report of these users has been saved to: $OrphanReportCsvPath"
}
else {
    Write-Host "`nNo Azure AD users were found that are missing in on-prem AD."
}

###############################################################################
# 12. Output and export final results
###############################################################################
Write-Host "`n--- Summary of Hard Matching Operations ---"
$Results | Format-Table -AutoSize

# Export all operations (SuccessCsvPath)
if ($domainDiscrepancy) {
    "DomainDiscrepancy: $domainDiscrepancy" | Out-File $SuccessCsvPath
    $Results | Export-Csv -Path $SuccessCsvPath -NoTypeInformation -Append
}
else {
    $Results | Export-Csv -Path $SuccessCsvPath -NoTypeInformation
}
Write-Host "`nA CSV of all operations was saved to: $SuccessCsvPath"

# Export failures, if any (FailureCsvPath)
$Failures = $Results | Where-Object { $_.Status -eq "FAILED" }
if ($Failures) {
    if ($domainDiscrepancy) {
        "DomainDiscrepancy: $domainDiscrepancy" | Out-File $FailureCsvPath
        $Failures | Export-Csv -Path $FailureCsvPath -NoTypeInformation -Append
    }
    else {
        $Failures | Export-Csv -Path $FailureCsvPath -NoTypeInformation
    }
    Write-Host "`nA CSV of all failures was saved to: $FailureCsvPath"
}
else {
    Write-Host "`nNo failures found - no CSV created."
}

###############################################################################
# 13. Disconnect from Microsoft Graph
###############################################################################
Disconnect-MgGraph | Out-Null