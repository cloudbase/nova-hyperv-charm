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

Import-Module JujuHelper
Import-Module JujuHooks
Import-Module JujuUtils
Import-Module JujuWindowsUtils
Import-Module Networking
Import-Module WSFCCharmUtils
Import-Module Templating
Import-Module HyperVNetworking
Import-Module OVSCharmUtils
Import-Module ADCharmUtils

$INSTALL_DIR = "${env:ProgramFiles}\Cloudbase Solutions\OpenStack\Nova"
$OVS_INSTALL_DIR = "${env:ProgramFiles}\Cloudbase Solutions\Open vSwitch"
$OVS_VSCTL = Join-Path $OVS_INSTALL_DIR "bin\ovs-vsctl.exe"
$env:OVS_RUNDIR = "$env:ProgramData\openvswitch"
$DISTRO_URLS = @{
    'kilo' = @{
        "installer" = @{
            'msi' = 'https://www.cloudbase.it/downloads/HyperVNovaCompute_Kilo_2015_1.msi#md5=49a9f59f8800de378c995032cf26aaaf';
            'zip' = $null;
        }
        "cluster" = $false
    };
    'liberty' = @{
        "installer" = @{
            'msi' = 'https://cloudbase.it/downloads/HyperVNovaCompute_Liberty_12_0_0.msi#md5=71b77c82dd7990891e108a98a1ecd234';
            'zip' = 'https://www.cloudbase.it/downloads/HyperVNovaCompute_Liberty_12_0_0.zip';
        };
        "cluster" = $false
    };
    'mitaka' = @{
        "installer" = @{
            'msi' = "https://cloudbase.it/downloads/HyperVNovaCompute_Mitaka_13_0_0.msi";
            'zip' = "https://cloudbase.it/downloads/HyperVNovaCompute_Mitaka_13_0_0.zip";
        };
        "cluster" = $true
    };
}
$DEFAULT_DISTRO = "mitaka"
$COMPUTERNAME = [System.Net.Dns]::GetHostName()


function Open-CharmPorts {
    $ports = @{
        "tcp" = @("5985", "5986", "3343", "445", "135", "139");
        "udp" = @("5985", "5986", "3343", "445", "135", "139");
    }
    Open-Ports -Ports $ports | Out-Null
}

function Install-Prerequisites {
    <#
    .SYNOPSIS
    Returns a boolean to indicate if a reboot is needed or not
    #>

    if (Get-IsNanoServer) {
        return $false
    }
    $rebootNeeded = $false
    try {
        $needsHyperV = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V'
    } catch {
        Throw "Failed to get Hyper-V role status: $_"
    }
    if ($needsHyperV.State -ne "Enabled") {
        $installHyperV = Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V' -All -NoRestart
        if ($installHyperV.RestartNeeded) {
            $rebootNeeded = $true
        }
    } else {
        if ($needsHyperV.RestartNeeded) {
            $rebootNeeded = $true
        }
    }
    $stat = Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-Management-PowerShell' -All -NoRestart
    if ($stat.RestartNeeded) {
        $rebootNeeded = $true
    }
    return $rebootNeeded
}

function Get-OpenstackVersion {
    $distro = Get-JujuCharmConfig -Scope "openstack-version"
    if($distro -eq $false){
        $distro = Get-JujuCharmConfig -Scope "openstack-origin"
    }
    return $distro
}

function Get-PythonDir {
    $pythonDir = Join-Path $INSTALL_DIR "Python27"
    if(!(Test-Path $pythonDir)){
        $pythonDir = Join-Path $INSTALL_DIR "Python"
        if(!(Test-Path $pythonDir)) {
            Throw "Could not find python directory"
        }
    }
    return $pythonDir
}

function New-ExeServiceWrapper {
    $pythonDir = Get-PythonDir
    $python = Join-Path $pythonDir "python.exe"
    $updateWrapper = Join-Path $pythonDir "Scripts\UpdateWrappers.py"

    $cmd = @($python, $updateWrapper, "nova-compute = nova.cmd.compute:main")
    Invoke-JujuCommand -Command $cmd

    $version = Get-JujuCharmConfig -Scope 'openstack-version'
    $consoleScript = "neutron-hyperv-agent = neutron.cmd.eventlet.plugins.hyperv_neutron_agent:main"
    if($version -eq "mitaka") {
        $consoleScript = "neutron-hyperv-agent = hyperv.neutron.l2_agent:main"
    }

    $cmd = @($python, $updateWrapper, $consoleScript)
    Invoke-JujuCommand -Command $cmd
}

