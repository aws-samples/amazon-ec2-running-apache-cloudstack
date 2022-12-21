#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

set -eu
source ./common.sh

dns_ip_address=
efs=false
gateway_ip_address=
host_ip_address=
host_username='root'
key_pair_id=
netmask='255.255.0.0'
pod_cidr=
primary_storage_url=
public_traffic_cidr=
secondary_storage_url=
shared_network_cidr=
template_name='Sample Template'
template_url=

help() {
    echo "Sets up a simple demo configuration in Apache CloudStack."
    echo
    echo "Prereqs:"
    echo " - Apache CloudStack (4.16 or higher, so key authentication can be used to configure the host)"
    echo " - KVM"
    echo " - SSH access to the host (hypervisor) machine using key authentication"
    echo
    echo "OPTIONS"
    echo "  --dns-ip <x.x.x.x>                     DNS server address"
    echo "  --efs                                  Configure storage for EFS"
    echo "  --gateway-ip <x.x.x.x>                 Virtual subnet gateway IP address"
    echo "  --host-ip <x.x.x.x>                    Hostname to set on the server"
    echo "  --host-username <username>             User that can 'sudo su' without a password on the host machine (default = $host_username)"
    echo "  --key-pair <key pair ID>               The ID of the key pair that's needed to SSH to the host instance (optional)"
    echo "  --netmask <x.x.x.x>                    Virtual/Overlay subnet netmask (default = $netmask)"
    echo "  --pod-cidr <x.x.x.x/x>                 Pod CIDR"
    echo "  --primary-storage-url <url>            Primary storage URL (e.g. nfs://server/path)"
    echo "  --public-traffic-cidr <x.x.x.x/x>      Public traffic CIDR"
    echo "  --secondary-storage-url <url>          Secondary storage URL (e.g. nfs://server/path)"
    echo "  --shared-network-cidr <x.x.x.x/x>      Shared network CIDR"
    echo "  --template-name <name>                 Sample template name (default = $template_name)"
    echo "  --template-url <url>                   Sample template URL (optional)"
    echo
    exit 1
}


##################################
# Parse the command line arguments
##################################

[[ $# -ne 0 ]] || help

long_opts=dns-ip:,efs,gateway-ip:,help,host-ip:,host-username:,key-pair:,netmask:,pod-cidr:,primary-storage-url:,public-traffic-cidr:,secondary-storage-url:,shared-network-cidr:,template-name:,template-url:

! parsed_opts=$(getopt --options "" --longoptions=$long_opts --name "$0" -- "$@")
[[ ${PIPESTATUS[0]} -eq 0 ]] || help

eval set -- "$parsed_opts"

while true; do
    case "$1" in
        --dns-ip)
            dns_ip_address="$2"
            shift 2
            ;;
        --efs)
            efs=true
            shift
            ;;
        --help)
            shift
            help
            ;;
        --gateway-ip)
            gateway_ip_address="$2"
            shift 2
            ;;
        --host-ip)
            host_ip_address="$2"
            shift 2
            ;;
        --host-username)
            host_username="$2"
            shift 2
            ;;
        --key-pair)
            key_pair_id="$2"
            shift 2
            ;;
        --netmask)
            netmask="$2"
            shift 2
            ;;
        --pod-cidr)
            pod_cidr="$2"
            shift 2
            ;;
        --primary-storage-url)
            primary_storage_url="$2"
            shift 2
            ;;
        --public-traffic-cidr)
            public_traffic_cidr="$2"
            shift 2
            ;;
        --secondary-storage-url)
            secondary_storage_url="$2"
            shift 2
            ;;
        --shared-network-cidr)
            shared_network_cidr="$2"
            shift 2
            ;;
        --template-name)
            [[ -z $2 ]] || template_name="$2"
            shift 2
            ;;
        --template-url)
            template_url="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "A bug in the script let an unrecognized arg get past getopt.  Arg: $1"
            exit 1
            ;;
    esac
done


#############################################
# Check privileges and install script prereqs
#############################################

require_root

echo "Prereqs..."
command -v jq || yum install -y jq
echo $PATH | grep -q /usr/local/bin || export PATH=$PATH:/usr/local/bin

#########################################
# Make sure all provided values look good
#########################################

verify_ip_address_format "$dns_ip_address" "DNS IP address"
verify_ip_address_format "$gateway_ip_address" "Gateway IP address"
verify_ip_address_format "$host_ip_address" "Host IP address"
verify_not_blank "$host_username" "Host username"
verify_ip_address_format "$netmask" "Netmask"
verify_cidr_format "$pod_cidr" "Pod CIDR"
verify_not_blank "$primary_storage_url" "Primary storage URL"
verify_cidr_format "$public_traffic_cidr" "Public traffic CIDR"
verify_not_blank "$secondary_storage_url" "Secondary storage URL"
verify_cidr_format "$shared_network_cidr" "Shared network CIDR"


#############################
# Check resource availability
#############################

verify_connectivity "$dns_ip_address" 53 "DNS server"


###############################
# Start of system configuration
###############################

fatal() {
  echo "$1" >&2
  exit 1
}

# Run CMK and return the output if it's successful.  If it fails, the output is written to stderr and the script exits.
run_cmk() {
  ! result=$(cmk -o json "$@")
  [[ ${PIPESTATUS[0]} -eq 0 ]] || fatal "$result"
  echo $result
}

# Runs CMK but without displaying the output to stdout.  Errors are handled like run_cmk().
cmk_no_output() {
  run_cmk "$@" > /dev/null
}

