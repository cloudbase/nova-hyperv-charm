# Copyright 2014-2016 Cloudbase Solutions Srl
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

Import-Module JujuHooks
Import-Module JujuWindowsUtils
Import-Module Networking


function Get-NetType {
    $netType = Get-JujuCharmConfig -Scope "network-type"
    if(Get-IsNanoServer) {
        # Force hyperv network manager for versions that do not support OVS
        $netType = "hyperv"
    }
    return $netType
}

function Get-JujuVMSwitch {
    $VMswitchName = Get-JujuCharmConfig -Scope "vmswitch-name"
    if (!$VMswitchName){
        return "br100"
    }
    return $VMswitchName
}

function Get-InterfaceFromConfig {
    Param(
        [string]$ConfigOption="data-port",
        [switch]$MustFindAdapter=$false
    )

    $nic = $null
    $DataInterfaceFromConfig = Get-JujuCharmConfig -Scope $ConfigOption
    Write-JujuInfo "Looking for $DataInterfaceFromConfig"
    if (!$DataInterfaceFromConfig){
        if($MustFindAdapter) {
            Throw "No data-port was specified"
        }
        return $null
    }
    $byMac = @()
    $byName = @()
    $macregex = "^([a-f-A-F0-9]{2}:){5}([a-fA-F0-9]{2})$"
    foreach ($i in $DataInterfaceFromConfig.Split()){
        if ($i -match $macregex){
            $byMac += $i.Replace(":", "-")
        }else{
            $byName += $i
        }
    }
    if ($byMac.Length){
        $nicByMac = Get-NetAdapter | Where-Object { $_.MacAddress -in $byMac -and $_.DriverFileName -ne "vmswitch.sys" }
    }
    if ($byName.Length){
        $nicByName = Get-NetAdapter | Where-Object { $_.Name -in $byName }
    }
    if ($nicByMac -ne $null) {
        if ($nicByMac.GetType() -ne [System.Array]) {
            $nicByMac = @($nicByMac)
        }
    } else {
        $nicByMac = @()
    }
    if ($nicByName -ne $null) {
        if ($nicByName.GetType() -ne [System.Array]) {
            $nicByName = @($nicByName)
        }
    } else {
        $nicByName = @()
    }
    $ret = $nicByMac + $nicByName
    if ($ret.Length -eq 0 -and $MustFindAdapter){
        Throw "Could not find network adapters"
    }
    $ret | Enable-Netadapter | Out-Null
    return $ret
}

function Get-FallbackNetadapter {
    $name = Get-MainNetadapter
    $net = Get-NetAdapter -Name $name
    return $net
}

function Get-RealInterface {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [Microsoft.Management.Infrastructure.CimInstance]$interface
    )
    PROCESS {
        if($interface.DriverFileName -ne "vmswitch.sys") {
            return $interface
        }
        $realInterface = Get-NetAdapter | Where-Object {
            $_.MacAddress -eq $interface.MacAddress -and $_.ifIndex -ne $interface.ifIndex
        }

        if(!$realInterface){
            Throw "Failed to find interface attached to VMSwitch"
        }
        return $realInterface[0]
    }
}

function Wait-ForBondUp {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$bond
    )

    $b = Get-NetLbfoTeam -Name $bond -ErrorAction SilentlyContinue
    if (!$b){
        Write-JujuLog "Bond interface $bond not found"
        return $false
    }
    Write-JujuLog "Found bond: $bond"
    $count = 0
    while ($count -lt 30){
        Write-JujuLog ("Bond status is " + $b.Status)
        $b = Get-NetLbfoTeam -Name $bond -ErrorAction SilentlyContinue
        if ($b.Status -eq "Up" -or $b.Status -eq "Degraded"){
            Write-JujuLog ("bond interface status is " + $b.Status)
            return $true
        }
        Start-Sleep 1
        $count ++
    }
    return $false
}

function New-BondInterface {
    if(Get-IsNanoServer) {
        # Not supported on Nano yet
        return $false
    }
    $name = Get-JujuCharmConfig -Scope "bond-name"
    $bondPorts = Get-InterfaceFromConfig -ConfigOption "bond-ports"
    if ($bondPorts.Length -eq 0) {
        return $false
    }

    $bondExists = Get-NetLbfoTeam -Name $name -ErrorAction SilentlyContinue
    if ($bondExists){
        return $true
    }

    $bond = New-NetLbfoTeam -Name $name -TeamMembers $bondPorts.Name -TeamNicName $name -TeamingMode LACP -Confirm:$false
    $isUp = Wait-ForBondUp -bond $bond.Name
    if (!$isUp){
        Throw "Failed to bring up $name"
    }

    $adapter = Get-NetAdapter -Name $name
    if(!$adapter){
        Throw "Failed to find $name"
    }
    $returnCode = Invoke-DHCPRenew $adapter
    if($returnCode -eq 1) {
        Invoke-JujuReboot -Now
    }
    return $name
}

function Get-IPSAsArray {
    Param(
        [Parameter(Mandatory=$true)]
        [int]$ifIndex
    )

    $addr = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")
    $addresses = Get-NetIPAddress -InterfaceIndex $ifIndex
    foreach ($i in $addresses) {
        $ip = [System.Collections.Generic.Dictionary[string, object]](New-Object "System.Collections.Generic.Dictionary[string, object]")
        $ip["IPAddress"] = [string]$i.IPAddress;
        $ip["PrefixLength"] = [string]$i.PrefixLength;
        $ip["InterfaceIndex"] = [string]$i.InterfaceIndex;
        $ip["AddressFamily"] = [string]$i.AddressFamily;
        $addr.Add($ip)
    }
    return $addr
}

function Get-NameserversAsArray {
    Param(
        [Parameter(Mandatory=$true)]
        [int]$ifIndex
    )
    $nslist = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")
    $nameservers = Get-DnsClientServerAddress -InterfaceIndex $ifIndex
    foreach ($i in $nameservers) {
        if(!$i.ServerAddresses.Count) {
            continue
        }
        foreach($j in $i.ServerAddresses) {
            $nslist.Add($j)
        }
    }
    return $nslist
}

function Get-InterfaceIpInformation {
    Param(
        [Parameter(Mandatory=$true)]
        [int]$ifIndex
    )
    $adapter = Get-NetAdapter -ifIndex $ifIndex
    $ns = (Get-NameserversAsArray -ifIndex $ifIndex)
    $ips = (Get-IPSAsArray -ifIndex $ifIndex)

    $adapterInfo = [System.Collections.Generic.Dictionary[string, object]](New-Object "System.Collections.Generic.Dictionary[string, object]")

    $adapterInfo["name"] = $adapter.Name
    $adapterInfo["index"] = $ifIndex
    $adapterInfo["mac"] = $adapter.MacAddress
    if($ips.Count) {
        $adapterInfo["addresses"] = (Get-IPSAsArray -ifIndex $ifIndex);
    }
    if($ns.Count) {
        $adapterInfo["nameservers"] = (Get-NameserversAsArray -ifIndex $ifIndex)
    }
    return $adapterInfo
}
