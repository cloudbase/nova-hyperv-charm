#
# Copyright 2014-2016 Cloudbase Solutions SRL
#

$ErrorActionPreference = "Stop"

Import-Module JujuLogging


try {
    Import-Module S2DCharmUtils

    Remove-UnhealthyStoragePools
    Clear-ExtraDisks
} catch {
    Write-HookTracebackToLog $_
    exit 1
}
