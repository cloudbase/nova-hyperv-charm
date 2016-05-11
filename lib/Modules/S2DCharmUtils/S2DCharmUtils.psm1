#
# Copyright 2015-2016 Cloudbase Solutions SRL
#

$ErrorActionPreference = "Stop"

Import-Module ADCharmUtils
Import-Module WSFCCharmUtils
Import-Module JujuHooks

$COMPUTERNAME = [System.Net.Dns]::GetHostName()


function Remove-UnhealthyStoragePools {
    # NOTE(ibalutoiu):
    #     After you reinstall the OS and you still have the extra disks that
    #     formed a storage pool before, this one is listed with "Unknown" status and
    #     read-only mode. After disabling read-only flag, the storage pool becomes
    #     "Unhealthy" and it's unusable.
    $unknownReadOnly = Get-StoragePool | Where-Object { ($_.HealthStatus -eq "Unknown") -and ($_.IsReadOnly -eq $true) }
    foreach($pool in $unknownReadOnly) {
        Set-StoragePool -InputObject $pool -IsReadOnly $false
    }
    $unhealthyReadOnly = Get-StoragePool | Where-Object { $_.HealthStatus -eq "Unhealthy" }
    foreach($pool in $unknownReadOnly) {
        Remove-StoragePool -InputObject $pool -Confirm:$false
    }
}

function Clear-ExtraDisks {
    $extraDisks = Get-Disk | Where-Object { $_.IsBoot -eq $false -and
                                            $_.IsSystem -eq $false -and
                                            $_.Number -ne $null }
    if($extraDisks) {
        $offline = $extraDisks | Where-Object { $_.IsOffline -eq $true }
        if($offline) {
            Set-Disk -InputObject $offline -IsOffline:$False
        }
        $readonly = $extraDisks | Where-Object { $_.IsReadOnly -eq $true }
        if($readonly){
            Set-Disk -InputObject $readonly -IsReadOnly:$False
        }
        $initializedDisks = $extraDisks | Where-Object { $_.PartitionStyle -ne "RAW" }
        if($initializedDisks) {
            Clear-Disk -InputObject $initializedDisks -RemoveData -RemoveOEM -Confirm:$false
        }
    }
}

function Start-S2DRelationChangedHook {
    $adCtxt = Get-ActiveDirectoryContext
    if (!$adCtxt.Count) {
        Write-JujuLog "Delaying the S2D relation changed hook until AD context is ready"
        return
    }
    $wsfcCtxt = Get-WSFCContext
    if (!$wsfcCtxt.Count) {
        Write-JujuLog "Delaying the S2D relation changed hook until WSFC context is ready"
        return
    }
    $settings = @{
        'ready' = $true;
        'computername' = $COMPUTERNAME;
        'joined-cluster-name' = $wsfcCtxt['cluster-name']
    }
    $rids = Get-JujuRelationIds -Relation 's2d'
    foreach ($rid in $rids) {
        $ret = Set-JujuRelation -RelationId $rid -Settings $settings
        if ($ret -ne $true) {
            Write-JujuWarning "Failed to set S2D relation context."
        }
    }
}