function Get-FilesDir {
    $charmDir = Get-JujuCharmDir
    $files =  Join-Path $charmDir "files"
    return $files
}

function Get-ServiceWrapper {
    Param(
        [Parameter(Mandatory=$false)]
        [string]$Service
    )
    $wrapperName = ("OpenStackService{0}.exe" -f $Service)
    $svcPath = Join-Path $INSTALL_DIR ("bin\{0}" -f $wrapperName)
    if(!(Test-Path $svcPath)) {
        $svcPath = Join-Path $INSTALL_DIR "bin\OpenStackService.exe"
        if(!(Test-Path $svcPath)) {
            Throw "Failed to find service wrapper"
        }
    }
    return $svcPath
}

function Enable-MSiSCSI {
    Write-JujuWarning "Enabling MSiSCSI"
    $svc = Get-Service MSiSCSI -ErrorAction SilentlyContinue
    if($svc) {
        Start-Service MSiSCSI
        Set-Service MSiSCSI -StartupType Automatic
    } else {
        Write-JujuWarning "MSiSCSI service was not found"
    }
}

function New-ConfigFile {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$ServiceName
    )

    $jujuCharmServices = Get-CharmServices
    $shouldRestart = $true
    $service = $jujuCharmServices[$ServiceName]
    if (!$service){
        Write-JujuWarning "No such service $ServiceName. Not generating config"
        return $false
    }
    $incompleteContexts = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")
    $allContexts = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")
    $mergedContext = [System.Collections.Generic.Dictionary[string, object]](New-Object "System.Collections.Generic.Dictionary[string, object]")

    foreach ($context in $service['context_generators']){
        Write-JujuInfo ("Getting context for {0}" -f $context["relation"])
        $allContexts.Add($context["relation"])
        $ctx = & $context["generator"]
        Write-JujuInfo ("Got {0} context: {1}" -f @($context["relation"], $ctx.Keys))
        if (!$ctx.Count){
            # Context is empty. Probably peer not ready
            Write-JujuWarning ("Context for {0} is EMPTY" -f $context["relation"])
            $incompleteContexts.Add($context["relation"])
            $shouldRestart = $false
            continue
        }
        foreach ($val in $ctx.Keys) {
            $mergedContext[$val] = $ctx[$val]
        }
    }
    Set-IncompleteStatusContext -ContextSet $allContexts -Incomplete $incompleteContexts
    if(!$mergedContext.Count) {
        return $false
    }
    Start-RenderTemplate -Context $mergedContext -TemplateName $service["template"] -OutFile $service["config"]
    return $shouldRestart
}

function Get-DataPort {
    # try and set up bonding early. This will create
    # a new Net-LbfoTeam and try to acquire an IP address
    # via DHCP. This interface may receive os-data-network IP.
    $bondName = New-BondInterface
    $managementOS = Get-JujuCharmConfig -Scope "vmswitch-management"

    $netType = Get-NetType
    if ($netType -eq "ovs"){
        Write-JujuInfo "Trying to fetch OVS data port"
        $dataPort = Get-OVSDataPort
        return @($dataPort[0], $false)
    }

    if ($bondName) {
        $adapter = Get-NetAdapter -Name $bondName
        return @($adapter, $managementOS)
    }

    Write-JujuInfo "Trying to fetch data port from config"
    $nic = Get-InterfaceFromConfig
    if(!$nic) {
        $nic = Get-FallbackNetadapter
        $managementOS = $true
    }
    $nic = Get-RealInterface $nic[0]
    return @($nic[0], $managementOS)
}

function Start-ConfigureVMSwitch {
    $VMswitchName = Get-JujuVMSwitch
    $vmswitch = Get-VMSwitch -SwitchType External -Name $VMswitchName -ErrorAction SilentlyContinue

    if($vmswitch){
        return $true
    }

    $dataPort, $managementOS = Get-DataPort
    $VMswitches = Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue
    if ($VMswitches -and $VMswitches.Count -gt 0){
        foreach($i in $VMswitches){
            if ($i.NetAdapterInterfaceDescription -eq $dataPort.InterfaceDescription) {
                Rename-VMSwitch $i -NewName $VMswitchName
                Set-VMSwitch -Name $VMswitchName -AllowManagementOS $managementOS
                return $true
            }
        }
    }

    Write-JujuInfo "Adding new vmswitch: $VMswitchName"
    New-VMSwitch -Name $VMswitchName -NetAdapterName $dataPort.Name -AllowManagementOS $managementOS
    return $true
}

