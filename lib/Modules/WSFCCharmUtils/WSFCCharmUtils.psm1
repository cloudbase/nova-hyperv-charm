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

Import-Module JujuHooks
Import-Module JujuLogging


function Get-WSFCContext {
    $key = "clustered-${env:COMPUTERNAME}"
    $requiredCtxt = @{
        $key = $null
        'cluster-name' = $null
        'cluster-ip' = $null
    }
    $ctxt = Get-JujuRelationContext -Relation "failover-cluster" -RequiredContext $requiredCtxt
    if(!$ctxt.Count) {
        return @{}
    }
    return $ctxt
}

function Set-ClusterableStatus {
    Param(
        [Parameter(Mandatory=$true)]
        [boolean]$Ready=$true,
        [Parameter(Mandatory=$false)]
        [string]$Relation
    )

    $relationSettings = @{
        "computername" = $env:COMPUTERNAME
        "ready" = $Ready
    }
    if($Relation) {
        $rids = Get-JujuRelationIds -Relation $Relation
    } else {
        $rids = Get-JujuRelationId
    }
    foreach ($rid in $rids) {
        Write-JujuWarning ("Setting: {0} --> {1}" -f @($relationSettings["computername"], $relationSettings["ready"]))
        Set-JujuRelation -RelationId $rid -Settings $relationSettings
    }
}

Export-ModuleMember -Function @(
    'Get-WSFCContext',
    'Set-ClusterableStatus'
)
