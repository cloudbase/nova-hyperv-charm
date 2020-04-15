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
Import-Module OpenStackCommon
Import-Module JujuLogging
Import-Module Networking


function Get-NetType {
    $cfg = Get-JujuCharmConfig
    if($cfg['network-type'] -notin $NOVA_VALID_NETWORK_TYPES) {
        Throw ("Invalid network type: '{0}'" -f @($cfg['network-type']))
    }
    if((Get-IsNanoServer) -and ($cfg['network-type'] -ne 'hyperv')) {
        Throw ("'{0}' network type is not supported on Nano Server" -f @($cfg['network-type']))
    }
    return $cfg['network-type']
}

function Get-JujuVMSwitchName {
    $cfg = Get-JujuCharmConfig
    $vmSwitchName = $cfg['vmswitch-name']
    if (!$vmSwitchName) {
        return $NOVA_DEFAULT_SWITCH_NAME
    }
    return $vmSwitchName
}

function Get-JujuVMSwitch {
    $vmSwitchName = Get-JujuVMSwitchName
    $vmSwitch = Get-VMSwitch -SwitchType External -Name $vmSwitchName -ErrorAction SilentlyContinue
    if($vmSwitch) {
        return $vmSwitch
    }
    return $null
}

function Get-NICsByMAC {
    Param(
        [Parameter(Mandatory=$false)]
        [string[]]$MACAddresses
    )

    if (!$MACAddresses.Count) {
        return $null
    }
    [System.Array]$nics = Get-NetAdapter | Where-Object {
        $_.MacAddress -in $MACAddresses -and
        $_.DriverFileName -notin @("vmswitch.sys", "NdisImPlatform.sys")
    }
    if(!$nics) {
        return $null
    }
    return $nics
}

function Get-NICsByName {
    Param(
        [Parameter(Mandatory=$false)]
        [string[]]$Names
    )

    if (!$Names.Count) {
        return $null
    }
    [System.Array]$nics = Get-NetAdapter | Where-Object {
        $_.Name -in $Names -and
        $_.DriverFileName -ne "vmswitch.sys"
    }
    if(!$nics) {
        return $null
    }
    return $nics
}

function Get-InterfaceFromConfig {
    Param(
        [string]$ConfigOption="data-port",
        [switch]$MustFindAdapter=$false
    )

    $cfg = Get-JujuCharmConfig
    $dataInterfaceFromConfig = $cfg[$ConfigOption]
    Write-JujuWarning "Looking for interfaces: $dataInterfaceFromConfig"
    if (!$dataInterfaceFromConfig) {
        if($MustFindAdapter) {
            Throw "No config option '$ConfigOption' was specified"
        }
        return $null
    }
    $byMac = @()
    $byName = @()
    $macregex = "^([a-fA-F0-9]{2}:){5}([a-fA-F0-9]{2})$"
    foreach ($i in $dataInterfaceFromConfig.Split()) {
        if ($i -match $macregex) {
            $byMac += $i.Replace(":", "-")
        } else {
            $byName += $i
        }
    }
    $ifs = @()
    $nicsByMac = Get-NICsByMAC -MACAddresses $byMac
    if($nicsByMac) {
        $ifs += [System.Array]$nicsByMac
    }
    $nicsByName = Get-NICsByName -Names $byName
    if($nicsByName) {
        $ifs += [System.Array]$nicsByName
    }
    if ($ifs.Count) {
        $ifs | Enable-NetAdapter | Out-Null
    } else {
        if($MustFindAdapter) {
            Throw "Could not find network adapters"
        }
    }
    return $ifs
}

function Get-FallbackNetadapter {
    $name = Get-MainNetadapter
    $net = Get-NetAdapter -Name $name
    return $net
}

function Get-IPSAsArray {
    Param(
        [Parameter(Mandatory=$true)]
        [int]$InterfaceIndex
    )

    $addr = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")
    [System.Array]$addresses = Get-NetIPAddress -InterfaceIndex $InterfaceIndex
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
        [int]$InterfaceIndex
    )

    $nslist = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")
    $nameservers = Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex
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
        [int]$InterfaceIndex
    )

    $adapter = Get-NetAdapter -InterfaceIndex $InterfaceIndex
    $adapterInfo = [System.Collections.Generic.Dictionary[string, object]](New-Object "System.Collections.Generic.Dictionary[string, object]")
    $adapterInfo["name"] = $adapter.Name
    $adapterInfo["index"] = $InterfaceIndex
    $adapterInfo["mac"] = $adapter.MacAddress
    $adapterInfo["vlan"] = $adapter.VlanID
    $ips = Get-IPSAsArray -InterfaceIndex $InterfaceIndex
    if($ips.Count) {
        $adapterInfo["addresses"] = $ips
    }
    $ns = Get-NameserversAsArray -InterfaceIndex $InterfaceIndex
    if($ns) {
        $adapterInfo["nameservers"] = $ns
    }
    $defaultNetRoute = Get-NetRoute -InterfaceIndex $InterfaceIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
    if($defaultNetRoute) {
        $adapterInfo["default_gateway"] = $defaultNetRoute.NextHop
    }
    return $adapterInfo
}
