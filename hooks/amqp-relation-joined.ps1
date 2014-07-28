# we want to exit on error
# $ErrorActionPreference = "Stop"

Import-Module -DisableNameChecking CharmHelpers

$rabbitUser = charm_config -scope 'rabbit-user'
$rabbitVhost = charm_config -scope 'rabbit-vhost'

$relation_set = @{
    'username'=$rabbitUser;
    'vhost'=$rabbitVhost
}
$ret = relation_set -relation_id $null -relation_settings $relation_set
if ($ret -eq $false){
    Juju-Error "Failed to set amqp relation" -Fatal $false
}