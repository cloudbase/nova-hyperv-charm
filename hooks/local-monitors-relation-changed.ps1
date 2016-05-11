#
# Copyright 2016 Cloudbase Solutions SRL
#

$ErrorActionPreference = "Stop"

Import-Module JujuLogging
Import-Module JujuHooks
Import-Module powershell-yaml


function Set-LocalMonitors {
    $switchName = Get-JujuCharmConfig -Scope 'vmswitch-name'
    $charmServices = Get-CharmServices
    $novaService = $charmServices['nova']['service']
    $netType = Get-NetType
    if($netType -eq 'hyperv') {
        $neutronService = $charmServices['neutron']['service']
    } elseif($netType -eq 'ovs') {
        $neutronService = $charmServices['neutron-ovs']['service']
    } else {
        throw "Unknown network-type"
    }
    $monitors = @{
        'version' = '0.3'
        'monitors' = @{
            'remote' = @{
                'nrpe' = @{
                    'hyper_v_health_ok_check' = @{
                        'command' = "CheckCounter -a Counter=`"\\Hyper-V Virtual Machine Health Summary\\Health Ok`""
                    };
                    'hyper_v_health_critical_check' = @{
                        'command' = "CheckCounter -a Counter=`"\\Hyper-V Virtual Machine Health Summary\\Health Critical`""
                    };
                    'hyper_v_logical_processors' = @{
                        'command' = "CheckCounter -a Counter=`"\\Hyper-V Hypervisor\\Logical Processors`""
                    };
                    'hyper_v_virtual_processors' = @{
                        'command' = "CheckCounter -a Counter=`"\\Hyper-V Hypervisor\\Virtual Processors`""
                    };
                    'hyper_v_virtual_switch_packets_per_sec' = @{
                        'command' = "CheckCounter -a Counter=`"\\Hyper-V Virtual Switch($switchName)\\Packets/sec`""
                    };
                    'hyper_v_partitions' = @{
                        'command' = "CheckCounter -a Counter=`"\\Hyper-V Hypervisor\\Partitions`""
                    };
                    'nova_compute_service_status' = @{
                        'command' = "check_service -a service=$novaService"
                    };
                    'neutron_service_status' = @{
                        'command' = "check_service -a service=$neutronService"
                    }
                }
            }
        }
    }
    $configMonitors = Get-JujuCharmConfig -Scope 'monitors'
    if($configMonitors) {
        # Get extra monitors declared in charm config
        $cfgMons = ConvertFrom-Yaml -Yaml "$configMonitors`r`n" -AllDocuments
        if ($cfgMons['monitors'] -and $cfgMons['monitors']['remote'] -and $cfgMons['monitors']['remote']['nrpe']) {
            foreach($key in $cfgMons['monitors']['remote']['nrpe'].Keys) {
                $monitors['monitors']['remote']['nrpe'][$key] = $cfgMons['monitors']['remote']['nrpe'][$key]
            }
        } else {
            Write-JujuWarning "No monitors has been set in charm config"
        }
    }
    $tempFile = Join-Path $env:TEMP "nsclient-monitors.yaml"
    ConvertTo-Yaml $monitors -OutFile $tempFile -Force
    $monitorsYaml = (Get-Content $tempFile) -Join "`n"
    Remove-Item $tempFile
    $settings = @{
        'monitors' = $monitorsYaml;
    }
    $rids = Get-JujuRelationIds -Relation 'local-monitors'
    foreach($rid in $rids) {
        Set-JujuRelation -RelationId $rid -Settings $settings
    }
}


try {
    Set-LocalMonitors
} catch {
    Write-HookTracebackToLog $_
    exit 1
}
