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
    Import-Module ADCharmUtils

    $adCtxt = Get-ActiveDirectoryContext
    if(!$adCtxt.Count) {
        # TODO(ibalutoiu):
        # This means that AD relation was removed and we need to set the
        # computer domain to default 'WORKGROUP' and do a computer reboot.
        Write-JujuWarning "AD context is empty"
        exit 0
    }

    Set-DnsClientServerAddress -InterfaceAlias * -ServerAddresses $adCtxt['address']
    Invoke-JujuCommand -Command @("ipconfig", "/flushdns")
} catch {
    Write-HookTracebackToLog $_
    exit 1
}
