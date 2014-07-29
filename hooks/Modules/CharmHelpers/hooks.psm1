function ExecRetry($command, $maxRetryCount = 10, $retryInterval=2)
{
    $currErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $retryCount = 0
    while ($true)
    {
        try
        {
            & $command
            break
        }
        catch [System.Exception]
        {
            $retryCount++
            if ($retryCount -ge $maxRetryCount)
            {
                $ErrorActionPreference = $currErrorActionPreference
                throw
            }
            else
            {
                Write-Error $_.Exception
                Start-Sleep $retryInterval
            }
        }
    }

    $ErrorActionPreference = $currErrorActionPreference
}

function Juju-Error {
    param (
        [Parameter(Mandatory=$true)]
        [string]$Msg,
        [bool]$fatal=$true
    )
    juju-log.exe $Msg
    if($fatal){
        Throw $Msg
    }
}

function Restart-Service {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ServiceName
    )
    try {
        Stop-Service $ServiceName
        Start-Service $ServiceName
    }catch{
        Juju-Error -Msg "Failed to restart $ServiceName" -fatal $false
    }
}

function Check-ContextComplete {
    Param (
        [Parameter(Mandatory=$true)]
        [hashtable]$ctx
    )
    foreach ($i in $ctx.GetEnumerator()){
        if (!$i.Value){
            juju-log.exe $i.Name + " is empty"
            return $false
        }
    }
    return $true
}

function charm_dir {
    return ${env:CHARM_DIR}
}

function in_relation_hook() {
    if (${env:JUJU_RELATION}){
        return $true
    }
    return $false
}

function relation_type() {
    return ${env:JUJU_RELATION}
}

function relation_id() {
    return ${env:JUJU_RELATION_ID}
}

function local_unit() {
    return ${env:JUJU_UNIT_NAME}
}

function remote_unit() {
    return ${env:JUJU_REMOTE_UNIT}
}

function service_name() {
    return (local_unit).split("/")[0]
}

function RunCommand {
    param (
        [Parameter(Mandatory=$true)]
        [array]$cmd
    )
    $cmdJoined = $cmd -join " "
    $newCmd = "`$retval = $cmdJoined; if(`$? -eq `$false){return `$false} return `$retval"
    $scriptblock = $ExecutionContext.InvokeCommand.NewScriptBlock($newCmd)
    $ret = Invoke-Command -ScriptBlock $scriptblock

    if ($ret){
        return $ret
    }
    return $false
}

function charm_config {
    param(
        [string]$scope=$null
    )
    # Charm configuration
    $cmd = @("config-get.exe", "--format=json")
    if ($scope -ne $null){
        $cmd += $scope
    }
    $ret = RunCommand $cmd
    if ($ret){
        try{
            return $ret | ConvertFrom-Json
        }catch{
            return $false
        }
    }
    return $ret
}

function relation_get {
    param(
        [string]$attr=$null,
        [string]$unit=$null,
        [string]$rid=$null
    )
    $cmd = @("relation-get.exe", "--format=json")
    if ($rid) {
        $cmd += "-r"
        $cmd += $rid
    }
    if ($attr) {
        $cmd += $attr
    }else{
        $cmd += '-'
    }
    if ($unit){
        $cmd += $unit
    }
    $ret = RunCommand $cmd
    if ($ret){
        try{
            return $ret | ConvertFrom-Json
        }catch{
            return $false
        }
    }
    return $ret
}

function relation_set {
    param (
        [string]$relation_id=$null,
        [hashtable]$relation_settings=@{}
    )
    $cmd = @("relation-set.exe")
    if ($relation_id) {
        $cmd += "-r"
        $cmd += $relation_id
    }
    foreach ($i in $relation_settings.GetEnumerator()) {
        if ($i.Value -eq $null){
            $cmd += $i.Name + "="
        }else{
            $cmd += $i.Name + "=" + $i.Value
        }
    }
    return RunCommand $cmd
}

function relation_ids {
    param (
        [string]$reltype=$null
    )
    $cmd = @("relation-ids.exe", "--format=json")
    if ($reltype) {
        $relation_type = $reltype
    }else{
        $relation_type = relation_type
    }
    if ($relation_type){
        $cmd += $relation_type
        try{
            return RunCommand $cmd | ConvertFrom-Json
        }catch{
            return $false
        }
    }
    return $false
}

