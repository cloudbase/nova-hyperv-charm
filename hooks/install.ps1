#
# Copyright 2014 Cloudbase Solutions SRL
#

$ErrorActionPreference = "Stop"

try {
    Import-Module -DisableNameChecking CharmHelpers
    Import-Module -Force -DisableNameChecking "$psscriptroot\compute-hooks.psm1"
}catch {
    juju-log.exe "Failed to run install: $_"
    exit 1
}

function Juju-RunInstall {
    juju-log.exe "Prerequisites"
    Install-Prerequisites
    juju-log.exe "Cloudbase certificate"
    Import-CloudbaseCert -NoRestart
    juju-log.exe "Configure vmswitch"
    Juju-ConfigureVMSwitch
    $installerPath = Get-NovaInstaller
    Juju-Log "Running Nova install"
    Install-Nova -InstallerPath $installerPath
    Configure-NeutronAgent
}

try{
    juju-log.exe "Starting install"
    Juju-RunInstall
}catch{
    juju-log.exe "Failed to run install: $_"
    exit 1
}
