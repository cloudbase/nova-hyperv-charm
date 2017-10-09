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

Import-Module JujuWindowsUtils
Import-Module JujuHooks
Import-Module JujuLogging
Import-Module JujuUtils
Import-Module HyperVNetworking
Import-Module OVSCharmUtils
Import-Module JujuHelper
Import-Module S2DCharmUtils
Import-Module ADCharmUtils
Import-Module OpenStackCommon
Import-Module WSFCCharmUtils


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
    Install-WindowsFeatures -Features @('RSAT-Hyper-V-Tools')
    return $rebootNeeded
}

function New-ExeServiceWrapper {
    $pythonDir = Get-PythonDir -InstallDir $NOVA_INSTALL_DIR
    $python = Join-Path $pythonDir "python.exe"
    $updateWrapper = Join-Path $pythonDir "Scripts\UpdateWrappers.py"

    $cmd = @($python, $updateWrapper, "nova-compute = nova.cmd.compute:main")
    Invoke-JujuCommand -Command $cmd

    $cmd = @($python, $updateWrapper, "neutron-hyperv-agent = hyperv.neutron.l2_agent:main")
    Invoke-JujuCommand -Command $cmd
}

function Enable-MSiSCSI {
    Write-JujuWarning "Enabling MSiSCSI"
    $svc = Get-Service "MSiSCSI" -ErrorAction SilentlyContinue
    if ($svc) {
        Start-Service "MSiSCSI"
        Set-Service "MSiSCSI" -StartupType Automatic
    } else {
        Write-JujuWarning "MSiSCSI service was not found"
    }
}

function Get-DataPorts {
    $netType = Get-NetType
    if ($netType -eq "ovs") {
        Write-JujuWarning "Fetching OVS data ports"
        $dataPorts = Get-OVSDataPorts
        return @($dataPorts, $false)
    }
    $cfg = Get-JujuCharmConfig
    $managementOS = $cfg['vmswitch-management']
    Write-JujuWarning "Fetching data port from config"
    $dataPorts = Get-InterfaceFromConfig
    if (!$dataPorts) {
        $fallbackAdapter = Get-FallbackNetadapter
        $dataPorts = @($fallbackAdapter)
        $managementOS = $true
    }
    return @($dataPorts, $managementOS)
}

function Start-ConfigureVMSwitch {
    $vmSwitchName = Get-JujuVMSwitchName
    if(!$vmSwitchName) {
        $vmSwitchName = $NOVA_DEFAULT_SWITCH_NAME
    }
    [array]$dataPorts, $managementOS = Get-DataPorts
    $dataPort = $dataPorts[0]
    $vmSwitches = [array](Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue)
    foreach ($i in $vmSwitches) {
        if ($i.NetAdapterInterfaceDescription -eq $dataPort.InterfaceDescription) {
            $agentRestart = $false
            if($i.Name -ne $vmSwitchName) {
                $agentRestart = $true
                Rename-VMSwitch $i -NewName $vmSwitchName | Out-Null
            }
            if($i.AllowManagementOS -ne $managementOS) {
                $agentRestart = $true
                Set-VMSwitch -Name $vmSwitchName -AllowManagementOS $managementOS -Confirm:$false
            }
            if($agentRestart) {
                $netType = Get-NetType
                if($netType -eq "ovs") {
                    $status = (Get-Service -Name $OVS_VSWITCHD_SERVICE_NAME).Status
                    if($status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
                        Restart-Service $OVS_VSWITCHD_SERVICE_NAME
                    }
                }
            }
            return
        }
    }
    $vmSwitch = Get-JujuVMSwitch
    if($vmSwitch) {
        # VMSwitch was already created by it has the wrong port. We just change it.
        Set-VMSwitch -VMSwitch $vmSwitch -NetAdapterName $dataPort.Name -Confirm:$false
        return
    }
    Write-JujuWarning "Adding new vmswitch: $vmSwitchName"
    New-VMSwitch -Name $vmSwitchName -NetAdapterName $dataPort.Name -AllowManagementOS $managementOS | Out-Null
}

function Install-NovaFromZip {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$InstallerPath
    )

    if ((Test-Path $NOVA_INSTALL_DIR)) {
        Remove-Item -Recurse -Force $NOVA_INSTALL_DIR
    }
    Write-JujuWarning "Unzipping '$InstallerPath' to '$NOVA_INSTALL_DIR'"
    Expand-ZipArchive -ZipFile $InstallerPath -Destination $NOVA_INSTALL_DIR | Out-Null
    $configDir = Join-Path $NOVA_INSTALL_DIR "etc"
    if (!(Test-Path $configDir)) {
        New-Item -ItemType Directory $configDir | Out-Null
        $distro = Get-OpenstackVersion
        if($distro -eq "newton") {
            $templatesDir = Join-Path (Get-JujuCharmDir) "templates"
            $policyFile = Join-Path $templatesDir "$distro\policy.json"
            Copy-Item $policyFile $configDir | Out-Null
        }
    }
    New-ExeServiceWrapper | Out-Null
}

