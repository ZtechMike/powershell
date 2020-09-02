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

# Add VeeamPSSnapin
Add-PSSnapin VeeamPSSnapin

# Create Array for PSObject
$aResults = @()

$tenantlist = get-vbrcloudtenant

$tenant = $tenantlist[0]

#foreach ($tenant in $tenantlist) {
    
    $repos = $tenant.Resources.Repository

    foreach ($repo in $repos) { 
        $backups = $repo.GetBackups()
        $backups = $backups | Where-Object { $_.IsChildBackup -eq $true }
    
        # All backups for all tenants at least on this repo
        foreach ($backup in $backups) {
            # Root element is tenant name 
            $name = ($backup.GetFullPathWithTenantFolder()).Elements[0]
            # retrieves all files related to backup 
            $files = $backup.GetAllStorages()
        
            foreach ($file in $files) {
                # Get GFS Flag of File
                $gfs = $file.GfsPeriod

                # Determine if file is Full or Incremental
                if ($file.IsFull -eq $true) {
                    $BackupType = 'Full'
                }
                else {
                    $BackupType = 'Incremental'
                }

                # Get VM ID
                $file.FilePath -match "^([^.]+)" > $null
                $vmID = $Matches[0]
            
                # Get BackupSize of file
                $backupSizekb = $file.Stats.BackupSize
    
                # Convert BackupSize from KB to GB
                $backupSizegb = [math]::Round($backupSizekb / 1gb, 2)
            
                if ($gfs -ne 'none') {
                    Write-Host $file.FilePath " GFS file" $backupSizegb
                    $filedetailGFS = [PSCustomObject]@{
                        Tenant       = $name
                        vmID         = $vmID
                        FileName     = $file.FilePath
                        BackupType   = $BackupType
                        BackupSize   = $backupSizegb
                        CreationTime = $file.CreationTime
                        GfsPeriod    = $file.GfsPeriod
                        JobName      = $backup.JobName
                    }
                    # Add data to Array
                    $aResults += $filedetailGFS
                }
                else {
                    Write-Host $file.FilePath " NOT GFS"
                    $filedetailNOTGFS = [PSCustomObject]@{
                        Tenant       = $name
                        vmID         = $vmID
                        FileName     = $file.FilePath
                        BackupType   = $BackupType
                        BackupSize   = $backupSizegb
                        CreationTime = $file.CreationTime
                        GfsPeriod    = $file.GfsPeriod
                        JobName      = $backup.JobName
                    }
                    # Add data to Array
                    $aResults += $filedetailNOTGFS
                }
            }
        }
    }
#}

$datestring = (Get-Date).ToString("s").Replace(":", "-")
$outfile = "c:\temp\GFSReport_$datestring.csv"

$aResults | Export-Csv $outfile