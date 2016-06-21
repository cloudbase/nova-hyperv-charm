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
Import-Module HyperVNetworking
Import-Module Networking

$OVS_EXT_NAME = "Open vSwitch Extension"
$OVS_INSTALL_DIR = "${env:ProgramFiles}\Cloudbase Solutions\Open vSwitch"
$OVS_VSCTL = Join-Path $OVS_INSTALL_DIR "bin\ovs-vsctl.exe"
$env:OVS_RUNDIR = "$env:ProgramData\openvswitch"
$JUJU_BR = "juju-br"

function Get-DataPortFromDataNetwork {
    $dataNetwork = Get-JujuCharmConfig -Scope "os-data-network"
    if (!$dataNetwork) {
        Write-JujuInfo "os-data-network is not defined"
        return $false
    }

    $adapterInfo = Get-CharmState -Namespace "novahyperv" -Key "adapter_info"
    if($adapterInfo){
        return Get-NetAdapter -Name $adapterInfo["name"]
    }

    # If there is any network interface configured to use DHCP and did not get an IP address
    # we manually renew its lease and try to get an IP address before searching for the data network
    $interfaces = Get-CimInstance -Class win32_networkadapterconfiguration | Where-Object { 
        $_.IPEnabled -eq $true -and $_.DHCPEnabled -eq $true -and $_.DHCPServer -eq "255.255.255.255"
    }
    if($interfaces){
        $interfaces.InterfaceIndex | Invoke-DHCPRenew -ErrorAction SilentlyContinue
    }
    $netDetails = $dataNetwork.Split("/")
    $decimalMask = ConvertTo-Mask $netDetails[1]

    $configuredAddresses = Get-NetIPAddress -AddressFamily IPv4
    foreach ($i in $configuredAddresses) {
        Write-JujuInfo ("Checking {0} on interface {1}" -f @($i.IPAddress, $i.InterfaceAlias))
        if ($i.PrefixLength -ne $netDetails[1]){
            continue
        }
        $network = Get-NetworkAddress $i.IPv4Address $decimalMask
        Write-JujuInfo ("Network address for {0} is {1}" -f @($i.IPAddress, $network))
        if ($network -eq $netDetails[0]){
            $adapterInfo = Get-InterfaceIpInformation -ifIndex $i.IfIndex
            Set-CharmState -Namespace "novahyperv" -Key "local_ip" -Value $i.IPAddress
            Set-CharmState -Namespace "novahyperv" -Key "adapter_info" -Value $adapterInfo
            return Get-NetAdapter -ifindex $i.IfIndex
        }
    }
    return $false
}

function Get-OVSDataPort {
    $dataPort = Get-DataPortFromDataNetwork
    if ($dataPort){
        return Get-RealInterface $dataPort
    } else {
        $port = Get-FallbackNetadapter
        $local_ip = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $port.IfIndex -ErrorAction SilentlyContinue
        if(!$local_ip){
            Throw "failed to get fallback adapter IP address"
        }
        $adapterInfo = Get-InterfaceIpInformation -ifIndex $port.IfIndex
        Set-CharmState -Namespace "novahyperv" -Key "local_ip" -Value $local_ip[0]
        Set-CharmState -Namespace "novahyperv" -Key "adapter_info" -Value $adapterInfo
        return Get-RealInterface $port
    }
}

function Confirm-OVSTapDeviceAddress {
    Param(
        [Parameter(Mandatory=$true)]
        [object]$Info
    )
    $exists = Get-NetAdapter $JUJU_BR
    if(!$exists) {
        Throw "Could not find OVS adapter"
    }
    $ips = $Info["addresses"]
    if(!$ips -or !$ips.Count) {
        return
    }
    foreach ($i in $ips) {
        $hasAddr = Get-NetIPAddress -AddressFamily $i["AddressFamily"].Trim() -IPAddress $i["IPAddress"].Trim() `
                                    -PrefixLength $i["PrefixLength"] -ErrorAction SilentlyContinue
        if($hasAddr) {
            if($hasAddr.InterfaceIndex -ne $exists.ifIndex) {
                $hasAddr | Remove-NetIPAddress -Confirm:$false | Out-Null
            } else {
                continue
            }
        }
        if ($i["AddressFamily"] -eq "IPv6") { continue }
        New-NetIPAddress -IPAddress $i["IPAddress"].Trim() -PrefixLength $i["PrefixLength"] -InterfaceIndex $exists.ifIndex | Out-Null
    }
    return
}

function Confirm-InternalOVSInterfaces {
    $dataPort = Get-DataPortFromDataNetwork
    if(!$dataPort) {
        Throw "Failed to find data port"
    }
    $adapterInfo = Get-CharmState -Namespace "novahyperv" -Key "adapter_info"

    Invoke-JujuCommand -Command @($OVS_VSCTL, "--may-exist", "add-br", $JUJU_BR)
    Invoke-JujuCommand -Command @($OVS_VSCTL, "--may-exist", "add-port", $JUJU_BR, $adapterInfo["name"])

    # Enable the OVS tap device
    Get-Netadapter $JUJU_BR | Enable-NetAdapter
    Confirm-OVSTapDeviceAddress -Info $adapterInfo
}

function Get-OVSExtStatus {
    $br = Get-JujuVMSwitch
    Write-JujuInfo "Switch name is $br"
    $ext = Get-VMSwitchExtension -VMSwitchName $br -Name $OVS_EXT_NAME

    if (!$ext){
        Write-JujuInfo "Open vSwitch extension not installed"
        return $null
    }

    return $ext
}

function Enable-OVSExtension {
    $ext = Get-OVSExtStatus
    if (!$ext){
       Throw "Cannot enable OVS extension. Not installed"
    }
    if (!$ext.Enabled) {
        Enable-VMSwitchExtension $OVS_EXT_NAME $ext.SwitchName
    }
    return $true
}

function Disable-OVSExtension {
    $ext = Get-OVSExtStatus
    if ($ext -ne $null -and $ext.Enabled -eq $true) {
        Disable-VMSwitchExtension $OVS_EXT_NAME $ext.SwitchName
    }
    return $true
}