function Install-NovaFromMSI {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$InstallerPath
    )

    $logFile = Join-Path $env:APPDATA "nova-installer-log.txt"
    $extraParams = @("SKIPNOVACONF=1", "INSTALLDIR=`"$NOVA_INSTALL_DIR`"")
    Install-Msi -Installer $InstallerPath -LogFilePath $logFile -ExtraArgs $extraParams
    # Delete the Windows services created by default by the MSI,
    # so the charm can create them later on.
    $serviceNames = @(
        $NOVA_COMPUTE_SERVICE_NAME,
        $NEUTRON_HYPERV_AGENT_SERVICE_NAME,
        $NEUTRON_OVS_AGENT_SERVICE_NAME
    )
    Remove-WindowsServices -Names $serviceNames
}

function Install-Nova {
    Write-JujuWarning "Running Nova install"
    $installerPath = Get-InstallerPath -Project 'Nova'
    $installerExtension = $installerPath.Split('.')[-1]
    switch($installerExtension) {
        "zip" {
            Install-NovaFromZip $installerPath
        }
        "msi" {
            Install-NovaFromMSI $installerPath
        }
        default {
            Throw "Unknown installer extension: $installerExtension"
        }
    }
    $release = Get-OpenstackVersion
    Set-JujuApplicationVersion -Version $NOVA_PRODUCT[$release]['version']
    Set-CharmState -Namespace "novahyperv" -Key "release_installed" -Value $release
    Remove-Item $installerPath
}

function Get-NeutronServiceName {
    <#
    .SYNOPSIS
    Returns the neutron service name.
    #>

    $netType = Get-NetType
    $charmServices = Get-CharmServices
    if ($netType -eq "hyperv") {
        return $charmServices['neutron']['service']
    } elseif ($netType -eq "ovs") {
        return $charmServices['neutron-ovs']['service']
    }
    Throw "Unknown network type: $netType"
}

function Get-NovaServiceName {
    $charmServices = Get-CharmServices
    return $charmServices['nova']['service']
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
        if (!$migrationNet) {
            Start-ExecuteWithRetry -ScriptBlock {
                Add-VMMigrationNetwork -Subnet "$networkAddress/$prefixLength" -Confirm:$false
            } -RetryMessage "Failed to add VM migration networking. Retrying"
        }
    }
}

function New-CharmServices {
    $charmServices = Get-CharmServices
    foreach($svcName in $charmServices.Keys) {
        $agent = Get-Service $charmServices[$svcName]["service"] -ErrorAction SilentlyContinue
        if (!$agent) {
            New-Service -Name $charmServices[$svcName]["service"] `
                        -BinaryPathName $charmServices[$svcName]["serviceBinPath"] `
                        -DisplayName $charmServices[$svcName]["display_name"] -Confirm:$false
            Start-ExternalCommand { sc.exe failure $charmServices[$svcName]["service"] reset=5 actions=restart/1000 }
            Start-ExternalCommand { sc.exe failureflag $charmServices[$svcName]["service"] 1 }
            Stop-Service $charmServices[$svcName]["service"]
        }
    }
}

function Start-ConfigureNeutronAgent {
    $services = Get-CharmServices
    $netType = Get-NetType
    switch($netType) {
        "hyperv" {
            Stop-Service $services["neutron-ovs"]["service"]
            Disable-Service $services["neutron-ovs"]["service"]
            Remove-CharmState -Namespace "novahyperv" -Key "ovs_adapters_info"
            Disable-OVS
            Start-ConfigureVMSwitch
            Enable-Service $services["neutron"]["service"]
        }
        "ovs" {
            Stop-Service $services["neutron"]["service"]
            Disable-Service $services["neutron"]["service"]
            Install-OVS
            Start-ConfigureVMSwitch
            Enable-OVS
            New-OVSInternalInterfaces
            Enable-Service $services["neutron-ovs"]["service"]
        }
        Default {
            Throw "Invalid network type: $netType"
        }
    }
}

function Restart-Neutron {
    $serviceName = Get-NeutronServiceName
    Stop-Service $serviceName
    Start-Service $serviceName
    $netType = Get-NetType
    if($netType -eq "ovs") {
        $status = (Get-Service -Name $OVS_VSWITCHD_SERVICE_NAME).Status
        if($status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
            Restart-Service $OVS_VSWITCHD_SERVICE_NAME | Out-Null
        }
    }
}

function Restart-Nova {
    $serviceName = Get-NovaServiceName
    Stop-Service $serviceName
    Start-Service $serviceName
}

function Get-CharmServices {
    $distro = Get-OpenstackVersion
    $novaConf = Join-Path $NOVA_INSTALL_DIR "etc\nova.conf"
    $neutronHypervConf = Join-Path $NOVA_INSTALL_DIR "etc\neutron_hyperv_agent.conf"
    $neutronOVSConf = Join-Path $NOVA_INSTALL_DIR "etc\neutron_ovs_agent.conf"
    $serviceWrapperNova = Get-ServiceWrapper -Service "Nova" -InstallDir $NOVA_INSTALL_DIR
    $serviceWrapperNeutron = Get-ServiceWrapper -Service "Neutron" -InstallDir $NOVA_INSTALL_DIR
    $pythonDir = Get-PythonDir -InstallDir $NOVA_INSTALL_DIR
    $novaExe = Join-Path $pythonDir "Scripts\nova-compute.exe"
    $neutronHypervAgentExe = Join-Path $pythonDir "Scripts\neutron-hyperv-agent.exe"
    $neutronOVSAgentExe = Join-Path $pythonDir "Scripts\neutron-openvswitch-agent.exe"
    $jujuCharmServices = @{
        "nova" = @{
            "template" = "$distro\nova.conf"
            "service" = $NOVA_COMPUTE_SERVICE_NAME
            "binpath" = "$novaExe"
            "serviceBinPath" = "`"$serviceWrapperNova`" nova-compute `"$novaExe`" --config-file `"$novaConf`""
            "config" = "$novaConf"
            "display_name" = "Nova Compute Hyper-V Agent"
            "context_generators" = @(
                @{
                    "generator" = (Get-Item "function:Get-RabbitMQContext").ScriptBlock
                    "relation" = "amqp"
                    "mandatory" = $true
                },
                @{
                    "generator" = (Get-Item "function:Get-CloudComputeContext").ScriptBlock
                    "relation" = "cloud-compute"
                    "mandatory" = $true
                },
                @{
                    "generator" = (Get-Item "function:Get-GlanceContext").ScriptBlock
                    "relation" = "image-service"
                    "mandatory" = $true
                },
                @{
                    "generator" = (Get-Item "function:Get-CharmConfigContext").ScriptBlock
                    "relation" = "config"
                    "mandatory" = $true
                },
                @{
                    "generator" = (Get-Item "function:Get-SystemContext").ScriptBlock
                    "relation" = "system"
                    "mandatory" = $true
                },
                @{
                    "generator" = (Get-Item "function:Get-FreeRDPContext").ScriptBlock
                    "relation" = "free-rdp"
                    "mandatory" = $false
                },
                @{
                    "generator" = (Get-Item "function:Get-S2DCSVContext").ScriptBlock
                    "relation" = "csv"
                    "mandatory" = $false
                }
            )
        }
        "neutron" = @{
            "template" = "$distro\neutron_hyperv_agent.conf"
            "service" = $NEUTRON_HYPERV_AGENT_SERVICE_NAME
            "binpath" = "$neutronHypervAgentExe"
            "serviceBinPath" = "`"$serviceWrapperNeutron`" neutron-hyperv-agent `"$neutronHypervAgentExe`" --config-file `"$neutronHypervConf`""
            "config" = "$neutronHypervConf"
            "display_name" = "Neutron Hyper-V Agent"
            "context_generators" = @(
                @{
                    "generator" = (Get-Item "function:Get-RabbitMQContext").ScriptBlock
                    "relation" = "amqp"
                    "mandatory" = $true
                },
                @{
                    "generator" = (Get-Item "function:Get-CharmConfigContext").ScriptBlock
                    "relation" = "config"
                    "mandatory" = $true
                },
                @{
                    "generator" = (Get-Item "function:Get-SystemContext").ScriptBlock
                    "relation" = "system"
                    "mandatory" = $true
                }
            )
        }
        "neutron-ovs" = @{
            "template" = "$distro\neutron_ovs_agent.conf"
            "service" = $NEUTRON_OVS_AGENT_SERVICE_NAME
            "binpath" = "$neutronOVSAgentExe"
            "serviceBinPath" = "`"$serviceWrapperNeutron`" neutron-openvswitch-agent `"$neutronOVSAgentExe`" --config-file `"$neutronOVSConf`""
            "config" = "$neutronOVSConf"
            "display_name" = "Neutron Open vSwitch Agent"
            "context_generators" = @(
                @{
                    "generator" = (Get-Item "function:Get-RabbitMQContext").ScriptBlock
                    "relation" = "amqp"
                    "mandatory" = $true
                },
                @{
                    "generator" = (Get-Item "function:Get-CharmConfigContext").ScriptBlock
                    "relation" = "config"
                    "mandatory" = $true
                },
                @{
                    "generator" = (Get-Item "function:Get-SystemContext").ScriptBlock
                    "relation" = "system"
                    "mandatory" = $true
                },
                @{
                    "generator" = (Get-Item "function:Get-NeutronApiContext").ScriptBlock
                    "relation" = "neutron-plugin-api"
                    "mandatory" = $true
                }
            )
        }
    }
    return $jujuCharmServices
}

function Get-FreeRDPContext {
    Write-JujuWarning "Getting context from FreeRDP"
    $required = @{
        "enabled" = $null
        "html5_proxy_base_url" = $null
    }
    $ctx = Get-JujuRelationContext -Relation "free-rdp" -RequiredContext $required
    if (!$ctx.Count) {
        return @{}
    }
    return $ctx
}

function Get-S2DVolumeName {
    $volumeName = (Get-JujuLocalUnit) -replace '/', '-'
    return $volumeName
}

function Confirm-RunningClusterService {
    Start-Service "ClusSvc"
    $desiredStatus = [System.ServiceProcess.ServiceControllerStatus]::Running
    $retry = 0
    $maxRetries = 12
    $retryInterval = 5
    $clusterSvc = Get-Service -Name "ClusSvc"
    while($clusterSvc.Status -ne $desiredStatus) {
        if($retry -eq $maxRetries) {
            Throw ("Cluster service is not running. Current status: {0}" -f @($clusterSvc.Status))
        }
        Start-Sleep $retryInterval
        $clusterSvc = Get-Service -Name "ClusSvc"
        $retry += 1
    }
}

function Get-CSVMountPoint {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$CSVPath
    )

    $retry = 0
    $maxRetries = 12
    $retryInterval = 5
    while($retry -lt $maxRetries) {
        $csvPartitions = Start-ExecuteWithRetry {
            Get-ManagementObject -Namespace "root\MSCluster" -Class "MSCluster_DiskPartition" -ErrorAction Stop
        } -MaxRetryCount 12 -RetryInterval 5 -RetryMessage "Could not get the CSVs' partitions. Retrying"
        # Trim any possible ending '\' from the paths before comparing them
        $mountPoint = $csvPartitions | ForEach-Object { $_.MountPoints } | Where-Object { $_.Trim('\') -eq $CSVPath.Trim('\') }
        if($mountPoint) {
            return $mountPoint
        }
        Write-JujuWarning "Could not find the CSV mount point: $CSVPath. Retrying"
        Start-Sleep $retryInterval
        $retry++
    }
    return $null
}

function Confirm-CSVStatus {
    Param(
        [Parameter(Mandatory=$true)]
        [string]$CSVName,
        [Parameter(Mandatory=$true)]
        [string]$CSVPath
    )

    Confirm-RunningClusterService
    if((Get-IsNanoServer)) {
        # NOTE(ibalutoiu): On Nano Server, just check if the CSV path exists.
        if(!(Test-Path $CSVPath)) {
            return $false
        }
        return $true
    }
    # Check if the CSV is mounted locally with a timeout
    $mountPoint = Get-CSVMountPoint -CSVPath $CSVPath
    if($mountPoint) {
        return $true
    }
    # Sometimes, the above check fails when the cluster service doesn't initialize properly
    # and the node doesn't have all the CSVs mounted locally. We restart the cluster
    # service and check again. This time, if the check fails, an exception is thrown.
    Write-JujuWarning "Restarting the cluster service"
    Restart-Service "ClusSvc" | Out-Null
    Confirm-RunningClusterService
    $mountPoint = Get-CSVMountPoint -CSVPath $CSVPath
    if($mountPoint) {
        return $true
    }
    Throw "Could not find the CSV $CSVName mount point: $CSVPath"
}

function Get-S2DCSVContext {
    Write-JujuWarning "Generating context for S2D CSV"
    $required = @{"csv-paths" = $null}
    $s2dCtxt = Get-JujuRelationContext -Relation "csv" -RequiredContext $required
    if(!$s2dCtxt.Count) {
        return @{}
    }
    $s2dCtxt['csv-paths'] = Get-UnmarshaledObject $s2dCtxt['csv-paths']
    $volumeName = Get-S2DVolumeName
    $volumePath = $s2dCtxt['csv-paths'][$volumeName]
    if(!$volumePath) {
        return @{}
    }
    $csvStatus = Confirm-CSVStatus -CSVName $volumeName -CSVPath $volumePath
    if(!$csvStatus) {
        return @{}
    }
    $ctxt = @{}
    $cfg = Get-JujuCharmConfig
    if(!$cfg['enable-cluster-driver']) {
        Write-JujuWarning "S2D CSV context is ready but cluster driver is disabled"
        return $ctxt
    }
    $version = Get-OpenstackVersion
    [string]$ctxt["instances_cluster_dir"] = Join-Path $volumePath "Instances"
    $ctxt["compute_cluster_driver"] = $NOVA_PRODUCT[$version]['compute_cluster_driver']
    # Catch any IO error from mkdir, on the count that being a clustered storage
    # another node might create the folder between the time we Test-Path and
    # the time we execute mkdir. Test again in case of IO exception.
    try {
        if (!(Test-Path $ctxt["instances_cluster_dir"])) {
            New-Item -ItemType Directory $ctxt["instances_cluster_dir"] | Out-Null
        }
   } catch [System.IO.IOException] {
        if (!(Test-Path $ctxt["instances_cluster_dir"])) {
            Throw $_
        }
    }
    return $ctxt
}

function Get-CloudComputeContext {
    Write-JujuWarning "Generating context for nova cloud controller"
    $required = @{
        "service_protocol" = $null
        "service_port" = $null
        "auth_host" = $null
        "auth_port" = $null
        "auth_protocol" = $null
        "service_tenant_name" = $null
        "service_username" = $null
        "service_password" = $null
        "region" = $null
        "api_version" = $null
    }
    $optionalCtx = @{
        "neutron_url" = $null
        "quantum_url" = $null
    }
    $ctx = Get-JujuRelationContext -Relation 'cloud-compute' -RequiredContext $required -OptionalContext $optionalCtx
    if (!$ctx.Count -or (!$ctx["neutron_url"] -and !$ctx["quantum_url"])) {
        Write-JujuWarning "Missing required relation settings for Neutron. Peer not ready?"
        return @{}
    }
    if (!$ctx["neutron_url"]) {
        $ctx["neutron_url"] = $ctx["quantum_url"]
    }
    $ctx["auth_strategy"] = "keystone"
    $ctx["admin_auth_uri"] = "{0}://{1}:{2}" -f @($ctx["service_protocol"], $ctx['auth_host'], $ctx['service_port'])
    $ctx["admin_auth_url"] = "{0}://{1}:{2}" -f @($ctx["auth_protocol"], $ctx['auth_host'], $ctx['auth_port'])
    return $ctx
}

function Get-NeutronApiContext {
    Write-JujuWarning "Generating context for neutron-api"
    $required = @{
        "overlay-network-type" = $null
    }
    $ctxt = Get-JujuRelationContext -Relation 'neutron-plugin-api' -RequiredContext $required
    if(!$ctxt.Count) {
        return @{}
    }
    $ctxt["tunnel_types"] = $ctxt['overlay-network-type']
    $ctxt["local_ip"] = Get-OVSLocalIP
    return $ctxt
}

function Get-HGSContext {
    $requiredCtxt = @{
        'private-address' = $null
        'hgs-domain-name' = $null
        'hgs-service-name' = $null
    }
    $ctxt = Get-JujuRelationContext -Relation "hgs" -RequiredContext $requiredCtxt
    if (!$ctxt) {
        return @{}
    }
    return $ctxt
}

function Get-SystemContext {
    $release = Get-OpenstackVersion
    $ovsDBSockFile = Join-Path $env:ProgramData "openvswitch\db.sock"
    $ctxt = @{
        "install_dir" = "$NOVA_INSTALL_DIR"
        "force_config_drive" = "False"
        "config_drive_inject_password" = "False"
        "config_drive_cdrom" = "False"
        "vmswitch_name" = Get-JujuVMSwitchName
        "compute_driver" = $NOVA_PRODUCT[$release]['compute_driver']
        "my_ip" = Get-JujuUnitPrivateIP
        "lock_dir" = "$NOVA_DEFAULT_LOCK_DIR"
        "ovs_db_sock_file" = "$ovsDBSockFile"
    }
    if(!(Test-Path -Path $ctxt['lock_dir'])) {
        New-Item -ItemType Directory -Path $ctxt['lock_dir']
    }
    if (Get-IsNanoServer) {
        $ctxt["force_config_drive"] = "True"
        $ctxt["config_drive_inject_password"] = "True"
        $ctxt["config_drive_cdrom"] = "True"
    }
    return $ctxt
}

function Get-CharmConfigContext {
    $ctxt = Get-ConfigContext
    if(!$ctxt['log_dir']) {
        $ctxt['log_dir'] = "$NOVA_DEFAULT_LOG_DIR"
    }
    if(!$ctxt['instances_dir']) {
        $ctxt['instances_dir'] = "$NOVA_DEFAULT_INSTANCES_DIR"
    }
    foreach($dir in @($ctxt['log_dir'], $ctxt['instances_dir'])) {
        if (!(Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir
        }
    }
    return $ctxt
}

function Uninstall-Nova {
    $productNames = $NOVA_PRODUCT[$SUPPORTED_OPENSTACK_RELEASES].Name
    $productNames += $NOVA_PRODUCT['beta_name']
    $installedProductName = $null
    foreach($name in $productNames) {
        if(Get-ComponentIsInstalled -Name $name -Exact) {
            $installedProductName = $name
            break
        }
    }
    if($installedProductName) {
        Write-JujuWarning "Uninstalling '$installedProductName'"
        Uninstall-WindowsProduct -Name $installedProductName
    }
    $serviceNames = @(
        $NOVA_COMPUTE_SERVICE_NAME,
        $NEUTRON_HYPERV_AGENT_SERVICE_NAME,
        $NEUTRON_OVS_AGENT_SERVICE_NAME
    )
    Remove-WindowsServices -Names $serviceNames
    if(Test-Path $NOVA_INSTALL_DIR) {
        Remove-Item -Recurse -Force $NOVA_INSTALL_DIR
    }
    Remove-CharmState -Namespace "novahyperv" -Key "release_installed"
}

function Start-UpgradeOpenStackVersion {
    $installedRelease = Get-CharmState -Namespace "novahyperv" -Key "release_installed"
    $release = Get-OpenstackVersion
    if($installedRelease -and ($installedRelease -ne $release)) {
        Write-JujuWarning "Changing Nova Compute release from '$installedRelease' to '$release'"
        Uninstall-Nova
        Install-Nova
    }
}

function Set-HyperVUniqueMACAddressesPool {
    $registryNamespace = "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Virtualization"
    $randomBytes = @(
        [byte](Get-Random -Minimum 0 -Maximum 255),
        [byte](Get-Random -Minimum 0 -Maximum 255)
    )
    # Generate unique pool of MAC addresses
    $minMacAddress = @(0x00, 0x15, 0x5D, $randomBytes[0], $randomBytes[1], 0x00)
    Set-ItemProperty -Path $registryNamespace -Name "MinimumMacAddress" -Value ([byte[]]$minMacAddress)
    $maxMacAddress = @(0x00, 0x15, 0x5D, $randomBytes[0], $randomBytes[1], 0xff)
    Set-ItemProperty -Path $registryNamespace -Name "MaximumMacAddress" -Value ([byte[]]$maxMacAddress)
}

function Set-S2DHealthChecksRelation {
    $s2dRelationCreated = Confirm-JujuRelationCreated -Relation 's2d'
    $csvRelationCreated = Confirm-JujuRelationCreated -Relation 'csv'
    if(!$s2dRelationCreated -or !$csvRelationCreated) {
        return
    }
    $rids = Get-JujuRelationIds 's2d-health-check'
    foreach($rid in $rids) {
        Set-JujuRelation -RelationId $rid -Settings @{
            'system-check-date' = (Get-Date).ToString()
            'csv-name' = Get-S2DVolumeName
        }
    }
}

function Set-CharmUnitStatus {
    Param(
        [array]$IncompleteRelations=@()
    )

    if(!$IncompleteRelations.Count) {
        Open-Ports -Ports $NOVA_CHARM_PORTS | Out-Null
        $msg = "Unit is ready"
        $s2dCsvCtxt = Get-S2DCSVContext
        if($s2dCsvCtxt.Count) {
            $msg += " and clustered"
        }
        Set-JujuStatus -Status active -Message $msg
        return
    }
    $IncompleteRelations = $IncompleteRelations | Select-Object -Unique
    $msg = "Incomplete relations: {0}" -f @($IncompleteRelations -join ', ')
    Set-JujuStatus -Status blocked -Message $msg
}

function Invoke-InstallHook {
    if (!(Get-IsNanoServer)) {
        try {
            Set-MpPreference -DisableRealtimeMonitoring $true
        } catch {
            # No need to error out the hook if this fails.
            Write-JujuWarning "Failed to disable real-time monitoring."
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
    $prereqReboot = Install-Prerequisites
    if ($prereqReboot) {
        Invoke-JujuReboot -Now
    }
    Set-HyperVUniqueMACAddressesPool
    Install-Nova
}

function Invoke-StopHook {
    if(!(Get-IsNanoServer)) {
        Disable-OVS
        Uninstall-OVS
        Remove-CharmState -Namespace "novahyperv" -Key "ovs_adapters_info"
    }
    Uninstall-Nova
    $vmSwitch = Get-JujuVMSwitch
    if($vmSwitch) {
        $vmSwitch | Remove-VMSwitch -Force -Confirm:$false
    }
}

function Invoke-ConfigChangedHook {
    Start-UpgradeOpenStackVersion
    New-CharmServices
    Enable-MSiSCSI
    Start-ConfigureNeutronAgent
    $adCtxt = Get-ActiveDirectoryContext
    if(($adCtxt -ne $null) -and ($adCtxt.Count -gt 1) -and (Confirm-IsInDomain $adCtxt['domainName'])) {
        Enable-LiveMigration
        $cfg = Get-JujuCharmConfig
        Set-VMHost -MaximumVirtualMachineMigrations $cfg['max-concurrent-live-migrations'] `
                   -MaximumStorageMigrations $cfg['max-concurrent-live-migrations']
    }
    Set-S2DHealthChecksRelation
    $incompleteRelations = @()
    $services = Get-CharmServices
    $novaIncompleteRelations = New-ConfigFile -ContextGenerators $services['nova']['context_generators'] `
                                              -Template $services['nova']['template'] `
                                              -OutFile $services['nova']['config']
    if(!$novaIncompleteRelations.Count) {
        Write-JujuWarning "Restarting service Nova"
        Restart-Nova
    } else {
        $incompleteRelations += $novaIncompleteRelations
    }
    $netType = Get-NetType
    if ($netType -eq "hyperv") {
        $contextGenerators = $services['neutron']['context_generators']
        $template = $services['neutron']['template']
        $configFile = $services['neutron']['config']
    } elseif ($netType -eq "ovs") {
        $contextGenerators = $services['neutron-ovs']['context_generators']
        $template = $services['neutron-ovs']['template']
        $configFile = $services['neutron-ovs']['config']
    }
    $neutronIncompleteRelations = New-ConfigFile -ContextGenerators $contextGenerators `
                                                 -Template $template `
                                                 -OutFile $configFile
    if (!$neutronIncompleteRelations.Count) {
        Write-JujuWarning "Restarting service Neutron"
        Restart-Neutron
    } else {
        $incompleteRelations += $neutronIncompleteRelations
    }
    Set-CharmUnitStatus -IncompleteRelations $incompleteRelations
}

