<#
.SYNOPSIS
    Performs a hard match for each user in On-Prem AD to Azure AD by setting the OnPremisesImmutableId using Microsoft Graph.

.DESCRIPTION
    - Retrieves on-premises AD users (Get-ADUser).
    - Constructs an Azure AD UPN from the on-prem UPN and the provided PrimaryDomain.
    - Converts the on-prem AD ObjectGUID to a Base64 string (ImmutableID).
    - Retrieves all Azure AD users once and builds a dictionary for fast lookups.
    - If the standard UPN isn’t found, attempts fallback UPN patterns (using first name, initials, etc.) and verifies via name match.
    - Updates the matching Azure AD user’s OnPremisesImmutableId.
    - Logs successes and failures to CSV.
    - At the end, produces a report (CSV) listing Azure AD users that were NOT found in the on-prem AD list.
    
.NOTES
    - Requires: ActiveDirectory and Microsoft Graph modules.
    - Run with an account that can install modules and authenticate to Graph.
    - Test thoroughly in a non-production environment.
#>

param(
    [string]$FailureCsvPath = "C:\Techneaux\HardLinkScript\HardMatchFailures.csv",
    [string]$SuccessCsvPath = "C:\Techneaux\HardLinkScript\HardMatchSuccessLog.csv",
    [string]$OrphanReportCsvPath = "C:\Techneaux\HardLinkScript\AzureNotInAD.csv",
    [int]$MaxUsers = 20,
    [bool]$FullSend = $false,
    [string]$PrimaryDomain = $null,
    [string]$MSOLDomain = $null
)

###############################################################################
# 1. Validate required parameters
###############################################################################
if (-not $PrimaryDomain) {
    Write-Warning "ERROR: You MUST include the Org's Primary Domain. Example: -PrimaryDomain techneaux.com"
    exit 1
}

###############################################################################
# 2. Install Microsoft.Graph module if needed
###############################################################################
try {
    Install-Module Microsoft.Graph -ErrorAction Ignore -Scope CurrentUser
}
catch {
    Write-Warning "ERROR: Microsoft Graph Module Failed to Install. Troubleshoot manually then re-run script."
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
    Write-Warning "ERROR: Failed to Connect to MgGraph. Troubleshoot manually then re-run."
    exit 3
}

###############################################################################
# 5. Verify PrimaryDomain against tenant’s default domain
###############################################################################
try {
    # Retrieve organization info; the verifiedDomains property contains the default domain.
    $org = Get-MgOrganization -ErrorAction Stop
    $defaultDomain = ($org.VerifiedDomains | Where-Object { $_.IsDefault -eq $true }).Name
}
catch {
    Write-Warning "ERROR: Could not retrieve organization domain information."
    exit 5
}

