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


function Get-HGSContext {
    $requiredCtxt = @{
        'ready' = $null;
        'domain-name' = $null;
        'private-ip' = $null
    }
    $ctxt = Get-JujuRelationContext -Relation "hgs" -RequiredContext $requiredCtxt
    if (!$ctxt) {
        return @{}
    }
    return $ctxt
}

try {
    Import-Module JujuHooks
    Import-Module JujuWindowsUtils

    $ctxt = Get-HGSContext
    if(!$ctxt.Count) {
        Write-JujuWarning "HGS context is not ready yet"
        exit 0
    }

    Install-WindowsFeatures -Features @('HostGuardian', 'ShieldedVMToolsAdminPack', 'FabricShieldedTools')

    $mainAdapter = Get-MainNetadapter
    Set-DnsClientServerAddress -InterfaceAlias $mainAdapter -Addresses @($ctxt['private-ip'])

    $domain = $ctxt['domain-name']
    Set-HgsClientConfiguration -AttestationServerUrl "http://$domain/Attestation" `
                               -KeyProtectionServerUrl "http://$domain/KeyProtection" -Confirm:$false
} catch {
    Write-HookTracebackToLog $_
    exit 1
}