function Invoke-CinderAccountsRelationJoinedHook {
    $adCtxt = Get-ActiveDirectoryContext
    if(!$adCtxt.Count -or !$adCtxt['adcredentials']) {
        Write-JujuWarning "AD context is not ready yet"
        return
    }
    $cfg = Get-JujuCharmConfig
    $adGroup = "{0}\{1}" -f @($adCtxt['netbiosname'], $cfg['ad-computer-group'])
    $adUser = $adCtxt['adcredentials'][0]["username"]
    $marshaledAccounts = Get-MarshaledObject -Object @($adGroup, $adUser)
    $relationSettings = @{
        'accounts' = $marshaledAccounts
    }
    $rids = Get-JujuRelationIds 'cinder-accounts'
    foreach($rid in $rids) {
        Set-JujuRelation -RelationId $rid -Settings $relationSettings
    }
}

function Invoke-LocalMonitorsRelationJoined {
    $rids = Get-JujuRelationIds -Relation 'local-monitors'
    if(!$rids) {
        Write-JujuWarning "Relation 'local-monitors' is not established yet."
        return
    }
    $novaService = Get-NovaServiceName
    $neutronService = Get-NeutronServiceName
    $monitors = @{
        'monitors' = @{
            'remote' = @{
                'nrpe' = @{
                    'hyper_v_health_ok_check' = @{
                        'command' = "CheckCounter -a Counter=`"\\Hyper-V Virtual Machine Health Summary\\Health Ok`""
                    }
                    'hyper_v_health_critical_check' = @{
                        'command' = "CheckCounter -a Counter=`"\\Hyper-V Virtual Machine Health Summary\\Health Critical`""
                    }
                    'hyper_v_logical_processors' = @{
                        'command' = "CheckCounter -a Counter=`"\\Hyper-V Hypervisor\\Logical Processors`""
                    }
                    'hyper_v_virtual_processors' = @{
                        'command' = "CheckCounter -a Counter=`"\\Hyper-V Hypervisor\\Virtual Processors`""
                    }
                    'nova_compute_service_status' = @{
                        'command' = "check_service -a service=$novaService"
                    }
                    'neutron_service_status' = @{
                        'command' = "check_service -a service=$neutronService"
                    }
                }
            }
        }
    }
    $settings = @{
        'monitors' = Get-MarshaledObject $monitors
    }
    foreach($rid in $rids) {
        Set-JujuRelation -RelationId $rid -Settings $settings
    }
}

