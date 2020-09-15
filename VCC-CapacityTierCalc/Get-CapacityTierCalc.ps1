<#
.SYNOPSIS
    Estimates Capacity Tier size for new SOBR
.DESCRIPTION
    This script will gather information from a Veeam Cloud Connect Server and estimate how much space can be offloaded to Capacity Tier in a SOBR configuration. NOTE: This can only be used for a Standard Backup Repository or a SOBR where Capacity Tier is currently disabled.
.PARAMETER DAYS
    Number of days to keep backups in the Performance Tier before moving them to the Capacity Tier (object storage)
.OUTPUTS
    Get-CapacityTierCalc returns a PowerShell object containing Capacity Tier size report
.EXAMPLE
    Get-CapacityTierCalc.ps1 -Days 7

    Description
    -----------
    Generate a Capacity Tier size report using the specified Days as the offload period
.EXAMPLE
    Get-CapacityTierCalc.ps1 -Days 14 -Verbose

    Description
    -----------
    Verbose output is supported
.NOTES
    NAME:  Get-CapacityTierCalc.ps1
    VERSION: 1.0
    AUTHOR: Mike Zollmann, Chris Arceneaux
    TWITTER: @ZtechMike, @chris_arceneaux
    GITHUB: https://github.com/ZtechMike
    GITHUB: https://github.com/carceneaux
.LINK
    https://arsano.ninja/
.LINK
    https://helpcenter.veeam.com/docs/backup/vsphere/capacity_tier_inactive_backup_chain.html?ver=100
.LINK
    https://helpcenter.veeam.com/docs/backup/vsphere/new_capacity_tier.html?ver=100
#>
#Requires -Version 5.1
[cmdletbinding()]
param(
    [Parameter(Mandatory = $true)]
    [int] $Days = $true
)

# Registering VeeamPSSnapin if necessary
Write-Verbose "Registering Veeam PowerShell Snapin"
$registered = $false
foreach ($snapin in (Get-PSSnapin)) {
    if ($snapin.Name -eq "veeampssnapin") { $registered = $true }
}
if ($registered -eq $false) { Add-PSSnapin VeeamPSSnapin }

# Creating empty ArrayList
$aResults = [System.Collections.ArrayList]::new()
$repoList = [System.Collections.ArrayList]::new()

##### Data collection begins here #####
Write-Verbose "################################"
Write-Verbose "Starting data collection..."

# Retrieving Cloud Connect Information
$tenants = Get-VBRCloudTenant
$repoList.Add((Get-VBRBackupRepository)) | Out-Null
$repoList.Add((Get-VBRBackupRepository -ScaleOut)) | Out-Null

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

        Write-Verbose "Retrieving tenant backups located on $($repo.name)"
        $backups = $repo.GetBackups() #undocumented API call

        # All backups for all tenants at least on this repo
        foreach ($backup in $backups) {
            #Write-Verbose "$($tenant.name): Analyzing backup job files for $($backup.JobName)"

            # Root element is tenant name
            $name = ($backup.GetFullPathWithTenantFolder()).Elements[0]
            # Below conditional accounts for some backups jobs have the Veeam server as the first element
            if ($name -notmatch ($tenants.name -join '|')) {
                $name = ($backup.GetFullPathWithTenantFolder()).Elements[1]
            }

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

                # Retrieve repository information
                $repoName = $repo.Name
                $type = ($repoList | Where-Object {$_.Id.Guid -eq $backup.RepositoryId.Guid}).GetType().Name
                if ("VBRScaleOutBackupRepository" -eq $type) {
                    $sobr = $true
                } else {
                    $sobr = $false
                }

                $fileDetail = [PSCustomObject]@{
                    Id             = $file.Id.Guid
                    VmId           = $vmID
                    RepoId         = $backup.RepositoryId.Guid
                    RepoName       = $repoName
                    SOBR           = $sobr
                    Tenant         = $name
                    FileName       = $file.FilePath.ToString()
                    BackupType     = $BackupType
                    BackupSizeGB   = $backupSizegb
                    CreationTime   = $file.CreationTime
                    GfsPeriod      = $file.GfsPeriod
                    JobName        = $backup.JobName
                    BackupId       = $backup.Id.Guid
                    IsChildBackup  = $backup.IsChildBackup
                    ParentBackupId = $backup.ParentBackupId.Guid
                }
                # Add data to ArrayList
                $aResults.Add($fileDetail) | Out-Null
            }
        }
    }
}

# Eliminating duplicate files (caused by GetAllStorages & GetAllChildrenStorages)
$aResults = $aResults | Sort-Object -Property Id -Unique

##### Parsing data & applying logic for final report #####
Write-Verbose "################################"
Write-Verbose "Data collection complete: Applying logic for final report"

# Get current time
$current = Get-Date
# Creating empty ArrayList
$offload = [System.Collections.ArrayList]::new()

# Determine if GFS or not
Write-Verbose "Sorting backups GFS vs non-GFS..."
$gfs = $aResults | Where-Object { $_.GfsPeriod -ne "None" }
$notGfs = $aResults | Where-Object { $_.GfsPeriod -eq "None" }
Write-Verbose "GFS: $($gfs.count) - Non-GFS: $($notGfs.count) - Total: $($aResults.count)"

### GFS
# Is older than $Days?
$offload_gfs = $gfs | Where-Object { (New-TimeSpan $_.CreationTime $current).TotalDays -gt $Days }
foreach ($item in $offload_gfs) {
    $offload.Add($item) | Out-Null
}