function Start-DownloadFile {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$url
    )

    $URI = [System.Uri]$url
    $msi = $URI.segments[-1]
    $downloadLocation = Join-Path "$env:TEMP" $msi
    if ($URI.fragment){
        $fragment = $URI.fragment.Trim("#").Split("=")
        if($fragment[0] -eq "md5"){
            $md5 = $fragment[1]
        }
    }

    $fileExists = Test-Path $downloadLocation
    if ($fileExists){
        if ($md5){
            $fileHash = (Get-FileHash -Algorithm MD5 $downloadLocation).Hash
            if ($fileHash -eq $md5){
                return $downloadLocation
            }
        }else{
            return $downloadLocation
        }
    }
    Write-JujuInfo "Downloading file from $url to $downloadLocation"
    try {
        Start-ExecuteWithRetry {
            Invoke-FastWebRequest -Uri $url -OutFile $downloadLocation | Out-Null
        }
    } catch {
        Write-JujuErr "Could not download $url to destination $downloadLocation"
        Throw
    }
    return $downloadLocation
}

function Get-NovaInstaller {
    $distro = Get-OpenstackVersion
    $installerUrl = Get-JujuCharmConfig -Scope "installer-url"
    if ($distro -eq $false){
        $distro = $DEFAULT_DISTRO
    }
    Write-JujuInfo "installer-url is set to: $installerUrl"
    if (!$installerUrl) {
        if (!$DISTRO_URLS[$distro] -or !$DISTRO_URLS[$distro]["installer"]){
            Throw "Could not find a download URL for $distro"
        }
        if ((Get-IsNanoServer))  {
            if (!$DISTRO_URLS[$distro]["installer"]["zip"]) {
                Throw "Distro $distro does not support Nano server"
            }
            $url = $DISTRO_URLS[$distro]["installer"]["zip"]
        } else {
            $url = $DISTRO_URLS[$distro]["installer"]["msi"]
        }
    } else {
        $url = $installerUrl
    }
    [string]$location = Start-DownloadFile $url
    return $location
}

