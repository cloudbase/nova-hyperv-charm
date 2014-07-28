# we want to exit on error
# $ErrorActionPreference = "Stop"

Stop-Service nova-compute
Stop-Service neutron-hyperv-agent