function related_units {
    # A list of related units
    param (
        [string]$relid=$null
    )
    $cmd = @("relation-list.exe", "--format=json")
    if($relid){
        $relation_id = $relid
    }else{
        $relation_id = relation_id
    }

    if ($relation_id){
        $cmd += "-r " 
        $cmd += $relation_id
    }
    $ret = RunCommand $cmd
    if ($ret){
        try{
            return $ret | ConvertFrom-Json
        }catch{
            return $false
        }
    }
    return $ret
}

function relation_for_unit {
    # Get the json represenation of a unit's relation
    param (
        [string]$unit=$null,
        [string]$rid=$null
    )
    if ($unit){
        $unit_name = $unit
    }else{
        $unit_name = remote_unit
    }
    $relation = relation_get -unit $unit_name -rid $rid
    foreach ($i in $relation.GetEnumerator()) {
        if ($i.Name.EndsWith("-list")){
            $relation[$i.Name] = $relation[$i.Name].Split()
        }
    }
    $relation['__unit__'] = $unit_name
    return $relation
}

function relations_for_id {
    # Get relations of a specific relation ID
    param(
        [string]$relid=$null
    )
    $relation_data = @()
    if ($relid) {
        $relation_id = $relid
    }else{
        $relation_id = relation_ids
    }
    $related_units = related_units -relid $relation_id
    foreach ($i in $related_units){
        $unit_data = relation_for_unit -unit $i -relid $relation_id
        $unit_data['__relid__'] = $relation_id
        $relation_data += $unit_data
    }
    return $relation_data
}

function relations_of_type {
    # Get relations of a specific type
    param (
        [string]$reltype=$null
    )
    $relation_data = @()
    if ($reltype){
        $relation_type = $reltype
    }else{
        $relation_type = relation_type
    }
    $relation_ids = relation_ids $relation_type
    foreach ($i in $relation_ids){
        $rel_for_id = relations_for_id $i
        foreach ($j in $rel_for_id){
            $j['__relid__'] = $i
            $relation_data += $j
        }
    }
    return $relation_data
}

function is_relation_made {
    # Determine whether a relation is established by checking for
    # presence of key(s).  If a list of keys is provided, they
    # must all be present for the relation to be identified as made
    param (
        [Parameter(Mandatory=$true)]
        [string]$relation,
        [string]$keys='private-address'
    )
    $keys_arr = @()
    if ($keys.GetType().Name -eq "string"){
        $keys_arr += $keys
    }else{
        $keys_arr = $keys
    }
    $relation_ids = relation_ids -reltype relation
    foreach ($i in $relation_ids){
        $related_u = related_units -relid $i
        foreach ($j in $related_u){
            $temp = @{}
            foreach ($k in $keys_arr){
                $temp[$k] = relation_get -attr $k -unit $j -rid $i
            }
            foreach ($val in $temp.GetEnumerator()){
                if ($val.Value -eq $false){
                    return $false
                }
            }
        }
    }
    return $true
}

function open_port {
    # Open a service network port
    param (
        [Parameter(Mandatory=$true)]
        [string]$port,
        [string]$protocol="TCP"
    )
    $cmd = @("open-port.exe")
    $arg = $port + "/" + $protocol
    $cmd += $arg
    return RunCommand $cmd
}

function close_port {
    # Close a service network port
    param (
        [Parameter(Mandatory=$true)]
        [string]$port,
        [string]$protocol="TCP"
    )
    $cmd = @("close-port.exe")
    $arg = $port + "/" + $protocol
    $cmd += $arg
    return RunCommand $cmd
}

function unit_get {
    # Get the unit ID for the remote unit
    param (
        [Parameter(Mandatory=$true)]
        [string]$attr
    )
    $cmd = @("unit-get.exe", "--format=json", $attr)
    try{
        return RunCommand $cmd | ConvertFrom-Json
    }catch{
        return $false
    }
}

function unit_private_ip {
    return unit_get -attr "private-address"
}

Export-ModuleMember -Function *