function Install-NovaFromMSI {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$InstallerPath
    )

    $hasInstaller = Test-Path $InstallerPath
    if($hasInstaller -eq $false){
        $InstallerPath = Get-NovaInstaller
    }

    Write-JujuInfo "Installing from MSI installer: $InstallerPath"
    $unattendedArgs = @("SKIPNOVACONF=1", "INSTALLDIR=`"$INSTALL_DIR`"", "/qn", "/l*v", "$env:APPDATA\log.txt","/i", "$InstallerPath")
    $ret = Start-Process -FilePath msiexec.exe -ArgumentList $unattendedArgs -Wait -PassThru
    if($ret.ExitCode) {
        Throw ("Failed to install Nova: {0}" -f $ret.ExitCode)
    }
    return $true
}

function Install-NovaFromZip {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$InstallerPath
    )

    $distro = Get-OpenstackVersion
    $templatesDir = Join-Path (Get-JujuCharmDir) "templates"
    $policyFile = "$templatesDir\$distro\policy.json"
    if((Test-Path $INSTALL_DIR)) {
        Remove-Item -Recurse -Force $INSTALL_DIR | Out-Null
    }

    Write-JujuInfo "Unzipping $InstallerPath to $INSTALL_DIR"
    Expand-ZipArchive -ZipFile $InstallerPath -Destination $INSTALL_DIR | Out-Null
    $configDir = Join-Path $INSTALL_DIR "etc"
    if (!(Test-Path $configDir)) {
        New-Item -ItemType Directory $configDir | Out-Null
        Copy-Item $policyFile $configDir | Out-Null
    }
    New-ExeServiceWrapper
    return $true
}

function Install-Nova {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$InstallerPath
    )

    Write-JujuInfo "Running Nova install"

    if ($InstallerPath.EndsWith(".zip")) {
        $installed = Install-NovaFromZip $InstallerPath
    } elseif ($InstallerPath.EndsWith(".msi")) {
        $installed = Install-NovaFromMSI $InstallerPath
    } else {
        Throw "Unknown Nova installer extension"
    }
    Install-RootWrap
    return $installed
}

function Enable-LiveMigration {
    Enable-VMMigration
    $name = Get-MainNetadapter
    $netAddresses = Get-NetIPAddress -InterfaceAlias $name -AddressFamily IPv4
    foreach($netAddress in $netAddresses) {
        $prefixLength = $netAddress.PrefixLength
        $netmask = ConvertTo-Mask -MaskLength $prefixLength
        $networkAddress = Get-NetworkAddress -IPAddress $netAddress.IPAddress -SubnetMask $netmask
        $migrationNet = Get-VMMigrationNetwork | Where-Object { $_.Subnet -eq "$networkAddress/$prefixLength" }
        if(!$migrationNet) {
            Add-VMMigrationNetwork -Subnet "$networkAddress/$prefixLength" -Confirm:$false
        }
    }
}

function Confirm-CharmPrerequisites {
    $services = Get-CharmServices
    $hypervAgent = Get-Service $services["neutron"]["service"] -ErrorAction SilentlyContinue
    $novaCompute = Get-Service $services["nova"]["service"] -ErrorAction SilentlyContinue

    if(!$hypervAgent) {
        $name = $services["neutron"]["service"]
        $svcPath = $services["neutron"]["serviceBinPath"]
        New-Service -Name $name -BinaryPathName $svcPath -DisplayName $name -Description "Neutron Hyper-V Agent" -Confirm:$false
        Disable-Service $name
    }

    if(!$novaCompute){
        $name = $services["nova"]["service"]
        $svcPath = $services["nova"]["serviceBinPath"]
        New-Service -Name $name -BinaryPathName $svcPath -DisplayName $name -Description "Nova Compute" -Confirm:$false
    }
}

function Start-ConfigureNeutronAgent {
    $services = Get-CharmServices
    $vmswitch = Get-JujuVMSwitch
    $netType = Get-NetType

    if ($netType -eq "hyperv"){
        Disable-Service $services["neutron-ovs"]["service"]
        Stop-Service $services["neutron-ovs"]["service"] -ErrorAction SilentlyContinue

        Disable-OVS
        Enable-Service $services["neutron"]["service"]

        return $services["neutron"]
    }

    Confirm-OVSPrerequisites

    Disable-Service $services["neutron"]["service"]
    Stop-Service $services["neutron"]["service"]

    Enable-OVS
    Enable-Service $services["neutron-ovs"]["service"]

    Confirm-InternalOVSInterfaces
    return $services["neutron-ovs"]
}

function Get-OVSInstaller {
    $installerUrl = Get-JujuCharmConfig -Scope "ovs-installer-url"
    if ($installerUrl -eq $false) {
        Throw "Could not find a download URL for $distro"
    }
    $location = Start-DownloadFile $installerUrl
    return $location
}

function Install-OVS {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$InstallerPath
    )

    Write-JujuInfo "Running OVS install"
    $ovs = Get-ManagementObject -Class Win32_Product | Where-Object { $_.Name -match "open vswitch" }
    if ($ovs) {
        Write-JujuInfo "OVS is already installed"
        return $true
    }

    $hasInstaller = Test-Path $InstallerPath
    if($hasInstaller -eq $false){
        $InstallerPath = Get-OVSInstaller
    }
    Write-JujuInfo "Installing from $InstallerPath"
    $unattendedArgs = @("INSTALLDIR=`"$OVS_INSTALL_DIR`"", "/qb", "/l*v", "$env:APPDATA\ovs-log.txt", "/i", "$InstallerPath")
    $ret = Start-Process -FilePath msiexec.exe -ArgumentList $unattendedArgs -Wait -PassThru
    if($ret.ExitCode) {
        Throw "Failed to install OVS: $LASTEXITCODE"
    }
    return $true
}

function Disable-OVS {
    Stop-Service "ovs-vswitchd" -ErrorAction SilentlyContinue
    Stop-Service "ovsdb-server" -ErrorAction SilentlyContinue

    Disable-Service "ovs-vswitchd"
    Disable-Service "ovsdb-server"

    Disable-OVSExtension
}

function Enable-OVS {
    Enable-OVSExtension

    Enable-Service "ovsdb-server"
    Enable-Service "ovs-vswitchd"

    Start-Service "ovsdb-server"
    Start-Service "ovs-vswitchd"
}