function Invoke-HGSRelationJoined {
    $adCtxt = Get-ActiveDirectoryContext
    if(!$adCtxt.Count -or !(Confirm-IsInDomain $adCtxt['domainName'])) {
        Write-JujuWarning "AD context is not ready yet"
        return
    }
    $domainUser = "{0}\{1}" -f @($adCtxt['domainName'], $adCtxt['username'])
    $securePass = ConvertTo-SecureString $adCtxt['password'] -AsPlainText -Force
    $adCredential = New-Object System.Management.Automation.PSCredential($domainUser, $securePass)
    $session = New-CimSession -Credential $adCredential
    $adGroupName = Get-JujuCharmConfig -Scope 'ad-computer-group'
    $adGroup = Get-CimInstance -ClassName "Win32_Group" -Filter "Name='$adGroupName'" -CimSession $session
    $relationSettings = @{
        'ad-address' = $adCtxt['address']
        'ad-domain-name' = $adCtxt['domainName']
        'ad-user'= $adCtxt['username']
        'ad-user-password' = $adCtxt['password']
        'ad-group-sid' = $adGroup.SID
    }
    $rids = Get-JujuRelationIds -Relation 'hgs'
    foreach($rid in $rids) {
        Set-JujuRelation -RelationId $rid -Settings $relationSettings
    }
}

