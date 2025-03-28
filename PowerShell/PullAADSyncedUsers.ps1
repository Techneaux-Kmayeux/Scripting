<#
.SYNOPSIS
    Exports all Azure AD users who have "On-premises sync enabled" = True.
    Optionally attempts to look up their matching on-prem user in AD by decoding OnPremisesImmutableId.

.DESCRIPTION
    - Retrieves all Azure AD users with .OnPremisesSyncEnabled = $true.
    - Exports them to a CSV with DisplayName, UserPrincipalName, and OnPremisesImmutableId.
    - If OnPremisesImmutableId is present, decodes it and uses Get-ADUser to find the matching AD user (by GUID).
    - Adds columns for the AD user's CN and SamAccountName if found.
#>

# 1) Connect to Graph (if not already done):
Connect-MgGraph -Scopes "User.Read.All"
# or if already connected in your session, skip

# 2) Retrieve all AAD users with OnPremisesSyncEnabled = $true
Write-Host "Retrieving Azure AD users who are OnPremisesSyncEnabled..."
$allSynced = Get-MgUser -All -Property DisplayName,UserPrincipalName,OnPremisesSyncEnabled,OnPremisesImmutableId `
             | Where-Object { $_.OnPremisesSyncEnabled -eq $true }

Write-Host "Found $($allSynced.Count) users with OnPremisesSyncEnabled = True."

# 3) For each user, optionally decode the OnPremisesImmutableId and look up in AD
$results = foreach ($u in $allSynced) {

    # We'll decode the OnPremisesImmutableId if it exists
    $decodedGuid = $null
    $adCN        = $null
    $adSam       = $null

    if ($u.OnPremisesImmutableId) {
        try {
            # Decode from Base64 => raw GUID bytes => construct a Guid object
            $guidBytes = [System.Convert]::FromBase64String($u.OnPremisesImmutableId)
            $decodedGuid = New-Object Guid($guidBytes)

            # Attempt to find the AD user with that GUID
            $adUser = Get-ADUser -Filter { ObjectGUID -eq $decodedGuid } -Properties SamAccountName, CN -ErrorAction SilentlyContinue

            if ($adUser) {
                $adCN  = $adUser.CN
                $adSam = $adUser.SamAccountName
            }
        }
        catch {
            Write-Warning "Failed to decode OnPremisesImmutableId or find AD user for $($u.UserPrincipalName): $($_.Exception.Message)"
        }
    }

    # Construct an output object
    [pscustomobject]@{
        DisplayName           = $u.DisplayName
        UserPrincipalName     = $u.UserPrincipalName
        OnPremisesImmutableId = $u.OnPremisesImmutableId
        DecodedGUID           = $decodedGuid
        AD_CN                 = $adCN
        AD_SamAccountName     = $adSam
    }
}

# 4) Export to CSV
$csvPath = "C:\Temp\OnPremSyncEnabled_Users.csv"
$results | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "Exported $($results.Count) users to $csvPath"

# 5) (Optional) Disconnect if you want
# Disconnect-MgGraph