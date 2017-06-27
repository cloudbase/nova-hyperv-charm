# Copyright 2014-2016 Cloudbase Solutions Srl
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
    Import-Module JujuHooks
    Import-Module JujuUtils

    $renameReboot = Rename-JujuUnit
    if ($renameReboot) {
        Invoke-JujuReboot -Now
    }
    $constraintsList = @("Microsoft Virtual System Migration Service", "cifs")
    $settings = @{
        'computername' = [System.Net.Dns]::GetHostName()
        'constraints' = Get-MarshaledObject $constraintsList
    }
    $cfg = Get-JujuCharmConfig
    if($cfg['ad-user']) {
        $adUsers = @{
            $cfg['ad-user'] = @("Domain Admins", "Users")
        }
        $settings['users'] = Get-MarshaledObject $adUsers
    }
    if($cfg['ad-computer-group']) {
        $settings['computer-group'] = $cfg['ad-computer-group']
    }
    if($cfg['ad-ou']) {
        $settings['ou-name'] = $cfg['ad-ou']
    }
    $rids = Get-JujuRelationIds -Relation "ad-join"
    foreach ($rid in $rids) {
        Set-JujuRelation -RelationId $rid -Settings $settings
    }
} catch {
    Write-HookTracebackToLog $_
    exit 1
}
