Import-Module -DisableNameChecking CharmHelpers

# we want to exit on error
$ErrorActionPreference = "Stop"

$distro_urls = @{
    'icehouse' = 'https://www.cloudbase.it/downloads/HyperVNovaCompute_Icehouse_2014_1.msi';
    'havana'='https://www.cloudbase.it/downloads/HyperVNovaCompute_Havana_2013_2_2.msi';
    'grizzly'='https://www.cloudbase.it/downloads/HyperVNovaCompute_Grizzly.msi'
}

function Juju-GetInstaller {
    $distro = charm_config -scope "openstack-origin"
    if ($distro -eq $false){
        $distro = "havana"
    }
    if (!$distro_urls[$distro]){
        Juju-Error "Could not find a download URL for $distro"
    }
    $msi = $distro_urls[$distro].split('/')[-1]
    $download_location = "$env:TEMP\" + $msi
    $installerExists = Test-Path $download_location

    if ($installerExists){
        return $download_location
    }
    ExecRetry { (new-object System.Net.WebClient).DownloadFile($distro_urls[$distro], $download_location) }
    if ($? -eq $false){
        Juju-Error "Could not download $distro_urls[$distro] to destination $download_location"
    }
    return $download_location
}

function Juju-ConfigureVMSwitch {
    $interfaces = Get-NetAdapter -Physical
    $VMswitchName = Juju-GetVMSwitch
    $DataInterfaceFromConfig = charm_config -scope "data-interface"
    $VMswitches = Get-VMSwitch -SwitchType External

    if ($VMswitches.Count -gt 0){
        Rename-VMSwitch $VMswitches[0] -NewName $VMswitchName
        return $true
    }

    if ($interfaces.GetType().BaseType -ne [System.Array]){
        # we have ony one ethernet adapter. Going to use it for
        # vmswitch
        New-VMSwitch -Name $VMswitchName -NetAdapterName $interfaces.Name -AllowManagementOS $true
        if ($? -eq $false){
            Juju-Error "Failed to create vmswitch"
        }
    }else{
        if ($DataInterfaceFromConfig){
            juju-log.exe "Trying to use $DataInterfaceFromConfig"
            $DataInterface = $interfaces | Where-Object { $_.Name -match "$DataInterfaceFromConfig" }
            if (!$DataInterface){
                juju-log.exe "Could not find $DataInterfaceFromConfig. Trying auto select"
            }else{
                New-VMSwitch -Name $VMswitchName -NetAdapterName $DataInterface.Name -AllowManagementOS $false
                if ($? -eq $false){
                    Juju-Error "Failed to create vmswitch"
                }
                return $true
            }
        }
        juju-log.exe "Could not find Data interface in config. Trying auto select from $interfaces"
        $DataInterface = $interfaces | Where-Object {$_.Status -eq "Up" -and $_.Name -notlike "Management*" }
        if($DataInterface){
            if ($interfaces.GetType().BaseType -eq [System.Array]){
                # This case is error prone. Here goes nothing
                $DataInterface = $DataInterface[0]
            }
            juju-log.exe "Using interface $DataInterface.Name"
            New-VMSwitch -Name $VMswitchName -NetAdapterName $DataInterface.Name -AllowManagementOS $false
            if ($? -eq $false){
                Juju-Error "Failed to create vmswitch"
            }
            return $true
        }
        Juju-Error "Failed to determine data interface"
    }
    return $true
}

function Juju-NovaInstall {
    param(
        [Parameter(Mandatory=$true)]
        [string]$InstallerPath
    )
    $hasInstaller = Test-Path $InstallerPath
    if($hasInstaller -eq $false){
        $InstallerPath = Juju-GetInstaller
    }
    cmd.exe /C call msiexec.exe /i $InstallerPath /qb /passive /l*v "$env:APPDATA\log.txt" SKIPNOVACONF=1
    if ($? -eq $false){
        Juju-Error "Nova failed to install"
    }
    return $true
}

function Juju-RunInstall {
    Juju-ConfigureVMSwitch
    $installerPath = Juju-GetInstaller
    Juju-NovaInstall -InstallerPath $installerPath
}

Juju-RunInstall