function Confirm-OVSPrerequisites {
    try {
        $ovsdbSvc = Get-Service "ovsdb-server"
        $ovsSwitchSvc = Get-Service "ovs-vswitchd"
    } catch {
        $InstallerPath = Get-OVSInstaller
        Install-OVS $InstallerPath
    }
    if(!(Test-Path $OVS_VSCTL)){
        Throw "Could not find ovs-vsctl.exe in location: $OVS_VSCTL"
    }

    $services = Get-CharmServices
    $ovsAgent = Get-Service $services["neutron-ovs"]["service"] -ErrorAction SilentlyContinue
    if(!$ovsAgent) {
        $name = $services["neutron-ovs"].service
        $svcPath = $services["neutron-ovs"].serviceBinPath
        New-Service -Name $name -BinaryPathName $svcPath -DisplayName $name -Description "Neutron Open vSwitch Agent" -Confirm:$false
        Disable-Service $name
    }
}

function Disable-Service {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$ServiceName
    )

    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if ($svc -eq $null) {
        return $true
    }
    Get-Service $ServiceName | Set-Service -StartupType Disabled
}

function Enable-Service {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$ServiceName
    )

    $svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
    if ($svc -eq $null) {
        return $true
    }
    Get-Service $ServiceName | Set-Service -StartupType Automatic
}

function Restart-Neutron {
    $svc = Start-ConfigureNeutronAgent
    Stop-Service $svc.service
    Start-Service $svc.service
}

function Restart-Nova {
    $services = Get-CharmServices
    Stop-Service $services.nova.service
    Start-Service $services.nova.service
}

function Stop-Nova {
    $services = Get-CharmServices
    Stop-Service $services.nova.service
}

function Stop-Neutron {
    $services = Get-CharmServices
    $netType = Get-NetType
    if ($netType -eq "hyperv"){
        Stop-Service $services["neutron"]["service"]
    } elseif ($netType -eq "ovs") {
        Stop-Service $services['neutron-ovs']['service']
    }
}

function Import-CloudbaseCert {
    $filesDir = Get-FilesDir
    $crt = Join-Path $filesDir "Cloudbase_signing.cer"
    if (!(Test-Path $crt)){
        return $false
    }
    Import-Certificate $crt -StoreLocation LocalMachine -StoreName TrustedPublisher
}

function Install-RootWrap {
    $templatesDir =  Join-Path (Get-JujuCharmDir) "templates"
    $rootWrap = Join-Path $templatesDir "ovs\rootwrap.cmd"

    if(!(Test-Path $rootWrap)){
        return $true
    }

    $dst = Join-Path $INSTALL_DIR "bin\rootwrap.cmd"
    $parent = Split-Path -Path $dst -Parent
    $exists = Test-Path $parent
    if (!$exists){
        New-Item -ItemType Directory $parent | Out-Null
    }
    Copy-Item $rootWrap $dst
    return $true
}

