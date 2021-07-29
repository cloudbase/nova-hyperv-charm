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

$WINDOWS_GROUP_SIDS = @{
    "Remote Desktop Users" = "S-1-5-32-555"
    "Remote Management Users" = "S-1-5-32-580"
    "Hyper-V Administrators" = "S-1-5-32-578"
}
$NOVA_CC_CA_CERT = Join-Path $NOVA_CONFIG_DIR "nova_cc_ca_cert.pem"

function Install-Prerequisites {
    <#
    .SYNOPSIS
    Returns a boolean to indicate if a reboot is needed or not
    #>
    if (Get-IsNanoServer) {
        return $false
    }
    $rebootNeeded = $false
    $cfg = Get-JujuCharmConfig
    $extraFeatures = $cfg["extra-windows-features"]
    if ($extraFeatures) {
        $extraFeatures = $extraFeatures.Split()
        $extraFeaturesNeedsReboot = Install-WindowsFeatures -Features $extraFeatures -SuppressReboot:$true
        if ($extraFeaturesNeedsReboot) {
            $rebootNeeded = $true
        }
    }

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
    }

    $stat = Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-Management-PowerShell' -All -NoRestart
    if ($stat.RestartNeeded) {
        $rebootNeeded = $true
    }
    $featuresReboot = Install-WindowsFeatures -Features @('RSAT-Hyper-V-Tools') -SuppressReboot:$true
    if ($featuresReboot) {
        $rebootNeeded = $true
    }
    if (Enable-MPIO) {
        $rebootNeeded = $true
    }
    return $rebootNeeded
}

