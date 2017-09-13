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

Import-Module JujuHooks
Import-Module JujuLogging
Import-Module Networking
Import-Module OpenStackCommon
Import-Module HyperVNetworking
Import-Module JujuHelper

$OVS_SERVICES = @{
    $OVS_VSWITCHD_SERVICE_NAME = @{
        'display_name' = "Open vSwitch Service"
        'binary_path' = ("`"$OVS_INSTALL_DIR\bin\ovs-vswitchd.exe`" " +
                         "--log-file=`"$OVS_INSTALL_DIR\logs\ovs-vswitchd.log`" " +
                         "unix:`"${env:OVS_RUNDIR}\db.sock`" --unixctl=`"${env:OVS_RUNDIR}\ovs-vswitchd.ctl`" " +
                         "--pidfile --service --service-monitor")
    }
    $OVS_OVSDB_SERVICE_NAME = @{
        'display_name' = "Open vSwitch DB Service"
        'binary_path' = ("`"$OVS_INSTALL_DIR\bin\ovsdb-server.exe`" " +
                         "--log-file=`"$OVS_INSTALL_DIR\logs\ovsdb-server.log`" " +
                         "--pidfile --service --service-monitor " +
                         "--unixctl=`"${env:OVS_RUNDIR}\ovsdb-server.ctl`" " +
                         "--remote=`"db:Open_vSwitch,Open_vSwitch,manager_options`" " +
                         "--remote=punix:`"${env:OVS_RUNDIR}\db.sock`" `"$OVS_INSTALL_DIR\conf\conf.db`"")
    }
}


function Invoke-InterfacesDHCPRenew {
    <#
    .SYNOPSIS
     Renews DHCP for every NIC on the system with DHCP enabled.
    .PARAMETER TimeoutAfterWaitingDHCP
     Timeout in seconds after which the function no longer waits for the DHCP
     response to arrive.
    #>
    Param(
        [uint32]$TimeoutAfterWaitingDHCP=15
    )

    $interfaces = Get-CimInstance -Class Win32_NetworkAdapterConfiguration | Where-Object {
        $_.IPEnabled -eq $true -and $_.DHCPEnabled -eq $true -and $_.DHCPServer -eq "255.255.255.255"
    }
    if($interfaces) {
        $interfaces.InterfaceIndex | Invoke-DHCPRenew -ErrorAction SilentlyContinue | Out-Null
    }
    # Wait with a timeout for all interfaces to get a DHCP response
    $ready = $true
    $startTime = Get-Date
    do {
        foreach($index in $interfaces.Index) {
            $interface = Get-CimInstance -Class Win32_NetworkAdapterConfiguration -Filter "Index=$index"
            if(!$interface.DHCPLeaseObtained) {
                $ready = $false
            }
        }
        $diff = (Get-Date) - $startTime
        if($ready -or ($diff.Seconds -gt $TimeoutAfterWaitingDHCP)) {
            break
        }
        Write-JujuWarning "Waiting for all DHCP interfaces to get a DHCP response"
        Start-Sleep -Seconds 1
    } until($ready)
}

function Confirm-IPIsInDataNetwork {
    <#
    .SYNOPSIS
     Checks if an IP is in data network
    #>
    Param(
        [Parameter(Mandatory=$true)]
        [System.String]$DataNetwork,
        [Parameter(Mandatory=$true)]
        [Microsoft.Management.Infrastructure.CimInstance]$IP
    )

    if($IP.IPAddress -eq "127.0.0.1") {
        return $false
    }
    $port = Get-NetAdapter -InterfaceIndex $IP.IfIndex -ErrorAction SilentlyContinue
    if(!$port) {
        Write-JujuWarning ("Port with index '{0}' no longer exists" -f @($IP.IfIndex))
        return $false
    }
    $netDetails = $DataNetwork.Split("/")
    $decimalMask = ConvertTo-Mask $netDetails[1]
    Write-JujuWarning ("Checking {0} on interface {1}" -f @($IP.IPAddress, $IP.InterfaceAlias))
    if ($IP.PrefixLength -ne $netDetails[1]) {
        return $false
    }
    $network = Get-NetworkAddress $IP.IPv4Address $decimalMask
    Write-JujuWarning ("Network address for {0} is {1}" -f @($IP.IPAddress, $network))
    if ($network -ne $netDetails[0]) {
        return $false
    }
    return $true
}

function Get-DataPortsFromDataNetwork {
    <#
    .SYNOPSIS
     Returns a list with all the system ports in the data network
    #>

    $ports = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")
    $cfg = Get-JujuCharmConfig
    if (!$cfg["os-data-network"]) {
        Write-JujuWarning "'os-data-network' is not defined"
        return $ports
    }
    $ovsAdaptersInfo = Get-CharmState -Namespace "novahyperv" -Key "ovs_adapters_info"
    if($ovsAdaptersInfo) {
        foreach($i in $ovsAdaptersInfo) {
            $adapter = Get-NetAdapter -Name $i["name"]
            $ports.Add($adapter)
        }
        return $ports
    }
    $vmSwitchName = Get-JujuVMSwitchName
    $vmSwitch = Get-JujuVMSwitch
    if($vmSwitch) {
        $vmSwitchNetAdapter = Get-Netadapter -InterfaceDescription $vmSwitch.NetAdapterInterfaceDescription
        $managementOS = $vmSwitch.AllowManagementOS
        # Temporary set the management OS to $true
        Set-VMSwitch -VMSwitch $vmSwitch -AllowManagementOS $true -Confirm:$false
        [array]$managementOSAdapters = Get-VMNetworkAdapter -SwitchName $vmSwitchName -ManagementOS
    }
    # If there is any network interface configured to use DHCP and did not get an IP address
    # we manually renew its lease and try to get an IP address before searching for the data network
    Invoke-InterfacesDHCPRenew
    $ovsAdaptersInfo = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")
    $configuredAddresses = Get-NetIPAddress -AddressFamily IPv4
    foreach ($i in $configuredAddresses) {
        if(Confirm-IPIsInDataNetwork -DataNetwork $cfg['os-data-network'] -IP $i) {
            $isMgmtOSAdapter = $false
            $adapter = Get-NetAdapter -InterfaceIndex $i.IfIndex
            if($adapter.DeviceID -in $managementOSAdapters.DeviceID) {
                $isMgmtOSAdapter = $true
                $adapter = $vmSwitchNetAdapter
            }
            if($adapter.ifIndex -in $ports.ifIndex) {
                continue
            }
            $adapterInfo = Get-InterfaceIpInformation -InterfaceIndex $i.IfIndex
            if($isMgmtOSAdapter) {
                $adapterInfo['name'] = $vmSwitchNetAdapter.Name
                $adapterInfo['index'] = $vmSwitchNetAdapter.InterfaceIndex
                $adapterInfo['mac'] = $vmSwitchNetAdapter.MacAddress
            }
            $ovsAdaptersInfo.Add($adapterInfo)
            $ports.Add($adapter)
        }
    }
    if($ovsAdaptersInfo) {
        Set-CharmState -Namespace "novahyperv" -Key "ovs_adapters_info" -Value $ovsAdaptersInfo
    }
    if($vmswitch) {
        # Restore the management OS value for the switch
        Set-VMSwitch -VMSwitch $vmSwitch -AllowManagementOS $managementOS -Confirm:$false
    }
    return $ports
}

function Get-OVSDataPorts {
    $dataPorts = Get-DataPortsFromDataNetwork
    if ($dataPorts) {
        return $dataPorts
    }
    Write-JujuWarning "OVS data ports could not be found. Using the main adapter NIC as the data port"
    $fallbackPort = Get-FallbackNetadapter
    $adapterInfo = Get-InterfaceIpInformation -InterfaceIndex $fallbackPort.IfIndex
    Set-CharmState -Namespace "novahyperv" -Key "ovs_adapters_info" -Value @($adapterInfo)
    return @($fallbackPort)
}

function Set-OVSAdapterAddress {
    Param(
        [Parameter(Mandatory=$true)]
        [Object]$AdapterInfo
    )

    $ovsIf = Get-NetAdapter $OVS_JUJU_BR
    if(!$ovsIf) {
        Throw "Could not find OVS adapter."
    }
    $ips = $AdapterInfo["addresses"]
    if(!$ips) {
        Write-JujuWarning "No IP addresses saved to configure OVS adapter."
    }
    foreach ($i in $ips) {
        $ipAddr = Get-NetIPAddress -AddressFamily $i["AddressFamily"] -IPAddress $i["IPAddress"] `
                                   -PrefixLength $i["PrefixLength"] -ErrorAction SilentlyContinue
        if($ipAddr) {
            if($ipAddr.InterfaceIndex -eq $ovsIf.ifIndex) {
                continue
            }
            $ipAddr | Remove-NetIPAddress -Confirm:$false | Out-Null
        }
        if ($i["AddressFamily"] -eq "IPv6") {
            continue
        }
        New-NetIPAddress -IPAddress $i["IPAddress"] -PrefixLength $i["PrefixLength"] -InterfaceIndex $ovsIf.ifIndex | Out-Null
    }
    if($AdapterInfo['default_gateway']) {
        $hasRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -NextHop $AdapterInfo['default_gateway'] -ErrorAction SilentlyContinue
        if(!$hasRoute) {
            New-NetRoute -DestinationPrefix "0.0.0.0/0" -NextHop $AdapterInfo['default_gateway'] -InterfaceIndex $ovsIf.ifIndex | Out-Null
        }
    }
    if($AdapterInfo['nameservers'] -and ($AdapterInfo['nameservers'].Count -gt 0)) {
        Set-DnsClientServerAddress -ServerAddresses $AdapterInfo['nameservers'] -InterfaceIndex $ovsIf.ifIndex -Confirm:$false | Out-Null
    }
}

function New-OVSInternalInterfaces {
    $ovsAdaptersInfo = Get-CharmState -Namespace "novahyperv" -Key "ovs_adapters_info"
    if(!$ovsAdaptersInfo) {
        Throw "Failed to find OVS adapters info"
    }
    # Use only one adapter as OVS bridge port
    foreach($i in $ovsAdaptersInfo) {
        if(!$i['addresses']) {
            continue
        }
        $adapterInfo = $i
        break
    }
    Invoke-JujuCommand -Command @($OVS_VSCTL, "--may-exist", "add-br", $OVS_JUJU_BR) | Out-Null
    Invoke-JujuCommand -Command @($OVS_VSCTL, "--may-exist", "add-port", $OVS_JUJU_BR, $adapterInfo["name"]) | Out-Null
    # Enable the OVS adapter
    Get-Netadapter $OVS_JUJU_BR | Enable-NetAdapter | Out-Null
    Set-OVSAdapterAddress -AdapterInfo $adapterInfo
}

function Get-OVSLocalIP {
    $ovsAdapter = Get-Netadapter $OVS_JUJU_BR -ErrorAction SilentlyContinue
    if(!$ovsAdapter) {
        $netType = Get-NetType
        if($netType -eq "ovs") {
            Throw "Trying to get OVS local IP, but OVS adapter is not up"
        }
        Write-JujuWarning "OVS adapter is not created yet"
        return $null
    }
    [array]$addresses = Get-NetIPAddress -InterfaceIndex $ovsAdapter.InterfaceIndex -AddressFamily IPv4
    if(!$addresses) {
        Throw "No IPv4 addresses configured for the OVS port"
    }
    return $addresses[0].IPAddress
}

function Get-OVSExtStatus {
    $vmSwitch = Get-JujuVMSwitch
    if(!$vmSwitch) {
        Write-JujuWarning "VM switch was not created yet"
        return $null
    }
    $ext = Get-VMSwitchExtension -VMSwitchName $vmSwitch.Name -Name $OVS_EXT_NAME
    if (!$ext){
        Write-JujuWarning "Open vSwitch extension not installed"
        return $null
    }
    return $ext
}

function Enable-OVSExtension {
    $ext = Get-OVSExtStatus
    if (!$ext){
       Throw "Failed to enable OVS extension"
    }
    if (!$ext.Enabled) {
        Enable-VMSwitchExtension $OVS_EXT_NAME $ext.SwitchName | Out-Null
    }
}

function Disable-OVSExtension {
    $ext = Get-OVSExtStatus
    if ($ext -and $ext.Enabled) {
        Disable-VMSwitchExtension $OVS_EXT_NAME $ext.SwitchName | Out-Null
    }
}

function Get-OVSInstallerPath {
    $cfg = Get-JujuCharmConfig
    $installerUrl = $cfg['ovs-installer-url']
    if (!$installerUrl) {
        $installerUrl = $OVS_DEFAULT_INSTALLER_URL
    }
    $file = ([System.Uri]$installerUrl).Segments[-1]
    $tempDownloadFile = Join-Path $env:TEMP $file
    Start-ExecuteWithRetry {
        Invoke-FastWebRequest -Uri $installerUrl -OutFile $tempDownloadFile | Out-Null
    } -RetryMessage "OVS installer download failed. Retrying"
    return $tempDownloadFile
}

function Disable-OVS {
    $ovsServices = @($OVS_VSWITCHD_SERVICE_NAME, $OVS_OVSDB_SERVICE_NAME)
    # Check if both OVS services are up and running
    $ovsRunning = $true
    foreach($svcName in $ovsServices) {
        $service = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if(!$service) {
            $ovsRunning = $false
            continue
        }
        if($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Running) {
            $ovsRunning = $false
        }
    }
    if($ovsRunning) {
        $bridges = Start-ExternalCommand { & $OVS_VSCTL list-br }
        foreach($bridge in $bridges) {
            Start-ExternalCommand { & $OVS_VSCTL del-br $bridge }
        }
    }
    foreach($svcName in $ovsServices) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if($svc) {
            Stop-Service $svcName -Force
            Disable-Service $svcName
        }
    }
    Disable-OVSExtension
}

function Enable-OVS {
    Enable-OVSExtension
    $ovsServices = @($OVS_OVSDB_SERVICE_NAME, $OVS_VSWITCHD_SERVICE_NAME)
    foreach($svcName in $ovsServices) {
        Enable-Service $svcName
        Start-Service $svcName
    }
    Invoke-JujuCommand -Command @($OVS_VSCTL, 'set-manager', 'ptcp:6640:127.0.0.1')
}

function New-OVSWindowsServices {
    $ovsSvc = Get-ManagementObject -ClassName Win32_Service -Filter "Name='$OVS_VSWITCHD_SERVICE_NAME'"
    $ovsDBSvc = Get-ManagementObject -ClassName Win32_Service -Filter "Name='$OVS_OVSDB_SERVICE_NAME'"
    if(!$ovsSvc -and !$ovsDBSvc) {
        Write-JujuWarning "OVS services are not created yet"
        return
    }
    if(($ovsSvc.PathName -eq $OVS_SERVICES[$OVS_VSWITCHD_SERVICE_NAME]['binary_path']) -and
       ($ovsDBSvc.PathName -eq $OVS_SERVICES[$OVS_OVSDB_SERVICE_NAME]['binary_path'])) {
        Write-JujuWarning "OVS services are correctly configured"
        return
    }
    Stop-Service $OVS_VSWITCHD_SERVICE_NAME
    Stop-Service $OVS_OVSDB_SERVICE_NAME -Force
    Remove-WindowsServices -Names @($OVS_VSWITCHD_SERVICE_NAME, $OVS_OVSDB_SERVICE_NAME)
    foreach($svcName in @($OVS_OVSDB_SERVICE_NAME, $OVS_VSWITCHD_SERVICE_NAME)) {
        New-Service -Name $svcName -DisplayName $OVS_SERVICES[$svcName]['display_name'] `
                    -BinaryPathName $OVS_SERVICES[$svcName]['binary_path'] -Confirm:$false
        Start-Service -Name $svcName
        Set-Service -Name $svcName -StartupType Automatic
    }
}

function Install-OVS {
    if (Get-ComponentIsInstalled -Name $OVS_PRODUCT_NAME -Exact) {
        Write-JujuWarning "OVS is already installed"
        return
    }
    $installerPath = Get-OVSInstallerPath
    Write-JujuWarning "Installing OVS from '$installerPath'"
    $logFile = Join-Path $env:APPDATA "ovs-installer-log.txt"
    $extraParams = @("INSTALLDIR=`"$OVS_INSTALL_DIR`"")
    Install-Msi -Installer $installerPath -LogFilePath $logFile -ExtraArgs $extraParams
    New-OVSWindowsServices
}

function Uninstall-OVS {
    $isOVSInstalled = Get-ComponentIsInstalled -Name $OVS_PRODUCT_NAME -Exact
    if (!$isOVSInstalled) {
        Write-JujuWarning "OVS is not installed"
        return
    }
    Write-JujuWarning "Uninstalling OVS"
    Uninstall-WindowsProduct -Name $OVS_PRODUCT_NAME
}