function Get-CharmServices {
    $distro = Get-OpenstackVersion
    $novaConf = Join-Path $INSTALL_DIR "etc\nova.conf"
    $neutronConf = Join-Path $INSTALL_DIR "etc\neutron_hyperv_agent.conf"
    $neutronML2Conf = Join-Path $INSTALL_DIR "etc\ml2_conf.ini"
    $serviceWrapperNova = Get-ServiceWrapper -Service "Nova"
    $serviceWrapperNeutron = Get-ServiceWrapper -Service "Neutron"
    $pythonDir = Get-PythonDir
    $novaExe = Join-Path $pythonDir "Scripts\nova-compute.exe"
    $neutronHypervAgentExe = Join-Path $pythonDir "Scripts\neutron-hyperv-agent.exe"
    $neutronOpenvswitchExe = Join-Path $pythonDir "Scripts\neutron-openvswitch-agent.exe"
    $jujuCharmServices = @{
        "nova" = @{
            "template" = "$distro\nova.conf";
            "service" = "nova-compute";
            "binpath" = "$novaExe";
            "serviceBinPath" = "`"$serviceWrapperNova`" nova-compute `"$novaExe`" --config-file `"$novaConf`"";
            "config" = "$novaConf";
            "context_generators" = @(
                @{
                    "generator" = "Get-RabbitMQContext";
                    "relation" = "amqp";
                },
                @{
                    "generator" = "Get-NeutronContext";
                    "relation" = "cloud-compute";
                },
                @{
                    "generator" = "Get-GlanceContext";
                    "relation" = "image-service";
                },
                @{
                    "generator" = "Get-CharmConfigContext";
                    "relation" = "config";
                },
                @{
                    "generator" = "Get-SystemContext";
                    "relation" = "system";
                },
                @{
                    "generator" = "Get-S2DContext";
                    "relation" = "s2d";
                }
            );
        };
        "neutron" = @{
            "template" = "$distro\neutron_hyperv_agent.conf"
            "service" = "neutron-hyperv-agent";
            "binpath" = "$neutronHypervAgentExe";
            "serviceBinPath" = "`"$serviceWrapperNeutron`" neutron-hyperv-agent `"$neutronHypervAgentExe`" --config-file `"$neutronConf`"";
            "config" = "$neutronConf";
            "context_generators" = @(
                @{
                    "generator" = "Get-RabbitMQContext";
                    "relation" = "amqp";
                },
                @{
                    "generator" = "Get-NeutronContext";
                    "relation" = "cloud-compute";
                },
                @{
                    "generator" = "Get-CharmConfigContext";
                    "relation" = "config";
                },
                @{
                    "generator" = "Get-SystemContext";
                    "relation" = "system";
                },
                @{
                    "generator" = "Get-S2DContext";
                    "relation" = "s2d";
                }
                );
        };
        "neutron-ovs" = @{
            "template" = "$distro\ml2_conf.ini"
            "service" = "neutron-openvswitch-agent";
            "binpath" = "$neutronOpenvswitchExe";
            "serviceBinPath" = "`"$serviceWrapperNeutron`" neutron-openvswitch-agent `"$neutronOpenvswitchExe`" --config-file `"$neutronML2Conf`"";
            "config" = "$neutronML2Conf";
            "context_generators" = @(
                @{
                    "generator" = "Get-RabbitMQContext";
                    "relation" = "amqp";
                },
                @{
                    "generator" = "Get-NeutronContext";
                    "relation" = "cloud-compute";
                },
                @{
                    "generator" = "Get-CharmConfigContext";
                    "relation" = "config";
                },
                @{
                    "generator" = "Get-SystemContext";
                    "relation" = "system";
                },
                @{
                    "generator" = "Get-S2DContext";
                    "relation" = "s2d";
                }
                );
        };
    }
    return $jujuCharmServices
}

function Get-RabbitMQContext {
    Write-JujuLog "Generating context for RabbitMQ"
    $username = Get-JujuCharmConfig -Scope 'rabbit-user'
    $vhost = Get-JujuCharmConfig -Scope 'rabbit-vhost'
    if (!$username -or !$vhost){
        Write-JujuWarning "Missing required charm config options: rabbit-user or rabbit-vhost"
    }

    $required = @{
        "hostname"=$null;
        "password"=$null;
    }

    $optional = @{
        "vhost"=$null;
        "username"=$null;
        "ha_queues"=$null;
    }

    $ctx = Get-JujuRelationContext -Relation "amqp" -RequiredContext $required -OptionalContext $optional

    $data = @{}

    if($ctx.Count) {
        if(!$ctx["username"]) {
            $data["rabbit_userid"] = $username
        } else {
            $data["rabbit_userid"] = $ctx["username"]
        }
        if(!$ctx["vhost"]){
            $data["rabbit_virtual_host"] = $vhost
        } else {
            $data["rabbit_virtual_host"] = $ctx["vhost"]
        }
        if($ctx["ha_queues"]) {
            $data["rabbit_ha_queues"] = "True"
        } else {
            $data["rabbit_ha_queues"] = "False"
        }
        $data["rabbit_host"]=$ctx["hostname"];
        $data["rabbit_password"]=$ctx["password"];
    }
    return $data
}

