#
# Copyright 2014-2016 Cloudbase Solutions SRL
#

$ErrorActionPreference = "Stop"

Import-Module JujuLogging


try {
    Import-Module ADCharmUtils
    Import-Module WSFCCharmUtils
    Import-Module ComputeHooks
    Import-Module S2DCharmUtils
    Import-Module JujuUtils
    Import-Module JujuWindowsUtils

    if(Start-JoinDomain) {
        $adCtxt = Get-ActiveDirectoryContext
        if(!$adCtxt["adcredentials"]) {
            Write-JujuWarning "AD user credentials are not already set"
            exit 0
        }
        Grant-Privilege -User $adCtxt["adcredentials"][0]["username"] `
                        -Grant SeServiceLogonRight

        Write-JujuInfo "Setting $serviceName AD user"
        Grant-PrivilegesOnDomainUser -Username $adCtxt["adcredentials"][0]["username"]
        $charmServices = Get-CharmServices
        $serviceName = $charmServices['nova']['service']
        Stop-Service $serviceName
        Set-ServiceLogon -Services $serviceName -UserName $adCtxt["adcredentials"][0]["username"] `
                                                -Password $adCtxt["adcredentials"][0]["password"]
        Start-Service $serviceName

        Start-ADInfoRelationJoinedHook

        $hooksFolder = Join-Path $env:CHARM_DIR "hooks"
        $wrapper = Join-Path $hooksFolder "run-with-ad-credentials.ps1"
        $hook = Join-Path $hooksFolder "prepare-s2d.ps1"
        Start-ExecuteWithRetry {
            Start-ExternalCommand { & $wrapper $hook }
        }

        Start-WSFCRelationJoinedHook
        Start-S2DRelationChangedHook
        Start-ConfigChangedHook
    }
} catch {
    Write-HookTracebackToLog $_
    exit 1
}
