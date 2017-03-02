# Copyright 2016 Cloudbase Solutions Srl
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.


function Remove-ExtraStoragePools {
    Update-StorageProviderCache
    # Remove unhealthy storage pools
    $extraStoragePools = Get-StoragePool | Where-Object { $_.IsPrimordial -eq $false -and
                                                          $_.HealthStatus -ne "Healthy" }
    foreach($storagePool in $extraStoragePools) {
        Set-StoragePool -InputObject $storagePool -IsReadOnly:$false -ErrorAction SilentlyContinue
        $storagePool | Get-VirtualDisk | Remove-VirtualDisk -Confirm:$false -ErrorAction SilentlyContinue
        Remove-StoragePool -InputObject $storagePool -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Clear-ExtraDisks {
    Get-PhysicalDisk | Reset-PhysicalDisk -ErrorAction SilentlyContinue
    $extraDisks = Get-Disk | Where-Object { $_.IsBoot -eq $false -and
                                            $_.IsSystem -eq $false -and
                                            $_.Number -ne $null }
    if($extraDisks) {
        $offline = $extraDisks | Where-Object { $_.IsOffline -eq $true }
        if($offline) {
            Set-Disk -InputObject $offline -IsOffline:$False -ErrorAction Stop
        }
        $readonly = $extraDisks | Where-Object { $_.IsReadOnly -eq $true }
        if($readonly) {
            Set-Disk -InputObject $readonly -IsReadOnly:$False -ErrorAction Stop
        }
        $initializedDisks = $extraDisks | Where-Object { $_.PartitionStyle -ne "RAW" }
        if($initializedDisks) {
            Clear-Disk -InputObject $initializedDisks -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
        }
        $extraDisks | ForEach-Object {
            Set-Disk -InputObject $_ -IsReadOnly:$true -ErrorAction Stop
            Set-Disk -InputObject $_ -IsOffline:$true -ErrorAction Stop
        }
    }
}

Export-ModuleMember -Function @(
    'Remove-ExtraStoragePools',
    'Clear-ExtraDisks'
)