function Get-S2DContext {
    [string]$instancesDir = (Get-JujuCharmConfig -Scope 'instances-dir').Replace('/', '\')
    $ctxt = @{
        "instances_path" = $instancesDir;
        "compute_driver" = "hyperv.nova.driver.HyperVDriver";
    }

    $required = @{
        "volumepath"=$null;
    }
    $s2dCtxt = Get-JujuRelationContext -Relation "s2d" -RequiredContext $required
    $version = Get-JujuCharmConfig -Scope 'openstack-version'
    $enableCluster = Get-JujuCharmConfig -Scope 'enable-cluster-driver'
    if($s2dCtxt.Count){
        if($s2dCtxt["volumepath"] -and (Test-Path $s2dCtxt["volumepath"])) {
            [string]$ctxt["instances_path"] = Join-Path $s2dCtxt["volumepath"] "Instances"
        } else {
            Write-JujuWarning "Relation information states that an s2d volume should be present, but could not be found locally."
        }
    }
    if ($DISTRO_URLS[$version]['cluster'] -and $enableCluster) {
        $ctxt['compute_driver'] = 'hyperv.nova.cluster.driver.HyperVClusterDriver'
    }

    # Try and create the instanced_dir on the clustered storage. We do not bother testing if the
    # folder is already there before attempting to create it. There is a chance another node will
    # create the folder between the Test-Path call and the mkdir call. Might as well try, and check
    # for the existance of the folder if the command errors out.
    try {
        if (!(Test-Path $ctxt["instances_path"])) {
            New-Item -ItemType Directory $ctxt["instances_path"] | Out-Null
        }
   } catch [System.IO.IOException] {
        if (!(Test-Path $ctxt["instances_path"])) {
            Throw $_
        }
    }
    return $ctxt
}

function Get-NeutronContext {
    Write-JujuLog "Generating context for Neutron"

    $logdir = (Get-JujuCharmConfig -Scope 'log-dir').Replace('/', '\')
    $switchName = Get-JujuVMSwitch
    if (!(Test-Path $logdir)){
        New-Item -ItemType Directory $logdir
    }

    $required = @{
        "service_protocol"=$null;
        "service_port"=$null;
        "auth_host"=$null;
        "auth_port"=$null;
        "auth_protocol"=$null;
        "service_tenant_name"=$null;
        "service_username"=$null;
        "service_password"=$null;
    }

    $optionalCtx = @{
        "neutron_url"=$null;
        "quantum_url"=$null;
        "api_version"=$null;
    }

    $ctx = Get-JujuRelationContext -Relation 'cloud-compute' -RequiredContext $required -OptionalContext $optionalCtx

    if(!$ctx.Count -or (!$ctx["neutron_url"] -and !$ctx["quantum_url"])) {
        Write-JujuWarning "Missing required relation settings for Neutron. Peer not ready?"
        return @{}
    }

    if(!$ctx["neutron_url"]){
        $ctx["neutron_url"] = $ctx["quantum_url"]
    }
    if(!$ctx["api_version"] -or $ctx["api_version"] -eq 2) {
        $ctx["api_version"] = "2.0"
    }

    $ctx["neutron_auth_strategy"] = "keystone"
    $ctx["log_dir"] = $logdir
    $ctx["vmswitch_name"] = $switchName
    $ctx["neutron_admin_auth_uri"] = "{0}://{1}:{2}" -f @($ctx["service_protocol"], $ctx['auth_host'], $ctx['service_port'])
    $ctx["neutron_admin_auth_url"] = "{0}://{1}:{2}" -f @($ctx["auth_protocol"], $ctx['auth_host'], $ctx['auth_port'])
    $ctx["local_ip"] = [string](Get-CharmState -Namespace "novahyperv" -Key "local_ip")
    return $ctx
}

function Get-GlanceContext {
    Write-JujuLog "Getting glance context"
    $rids = Get-JujuRelationIds -Relation 'image-service'
    if(!$rids){
        return @{}
    }

    $required = @{
        "glance-api-server"=$null;
    }
    $ctx = Get-JujuRelationContext -Relation 'image-service' -RequiredContext $required -OptionalContext $optionalCtx
    $new = @{}
    foreach($i in $ctx.Keys){
        $new[$i.Replace("-", "_")] = $ctx[$i]
    }
    return $new
}

function Get-CharmConfigContext {
    $config = Get-JujuCharmConfig
    $asHash = @{}
    foreach ($i in $config.GetEnumerator()){
        $name = $i.Key
        if($name -eq "instances-dir"){
            continue
        }
        if($i.Value.Gettype() -is [System.String]){
            $v = ($i.Value).Replace('/', '\')
        }else{
            $v = $i.Value
        }
        $asHash[$name.Replace("-", "_")] = $v 
    }
    [string]$ip = Get-JujuUnitPrivateIP
    $asHash['my_ip'] = $ip 
    return $asHash
}

function Get-SystemContext {
    $asHash = @{
        "installDir" = $INSTALL_DIR;
        "force_config_drive" = "False";
        "config_drive_inject_password" = "False";
        "config_drive_cdrom" = "False";
    }
    if((Get-IsNanoServer)){
        $asHash["force_config_drive"] = "True";
        $asHash["config_drive_inject_password"] = "True";
        $asHash["config_drive_cdrom"] = "True";
    }
    return $asHash
}

function Set-IncompleteStatusContext {
    Param(
        [array]$ContextSet=@(),
        [array]$Incomplete=@()
    )
    $status = Get-JujuStatus -Full
    $currentIncomplete = @()
    if($status["message"]){
        $msg = $status["message"].Split(":")
        if($msg.Count -ne 2){
            return
        }
        if($msg[0] -eq "Incomplete contexts") {
            $currentIncomplete = $msg[1].Split(", ")
        }
    }
    $newIncomplete = [System.Collections.Generic.List[object]](New-Object "System.Collections.Generic.List[object]")
    if(!$Incomplete){
        foreach($i in $currentIncomplete) {
            if ($i -in $ContextSet){
                continue
            }
            $newIncomplete.Add($i)
        }
    } else {
        foreach($i in $currentIncomplete) {
            if($i -in $ContextSet -and !($i -in $Incomplete)){
                continue
            } else {
                $newIncomplete.Add($i)
            }
        }
        foreach($i in $Incomplete) {
            if ($i -in $newIncomplete) {
                continue
            }
            $newIncomplete.Add($i)
        }
    }
    if($newIncomplete){
        $msg = "Incomplete contexts: {0}" -f ($newIncomplete -Join ", ")
        Set-JujuStatus -Status blocked -Message $msg
    } else {
        Set-JujuStatus -Status waiting -Message "Contexts are complete"
    }
}

function Start-InstallHook {
    if(!(Get-IsNanoServer)){
        try {
            Set-MpPreference -DisableRealtimeMonitoring $true
        } catch {
            # No need to error out the hook if this fails.
            Write-JujuWarning "Failed to disable antivirus: $_"
        }
    }
    # Set machine to use high performance settings.
    try {
        Set-PowerProfile -PowerProfile Performance
    } catch {
        # No need to error out the hook if this fails.
        Write-JujuWarning "Failed to set power scheme."
    }
    Start-TimeResync
    $netbiosName = Convert-JujuUnitNameToNetbios
    $hostnameChanged = Get-CharmState -Namespace "Common" -Key "HostnameChanged"
    $hostnameReboot = $false
    $changeHostname = Get-JujuCharmConfig -Scope 'change-hostname'
    if ($changeHostname -and !$hostnameChanged -and ($computername -ne $netbiosName)) {
        Write-JujuWarning ("Changing computername from {0} to {1}" -f @($COMPUTERNAME, $netbiosName))
        Rename-Computer -NewName $netbiosName
        Set-CharmState -Namespace "Common" -Key "HostnameChanged" -Value $true
        $hostnameReboot = $true
    }
    $prereqReboot = Install-Prerequisites
    if ($hostnameReboot -or $prereqReboot) {
        Invoke-JujuReboot -Now
    }
    Import-CloudbaseCert
    Start-ConfigureVMSwitch
    $installerPath = Get-NovaInstaller
    Install-Nova -InstallerPath $installerPath
    Confirm-CharmPrerequisites
    Start-ConfigureNeutronAgent
    Enable-MSiSCSI
}

function Start-ConfigChangedHook {
    Start-ConfigureVMSwitch
    Confirm-CharmPrerequisites
    $adCtxt = Get-ActiveDirectoryContext
    if ($adCtxt.Count) {
        Enable-LiveMigration
    }

    $novaRestart = New-ConfigFile -ServiceName "nova"
    if ($novaRestart) {
        Write-JujuInfo "Restarting service Nova"
        Restart-Nova
    }

    $netType = Get-NetType
    if ($netType -eq "ovs") {
        $neutronRestart = New-ConfigFile -ServiceName "neutron-ovs"
    } else {
        $neutronRestart = New-ConfigFile -ServiceName "neutron"
    }
    if ($neutronRestart) {
        Write-JujuInfo "Restarting service Neutron"
        Restart-Neutron
    }
    if($novaRestart -and $neutronRestart) {
        Open-CharmPorts
        Set-JujuStatus -Status active -Message "Unit is ready"
    }
}
