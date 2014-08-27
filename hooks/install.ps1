#
# Copyright 2014 Cloudbase Solutions SRL
#

$ErrorActionPreference = "Stop"

Import-Module -DisableNameChecking CharmHelpers
Import-Module -Force -DisableNameChecking "$psscriptroot\compute-hooks.psm1"

# $ErrorActionPreference = "Stop"

$distro_urls = @{
    'icehouse' = 'https://www.cloudbase.it/downloads/HyperVNovaCompute_Icehouse_2014_1.msi';
    'havana'='https://www.cloudbase.it/downloads/HyperVNovaCompute_Havana_2013_2_2.msi';
    'grizzly'='https://www.cloudbase.it/downloads/HyperVNovaCompute_Grizzly.msi'
}

function Juju-GetInstaller {
    $distro = charm_config -scope "openstack-origin"
    if ($distro -eq $false){
        $distro = "icehouse"
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

function Juju-NovaInstall {
    param(
        [Parameter(Mandatory=$true)]
        [string]$InstallerPath
    )
    Juju-Log "Running install"
    $hasInstaller = Test-Path $InstallerPath
    if($hasInstaller -eq $false){
        $InstallerPath = Juju-GetInstaller
    }
    Juju-Log "Installing from $InstallerPath"
    cmd.exe /C call msiexec.exe /i $InstallerPath /qb /passive /l*v $env:APPDATA\log.txt SKIPNOVACONF=1

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
