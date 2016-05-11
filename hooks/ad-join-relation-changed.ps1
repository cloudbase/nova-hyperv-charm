#
# Copyright 2014-2016 Cloudbase Solutions SRL
#

$ErrorActionPreference = "Stop"

Import-Module JujuLogging

try {
    Import-Module ADCharmUtils
    Import-Module ComputeHooks
    Import-Module S2DCharmUtils
    Import-Module JujuUtils
    Import-Module JujuWindowsUtils

    if(Start-JoinDomain) {
        Start-ADJoinRelationChangedHook
        Start-ADInfoRelationJoinedHook

        $hooksFolder = Join-Path $env:CHARM_DIR "hooks"
        $wrapper = Join-Path $hooksFolder "run-with-ad-credentials.ps1"
        $hook = Join-Path $hooksFolder "prepare-s2d.ps1"
        if(Get-IsNanoServer) {
            Start-ExecuteWithRetry {
                Start-ExternalCommand { & $hook }
            }
        } else {
            Start-ExecuteWithRetry {
                Start-ExternalCommand { & $wrapper $hook }
            }
        }

        Start-WSFCRelationJoinedHook
        Start-S2DRelationChangedHook
        Start-ConfigChangedHook
    }
} catch {
    Write-HookTracebackToLog $_
    exit 1
}
