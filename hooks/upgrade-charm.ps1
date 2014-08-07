#
# Copyright 2014 Cloudbase Solutions SRL
#

Import-Module -DisableNameChecking CharmHelpers

$rabbitUser = charm_config -scope 'rabbit-user'
$rabbitVhost = charm_config -scope 'rabbit-vhost'

$relation_set = @{
    'username'=$rabbitUser;
    'vhost'=$rabbitVhost
}

$rids = relation_ids -reltype "amqp"

foreach ($rid in $rids){
    $ret = relation_set -relation_id $rid -relation_settings $relation_set
}