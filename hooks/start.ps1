# we want to exit on error
# $ErrorActionPreference = "Stop"

Start-Service nova-compute
Start-Service neutron-hyperv-agent