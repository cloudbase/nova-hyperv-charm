#
# Copyright 2014 Cloudbase Solutions SRL
#

$ErrorActionPreference = "Stop"

Import-Module -DisableNameChecking CharmHelpers
Import-Module -Force -DisableNameChecking "$psscriptroot\compute-hooks.psm1"

function Juju-RunInstall {
    Import-CloudbaseCert
    Juju-ConfigureVMSwitch
    $installerPath = Get-NovaInstaller
    Juju-Log "Running Nova install"
    Install-Nova -InstallerPath $installerPath
}

try{
    Juju-RunInstall
}catch{
    juju-log.exe "Failed to run install: $_.Exception"
    exit 1
}
