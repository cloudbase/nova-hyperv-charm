$utilsModulePath = Join-Path `
                (Split-Path $SCRIPT:MyInvocation.MyCommand.Path -Parent) `
                "utils.psm1"
Import-Module -Force -DisableNameChecking $utilsModulePath

function Start-Process-Redirect {
    param(
        [Parameter(Mandatory=$true)]
        [array]$Filename,
        [Parameter(Mandatory=$true)]
        [array]$Arguments,
        [Parameter(Mandatory=$false)]
        [array]$Domain,
        [Parameter(Mandatory=$false)]
        [array]$Username,
        [Parameter(Mandatory=$false)]
        $SecPassword
    )

    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName = $Filename
    if ($Domain -ne $null) {
        $pinfo.Username = $Username
        $pinfo.Password = $secPassword
        $pinfo.Domain = $Domain
    }
    $pinfo.CreateNoWindow = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.RedirectStandardOutput = $true
    $pinfo.UseShellExecute = $false
    $pinfo.LoadUserProfile = $true
    $pinfo.Arguments = $Arguments
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $pinfo
    $p.Start() | Out-Null
    $p.WaitForExit()

    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    juju-log.exe "stdout: $stdout"
    juju-log.exe "stderr: $stderr"

    return $p
}

function Get-FeatureAvailable {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FeatureName
    )

    $isAvailable = ((Get-WindowsFeature -Name $FeatureName).InstallState `
                   -eq "Available")

    return $isAvailable
}

function Get-FeatureInstall {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FeatureName
    )

    $installState = (Get-WindowsFeature -Name $FeatureName).InstallState

    $isInstall = ($installState -eq "Installed") `
                 -or ($installState -eq "InstallPending" )

    return $isInstall
}

function Install-WindowsFeatures {
     param(
        [Parameter(Mandatory=$true)]
        [array]$Features
    )

    $installedFeatures = 0
    $rebootNeeded = $false
    foreach ($feature in $Features) {
        $isAvailable = Get-FeatureAvailable $feature
        if ($isAvailable -eq $true) {
            $res = Install-WindowsFeature -Name $feature
            if ($res.RestartNeeded -eq 'Yes') {
                $rebootNeeded = $true
            }
        }
        $isInstall = Get-FeatureInstall $feature
        if ($isInstall -eq $true) {
            $installedFeatures = $installedFeatures + 1
        } else {
            juju-log.exe "Install failed for feature $feature"
        }
    }

    return @{"InstalledFeatures" = $installedFeatures;
             "Reboot" = $rebootNeeded }
}

function install_windows_features {
     param(
        [Parameter(Mandatory=$true)]
        [array]$Features
    )

    $res = Install-WindowsFeatures $Features

    return $res.InstalledFeatures
}

function get_available_windows_features {
     param(
        [Parameter(Mandatory=$true)]
        [array]$Features
    )

    $available = 0
    foreach ($feature in $Features) {
        $state = (Get-WindowsFeature -Name $feature).InstallState
        if (($state -eq 'Available') -or ($state -eq 'InstallPending')) {
            $available = $available + 1
        }
    }

    return $available
}

function Install-Windows-Features {
     param(
        [Parameter(Mandatory=$true)]
        [array]$Features
    )

    return (install_windows_features $Features)
}

function Is-Component-Installed {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name
    )

    $component = Get-WmiObject -Class Win32_Product | `
                     Where-Object { $_.Name -Match $Name}

    return ($component -ne $null)
}

function Set-Dns {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Interface,
        [Parameter(Mandatory=$true)]
        [array]$DnsIps
    )

    Set-DnsClientServerAddress `
        -InterfaceAlias $Interface -ServerAddresses $DnsIps
}

