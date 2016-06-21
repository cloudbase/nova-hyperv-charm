#
# Copyright 2016 Cloudbase Solutions SRL
#

$ErrorActionPreference = "Stop"

Import-Module JujuLogging
Import-Module JujuHooks
Import-Module JujuWindowsUtils


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
