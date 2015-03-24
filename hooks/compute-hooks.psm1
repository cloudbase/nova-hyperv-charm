#
# Copyright 2014 Cloudbase Solutions SRL
#
$ErrorActionPreference = "Stop"

$name = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
$fullPath = Join-Path $name "Modules\CharmHelpers"
Import-Module -Force -DisableNameChecking $fullPath

$lbfoBug = "$env:SystemDrive\lbfo-bug-workaround"
$ovs_vsctl = "${env:ProgramFiles(x86)}\Cloudbase Solutions\Open vSwitch\bin\ovs-vsctl.exe"
$ovsExtName = "Open vSwitch Extension"


function Juju-GetVMSwitch {
    $VMswitchName = charm_config -scope "vmswitch-name"
    if (!$VMswitchName){
        return "br100"
    }
    return $VMswitchName
}

function WaitFor-BondUp {
    Param(
    [Parameter(Mandatory=$true)]
    [string]$bond
    )

    $b = Get-NetLbfoTeam -Name $bond -ErrorAction SilentlyContinue
    if (!$b){
        Juju-Log "Bond interface $bond not found"
        return $false
    }
    Juju-Log "Found bond: $bond"
    $count = 0
    while ($count -lt 30){
        Juju-Log "Bond status is $b.Status"
        $b = Get-NetLbfoTeam -Name $bond -ErrorAction SilentlyContinue
        if ($b.Status -eq "Up" -or $b.Status -eq "Degraded"){
            Juju-Log ("bond interface status is " + $b.Status)
            return $true
        }
        Start-Sleep 1
        $count ++
    }
    return $false
}

function Setup-BondInterface {
    $bondExists = Get-NetLbfoTeam -Name "bond0" -ErrorAction SilentlyContinue
    if ($bondExists -ne $null){
        return $true
    }
    $bondPorts = Get-InterfaceFromConfig -ConfigOption "bond-ports"
    if ($bondPorts.Length -eq 0) {
        return $false
    }
    try {
        $bond = New-NetLbfoTeam -Name "bond0" -TeamMembers $bondPorts.Name -TeamNicName "bond0" -TeamingMode LACP -Confirm:$false
		if ($? -eq $false){
            Write-JujuError "Failed to create Lbfo team"
		}
    }catch{
        Write-JujuError "Failed to create Lbfo team: $_.Exception.Message"
    }
    $isUp = WaitFor-BondUp -bond $bond.Name
    if (!$isUp){
        Write-JujuError "Failed to bring up bond0"
    }
    return $true
}

function Get-TemplatesDir {
    $templates =  Join-Path "$env:CHARM_DIR" "templates"
    return $templates
}

function Get-PackageDir {
    $packages =  Join-Path "$env:CHARM_DIR" "packages"
    return $packages
}

function Get-FilesDir {
    $packages =  Join-Path "$env:CHARM_DIR" "files"
    return $packages
}

function Charm-Services {
    $template_dir = Get-TemplatesDir
    $distro = charm_config -scope "openstack-origin"
    $nova_config = "${env:programfiles(x86)}\Cloudbase Solutions\Openstack\Nova\etc\nova.conf"
    $neutron_config = "${env:programfiles(x86)}\Cloudbase Solutions\Openstack\Nova\etc\neutron_hyperv_agent.conf"

    $serviceWrapper = "${env:programfiles(x86)}\Cloudbase Solutions\Openstack\Nova\bin\OpenStackServiceNeutron.exe"
    $novaExe = "${env:programfiles(x86)}\Cloudbase Solutions\Openstack\Nova\Python27\Scripts\nova-compute.exe"
    $neutronHypervAgentExe = "${env:programfiles(x86)}\Cloudbase Solutions\Openstack\Nova\Python27\Scripts\neutron-hyperv-agent.exe"

    $JujuCharmServices = @{
        "nova"=@{
            "myname"="nova";
            "template"="$template_dir\$distro\nova.conf";
            "service"="nova-compute";
            "binpath"="$novaExe";
            "serviceBinPath"="`"$serviceWrapper`" nova-compute `"$novaExe`" --config-file `"$nova_config`"";
            "config"="$nova_config";
            "context_generators"=@(
                "Get-RabbitMQContext",
                "Get-NeutronContext",
                "Get-GlanceContext",
                "Get-CharmConfigContext"
                );
        };
        "neutron"=@{
            "myname"="neutron";
            "template"="$template_dir\$distro\neutron_hyperv_agent.conf"
            "service"="neutron-hyperv-agent";
            "binpath"="$neutronHypervAgentExe";
            "serviceBinPath"="`"$serviceWrapper`" neutron-hyperv-agent `"$neutronHypervAgentExe`" --config-file `"$neutron_config`"";
            "config"="$neutron_config";
            "context_generators"=@(
                "Get-RabbitMQContext",
                "Get-NeutronContext",
                "Get-CharmConfigContext"
                );
        };
    }
    return $JujuCharmServices
}

