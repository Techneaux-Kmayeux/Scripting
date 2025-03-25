<#
.SYNOPSIS
    Performs a hard match for each user in On-Prem AD to Azure AD by setting the OnPremisesImmutableId (Microsoft Graph approach).

.DESCRIPTION
    - Retrieves On-premises AD users (Get-ADUser).
    - Splits the user’s UPN at '@' and re-joins it with @PrimaryDomain.
    - Retrieves the on-premises ObjectGUID, converts it to Base64 for ImmutableID.
    - Attempts to set the OnPremisesImmutableId in Azure AD using Microsoft Graph.
    - If the initial Azure AD UPN isn't found, tries fallback name patterns.
    - Records successes and failures in memory; after finishing, writes a CSV of results and a CSV of failures.
    - Shows whether the user is Enabled or Disabled in on-prem AD (via the 'Enabled' property).

.NOTES
    - Requires: ActiveDirectory and Microsoft Graph modules
    - Test thoroughly in a non-production environment
    - Make sure to run as an account that can install modules (if they are missing),
      and that you authenticate to Graph with the right scopes/permissions
#>

param(
    [string]$FailureCsvPath = "C:\Techneaux\HardLinkScript\HardMatchFailures.csv",
    [string]$SuccessCsvPath = "C:\Techneaux\HardLinkScript\HardMatchSuccessLog.csv",
    [int]$MaxUsers = 20,
    [bool]$FullSend = $false,
    [string]$PrimaryDomain = $null,
    [string]$MSOLDomain = $null
)

###############################################################################
# 1. Validate required parameters
###############################################################################
if (-not $PrimaryDomain) {
    Write-Host "ERROR: You MUST include the Org's Primary Domain. Example: -PrimaryDomain techneaux.com"
    exit 1
}

###############################################################################
# 2. Attempt to install Microsoft.Graph if not present
###############################################################################
try {
    Install-Module Microsoft.Graph -ErrorAction Ignore -Scope CurrentUser
}
catch {
    Write-Host "ERROR: Microsoft Graph Module Failed to Install. Troubleshoot manually then re-run script."
    Exit 2
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
    Exit 3
}

###############################################################################
# 5. Ensure directories for CSV files exist
###############################################################################
$successDirectory = [System.IO.Path]::GetDirectoryName($SuccessCsvPath)
$failureDirectory = [System.IO.Path]::GetDirectoryName($FailureCsvPath)

if (-not (Test-Path $successDirectory)) {
    Write-Host "Directory $successDirectory does not exist. Creating..."
    New-Item -ItemType Directory -Force -Path $successDirectory | Out-Null
}
if (-not (Test-Path $failureDirectory)) {
    Write-Host "Directory $failureDirectory does not exist. Creating..."
    New-Item -ItemType Directory -Force -Path $failureDirectory | Out-Null
}

###############################################################################
# 6. Retrieve On-Prem AD users
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
# 7. Prepare a collection to store output results
###############################################################################
$Results = @()

