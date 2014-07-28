# we want to exit on error
# $ErrorActionPreference = "Stop"

Import-Module -DisableNameChecking CharmHelpers

$nova_restart = Generate-Config -ServiceName "nova"

if ($nova_restart){
    Restart-Service $JujuCharmServices["nova"]["service"]
}