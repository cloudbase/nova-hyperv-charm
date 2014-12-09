#
# Copyright 2014 Cloudbase Solutions SRL
#

$ErrorActionPreference = "Stop"

Import-Module -DisableNameChecking CharmHelpers
Import-Module -Force -DisableNameChecking "$psscriptroot\compute-hooks.psm1"

$distro_urls = @{
    'icehouse' = 'https://www.cloudbase.it/downloads/HyperVNovaCompute_Icehouse_2014_1_3.msi';
    'juno' = 'https://www.cloudbase.it/downloads/HyperVNovaCompute_Juno_2014_2.msi';
}

function Juju-GetInstaller {
    $distro = charm_config -scope "openstack-origin"
    $installer_url = charm_config -scope "installer-url"
    if ($distro -eq $false){
        $distro = "juno"
    }
    if ($installer_url - eq $false) {
        if (!$distro_urls[$distro]){
            Juju-Error "Could not find a download URL for $distro"
        }
        $url = $distro_urls[$distro]
    }else {
        $url = $installer_url
    }
    $msi = $url.split('/')[-1]
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