function Enable-MPIO {
    $cfg = Get-JujuCharmConfig
    if (!$cfg['enable-multipath-io']) {
        return $false
    }
    $mpioState = Get-WindowsOptionalFeature -Online -FeatureName MultiPathIO
    if ($mpioState.State -like "Enabled") {
        Write-JujuWarning "MPIO already enabled"
        $autoClaim = Get-MSDSMAutomaticClaimSettings
        if (!$autoclaim.iSCSI) {
            Enable-MSDSMAutomaticClaim -BusType iSCSI -ErrorAction SilentlyContinue | Out-Null
        }
        return $false
    }
    Write-JujuWarning "Enabling MultiPathIO feature"
    $status = Enable-WindowsOptionalFeature -Online -FeatureName MultiPathIO -NoRestart
    return $status.RestartNeeded
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
    $extraParams = @("SKIPNOVACONF=1", "INSTALLDIR=`"$NOVA_INSTALL_DIR`"", "ADDLOCAL=`"HyperVNovaCompute,NeutronHyperVAgent,NeutronOVSAgent,CeilometerComputeAgent,FreeRDP`"")
    Install-Msi -Installer $InstallerPath -LogFilePath $logFile -ExtraArgs $extraParams
    # Delete the Windows services created by default by the MSI,
    # so the charm can create them later on.
    $serviceNames = @(
        $NOVA_COMPUTE_SERVICE_NAME,
        $NEUTRON_HYPERV_AGENT_SERVICE_NAME,
        $NEUTRON_OVS_AGENT_SERVICE_NAME
    )
    foreach($serviceName in $serviceNames) {
        $service = Get-ManagementObject -ClassName "Win32_Service" -Filter "Name='$serviceName'"
        if($service) {
            Stop-Service $serviceName -Force
        }
    }
    # Add a trigger to neutron-ovs-agent so it does not start before ovs-vswitch.
    # This is necessary because neutron-ovs-agent has dependencies of ovs-vswitchd.
    # ovs-vswitchd is started on demand by a wmiprovider trigger (it waits for the wmi to be available so it can talk to vmswitch)
    # Because neutron-ovs-agent starts earlier than ovs-vswitchd, the task manager
    # starts ovs-vswitchd on neutron-ovs-agent start because it's a dependent service for the latter. In doing so, it ignores
    # the startup trigger configured on ovs-vswitchd. To overcome this, we will set the same start trigger present on ovs-vswitchd
    # to neutron-ovs-agent
    Start-ExternalCommand { sc.exe config $NEUTRON_OVS_AGENT_SERVICE_NAME start= demand } | Out-Null
    Start-ExternalCommand { sc.exe triggerinfo $NEUTRON_OVS_AGENT_SERVICE_NAME "start/strcustom/6066F867-7CA1-4418-85FD-36E3F9C0600C/VmmsWmiEventProvider" } | Out-Null
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

function Get-NovaServiceName {
    $charmServices = Get-CharmServices
    return $charmServices['nova']['service']
}

function Enable-LiveMigration {
    Enable-VMMigration
    $bindingAddress = Get-NetworkPrimaryAddress -Binding "migration"
    if (!$bindingAddress) {
        # TODO(gsamfira): Shouls we error?
        Write-JujuWarning "Failed to get binding IP address for migration network. Skipping live migration."
        return
    }
    $netAddresses = Get-NetIPAddress -IPAddress $bindingAddress
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

function Restart-Nova {
    $serviceName = Get-NovaServiceName
    Stop-Service $serviceName
    Start-Service $serviceName
}

function Get-CharmServices {
    $distro = Get-OpenstackVersion
    $novaConf = Join-Path $NOVA_INSTALL_DIR "etc\nova.conf"
    $serviceWrapperNova = Get-ServiceWrapper -Service "Nova" -InstallDir $NOVA_INSTALL_DIR
    $pythonDir = Get-PythonDir -InstallDir $NOVA_INSTALL_DIR
    $novaExe = Join-Path $pythonDir "Scripts\nova-compute.exe"
    $hasSMB = Confirm-JujuRelationCreated -Relation 'smb-share'
    $hasETCd = Confirm-JujuRelationCreated -Relation 'etcd'
    $jujuCharmServices = @{
        "nova" = @{
            "template" = "$distro/nova_conf"
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
                    "generator" = (Get-Item "function:Get-WSGateContext").ScriptBlock
                    "relation" = "wsgate"
                    "mandatory" = $false
                },
                @{
                    "generator" = (Get-Item "function:Get-S2DCSVContext").ScriptBlock
                    "relation" = "csv"
                    "mandatory" = $false
                },
                @{
                    "generator" = (Get-Item "function:Get-CoordinationBackendContext").ScriptBlock
                    "relation" = "etcd or smb-share"
                    "mandatory" = (Confirm-JujuRelationCreated -Relation 'csv')
                },
                @{
                    "generator" = (Get-Item "function:Get-NeutronPluginContext").ScriptBlock
                    "relation" = "neutron-plugin"
                    "mandatory" = $true
                }
            )
        }
    }
    return $jujuCharmServices
}

function Get-CoordinationBackendContext {
    $cfg = Get-JujuCharmConfig
    $coordBackend = $cfg["coordination-backend"]
    if($coordBackend) {
        Write-JujuWarning "Coordination backend overwritten in config. Skipping etcd context"
        return @{
            "coordination_backend_url" = $coordBackend
        }
    }

    $ctx = Get-SMBShareContext
    if (!$ctx.Count) {
        $ctx = Get-EtcdContext
        if (!$ctx.Count) {
            return @{}
        }
    }
    return $ctx
}

function Get-SMBShareContext {
    $requiredCtxt = @{
        "share" = $null
    }
    $ctxt = Get-JujuRelationContext -Relation "smb-share" -RequiredContext $requiredCtxt
    if(!$ctxt.Count) {
        Write-JujuWarning "smb-share context not ready"
        return @{}
    }
    $ret = @{
        "coordination_backend_url" = ("file://{0}" -f $ctxt["share"])
    }
    return $ret
}

function Get-NeutronPluginContext{
    Write-JujuWarning "Getting context for neutron-plugin"
    $required = @{
        "vswitch-name" = $null
        "neutron-service-name" = $null
    }
    $ctx = Get-JujuRelationContext -Relation "neutron-plugin" -RequiredContext $required
    if (!$ctx.Count) {
        return @{}
    }
    $ctx["vmswitch_name"] = $ctx["vswitch-name"]
    return $ctx
}

function Get-WSGateContext {
    Write-JujuWarning "Getting context from FreeRDP"
    $adCtx = Get-ActiveDirectoryContext
    if (!$adCtx.Count) {
        Write-JujuWarning "Get-WSGateContext: Not yet part of AD. Defering for later."
        return @{}
    }

    $required = @{
        "enabled" = $null
        "html5_proxy_base_url" = $null
        "allow_user" = $null
    }
    $ctx = Get-JujuRelationContext -Relation "free-rdp" -RequiredContext $required
    if (!$ctx.Count) {
        return @{}
    }
    $ret = @{}
    foreach($item in $ctx.Keys){
        $ret[$item] = ConvertFrom-Yaml $ctx[$item]
    }
    if ($ret["allow_user"]["netbios_domain"]) {
        $grpSID = $WINDOWS_GROUP_SIDS["Hyper-V Administrators"]
        $netbiosUser = "{0}\{1}" -f (
            $ret["allow_user"]["netbios_domain"], $ret["allow_user"]["username"])
        Add-UserToLocalGroup -Username $netbiosUser -GroupSID $grpSID
    }
    return $ret
}

function Get-S2DVolumeName {
    return "s2d-volume"
    # $volumeName = (Get-JujuLocalUnit) -replace '/', '-'
    # return $volumeName
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
    $computername = [System.Net.Dns]::GetHostName()
    $computeStorage = Join-Path $volumePath "ComputeStorage"
    $thisNode = Join-Path $computeStorage $computername

    $version = Get-OpenstackVersion
    [string]$ctxt["instances_dir"] = Join-Path $thisNode "Instances"
    $ctxt["compute_driver"] = $NOVA_PRODUCT[$version]['compute_cluster_driver']
    # Catch any IO error from mkdir, on the count that being a clustered storage
    # another node might create the folder between the time we Test-Path and
    # the time we execute mkdir. Test again in case of IO exception.
    Start-ExecuteWithRetry -ScriptBlock {
        if (!(Test-Path $ctxt["instances_dir"])) {
            New-Item -ItemType Directory $ctxt["instances_dir"] | Out-Null
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
        "admin_domain_name" = $null
        "ca_cert" = $null
    }
    $ctx = Get-JujuRelationContext -Relation 'cloud-compute' -RequiredContext $required -OptionalContext $optionalCtx
    if (!$ctx.Count -or (!$ctx["neutron_url"] -and !$ctx["quantum_url"])) {
        Write-JujuWarning "Missing required relation settings for Neutron. Peer not ready?"
        return @{}
    }
    if (!$ctx["neutron_url"]) {
        $ctx["neutron_url"] = $ctx["quantum_url"]
    }

    if ($ctx["ca_cert"]) {
        Write-FileFromBase64 -File $NOVA_CC_CA_CERT -Content $ctx["ca_cert"]
        $ctx["ssl_ca_cert"] = $NOVA_CC_CA_CERT

    }
    $ctx["auth_strategy"] = "keystone"
    $ctx["admin_auth_uri"] = "{0}://{1}:{2}" -f @($ctx["service_protocol"], $ctx['auth_host'], $ctx['service_port'])
    $ctx["admin_auth_url"] = "{0}://{1}:{2}" -f @($ctx["auth_protocol"], $ctx['auth_host'], $ctx['auth_port'])
    return $ctx
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

function Get-ServiceWrapperConfigContext {
    return @{
        "install_dir" = $NOVA_INSTALL_DIR
    }
}

function Get-EtcdContext {
    Write-JujuWarning "Generating context for etcd"

    $required = @{
        "client_ca" = $null
        "client_cert" = $null
        "client_key" = $null
        "connection_string" = $null
    }
    $optionalCtx = @{
        "version" = $null
    }
    $ctx = Get-JujuRelationContext -Relation 'etcd' -RequiredContext $required -OptionalContext $optionalCtx
    if (!$ctx.Count) {
        Write-JujuWarning "Missing required relation settings from Etcd. Peer not ready?"
        return @{}
    }
    # Write etcd certs
    $etcd_ca_file = Join-Path $NOVA_INSTALL_DIR "etc\etcd-ca.crt"
    $etcd_cert_file = Join-Path $NOVA_INSTALL_DIR "etc\etcd-client.crt"
    $etcd_key_file = Join-Path $NOVA_INSTALL_DIR "etc\etcd-client.key"
    # Remove the current certificates (if any) and add the new ones
    Remove-Item -Recurse -Force "$etcd_ca_file" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "$etcd_cert_file" -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force "$etcd_key_file" -ErrorAction SilentlyContinue
    # Write the new certificates
    Set-Content $etcd_ca_file $ctx["client_ca"]
    Set-Content $etcd_cert_file $ctx["client_cert"]
    Set-Content $etcd_key_file $ctx["client_key"]
    # Get first url from the connection string
    $etcd_url = $ctx["connection_string"].Split(',')
    # Set additional contexts
    $ctx["coordination_backend_url"] = "etcd3+{0}?ca_cert={1}&cert_key={2}&cert_cert={3}" -f @($etcd_url[0], [uri]::EscapeUriString("$etcd_ca_file"), [uri]::EscapeUriString("$etcd_key_file"), [uri]::EscapeUriString("$etcd_cert_file"))
    return $ctx
}

function Get-SystemContext {
    $release = Get-OpenstackVersion
    $ovsDBSockFile = Join-Path $env:ProgramData "openvswitch\db.sock"
    $ctxt = @{
        "install_dir" = "$NOVA_INSTALL_DIR"
        "force_config_drive" = "False"
        "config_drive_inject_password" = "False"
        "config_drive_cdrom" = "False"
        "compute_driver" = $NOVA_PRODUCT[$release]['compute_driver']
        "my_ip" = Get-JujuUnitPrivateIP
        "lock_dir" = "$NOVA_DEFAULT_LOCK_DIR"
        "ovs_db_sock_file" = "$ovsDBSockFile"
    }
    if(!(Test-Path -Path $ctxt['lock_dir'])) {
        New-Item -ItemType Directory -Path $ctxt['lock_dir']
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

    if (!$ctxt['reports_base_dir']) {
        $ctxt['reports_base_dir'] = Join-Path $OPENSTACK_VAR "reports"
    }

    $ctxt['reports_dir'] = Join-Path $ctxt['reports_base_dir'] "files"
    $ctxt['reports_trigger'] = Join-Path $ctxt['reports_base_dir'] "trigger"

    foreach($dir in @($ctxt['log_dir'], $ctxt['instances_dir'], $ctxt['reports_dir'], $ctxt['reports_trigger'])) {
        if (!(Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir
        }
    }
    if($ctxt['ssl_ca']) {
        $ca_file = Join-Path $NOVA_INSTALL_DIR "etc\ca.pem"
        Write-FileFromBase64 -Content $ctxt['ssl_ca'] -File $ca_file
        $ctxt['ssl_ca_file'] = $ca_file
    }
    $coordBackend = $ctxt["coordination_backend"]
    return $ctxt
}

function Invoke-FormatRawDisks {
    $cfg = Get-JujuCharmConfig
    if ($cfg['format-raw-devices']) {
        Get-Disk | Where-Object partitionstyle -eq 'raw' | `
        Initialize-Disk -PartitionStyle GPT -PassThru | `
        New-Partition -AssignDriveLetter -UseMaximumSize | `
        Format-Volume -FileSystem NTFS -Confirm:$false
    }
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

function Invoke-NeutronPluginRelationJoined {
    $cfg = Get-JujuCharmConfig
    $relationData = @{
        "openstack-version" = $cfg["openstack-distro"];
        "install-location" = $NOVA_INSTALL_DIR;
    }

    Set-JujuRelation -Settings $relationData
}

function Invoke-InstallHook {
    try {
        Set-MpPreference -DisableRealtimeMonitoring $true
    } catch {
        # No need to error out the hook if this fails.
        Write-JujuWarning "Failed to disable real-time monitoring."
    }

    # Set machine to use high performance settings.
    try {
        Set-PowerProfile -PowerProfile Performance
    } catch {
        # No need to error out the hook if this fails.
        Write-JujuWarning "Failed to set power scheme."
    }
    Start-TimeResync
    Invoke-FormatRawDisks

    $prereqReboot = Install-Prerequisites
    if ($prereqReboot) {
        Write-JujuWarning "Install-Prerequisites: Reboot required"
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

function Start-RenderServiceWrapperConfig {
    $svcWrapCtx = [System.Collections.Generic.Dictionary[string, object]](New-Object "System.Collections.Generic.Dictionary[string, object]")
    $releaseCtx = [System.Collections.Generic.Dictionary[string, object]](New-Object "System.Collections.Generic.Dictionary[string, object]")
    $svcWrapCtx["install_dir"] = $NOVA_INSTALL_DIR
    $distro = Get-OpenstackVersion

    Start-RenderTemplate -Context $svcWrapCtx `
        -TemplateName "$distro/nova_service_wrapper" `
        -OutFile (Join-Path $NOVA_INSTALL_DIR "etc\nova_service_wrapper.conf")
    Start-RenderTemplate -Context $releaseCtx `
        -TemplateName "$distro/release" `
        -OutFile (Join-Path $NOVA_INSTALL_DIR "etc\release")
}

function Invoke-ConfigChangedHook {
    $mpioReboot = Enable-MPIO
    if ($mpioReboot) {
        Write-JujuWarning "Enable-MPIO: Reboot required"
        Invoke-JujuReboot -Now
    }
    Start-UpgradeOpenStackVersion
    New-CharmServices
    Enable-MSiSCSI
    # Start-ConfigureNeutronAgent
    $adCtxt = Get-ActiveDirectoryContext
    if(($null -ne $adCtxt) -and ($adCtxt.Count -gt 1) -and (Confirm-IsInDomain $adCtxt['domainName'])) {
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

    Start-RenderServiceWrapperConfig

    if(!$novaIncompleteRelations.Count) {
        Write-JujuWarning "Restarting service Nova"
        Restart-Nova
    } else {
        $incompleteRelations += $novaIncompleteRelations
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
                }
            }
        }
    }
    $neutronPluginCtx = Get-NeutronPluginContext
    if ($neutronPluginCtx.Count) {
        $neutronService = $neutronPluginCtx["neutron-service-name"]
        $monitors["monitors"]["remote"]["nrpe"]["neutron_service_status"] = @{
            'command' = "check_service -a service=$neutronService"
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

    $hasRelation = Confirm-JujuRelationCreated -Relation "failover-cluster"
    if (!$hasRelation) {
        # This function was invoked from a hook triggered by another relation
        # That's to be expected if the failover-cluster was created before the
        # AD relation, and we need to re-run the hook after the AD relation is complete.
        return
    }

    $features = @('Failover-Clustering', 'File-Services')

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

function Invoke-SMBShareRelationJoinedHook {
    $adCtxt = Get-ActiveDirectoryContext
    if (!$adCtxt.Count) {
        Write-JujuWarning "Delaying the S2D relation joined hook until AD context is ready"
        return
    }

    $cfg = Get-ConfigContext
    if($cfg.Count -eq 0) {
        Write-JujuWarning "config context not yet ready"
        return
    }
    $adGroup = "{0}\{1}" -f @($adCtxt['netbiosname'], $cfg['ad_computer_group'])
    $adUser = $adCtxt['adcredentials'][0]["username"]

    $accounts = @(
        $adGroup,
        $adUser
    )

    $marshalledAccounts = Get-MarshaledObject -Object $accounts
    $settings = @{
        "share-name" = $cfg["share_name"]
        "accounts" = $marshalledAccounts
    }
    $rids = Get-JujuRelationIds -Relation "smb-share"
    foreach ($rid in $rids) {
        Set-JujuRelation -RelationId $rid -Settings $settings
    }
}

