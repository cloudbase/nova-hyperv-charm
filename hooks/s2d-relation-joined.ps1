# Copyright 2016 Cloudbase Solutions Srl
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.
#

$ErrorActionPreference = "Stop"

Import-Module JujuLogging


try {
    Import-Module ComputeHooks

    # NOTE(ibalutoiu):
    # The system PowerShell modules should be already part of the environment
    # variable $env:PSModulePath. On Nano Server with Juju 2.0 they are missing
    # due to a known bug. The following line will be removed once the bug
    # it's fixed.
    $env:PSModulePath += ";{0}" -f @(Join-Path $PSHome "Modules")

    Import-Module Storage

    Remove-ExtraStoragePools
    Clear-ExtraDisks
    Invoke-S2DRelationJoinedHook
} catch {
    Write-HookTracebackToLog $_
    exit 1
}