if [[ -n $key_pair_id ]]
then
    install_aws_cli

    # Adding a route so the AWS CLI will work.  This route will be removed as soon as the AWS CLI is no longer needed, so
    # it won't conflict with CloudStack's use of link-local addresses.
    echo "Adding temporary route..."
    route add 169.254.169.254/32 dev eth0

    echo "Getting the key needed to SSH to the host..."
    region=$(curl http://169.254.169.254/latest/meta-data/placement/region)
    /usr/local/bin/aws ssm get-parameter --name "/ec2/keypair/$key_pair_id" --region "$region" --with-decryption --query Parameter.Value --output text > ~/.ssh/key-pair
    chmod 600 ~/.ssh/key-pair

    echo "Removing temporary route..."
    route delete 169.254.169.254/32 dev eth0

    echo "Installing CloudStack's public key on the host..."
    ssh-keyscan -H "$host_ip_address" >> ~/.ssh/known_hosts
    scp -i ~/.ssh/key-pair /var/cloudstack/management/.ssh/id_rsa.pub "$host_username@$host_ip_address:~/.ssh/cloudstack.pub"
    ssh -i ~/.ssh/key-pair "$host_username@$host_ip_address" 'sudo bash -l -c "cat /home/'$host_username'/.ssh/cloudstack.pub >> /root/.ssh/authorized_keys"'
fi

echo "Installing CloudMonkey..."
wget https://github.com/apache/cloudstack-cloudmonkey/releases/download/6.2.0/cmk.linux.x86 -O /usr/local/bin/cmk
chmod +x /usr/local/bin/cmk

echo "Getting API details from management service..."
run_cmk sync

if [[ $efs == true ]]
then
  echo "Updating configuration for EFS..."
  cmk_no_output update configuration name=storage.overprovisioning.factor value=1
fi

echo "Creating zone..."
zone=$(run_cmk create zone "dns1=$dns_ip_address" "internaldns1=$dns_ip_address" name=Zone1 networktype=advanced)
zone_id=$(echo $zone | jq -r .zone.id)

echo "Creating physical network..."
physical_network=$(run_cmk create physicalnetwork name=PhysicalNetwork1 "zoneid=$zone_id" isolationmethods=VLAN vlan=1-1000)
physical_network_id=$(echo $physical_network | jq -r .physicalnetwork.id)
cmk_no_output add traffictype "physicalnetworkid=$physical_network_id" traffictype=Management
cmk_no_output add traffictype "physicalnetworkid=$physical_network_id" traffictype=Public
cmk_no_output add traffictype "physicalnetworkid=$physical_network_id" traffictype=Guest
cmk_no_output update physicalnetwork "id=$physical_network_id" state=Enabled
virtual_router_provider_id=$(run_cmk list networkserviceproviders | jq -r '.networkserviceprovider[] | select(.name=="VirtualRouter").id')
virtual_router_element_id=$(run_cmk list virtualrouterelements | jq -r ".virtualrouterelement[] | select(.nspid==\"$virtual_router_provider_id\").id")
cmk_no_output configure virtualrouterelement "id=$virtual_router_element_id" enabled=true
cmk_no_output update networkserviceprovider "id=$virtual_router_provider_id" state=Enabled

echo "Creating pod..."
eval $(ipcalc -nb $pod_cidr)
pod=$(run_cmk create pod "gateway=$gateway_ip_address" name=Pod1 "netmask=$netmask" "startip=$NETWORK" "endip=$BROADCAST" "zoneid=$zone_id")
pod_id=$(echo $pod | jq -r .pod.id)

echo "Creating public traffic IP range..."
eval $(ipcalc -nb $public_traffic_cidr)
cmk_no_output create vlaniprange "startip=$NETWORK" "endip=$BROADCAST" forvirtualnetwork=true "gateway=$gateway_ip_address" "netmask=$netmask" "zoneid=$zone_id"

echo "Creating cluster..."
cluster=$(run_cmk add cluster clustername=Cluster1 clustertype=CloudManaged hypervisor=KVM "podid=$pod_id" "zoneid=$zone_id")
cluster_id=$(echo $cluster | jq -r .cluster[0].id)

echo "Adding host..."
# When adding a host, password is a required field.  But we're using key authentication, so the value of the password doesn't matter.
cmk_no_output add host hypervisor=kvm "podid=$pod_id" "url=http://$host_ip_address" "zoneid=$zone_id" "clusterid=$cluster_id" username=root password=NotARealPassword

echo "Creating primary storage..."
cmk_no_output create storagepool name=PrimaryStorage1 "url=$primary_storage_url" "zoneid=$zone_id" scope=ZONE hypervisor=KVM

echo "Creating secondary storage..."
cmk_no_output add secondarystorage name=SecondaryStorage1 "url=$secondary_storage_url" "zoneid=$zone_id" scope=ZONE

echo "Creating shared network..."
network_offering_id=$(run_cmk list networkofferings | jq -r '.networkoffering[] | select(.name=="DefaultSharedNetworkOffering").id')
eval $(ipcalc -nb $shared_network_cidr)
cmk_no_output create network name=SharedNet1 displaytext=SharedNet1 "networkofferingid=$network_offering_id" "zoneid=$zone_id" vlan=untagged "gateway=$gateway_ip_address" "netmask=$netmask" "startip=$NETWORK" "endip=$BROADCAST" acltype=Domain

echo "Enabling zone..."
cmk_no_output update zone "id=$zone_id" allocationstate=Enabled

if [[ -n $template_url ]]
then
    echo "Registering template..."
    os_type_id=$(run_cmk list ostypes | jq -r '.ostype[] | select(.description=="None").id')
    cmk_no_output register template "url=$template_url" "name=$template_name" "displaytext=$template_name" format=QCOW2 hypervisor=KVM isfeatured=true ispublic=true zoneids=-1 "ostypeid=$os_type_id"
fi

echo "CloudStack configuration is complete."