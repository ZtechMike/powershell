<#
.SYNOPSIS
    This Script will gather information from a Veeam Cloud Connect Server and determine how much space can be offloaded to Capacity Tier in a SOBR configuration
.DESCRIPTION
    Long description
.INPUTS
    Inputs to this cmdlet (if any)
.OUTPUTS
    Output from this cmdlet (if any)
.NOTES

#>
[cmdletbinding()]
param()

# Registering VeeamPSSnapin if necessary
Write-Verbose "Registering Veeam PowerShell Snapin"
$registered = $false
foreach ($snapin in (Get-PSSnapin)) {
    if ($snapin.Name -eq "veeampssnapin") { $registered = $true }
}
if ($registered -eq $false) { Add-PSSnapin VeeamPSSnapin }

# Create ArrayList for output
$aResults = [System.Collections.ArrayList]::new()

# Retrieving all Cloud Connect Tenants
$tenants = Get-VBRCloudTenant

# Looping through tenants
foreach ($tenant in $tenants) {
    Write-Verbose "--------------------------------"
    Write-Verbose "$($tenant.name): Retrieving tenant backup resources"
    $repos = $tenant.Resources.Repository

    foreach ($repo in $repos) {
        # Preventing duplicate efforts
        if ($aResults -match $repo.Id.Guid) {
            Write-Verbose "$($repo.name): Repository already searched, skipping..."
            continue
        }

        Write-Verbose "Analyzing tenant backups located on $($repo.name)"
        $backups = $repo.GetBackups()

        # All backups for all tenants at least on this repo
        foreach ($backup in $backups) {
            #Write-Verbose "$($tenant.name): Analyzing backup job files for $($backup.JobName)"

            # Root element is tenant name
            $name = ($backup.GetFullPathWithTenantFolder()).Elements[0]
            # retrieves all files related to backup
            $files = $backup.GetAllStorages()
            $files += $backup.GetAllChildrenStorages()

            foreach ($file in $files) {
                #Write-Verbose "$($tenant.name): Analyzing file ($($file.FilePath.ToString()))"

                # Determine if file is Full or Incremental
                if ($file.IsFull -eq $true) {
                    $BackupType = 'Full'
                }
                else {
                    $BackupType = 'Incremental'
                }

                # Get VM ID: RegEx matches everything up to character and date string: "D2020-01-01"
                $file.FilePath.ToString() -match "^.*(?=(D\d{4}-\d{2}-\d{2}))" | Out-Null
                $vmID = $Matches[0]

                # Get BackupSize of file
                $backupSizekb = $file.Stats.BackupSize

                # Convert BackupSize from KB to GB
                $backupSizegb = [math]::Round($backupSizekb / 1gb, 2)

                $fileDetail = [PSCustomObject]@{
                    Id           = $file.Id
                    VmId         = $vmID
                    RepoId       = $backup.RepositoryId.Guid
                    Tenant       = $name
                    FileName     = $file.FilePath.ToString()
                    BackupType   = $BackupType
                    BackupSizeGB = $backupSizegb
                    CreationTime = $file.CreationTime
                    GfsPeriod    = $file.GfsPeriod
                    JobName      = $backup.JobName
                }
                # Add data to Array
                $aResults.Add($fileDetail)
            }
        }
    }
}

# Eliminating duplicate files (caused by GetAllStorages & GetAllChildrenStorages)
$aResults = $aResults | Sort-Object -Property Id -Unique

#$datestring = (Get-Date).ToString("s").Replace(":", "-")
#$outfile = "c:\temp\GFSReport_$datestring.csv"
#$aResults | Export-Csv $outfile



return $aResults