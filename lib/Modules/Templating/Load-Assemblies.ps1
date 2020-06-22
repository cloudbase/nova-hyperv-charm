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

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Initialize-Assemblies {
    $libDir = Join-Path $here "lib"
    $assemblies = @{
        "net45" = Join-Path $libDir "net45";
        "netstandard13" = Join-Path $libDir "netstandard1.3";
    }

    try {
        [DotLiquid.Template] | Out-Null
    } catch [System.Management.Automation.RuntimeException] {
        try {
            $mod = Join-Path $assemblies["net45"] "DotLiquid.dll"
            $resources = Join-Path $assemblies["net45"] "it/DotLiquid.resources.dll"
            [Reflection.Assembly]::LoadFrom($mod) | Out-Null
            [Reflection.Assembly]::LoadFrom($resources) | Out-Null
        } catch [System.Management.Automation.RuntimeException] {
            $mod = Join-Path $assemblies["netstandard13"] "DotLiquid.dll"
            $resources = Join-Path $assemblies["netstandard13"] "it/DotLiquid.resources.dll"
            [Reflection.Assembly]::LoadFrom($mod) | Out-Null
            [Reflection.Assembly]::LoadFrom($resources) | Out-Null
        }
    }
}

Initialize-Assemblies | Out-Null