function Get-RabbitMQContext {
    Juju-Log "Generating context for RabbitMQ"
    $username = charm_config -scope 'rabbit-user'
    $vhost = charm_config -scope 'rabbit-vhost'
    if (!$username -or !$vhost){
        Write-JujuError "Missing required charm config options: rabbit-user or rabbit-vhost"
    }

    $ctx = @{
        "rabbit_host"=$null;
        "rabbit_userid"=$username;
        "rabbit_password"=$null;
        "rabbit_virtual_host"=$vhost
    }

    $relations = relation_ids -reltype 'amqp'
    foreach($rid in $relations){
        $related_units = related_units -relid $rid
        foreach($unit in $related_units){
            $ctx["rabbit_host"] = relation_get -attr "private-address" -rid $rid -unit $unit
            $ctx["rabbit_password"] = relation_get -attr "password" -rid $rid -unit $unit
            $ctx_complete = Check-ContextComplete -ctx $ctx
            if ($ctx_complete){
                break
            }
        }
    }
    $ctx_complete = Check-ContextComplete -ctx $ctx
    if ($ctx_complete){
        return $ctx
    }
    Juju-Log "RabbitMQ context not yet complete. Peer not ready?"
    return @{}
}

function Get-NeutronUrl {
    Param (
        [Parameter(Mandatory=$true)]
        [string]$rid,
        [Parameter(Mandatory=$true)]
        [string]$unit
    )

    $url = relation_get -attr 'neutron_url' -rid $rid -unit $unit
    if ($url){
        return $url
    }
    $url = relation_get -attr 'quantum_url' -rid $rid -unit $unit
    return $url
}


function Get-NeutronContext {
    Juju-Log "Generating context for Neutron"

    $logdir = charm_config -scope 'log-dir'
    $instancesDir = charm_config -scope 'instances-dir'
    $logdirExists = Test-Path $logdir
    $instancesExist = Test-Path $instancesDir

    if (!$logdirExists){
        mkdir $logdir
    }

    if (!$instancesExist){
        mkdir $instancesDir
    }

    $ctx = @{
        "neutron_url"=$null;
        "keystone_host"=$null;
        "auth_port"=$null;
        "auth_protocol"=$null;
        "neutron_auth_strategy"="keystone";
        "neutron_admin_tenant_name"=$null;
        "neutron_admin_username"=$null;
        "neutron_admin_password"=$null;
        "log_dir"=$logdir;
        "instances_dir"=$instancesDir
    }

    $rids = relation_ids -reltype 'cloud-compute'
    foreach ($rid in $rids){
        $units = related_units -relid $rid
        foreach ($unit in $units){
            $url = Get-NeutronUrl -rid $rid -unit $unit
            if (!$url){
                continue
            }
            $ctx["neutron_url"] = $url
            $ctx["keystone_host"] = relation_get -attr 'auth_host' -rid $rid -unit $unit
            $ctx["auth_port"] = relation_get -attr 'auth_port' -rid $rid -unit $unit
            $ctx["auth_protocol"] = relation_get -attr 'auth_protocol' -rid $rid -unit $unit
            $ctx["neutron_admin_tenant_name"] = relation_get -attr 'service_tenant_name' -rid $rid -unit $unit
            $ctx["neutron_admin_username"] = relation_get -attr 'service_username' -rid $rid -unit $unit
            $ctx["neutron_admin_password"] = relation_get -attr 'service_password' -rid $rid -unit $unit
            $ctx_complete = Check-ContextComplete -ctx $ctx
            if ($ctx_complete){
                break
            }
        }
    }
    $ctx_complete = Check-ContextComplete -ctx $ctx
    if (!$ctx_complete){
        Juju-Log "Missing required relation settings for Neutron. Peer not ready?"
        return @{}
    }
    $ctx["neutron_admin_auth_url"] = $ctx["auth_protocol"] + "://" + $ctx['keystone_host'] + ":" + $ctx['auth_port']+ "/v2.0"
    return $ctx
}

