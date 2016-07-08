#
# Copyright 2014-2016 Cloudbase Solutions SRL
#

$ErrorActionPreference = "Stop"

Import-Module JujuLogging


try {
    Import-Module ComputeHooks

    Set-FreeRdpRelation
} catch {
    Write-HookTracebackToLog $_
    exit 1
}
