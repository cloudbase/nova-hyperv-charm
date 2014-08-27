$modules = "C:\Users\$env:USERNAME\Documents\WindowsPowerShell\Modules"
$charmHelpers = "..\..\Modules\CharmHelpers"
$computeHooksPsm1 = "..\..\compute-hooks.psm1"

function CopyTo-Modules () {
    if ((Test-Path $modules) -eq $false) {
        New-Item -ItemType Directory -Path $modules
    }
    Copy-Item -Path $charmHelpers -Destination $modules -Recurse
    $res = New-Item -ItemType Directory -Path "$modules\compute-hooks"
    Copy-Item -Path $computeHooksPsm1 -Destination "$modules\compute-hooks"
}

function RemoveFrom-Modules () {
    if (Test-Path "$modules\compute-hooks") {
        Remove-Item "$modules\compute-hooks" -Force -Recurse
    }
    if (Test-Path "$modules\CharmHelpers") {
        Remove-Item "$modules\CharmHelpers" -Force -Recurse
    }
}

CopyTo-Modules
Import-Module compute-hooks -DisableNameChecking

Describe "Juju-GetVMSwitch" {

    Context "No vmswitch name in config" {
        Mock charm_config { return $false }
        It "should return br100" {
            { Juju-GetVMSwitch } | Should Be "br100"
        }
    }

    Context "Vmswitch name in config" {
        Mock charm_config { return "br-int" }
        It "should return br-int" {
            { Juju-GetVMSwitch } | Should Be "br-int"
        }
    }
}

Describe "Get-RabbitMQContext" {

    Context "No relation ids available" {
        Mock charm_config { return "fake-user" } `
            -ParameterFilter { $scope -eq "rabbit-user" }
        Mock charm_config { return "fake-vhost" } `
            -ParameterFilter { $attr -eq "rabbit-vhost" }
        Mock relation_ids { return $null } `
            -ParameterFilter { $reltype -eq "amqp" }
        It "should return empty context" {
            { Get-RabbitMQContext } | Should Be @{}
        }
    }

    Context "Missing relation information" {
        Mock relation_get { return "fake-pass" } `
            -ParameterFilter { $attr -eq "password" }
        Mock relation_get { return $null } `
            -ParameterFilter { $attr -eq "private-address" }
        Mock charm_config { return "fake-user" } `
            -ParameterFilter { $scope -eq "rabbit-user" }
        Mock charm_config { return "fake-vhost" } `
            -ParameterFilter { $attr -eq "rabbit-vhost" }
        It "should return empty context" {
            { Get-RabbitMQContext } | Should Be @{}
        }
    }

    Context "Context is complete" {
        $ctx = @{
            "rabbit_host"="192.168.1.1";
            "rabbit_userid"="fake-user";
            "rabbit_password"="fake-pass";
            "rabbit_virtual_host"="fake-vhost"
        }
        Mock relation_get { return "fake-pass" } `
            -ParameterFilter { $attr -eq "password" }
        Mock relation_get { return "192.168.1.1" } `
            -ParameterFilter { $attr -eq "private-address" }
        Mock charm_config { return "fake-user" } `
            -ParameterFilter { $scope -eq "rabbit-user" }
        Mock charm_config { return "fake-vhost" } `
            -ParameterFilter { $attr -eq "rabbit-vhost" }
        It "should return valid context" {
            Get-RabbitMQContext | Should Be $ctx
        }
    }
}

Describe "Get-NeutronContext" {

    Context "No relation ids" {
        Mock relation_ids { return $null } `
            -ParameterFilter { $reltype -eq "cloud-compute" }
        It "should return empty context" {
            Get-NeutronContext | Should Be ${}
        }
    }

    Context "Empty neutron URL should return empty context" {
        Mock relation_get { return $null } `
            -ParameterFilter { $attr -eq "neutron_url" }
        Mock relation_get { return $null } `
            -ParameterFilter { $attr -eq "quantum_url" }
        It "should return empty context" {
            Get-NeutronContext | Should Be ${}
        }
    }

    Context "Missing relation information should return empty context" {
        Mock charm_config { return "C:\Fake\Path" } `
            -ParameterFilter { $scope -eq "log-dir" }
        Mock charm_config { return "C:\Fake\Path" } `
            -ParameterFilter { $scope -eq "instances-dir"}
        Mock relation_get { return "http://example.com" } `
            -ParameterFilter { $attr -eq "neutron_url" }
        Mock relation_get { return $null } `
            -ParameterFilter { $attr -eq "quantum_url" }
        Mock relation_get { return "fake-host" } `
            -ParameterFilter { $attr -eq "auth_host" }
        Mock relation_get { return "80" } `
            -ParameterFilter { $attr -eq "auth_port" }
        Mock relation_get { return "443" } `
            -ParameterFilter { $attr -eq "service_tenant_name" }
        Mock relation_get { return "fake-name" } `
            -ParameterFilter { $attr -eq "service_username" }
        Mock relation_get { return $null } `
            -ParameterFilter { $attr -eq "service_password" }
        It "should return empty context" {
            Get-NeutronContext | Should Be ${}
        }
    }

    Context "Missing relation information should return empty context" {
        $ctx = @{
            "neutron_url"="http://example.com";
            "keystone_host"="fake-host";
            "auth_port"="80";
            "neutron_auth_strategy"="keystone";
            "neutron_admin_tenant_name"="fake-tenant";
            "neutron_admin_username"="fake-name";
            "neutron_admin_password"="fake-pass";
            "log_dir"="C:\Fake\Path";
            "instances_dir"="C:\Fake\Path"
        }
        Mock charm_config { return "C:\Fake\Path" } `
            -ParameterFilter { $scope -eq "log-dir" }
        Mock charm_config { return "C:\Fake\Path" } `
            -ParameterFilter { $scope -eq "instances-dir"}
        Mock relation_get { return "http://example.com" } `
            -ParameterFilter { $attr -eq "neutron_url" }
        Mock relation_get { return $null } `
            -ParameterFilter { $attr -eq "quantum_url" }
        Mock relation_get { return "fake-host" } `
            -ParameterFilter { $attr -eq "auth_host" }
        Mock relation_get { return "80" } `
            -ParameterFilter { $attr -eq "auth_port" }
        Mock relation_get { return "fake-tenant" } `
            -ParameterFilter { $attr -eq "service_tenant_name" }
        Mock relation_get { return "fake-name" } `
            -ParameterFilter { $attr -eq "service_username" }
        Mock relation_get { return "fake-pass" } `
            -ParameterFilter { $attr -eq "service_password" }
        It "should return empty context" {
            Get-NeutronContext | Should Be $ctx
        }
    }
}

RemoveFrom-Modules