function Get-GlanceContext {
    Juju-Log "Getting glance context"
    $rids = relation_ids -reltype 'image-service'
    if(!$rids){
        return @{}
    }
    foreach ($i in $rids){
        $units = related_units -relid $i
        foreach ($j in $units){
            $api_server = relation_get -attr 'glance-api-server' -rid $i -unit $j
            if($api_server){
                return @{"glance_api_servers"=$api_server}
            }
        }
    }
    Juju-Log "Glance context not yet complete. Peer not ready?"
    return @{}
}


function Get-CharmConfigContext {
    $config = charm_config
    $noteProp = $config | Get-Member -MemberType NoteProperty
    $asHash = @{}
    foreach ($i in $noteProp){
        $name = $i.Name
        $asHash[$name] = $config.$name
    }
    return $asHash
}

function Generate-Config {
    param (
        [Parameter(Mandatory=$true)]
        [string]$ServiceName
    )
    $JujuCharmServices = Charm-Services
    $should_restart = $true
    $service = $JujuCharmServices[$ServiceName]
    if (!$service){
        Write-JujuError -Msg "No such service $ServiceName" -Fatal $false
        return $false
    }
    $config = gc $service["template"]
    # populate config with variables from context
    foreach ($context in $service['context_generators']){
        Juju-Log "Getting context for $context"
        $ctx = & $context
        Juju-Log "Got $context context $ctx"
        if ($ctx.Count -eq 0){
            # Context is empty. Probably peer not ready
            Juju-Log "Context for $context is EMPTY"
            $should_restart = $false
            continue
        }
        foreach ($val in $ctx.GetEnumerator()) {
            $regex = "{{[\s]{0,}" + $val.Name + "[\s]{0,}}}"
            $config = $config -Replace $regex,$val.Value
        }
    }
    # Any variables not available in context we remove
    $config = $config -Replace "{{[\s]{0,}[a-zA-Z0-9_-]{0,}[\s]{0,}}}",""
    Set-Content $service["config"] $config
    # Restart-Service $service["service"]
    return $should_restart
}

