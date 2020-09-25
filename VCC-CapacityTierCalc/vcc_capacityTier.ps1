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

# Get all Tenants in VCC
$tenantlist = Get-VBRCloudTenant -Name "userTestCO1"

# Loop through Tenant List and get info on GFS flagged restore points
Foreach ($tenant in $tenantlist) {

    $repo = $tenant.Resources.RepositoryFriendlyName
    $backups = $tenant.Resources.Repository.GetBackups()
    $files = $backups[0].GetAllChildrenStorages()

    foreach ($file in $files) {

        $gfs = $file.GfsPeriod

        # Get BackupSize of file
        $backupSizekb = $file.Stats.BackupSize

        # Convert BackupSize from KB to GB
        $backupSizegb = [math]::Round($backupSizekb / 1gb, 2)

        if ($gfs -eq 'Weekly') {
            Write-Host $file.FilePath "WEEKLY GFS file" $backupSizegb
            $filedetailW = [PSCustomObject]@{
                Repo = $repo
                FileName = $file.FilePath
                BackupSize = $backupSizegb
                CreationTime = $file.CreationTime
                GfsPeriod = $file.GfsPeriod
            }
            # Add data to Array
            $aResults += $filedetailW
        }elseif ($gfs -eq 'Monthly') {
            Write-Host $file.FilePath "MONTHLY GFS file" $backupSizegb
            $filedetailM = [PSCustomObject]@{
                Repo = $repo
                FileName = $file.FilePath
                BackupSize = $backupSizegb
                CreationTime = $file.CreationTime
                GfsPeriod = $file.GfsPeriod
            }
            # Add data to Array
            $aResults += $filedetailM
        }elseif ($gfs -eq 'Yearly') {
            Write-Host $file.FilePath "YEARLY GFS file" $backupSizegb
            $filedetailY = [PSCustomObject]@{
                Repo = $repo
                FileName = $file.FilePath
                BackupSize = $backupSizegb
                CreationTime = $file.CreationTime
                GfsPeriod = $file.GfsPeriod
            }
            # Add data to Array
            $aResults += $filedetailY
        }else {
            Write-Host $file.FilePath "NOT GFS"
        }
    }
}

$aResults | Export-Csv "C:\temp\vccReport.csv"