if ($PrimaryDomain.ToLower() -ne $defaultDomain.ToLower()) {
    Write-Host "WARNING: The PrimaryDomain you provided ('$PrimaryDomain') does not match the tenant's default domain ('$defaultDomain')."
    $response = Read-Host "Would you like to continue? (Y/N)"
    if ($response -notin @("Y","y")) {
        Write-Warning "User opted to exit due to domain mismatch."
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
    Write-Warning "ERROR: Failed to retrieve Azure AD users. Exiting."
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
$ProcessedUPNs = @()  # will hold the converted UPNs from on-prem users

###############################################################################
# 10. Process each on-prem AD user
###############################################################################
foreach ($user in $OnPremUsers) {

    # Skip if no UPN exists
    if (-not $user.UserPrincipalName) {
        Write-Warning "Skipping user $($user.SamAccountName) - no UPN found."
        continue
    }
    
    # Get on-prem name details
    $onPremFirstName = $user.GivenName
    $onPremLastName  = $user.Surname
    $onPremMiddle    = $user.MiddleName  # (or use $user.Initials if preferred)
    
    # Construct primary Azure AD UPN from on-prem UPN (local part + provided PrimaryDomain)
    $localPart = $user.UserPrincipalName.Split('@')[0]
    $azureADUPN = "$localPart@$PrimaryDomain"
    
    # Track this converted UPN (in lowercase for consistent matching)
    $ProcessedUPNs += $azureADUPN.ToLower()
    
    # Attempt lookup in our Azure AD dictionary
    $azureUser = $AzureUsersByUPN[$azureADUPN.ToLower()]
    
    # If not found, try fallback patterns (only if first and last names exist)
    if (-not $azureUser -and $onPremFirstName -and $onPremLastName) {
        $candidateUPNs = @()
        # Pattern 1: firstName@domain
        $candidateUPNs += "$onPremFirstName@$PrimaryDomain"
        # Pattern 2: firstInitial + lastName@domain
        if ($onPremFirstName.Length -ge 1 -and $onPremLastName.Length -ge 1) {
            $candidateUPNs += ("{0}{1}@{2}" -f $onPremFirstName.Substring(0,1), $onPremLastName, $PrimaryDomain)
        }
        # Pattern 3: firstInitial + middleInitial + lastName@domain (if middle exists)
        if ($onPremMiddle -and $onPremMiddle.Length -ge 1 -and $onPremFirstName.Length -ge 1 -and $onPremLastName.Length -ge 1) {
            $candidateUPNs += ("{0}{1}{2}@{3}" -f $onPremFirstName.Substring(0,1), $onPremMiddle.Substring(0,1), $onPremLastName, $PrimaryDomain)
        }
        # Pattern 4: firstName + lastNameInitial@domain
        if ($onPremLastName.Length -ge 1) {
            $candidateUPNs += ("{0}{1}@{2}" -f $onPremFirstName, $onPremLastName.Substring(0,1), $PrimaryDomain)
        }
        # Pattern 5: firstName.lastName@domain
        $candidateUPNs += ("{0}.{1}@{2}" -f $onPremFirstName, $onPremLastName, $PrimaryDomain)
        
        foreach ($candidate in $candidateUPNs) {
            Write-Verbose "Trying alternative UPN: $candidate"
            $potentialUser = $AzureUsersByUPN[$candidate.ToLower()]
            if ($potentialUser) {
                # Verify name match
                if ($potentialUser.GivenName -eq $onPremFirstName -and $potentialUser.Surname -eq $onPremLastName) {
                    Write-Verbose "Found matching Azure AD user via alternative UPN: $candidate"
                    $azureADUPN = $candidate
                    $azureUser = $potentialUser
                    break
                }
                else {
                    Write-Verbose "User found via candidate UPN but name mismatch. Continuing..."
                }
            }
        }
    }
    
    # Convert the on-prem AD ObjectGUID to a Base64 string
    $immutableId = [System.Convert]::ToBase64String($user.ObjectGUID.ToByteArray())
    
    # If no matching Azure AD user was found, record failure and continue to next user
    if (-not $azureUser) {
        $Results += [pscustomobject]@{
            OnPremUser    = $user.UserPrincipalName
            AzureADUser   = $azureADUPN
            Status        = "FAILED"
            Reason        = "User not found in Azure AD"
            OnPremEnabled = $user.Enabled
            NewID         = $immutableId
            PreviousID    = $null
        }
        Write-Warning "FAILED: $($user.UserPrincipalName) => $azureADUPN : User not found in Azure AD"
        continue
    }
    
    # Retrieve previous OnPremisesImmutableId from the found Azure user
    $PriorId = $azureUser.OnPremisesImmutableId
    
    # Attempt to update the Azure AD user with the new OnPremisesImmutableId
    try {
        Update-MgUser -UserId $azureADUPN -OnPremisesImmutableId $immutableId -ErrorAction Stop
        
        $Results += [pscustomobject]@{
            OnPremUser    = $user.UserPrincipalName
            AzureADUser   = $azureADUPN
            Status        = "SUCCESS"
            Reason        = ""
            OnPremEnabled = $user.Enabled
            NewID         = $immutableId
            PreviousID    = $PriorId
        }
        
        Write-Host "SUCCESS: Set OnPremisesImmutableId for $($user.UserPrincipalName) => $azureADUPN"
    }
    catch {
        $Results += [pscustomobject]@{
            OnPremUser    = $user.UserPrincipalName
            AzureADUser   = $azureADUPN
            Status        = "FAILED"
            Reason        = $_.Exception.Message
            OnPremEnabled = $user.Enabled
            NewID         = $immutableId
            PreviousID    = $PriorId
        }
        Write-Warning "FAILED: $($user.UserPrincipalName) => $azureADUPN : $($_.Exception.Message)"
    }
}

###############################################################################
# 11. Cross-reference: Identify Azure users not present in on-prem AD
###############################################################################
$OrphanedAzureUsers = @()
foreach ($key in $AzureUsersByUPN.Keys) {
    if (-not ($ProcessedUPNs -contains $key)) {
        $OrphanedAzureUsers += $AzureUsersByUPN[$key]
    }
}

if ($OrphanedAzureUsers.Count -gt 0) {
    Write-Host "`nFound $($OrphanedAzureUsers.Count) Azure AD user(s) that were NOT present in on-prem AD."
    $OrphanedAzureUsers | Export-Csv -Path $OrphanReportCsvPath -NoTypeInformation
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

# Export all operations to CSV
$Results | Export-Csv -Path $SuccessCsvPath -NoTypeInformation
Write-Host "`nA CSV of all operations was saved to: $SuccessCsvPath"

# Export failures, if any exist
$Failures = $Results | Where-Object { $_.Status -eq "FAILED" }
if ($Failures) {
    $Failures | Export-Csv -Path $FailureCsvPath -NoTypeInformation
    Write-Host "`nA CSV of all failures was saved to: $FailureCsvPath"
}
else {
    Write-Host "`nNo failures found - no CSV created."
}

###############################################################################
# 13. Disconnect from Microsoft Graph (suppress output)
###############################################################################
Disconnect-MgGraph | Out-Null