function Is-In-Domain {
    param(
        [Parameter(Mandatory=$true)]
        [string]$WantedDomain
    )

    $currentDomain = (Get-WmiObject -Class `
                          Win32_ComputerSystem).Domain.ToLower()
    $comparedDomain = ($WantedDomain).ToLower()
    $inDomain = $currentDomain.Equals($comparedDomain)

    return $inDomain
}

function Get-NetAdapterName {
    param()

    return (Get-NetAdapter).Name
}

function Get-Default-Ethernet-Network-Name {
    param(
        [Parameter(Mandatory=$false)]
        [string]$Second="Primary"
    )

    $name1 = "Management0"
    $name2 = "Ethernet0"
    $found = $false

    try {
        if ($Second -eq "Primary") {
            $interface = Get-NetAdapter `
                         | Where-Object { $_.Name -match $name1 `
                                        -or $_.Name -match $name2 } `
                         | Select-Object -First 1
        } else {
            $interface = Get-NetAdapter `
                         | Where-Object { $_.Name -notmatch $name1 `
                                        -and $_.Name -notmatch $name2 } `
                         | Select-Object -First 1
        }
        if ($interface -ne $null) {
            $found = $true
            $name = $interface.Name
        }
    } catch {
        $found = $false
    }

    if ($found -ne $true){
        $name = Get-NetAdapterName
    }

    return $name
}

function Get-Ethernet-Network-Name {
    param()

    $name = Get-Default-Ethernet-Network-Name "Primary"

    return $name
}

function Get-Second-Ethernet-Network-Name {
    param()

    $name = Get-Default-Ethernet-Network-Name "Second"

    return $name
}

function Create-Local-Admin {
    param(
        [Parameter(Mandatory=$true)]
        [string]$LocalAdminUsername,
        [Parameter(Mandatory=$true)]
        [string]$LocalAdminPassword
    )

    $existentUser = Get-WmiObject -Class Win32_Account `
                        -Filter "Name = '$LocalAdminUsername'" 
    if ($existentUser -eq $null) {
        $computer = [ADSI]"WinNT://$env:computername"
        $localAdmin = $computer.Create("User", $LocalAdminUsername)
        $localAdmin.SetPassword($LocalAdminPassword)
        $localAdmin.SetInfo()
        $LocalAdmin.FullName = $LocalAdminUsername
        $LocalAdmin.SetInfo()
        $LocalAdmin.UserFlags = 1 + 512 + 65536 #logon script|normal user|no pass expiration
        $LocalAdmin.SetInfo()
    } else {
        net.exe user $LocalAdminUsername $LocalAdminPassword
    }
    if ((net localgroup administrators `
       | Where-Object { $_ -Match $LocalAdminUsername }).Length -eq 0) {
        ([ADSI]"WinNT://$env:computername/Administrators,group").Add("WinNT://$env:computername/$LocalAdminUsername")
    }
}

function Get-Domain-Name{
    param(
        [Parameter(Mandatory=$true)]
        [string]$FullDomainName
    )

    $domainNameParts = $FullDomainName.split(".")
    $domainNamePartsPosition = $domainNameParts.Length - 2
    $domainName = [System.String]::Join(".", $domainNameParts[0..$domainNamePartsPosition])

    return $domainName
}

function Get-Ad-Credential{
    param(
        [Parameter(Mandatory=$true)]
        $params
    )

    $adminusername = $params["ad_username"]
    $adminpassword = $params["ad_password"]
    $domain = Get-Domain-Name $params["ad_domain"]
    $passwordSecure = $adminpassword | ConvertTo-SecureString -asPlainText -Force
    $adCredential = New-Object System.Management.Automation.PSCredential("$domain\$adminusername", $passwordSecure)

    return $adCredential
}

function Join-Any-Domain{
    param(
        [Parameter(Mandatory=$true)]
        [string]$domain,
        [Parameter(Mandatory=$true)]
        [string]$domainCtrlIp,
        [Parameter(Mandatory=$true)]
        $localCredential,
        [Parameter(Mandatory=$true)]
        $adCredential
    )

    $networkName = (Get-Ethernet-Network-Name)
    Set-Dns $networkName $domainCtrlIp
    $domain = Get-Domain-Name $domain
    Add-Computer -LocalCredential $localCredential -Credential $adCredential -Domain $domain
}

function Get-CharmStateKeyPath {
    param()

    return "HKLM:\SOFTWARE\Wow6432Node\Cloudbase Solutions"
}

function Set-CharmState{
    param (
        [Parameter(Mandatory=$true)]
        [string]$charmName,
        [Parameter(Mandatory=$true)]
        [string]$key,
        [Parameter(Mandatory=$true)]
        [string]$val
        )

    $keyPath = Get-CharmStateKeyPath
    $fullKey = ($charmName + $key)
    $property = New-ItemProperty $keyPath -Name $fullKey -Value $val -PropertyType String -ErrorAction SilentlyContinue

    if ($property -eq $null) {        
        Set-ItemProperty $keyPath -Name $fullKey -Value $val
    }
}

function Get-CharmState{
    param (
        [Parameter(Mandatory=$true)]
        [string]$charmName,
        [Parameter(Mandatory=$true)]
        [string]$key
        )

    $keyPath = Get-CharmStateKeyPath
    $fullKey = ($charmName + $key)
    $property = Get-ItemProperty $keyPath -Name $fullKey -ErrorAction SilentlyContinue

    if ($property -ne $null) {
        return $property | Select -ExpandProperty $fullKey
    } else {
        return $property
    }
}


function Rename-Hostname{
    $jujuUnitName=${env:JUJU_UNIT_NAME}.split('/')
    if ($jujuUnitName[0].Length -ge 15 ){
        $jujuName = $jujuUnitName[0].substring(0,12)
    }else{
        $jujuName = $jujuUnitName[0]
    }
    $newHostname = $jujuName + $jujuUnitName[1]

    if ($env:computername -ne $newHostname){
        Rename-Computer -NewName $newHostname
        exit $env:JUJU_MUST_REBOOT
    }
}

function Juju-Log{
    param (
        [Parameter(Mandatory=$true)]
        $args
        )
    juju-log.exe $args
}

function Create-AD-Users{
    param (
        [Parameter(Mandatory=$true)]
        $usersToAdd,
        [Parameter(Mandatory=$true)]
        [string]$adminusername,
        [Parameter(Mandatory=$true)]
        $adminpassword,
        [Parameter(Mandatory=$true)]
        [string]$domain,
        [Parameter(Mandatory=$true)]
        [string]$dcName,
        [Parameter(Mandatory=$true)]
        [string]$machinename
        )

    $dcsecpassword = ConvertTo-SecureString $adminpassword -AsPlainText -Force
    $dccreds = New-Object System.Management.Automation.PSCredential("$domain\$adminusername", $dcsecpassword)
    $session = New-PSSession -ComputerName $dcName -Credential $dccreds
    Import-PSSession -Session $session -CommandName New-ADUser, Get-ADUser, Set-ADAccountPassword

    foreach($user in $usersToAdd){
        $username = $user['Name']
        $password = $user['Password']
        $alreadyUser = $False
        try{
            $alreadyUser = (Get-ADUser $username) -ne $Null
        }
        catch{
            $alreadyUser = $False
        }

        $securePassword = ConvertTo-SecureString $password -AsPlainText -Force
        if($alreadyUser -eq $False){
            $Description = "AD user"
            New-ADUser -Name $username -AccountPassword $securePassword -Description $Description -Enabled $True

            $User = [ADSI]("WinNT://$domain/$username")
            $Group = [ADSI]("WinNT://$machinename/Administrators")
            $Group.PSBase.Invoke("Add",$User.PSBase.Path)
        }
        else{
            Juju-Log "User already addded"
            Set-ADAccountPassword -NewPassword $securePassword -Identity $username
        }
    }
    $session | Remove-PSSession
}

function Change-ServiceLogon{
    param (
        [Parameter(Mandatory=$true)]
        $services,
        [Parameter(Mandatory=$true)]
        [string]$userName,
        [Parameter(Mandatory=$false)]
        $password
        )

    $services | ForEach-Object { $_.Change($null,$null,$null,$null,$null,$null,$userName,$password) }
}

function Get-Subnet{
    param (
        [Parameter(Mandatory=$true)]
        $ip,
        [Parameter(Mandatory=$true)]
        $netmask
        )
    $class = 32
    $netmaskClassDelimiter = "255"
    $netmaskSplit = $netmask -split "[.]"
    $ipSplit = $ip -split "[.]"
    for($i = 0; $i -lt 4; $i++){
        if($netmaskSplit[$i] -ne $netmaskClassDelimiter){
            $class -= 8
            $ipSplit[$i] = "0"
        }
    }

    $fullSubnet = ($ipSplit -join ".") + "/" + $class
    return $fullSubnet
}

function New-NetstatObject {
    Param(
        [Parameter(Mandatory=$True)]
        $Properties
    )
    
    $process = New-Object psobject -property @{
        Protocol      = $Properties.Protocol
        LocalAddress  = $Properties.LAddress
        LocalPort     = $Properties.LPort
        RemoteAddress = $Properties.RAddress
        RemotePort    = $Properties.RPort
        State         = $Properties.State
        ID            = [int]$Properties.PID
        ProcessName   = ( $ps | Where-Object {$_.Id -eq $Properties.PID} ).ProcessName
    }

    return $process
}

# It works only for netstat -ano
function Get-NetstatObjects {
    $null, $null, $null, $null, $netstat = netstat -ano
    $ps = Get-Process

    [regex]$regexTCP = '(?<Protocol>\S+)\s+(?<LAddress>\S+):(?<LPort>\S+)\s+(?<RAddress>\S+):(?<RPort>\S+)\s+(?<State>\S+)\s+(?<PID>\S+)'
    [regex]$regexUDP = '(?<Protocol>\S+)\s+(?<LAddress>\S+):(?<LPort>\S+)\s+(?<RAddress>\S+):(?<RPort>\S+)\s+(?<PID>\S+)'

    $objects = @()

    foreach ($line in $netstat)
    {
        switch -regex ($line.Trim())
        {
            $regexTCP
            {
                $process = New-NetstatObject -Properties $matches
                $objects = $objects + $process
                continue
            }
            $regexUDP
            {
                $process = New-NetstatObject -Properties $matches
                $objects = $objects + $process
                continue
            }
        }
    }

    return $objects
}

Export-ModuleMember -Function *