function Invoke-HGSRelationChanged {
    $ctxt = Get-HGSContext
    if(!$ctxt.Count) {
        Write-JujuWarning "HGS context is not ready yet"
        return
    }
    Write-JujuWarning "Installing required HGS features"
    Install-WindowsFeatures -Features @('HostGuardian', 'RSAT-Shielded-VM-Tools', 'FabricShieldedTools')
    $nameservers = Get-CharmState -Namespace "novahyperv" -Key "nameservers"
    if(!$nameservers) {
        # Save the current DNS nameservers before pointing the DNS to the HGS server
        $nameservers = Get-PrimaryAdapterDNSServers
        Set-CharmState -Namespace "novahyperv" -Key "nameservers" -Value $nameservers
    }
    Set-DnsClientServerAddress -InterfaceAlias * -Addresses @($ctxt['private-address'])
    $hgsAddress = "{0}.{1}" -f @($ctxt['hgs-service-name'], $ctxt['hgs-domain-name'])
    Set-HgsClientConfiguration -AttestationServerUrl "http://$hgsAddress/Attestation" `
                               -KeyProtectionServerUrl "http://$hgsAddress/KeyProtection" -Confirm:$false
}

function Invoke-HGSRelationDeparted {
    # Restore the DNS'es saved before pointing the DNS to the HGS server
    $nameservers = Get-CharmState -Namespace "novahyperv" -Key "nameservers"
    if($nameservers) {
        Set-DnsClientServerAddress -InterfaceAlias * -Addresses $nameservers
        Remove-CharmState -Namespace "novahyperv" -Key "nameservers"
    }
}

function Invoke-AMQPRelationJoinedHook {
    $username, $vhost = Get-RabbitMQConfig
    $relationSettings = @{
        'username' = $username
        'vhost' = $vhost
    }
    $rids = Get-JujuRelationIds -Relation "amqp"
    foreach ($rid in $rids){
        Set-JujuRelation -RelationId $rid -Settings $relationSettings
    }
}

function Invoke-MySQLDBRelationJoinedHook {
    $database, $databaseUser = Get-MySQLConfig
    $settings = @{
        'database' = $database
        'username' = $databaseUser
        'hostname' = Get-JujuUnitPrivateIP
    }
    $rids = Get-JujuRelationIds 'mysql-db'
    foreach ($r in $rids) {
        Set-JujuRelation -Settings $settings -RelationId $r
    }
}

function Invoke-WSFCRelationJoinedHook {
    $ctx = Get-ActiveDirectoryContext
    if(!$ctx.Count -or !(Confirm-IsInDomain $ctx["domainName"])) {
        Set-ClusterableStatus -Ready $false -Relation "failover-cluster"
        return
    }
    if (Get-IsNanoServer) {
        $features = @('FailoverCluster-NanoServer')
    } else {
        $features = @('Failover-Clustering', 'File-Services')
    }
    Install-WindowsFeatures -Features $features
    Set-ClusterableStatus -Ready $true -Relation "failover-cluster"
}

function Invoke-S2DRelationJoinedHook {
    $adCtxt = Get-ActiveDirectoryContext
    if (!$adCtxt.Count) {
        Write-JujuWarning "Delaying the S2D relation joined hook until AD context is ready"
        return
    }
    $wsfcCtxt = Get-WSFCContext
    if (!$wsfcCtxt.Count) {
        Write-JujuWarning "Delaying the S2D relation joined hook until WSFC context is ready"
        return
    }
    $settings = @{
        'ready' = $true
        'computername' = [System.Net.Dns]::GetHostName()
        'cluster-name' = $wsfcCtxt['cluster-name']
        'cluster-ip' = $wsfcCtxt['cluster-ip']
    }
    $rids = Get-JujuRelationIds -Relation 's2d'
    foreach ($rid in $rids) {
        Set-JujuRelation -RelationId $rid -Settings $settings
    }
}

function Invoke-CSVRelationJoinedHook {
    $rids = Get-JujuRelationIds -Relation 'csv'
    if(!$rids) {
        Write-JujuWarning "Relation 'csv' is not established yet."
        return
    }
    $cfg = Get-JujuCharmConfig
    if(!$cfg['csv-performance-size'] -and !$cfg['csv-capacity-size']) {
        Write-JujuWarning "Neither of the config options csv-performance-size or csv-capacity-size was specifed"
        Set-JujuStatus -Status 'blocked' -Message 'CSV relation established, but csv was not configured'
        return
    }
    $relationSettings = @{
        'volume-name' = Get-S2DVolumeName
    }
    if($cfg['csv-performance-size']) {
        $relationSettings['performance-tier-size'] = $cfg['csv-performance-size']
    }
    if($cfg['csv-capacity-size']) {
        $relationSettings['capacity-tier-size'] = $cfg['csv-capacity-size']
    }
    $rids = Get-JujuRelationIds -Relation 'csv'
    foreach ($rid in $rids) {
        Set-JujuRelation -RelationId $rid -Settings $relationSettings
    }
}