###############################################################################
# 8. Process each On-Prem user
###############################################################################
foreach ($user in $OnPremUsers) {

    # Skip if there's no UPN at all
    if (-not $user.UserPrincipalName) {
        Write-Warning "Skipping user $($user.SamAccountName) - no UPN found."
        continue
    }

    # Gather name details for fallback logic
    $onPremFirstName = $user.GivenName
    $onPremLastName  = $user.Surname
    $onPremMiddle    = $user.MiddleName  # or $user.Initials

    # Construct initial Azure AD UPN: localPart + @PrimaryDomain
    $localPart  = $user.UserPrincipalName.Split('@')[0]
    $azureADUPN = "$localPart@$PrimaryDomain"

    # Try initial approach
    try {
        # -ErrorAction Stop ensures 404 or other errors become terminating
        $azureUser = Get-MgUser -UserId $azureADUPN -ErrorAction Stop
    }
    catch {
        # If not found or error, set $azureUser to null
        $azureUser = $null
    }

    # If initial attempt fails, try fallback patterns (only if we have first + last name)
    if (-not $azureUser) {
        if ($onPremFirstName -and $onPremLastName) {
            # Build an array of candidate UPNs
            $candidateUPNs = @()

            # 1. firstName@domain
            $candidateUPNs += "$onPremFirstName@$PrimaryDomain"

            # 2. firstInitial + lastName
            if ($onPremFirstName.Length -ge 1 -and $onPremLastName.Length -ge 1) {
                $candidateUPNs += ("{0}{1}@{2}" -f $onPremFirstName.Substring(0,1), $onPremLastName, $PrimaryDomain)
            }

            # 3. firstInitial + middleInitial + lastName (if middle is present)
            if ($onPremMiddle -and $onPremMiddle.Length -ge 1 -and $onPremFirstName.Length -ge 1 -and $onPremLastName.Length -ge 1) {
                $candidateUPNs += ("{0}{1}{2}@{3}" -f $onPremFirstName.Substring(0,1), $onPremMiddle.Substring(0,1), $onPremLastName, $PrimaryDomain)
            }

            # 4. firstName + lastNameInitial
            if ($onPremLastName -and $onPremLastName.Length -ge 1) {
                $candidateUPNs += ("{0}{1}@{2}" -f $onPremFirstName, $onPremLastName.Substring(0,1), $PrimaryDomain)
            }

            # 5. firstName.lastName
            $candidateUPNs += ("{0}.{1}@{2}" -f $onPremFirstName, $onPremLastName, $PrimaryDomain)

            # Try each pattern in order
            foreach ($candidate in $candidateUPNs) {
                Write-Verbose "Trying alternative UPN: $candidate"
                try {
                    $potentialUser = Get-MgUser -UserId $candidate -ErrorAction Stop -Property GivenName,Surname
                }
                catch {
                    # 404 or other error means not found, move on
                    $potentialUser = $null
                }

                if ($potentialUser) {
                    # Found a user, now validate first/last name match
                    if (
                        $potentialUser.GivenName -eq $onPremFirstName -and
                        $potentialUser.Surname   -eq $onPremLastName
                    ) {
                        Write-Verbose "Found matching Azure AD user via alternative UPN: $candidate"
                        # Update the azureADUPN to our candidate and break
                        $azureADUPN = $candidate
                        break
                    }
                    else {
                        Write-Verbose "User found but name mismatch. Continuing..."
                    }
                }
            } # end foreach candidate
        } # end if we have first+last
    } # end if not $azureUser

    # Convert the on-prem AD ObjectGUID to base64
    $immutableId = [System.Convert]::ToBase64String($user.ObjectGUID.ToByteArray())

    # Now do the final get/update with erroraction stop. If user doesn't exist, we catch + mark fail
    try {
        # Retrieve the user again (or for the first time, if fallback found them).
        $PriorId = Get-MgUser -UserId $azureADUPN -Property OnPremisesImmutableId -ErrorAction Stop |
                   Select-Object -ExpandProperty OnPremisesImmutableId

        # Attempt to set OnPremisesImmutableId
        Update-MgUser -UserId $azureADUPN -OnPremisesImmutableId $immutableId -ErrorAction Stop

        # Record success
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
        # Record failure
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
} # end foreach user

###############################################################################
# 9. Output final results
###############################################################################
Write-Host "`n--- Summary of Hard Matching Operations ---"
$Results | Format-Table -AutoSize

# Export all results
$Results | Export-Csv -Path $SuccessCsvPath -NoTypeInformation
Write-Host "`nA CSV of all operations was saved to: $SuccessCsvPath"

# Export only failures
$Failures = $Results | Where-Object { $_.Status -eq "FAILED" }
if ($Failures) {
    $Failures | Export-Csv -Path $FailureCsvPath -NoTypeInformation
    Write-Host "`nA CSV of all failures was saved to: $FailureCsvPath"
}
else {
    Write-Host "`nNo failures found - no CSV created."
}

###############################################################################
# 10. Disconnect from Microsoft Graph (suppress output)
###############################################################################
Disconnect-MgGraph | Out-Null