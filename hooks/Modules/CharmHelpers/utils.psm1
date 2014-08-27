
# HELPER FUNCTIONS
function Restore-EnvironmentVariable ($variable, $prevValue) {
    if ($prevValue -eq $null -and (Test-Path "Env:$variable")) {
        Remove-Item "Env:$variable"
    } else {
        [Environment]::SetEnvironmentVariable($variable,$prevValue)
    }
}

function Prepare-MockEnvVariable($varName, $value) {
    $prevValue = [Environment]::GetEnvironmentVariable($varName)
    [Environment]::SetEnvironmentVariable($varName,$value)
    return $prevValue
}

function Compare-Objects ($first, $last) {
    (Compare-Object $first $last -SyncWindow 0).Length -eq 0
}

function Compare-ScriptBlocks {
    param(
        [System.Management.Automation.ScriptBlock]$scrBlock1,
        [System.Management.Automation.ScriptBlock]$scrBlock2
    )

    $sb1 = $scrBlock1.ToString()
    $sb2 = $scrBlock2.ToString()

    return ($sb1.CompareTo($sb2) -eq 0)
}

function Add-FakeObjProperty ([ref]$obj, $name, $value) {
    Add-Member -InputObject $obj.value -MemberType NoteProperty `
        -Name $name -Value $value
}

function Add-FakeObjProperties ([ref]$obj, $fakeProperties, $value) {
    foreach ($prop in $fakeProperties) {
        Add-Member -InputObject $obj.value -MemberType NoteProperty `
            -Name $prop -Value $value
    }
}

function Add-FakeObjMethod ([ref]$obj, $name) {
    Add-Member -InputObject $obj.value -MemberType ScriptMethod `
        -Name $name -Value { return 0 }
}

function Add-FakeObjMethods ([ref]$obj, $fakeMethods) {
    foreach ($method in $fakeMethods) {
        Add-Member -InputObject $obj.value -MemberType ScriptMethod `
            -Name $method -Value { return 0 }
    }
}

function Compare-Arrays ($arr1, $arr2) {
    return (((Compare-Object $arr1 $arr2).InputObject).Length -eq 0)
}

function Compare-HashTables ($tab1, $tab2) {
    if ($tab1.Count -ne $tab2.Count) {
        return $false
    }

    foreach ($i in $tab1.Keys) {
        if (($tab2.ContainsKey($i) -eq $false) -or ($tab1[$i] -ne $tab2[$i])) {
            return $false
        }
    }

    return $true
}

function Exit-Basic {
    param(
        [int]$ExitCode
    )

    exit $ExitCode
}

function Invoke-StaticMethod {
    param(
        [parameter(Mandatory=$true)]
        [string]$Type,
        [parameter(Mandatory=$true)]
        [string]$Name,
        [array]$Params=$null
    )

    $fullType = "System.Management.Automation." + $Type
    $staticClass = [Type]$fullType
    return $staticClass::$Name.Invoke($Params)
}

#Testable methods
function ExecuteWith-RetryCmdCommand {
    param(
        [ScriptBlock]$Command,
        [int]$MaxRetryCount=3,
        [int]$RetryInterval=0,
        [array]$ExitCodes=@(0),
        [array]$ArgumentList=@()
    )

    $currentErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $retryCount = 0

    while ($true) {
        try {
            $res = Invoke-Command -ScriptBlock $Command `
                     -ArgumentList $ArgumentList
            if ($ExitCodes -contains $LASTEXITCODE) {
                return @{"Result"=$res;
                         "ExitCode"=$LASTEXITCODE};
            } else {
                throw $res
            }
        } catch [System.Exception] {
            if ($retryCount -ge $MaxRetryCount) {
                $ErrorActionPreference = $currentErrorActionPreference
                throw $_.Exception
            } else {
                Start-Sleep $RetryInterval
            }
            $retryCount++
        }
    }

    $ErrorActionPreference = $currentErrorActionPreference
}

function ExecuteWith-RetryPSCommand {
    param(
        [ScriptBlock]$Command,
        [int]$MaxRetryCount=3,
        [int]$RetryInterval=0,
        [array]$ArgumentList=@()
    )

    $currentErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $retryCount = 0

    while ($true) {
        try {
            $res = Invoke-Command -ScriptBlock $Command `
                     -ArgumentList $ArgumentList
            return $res
        } catch [System.Exception] {
            if ($retryCount -ge $MaxRetryCount) {
                $ErrorActionPreference = $currentErrorActionPreference
                throw $_.Exception
            } else {
                Start-Sleep $RetryInterval
            }
            $retryCount++
        }
    }

    $ErrorActionPreference = $currentErrorActionPreference
}

function ExecRetry {
    param(
        [ScriptBlock]$Command,
        [int]$MaxRetryCount=3,
        [int]$RetryInterval=0
    )

    ExecuteWith-RetryPSCommand $Command $MaxRetryCount $RetryInterval
}

function ExecuteWith-Retry {
    param(
        [ScriptBlock]$Command,
        [int]$MaxRetryCount=3,
        [int]$RetryInterval=0
    )

    ExecuteWith-RetryPSCommand $Command $MaxRetryCount $RetryInterval
}

function ExitFrom-JujuHook {
    param($WithReboot=$false)
    if ($WithReboot -eq $true) {
        Exit-Basic $env:JUJU_MUST_REBOOT
    } else {
        Exit-Basic 0
    }
}

Export-ModuleMember -Function *