### NOT GFS
# Matching Parent/Child JobNames - makes sure backup chains are complete
for ($i = 0; $i -le $notGfs.count; $i++) {
    if ($notGfs[$i].IsChildBackup) {
        # Child backup found - Searching for parent
        $name = ($notGfs | Where-Object { $_.BackupId -eq ($notGfs[$i].ParentBackupId) }).JobName
        # Parent backup found - Updating JobName to match parent
        $notGfs[$i].JobName = $name
    }
}

# Looping through tenants
$tenants = ($notGfs | Select-Object Tenant -Unique).Tenant
foreach ($tenant in $tenants) {
    Write-Verbose "--------------------------------"

    # Looping through tenant backup jobs
    $jobs = ($notGfs | Where-Object { $_.Tenant -eq $tenant } | Select-Object JobName -Unique).JobName
    Write-Verbose "$($tenant): Analyzing $($jobs.count) backup jobs"
    foreach ($job in $jobs) {
        # Initializing variable
        $inactive = $null

        # Identifying all files belonging to job
        $files = $notGfs | Where-Object { ($_.Tenant -eq $tenant) -and ($_.JobName -eq $job) }
        # Finding latest full backup for job
        $latest = $files | Sort-Object CreationTime -Descending | Select-Object -First 1

        # Determine inactive chains - different logic depending on job backup mode
        # https://helpcenter.veeam.com/docs/backup/vsphere/capacity_tier_inactive_backup_chain.html?ver=100
        if ($files.FileName -match ".vib") {
            # Backup Mode: Forward Incremental
            # Finding all backups previous to the most recent full backup
            $inactive = ($files | Where-Object { (New-TimeSpan $_.CreationTime $latest.CreationTime).TotalSeconds -gt 0 })
        }
        elseif ($files.FileName -match ".vrb") {
            # Backup Mode: Reverse Incremental
            # Finding all backups previous to the most recent full backup
            $files = $files | Where-Object { (New-TimeSpan $_.CreationTime $latest.CreationTime).TotalSeconds -le 0 } | Sort-Object CreationTime -Descending  #sort newest to oldest
            # Finding where inactive chain begins
            switch ($true) {
                ("Full" -eq $files[0].BackupType) {
                    #inactive chain begins on this full backup
                    $inactive = $files
                    break
                }
                ("Full" -eq $files[1].BackupType) {
                    #inactive chain begins on this full backup
                    $inactive = $files | Where-Object { $_.Id -ne $files[0].Id }
                    break
                }
                default {
                    #inactive chain begins after most recent full backup and 2 incrementals
                    $inactive = $files | Where-Object { ($_.Id -ne $files[0].Id) -and ($_.Id -ne $files[1].Id) }
                    break
                }
            }
        }
        else {
            # Jobs with only full backups: Backup Mode doesn't matter
            $inactive = $files
        }

        # Which files of inactive chain(s) are older than $Days?
        $offload_nonGfs = $inactive | Where-Object { (New-TimeSpan $_.CreationTime $current).TotalDays -gt $Days }
        if ($offload_nonGfs) {
            foreach ($item in $offload_nonGfs) {
                $offload.Add($item) | Out-Null
            }
        }
    }
}

# Sample output format
#Repository | SOBR | GFS | Sealed | Unsealed | CapacityTierGB

# Creating empty ArrayList
$output = [System.Collections.ArrayList]::new()

# Looping through repositories
$repos = ($offload | Select-Object RepoName -Unique).RepoName
Write-Verbose "###### Backups to be offloaded ######"
foreach ($repo in $repos) {
    $sobr = ($offload | Where-Object { $_.RepoName -eq $repo } | Select-Object -First 1).SOBR
    $gfsCount = @($offload | Where-Object { ($_.RepoName -eq $repo) -and ($_.GfsPeriod -ne "None") }).count
    $nonGfsCount = @($offload | Where-Object { ($_.RepoName -eq $repo) -and ($_.GfsPeriod -eq "None") }).count

    Write-Verbose "Repository: $repo"
    Write-Verbose "GFS: $gfsCount"
    Write-Verbose "Non-GFS: $nonGfsCount"

    # Summing up totals
    $gfsSizeGB = ($offload | Where-Object { ($_.RepoName -eq $repo ) -and ($_.GfsPeriod -ne "None") } | Measure-Object BackupSizeGB -Sum).Sum
    $nonGfsSizeGB = ($offload | Where-Object { ($_.RepoName -eq $repo) -and ($_.GfsPeriod -eq "None") } | Measure-Object BackupSizeGB -Sum).Sum

    $row = [PSCustomObject]@{
        Repository   = $repo
        SOBR         = $sobr
        GfsSizeGB    = if ($gfsSizeGB){ $gfsSizeGB } else { 0 }
        NonGfsSizeGB = if ($nonGfsSizeGB){ $nonGfsSizeGB } else { 0 }
    }
    # Add data to output
    $output.Add($row) | Out-Null
}
Write-Verbose "Total amount to be offloaded: $(($offload | Measure-Object BackupSizeGB -Sum).Sum)GB"
Write-Verbose "################################"
Write-Warning "Output values are estimates and will vary depending on the data being backed up. GFS backups can achieve the greatest block clone space savings up to/and over 90%. This tool can only provide estimates and not hard numbers."

return $output