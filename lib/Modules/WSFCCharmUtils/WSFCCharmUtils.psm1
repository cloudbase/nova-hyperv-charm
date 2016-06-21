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

Import-Module JujuHooks

$COMPUTERNAME = [System.Net.Dns]::GetHostName()


function Get-WSFCContext {
    $key = "clustered-$COMPUTERNAME"
    $requiredCtxt = @{
        $key = $null;
        'cluster-name' = $null;
        'cluster-ip' = $null
    }
    $ctxt = Get-JujuRelationContext -Relation "failover-cluster" -RequiredContext $requiredCtxt
    if(!$ctxt.Count) {
        return @{}
    }
    return $ctxt
}

function Set-ClusterableStatus {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [int]$Ready=1,
        [Parameter(Mandatory=$false)]
        [string]$Relation
    )
    PROCESS {
        $relation_set = @{
            "computername"=$COMPUTERNAME; 
            "ready"=$Ready;
        }
        if($Relation) {
            $rids = Get-JujuRelationIds -Relation $Relation
        } else {
            $rids = Get-JujuRelationId
        }
        foreach ($rid in $rids){
            Write-JujuInfo ("Setting: {0} --> {1}" -f @($relation_set["computername"], $relation_set["ready"]))
            Set-JujuRelation -RelationId $rid -Settings $relation_set
        }
    }
}

function Start-WSFCRelationJoinedHook {
    $ctx = Get-ActiveDirectoryContext
    if(!$ctx.Count -or !(Confirm-IsInDomain $ctx["domainName"])) {
        Set-ClusterableStatus -Ready 0 -Relation "failover-cluster"
        return
    }

    if (Get-IsNanoServer) {
        $features = @('FailoverCluster-NanoServer')
    } else {
        $features = @('File-Services','FailoverCluster-FullServer','FailoverCluster-Powershell')
    }
    Install-WindowsFeatures -Features $features
    Set-ClusterableStatus -Ready 1 -Relation "failover-cluster"
}
