#
# Copyright 2016 Cloudbase Solutions SRL
#

$ErrorActionPreference = "Stop"

Import-Module JujuLogging


try {
    Import-Module ADCharmUtils

    Start-ADInfoRelationJoinedHook
} catch {
    Write-HookTracebackToLog $_
    exit 1
}