function Get-InterfaceFromConfig {
    Param (
        [string]$ConfigOption="data-port",
        [switch]$MustFindAdapter=$false
    )

    $nic = $null
    $DataInterfaceFromConfig = charm_config -scope $ConfigOption
    Juju-Log "Looking for $DataInterfaceFromConfig"
    if ($DataInterfaceFromConfig -eq $null){
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
    Juju-Log "We have MAC: $byMac  Name: $byName"
    if ($byMac.Length -ne 0){
        $nicByMac = Get-NetAdapter | Where-Object { $_.MacAddress -in $byMac }
    }
    if ($byName.Length -ne 0){
        $nicByName = Get-NetAdapter | Where-Object { $_.Name -in $byName }
    }
    if ($nicByMac -ne $null -and $nicByMac.GetType() -ne [System.Array]){
        $nicByMac = @($nicByMac)
    }
    if ($nicByName -ne $null -and $nicByName.GetType() -ne [System.Array]){
        $nicByName = @($nicByName)
    }
    $ret = $nicByMac + $nicByName
    if ($ret.Length -eq 0 -and $MustFindAdapter){
        Throw "Could not find network adapters"
    }
    return $ret
}

function Reset-Bond {
    Param(
    [Parameter(Mandatory=$true)]
    [string]$switch
    )
    $isUp = WaitFor-BondUp -bond "bond0"
    if (!$isUp){
        $s = Get-VMSwitch -name $switch -ErrorAction SilentlyContinue
        if ($s){
            stop-vm *
            Remove-VMSwitch -Name $VMswitchName -Confirm:$false -Force
        }
        $bond = Get-NetLbfoTeam -name "bond0" -ErrorAction SilentlyContinue
        if($bond){
            Remove-NetlbfoTeam -name "bond0" -Confirm:$false
        }
        Setup-BondInterface
        return $true
    }
    return $false
}

function Juju-ConfigureVMSwitch {
    $useBonding = Setup-BondInterface
    $managementOS = $false

    $VMswitchName = Juju-GetVMSwitch
    try {
        $isConfigured = Get-VMSwitch -SwitchType External -Name $VMswitchName -ErrorAction SilentlyContinue
    } catch {
        $isConfigured = $false
    }
    if ($isConfigured){
        if ($useBonding) {
            # This is a bug in the teaming feature with some drivers. If you create a VMSwitch using a bond
            # as external. After a reboot, the bond will be down unless you remove the vmswitch
            $wasReset = Reset-Bond $VMswitchName
            if(!$wasReset){
                return $true
            }
        }else{
            return $true
        }
    }else{
        if ($useBonding) {
            $wasReset = Reset-Bond $VMswitchName
        }
    }
    $VMswitches = Get-VMSwitch -SwitchType External
    if ($VMswitches.Count -gt 0){
        Rename-VMSwitch $VMswitches[0] -NewName $VMswitchName
        return $true
    }

    $interfaces = Get-NetAdapter -Physical | Where-Object {$_.Status -eq "Up"}

    if ($interfaces.GetType().BaseType -ne [System.Array]){
        # we have ony one ethernet adapter. Going to use it for
        # vmswitch
        New-VMSwitch -Name $VMswitchName -NetAdapterName $interfaces.Name -AllowManagementOS $true
        if ($? -eq $false){
            Write-JujuError "Failed to create vmswitch"
        }
    }else{
        Juju-Log "Trying to fetch data port from config"
        $nic = Get-InterfaceFromConfig -MustFindAdapter
        Juju-Log "Got NetAdapterName $nic"
        New-VMSwitch -Name $VMswitchName -NetAdapterName $nic[0].Name -AllowManagementOS $managementOS
        if ($? -eq $false){
            Write-JujuError "Failed to create vmswitch"
        }
    }
    $hasVM = Get-VM
    if ($hasVM){
        Connect-VMNetworkAdapter * -SwitchName $VMswitchName
        Start-VM *
    }
    return $true
}

$distro_urls = @{
    'icehouse' = 'https://www.cloudbase.it/downloads/HyperVNovaCompute_Icehouse_2014_1_3.msi';
    'juno' = 'https://www.cloudbase.it/downloads/HyperVNovaCompute_Juno_2014_2.msi';
}

function Download-File {
     param(
        [Parameter(Mandatory=$true)]
        [string]$url
    )

    $msi = $url.split('/')[-1]
    $download_location = Join-Path "$env:TEMP" $msi
    $installerExists = Test-Path $download_location

    if ($installerExists){
        return $download_location
    }
    Juju-Log "Downloading file from $url to $download_location"
    try {
        ExecuteWith-Retry { (new-object System.Net.WebClient).DownloadFile($url, $download_location) }
    } catch {
        Write-JujuError "Could not download $url to destination $download_location"
    }

    return $download_location
}

function Get-NovaInstaller {
    $distro = charm_config -scope "openstack-origin"
    $installer_url = charm_config -scope "installer-url"
    if ($distro -eq $false){
        $distro = "juno"
    }
    if ($installer_url -eq $false) {
        if (!$distro_urls[$distro]){
            Write-JujuError "Could not find a download URL for $distro"
        }
        $url = $distro_urls[$distro]
    }else {
        $url = $installer_url
    }
    $location = Download-File $url
    return $location
}

function Install-Nova {
    param(
        [Parameter(Mandatory=$true)]
        [string]$InstallerPath
    )
    Juju-Log "Running Nova install"
    $hasInstaller = Test-Path $InstallerPath
    if($hasInstaller -eq $false){
        $InstallerPath = Get-NovaInstaller
    }
    Juju-Log "Installing from $InstallerPath"
    cmd.exe /C call msiexec.exe /i $InstallerPath /qn /l*v $env:APPDATA\log.txt SKIPNOVACONF=1

    if ($lastexitcode){
        Write-JujuError "Nova failed to install"
    }
    return $true
}

function Disable-Service {
    param(
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
     param(
        [Parameter(Mandatory=$true)]
        [string]$ServiceName
    )

    Get-Service $ServiceName | Set-Service -StartupType Automatic
}


function Restart-Neutron {
    $services = Charm-Services
    Stop-Service $services.neutron.service
    Start-Service $services.neutron.service
}

function Restart-Nova {
    $services = Charm-Services
    Stop-Service $services.nova.service
    Start-Service $services.nova.service
}

function Stop-Neutron {
    $services = Charm-Services
    Stop-Service $services.neutron.service
}

function Import-CloudbaseCert {
    $filesDir = Get-FilesDir
    $crt = Join-Path $filesDir "Cloudbase_signing.cer"
    if (!(Test-Path $crt)){
        return $false
    }
    Import-Certificate $crt -StoreLocation LocalMachine -StoreName TrustedPublisher
}

function Run-ConfigChanged {
    Juju-ConfigureVMSwitch

    $nova_restart = Generate-Config -ServiceName "nova"
    $neutron_restart = Generate-Config -ServiceName "neutron"
    $JujuCharmServices = Charm-Services

    if ($nova_restart){
        juju-log.exe "Restarting service Nova"
        Restart-Nova
    }

    if ($neutron_restart -or $neutron_ovs_restart){
        juju-log.exe "Restarting service Neutron"
        Restart-Neutron
    }
}

Export-ModuleMember -Function * -Variable JujuCharmServices
