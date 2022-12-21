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

# Default values
cloudstack_version='4.17'
dns_ip_address=
efs_endpoint=
hostname='cloudstack-management'
interface_name='eth0'
limit_log_files=false
multicast_ip=
overlay_gateway_ip=
overlay_host_ip_address=
overlay_netmask='255.255.0.0'
rds_admin_secret=
rds_endpoint=
rds_port=3306
rds_service_secret=
zone_dir=zone1

help() {
    echo "Installs Apache CloudStack management on an EC2 instance using EFS for storage and a VXLAN subnet.  Must be run as root."
    echo
    echo "WARNING: If you're using a remote connection to run this script, you must either use nohup, or connect from a machine"
    echo "on the same subnet.  Otherwise, the script will fail during network configuration."
    echo
    echo "Prereqs:"
    echo " - Nitro EC2 instance with x86_64 architecture"
    echo " - CentOS 7"
    echo " - Sufficient space on the root volume for the database, unless you're using an external database such as RDS"
    echo " - Secrets Manager secrets with credentials for the RDS admin and service accounts, using the words username and password as keys"
    echo " - Internet access"
    echo
    echo
    echo "OPTIONS"
    echo "  --cloudstack-version <x.x>               CloudStack version to install (default=$cloudstack_version)"
    echo "  --dns-ip <x.x.x.x>                       DNS server IP address"
    echo "  --efs-endpoint <endpoint DNS name>       Fully qualified domain name of the EFS endpoint"
    echo "  --hostname <hostname>                    Hostname to set on the server (default = $hostname)"
    echo "  --interface <interface name>             Physical network interface name (default = $interface_name)"
    echo "  --limit-log-files                        Configure CloudStack logging to limit the sizes of the log files"
    echo "  --multicast-ip <x.x.x.x>                 Multicast IP address VXLAN should use"
    echo "  --overlay-gateway-ip <x.x.x.x>           Gateway IP address for the overlay network"
    echo "  --overlay-host-ip <x.x.x.x>              IP address that should be assigned to the host on the overlay network"
    echo "  --overlay-netmask <x.x.x.x>              Netmask for the overlay network (default = $overlay_netmask)"
    echo "  --rds-admin-secret <secret ID>           The ID of the secret that has the RDS admin account credentials"
    echo "  --rds-endpoint <endpoint DNS name>       Fully qualified domain name of the RDS endpoint (optional)"
    echo "  --rds-port <port number>                 RDS port number (default = $rds_port)"
    echo "  --rds-service-secret <secret ID>         The ID of the secret that has the RDS service account credentials"
    echo "  --zone-dir <directory name>              A directory with this name will be created in EFS for your first zone's storage (default = $zone_dir)"
    echo
    exit 1
}


##################################
# Parse the command line arguments
##################################

[[ $# -ne 0 ]] || help

long_opts=cloudstack-version:,dns-ip:,efs-endpoint:,help,hostname:,interface:,limit-log-files,multicast-ip:,overlay-gateway-ip:,overlay-host-ip:,overlay-netmask:,rds-admin-secret:,rds-endpoint:,rds-port:,rds-service-secret:,zone-dir:

! parsed_opts=$(getopt --options "" --longoptions=$long_opts --name "$0" -- "$@")
[[ ${PIPESTATUS[0]} -eq 0 ]] || help

eval set -- "$parsed_opts"

while true; do
    case "$1" in
        --cloudstack-version)
            cloudstack_version="$2"
            shift 2
            ;;
        --dns-ip)
            dns_ip_address="$2"
            shift 2
            ;;
        --efs-endpoint)
            efs_endpoint="$2"
            shift 2
            ;;
        --help)
            shift
            help
            ;;
        --hostname)
            hostname="$2"
            shift 2
            ;;
        --interface)
            interface_name="$2"
            shift 2
            ;;
        --limit-log-files)
            limit_log_files=true
            shift
            ;;
        --multicast-ip)
            multicast_ip="$2"
            shift 2
            ;;
        --overlay-gateway-ip)
            overlay_gateway_ip="$2"
            shift 2
            ;;
        --overlay-host-ip)
            overlay_host_ip_address="$2"
            shift 2
            ;;
        --overlay-netmask)
            overlay_netmask="$2"
            shift 2
            ;;
        --rds-admin-secret)
            rds_admin_secret="$2"
            shift 2
            ;;
        --rds-endpoint)
            rds_endpoint="$2"
            shift 2
            ;;
        --rds-port)
            rds_port="$2"
            shift 2
            ;;
        --rds-service-secret)
            rds_service_secret="$2"
            shift 2
            ;;
        --zone-dir)
            zone_dir="$2"
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
install_common_prereqs
install_mysql_repo
install_aws_cli

#########################################
# Make sure all provided values look good
#########################################

verify_cloudstack_version "$cloudstack_version"
verify_ip_address_format "$dns_ip_address" "DNS address"
verify_not_blank "$efs_endpoint" "EFS endpoint"
verify_not_blank "$hostname" "hostname"
verify_not_blank "$interface_name" "network interface name"
verify_ip_address_format "$multicast_ip" "VLXAN multicast address"
verify_ip_address_format "$overlay_gateway_ip" "overlay network gateway address"
verify_ip_address_format "$overlay_host_ip_address" "overlay network host IP address"
verify_ip_address_format "$overlay_netmask" "overlay network netmask"
verify_not_blank "$zone_dir" "zone directory name"
verify_not_blank "$rds_admin_secret" "RDS admin account secret"
verify_not_blank "$rds_endpoint" "RDS endpoint (required when some RDS values are provided)"
verify_not_blank "$rds_port" "RDS port (required when some RDS values are provided)"
verify_not_blank "$rds_service_secret" "RDS service account secret"


###########################
# Get and parse the secrets
###########################

# The secret_username and secret_password variables are populated by calling get_secret_credentials.
secret_username=
secret_password=
get_secret_credentials() {
    local secret_id="$1"
    command -v jq > /dev/null || yum install -y jq
    local secret_value=$(/usr/local/bin/aws secretsmanager get-secret-value --secret-id "$secret_id" --query SecretString --output json)
    # Use jq to parse the quoted JSON string, converting it to a raw form that can be fed into jq again.
    secret_value=$(echo $secret_value | jq -r)
    verify_not_blank "$secret_value" "Value of secret $secret_id is blank"
    secret_username=$(echo $secret_value | jq -r '.username')
    verify_not_blank "$secret_username" "username is blank in sercret $secret_id"
    secret_password=$(echo $secret_value | jq -r '.password')
    verify_not_blank "$secret_password" "password is blank in sercret $secret_id"
}

get_secret_credentials "$rds_admin_secret"
rds_admin_username=$secret_username
rds_admin_password=$secret_password

get_secret_credentials "$rds_service_secret"
rds_service_username=$secret_username
rds_service_password=$secret_password


#############################
# Check resource availability
#############################

verify_connectivity "$dns_ip_address" 53 "DNS server"
verify_connectivity "$efs_endpoint" 2049 "EFS"
verify_network_interface "$interface_name"
verify_connectivity "$rds_endpoint" "$rds_port" "RDS"

# Check DB
use_existing_database=false
echo "Checking the state of RDS..."
yum -y install mysql
found_databases_as_service=$(get_databases "$rds_endpoint" "$rds_port" "$rds_service_username" "$rds_service_password")
if [[ -n $(echo $found_databases_as_service | grep '\bcloud\b') ]]
then
    echo "Found cloud database using username $rds_service_username"
    use_existing_database=true
else
    found_databases_as_admin=$(get_databases "$rds_endpoint" "$rds_port" "$rds_admin_username" "$rds_admin_password")
    [[ -n $found_databases_as_admin ]] || bad_input "Unable to list databases as admin"
    [[ -z $(echo $found_databases_as_admin | grep '\bcloud\b') ]] || bad_input "Cloud database already exists, but couldn't be found using the service account"
fi


#######################
# Start of installation
#######################

# Hostname and IP address
# cloudstack-setup-databases will detect the IP address that the host instances will use to connect to the management instance.
# We need to force it to detect the overlay network IP address, instead of the VPC IP address.  Otherwise, the host won't be
# able to connect.  To do this, we need to give the management instance a fully qualified domain name, and then add that same
# FQDN to the /etc/hosts file, along with the IP address we want CloudStack to use.
fqdn="$hostname.localdomain"
echo "Setting the machine's hostname to $fqdn..."
hostnamectl set-hostname "$fqdn"
echo "$overlay_host_ip_address $fqdn" >> /etc/hosts

# Die if 'hostname --fqdn' doesn't return the right name.  CloudStack needs this to work.
if [[ $(hostname --fqdn) != "$fqdn" ]]
then
    echo "The hostname is configured incorrectly." >&2
    exit 1
fi

# Network
echo "Configuring the network..."
yum install -y bridge-utils net-tools

cat << EOF > /etc/sysconfig/network-scripts/ifcfg-cloudbr0
DEVICE=cloudbr0
TYPE=Bridge
ONBOOT=yes
BOOTPROTO=none
IPV6INIT=no
IPV6_AUTOCONF=no
DELAY=5
STP=no
USERCTL=no
NM_CONTROLLED=no
IPADDR=$overlay_host_ip_address
NETMASK=$overlay_netmask
DNS1=$dns_ip_address
GATEWAY=$overlay_gateway_ip
EOF

cat << EOF > /sbin/ifup-local
#!/bin/bash
# Set up VXLAN once cloudbr0 is available.
if [[ \$1 == "cloudbr0" ]]
then
    ip link add ethvxlan0 type vxlan id 100 dstport 4789 group "$multicast_ip" dev "$interface_name"
    brctl addif cloudbr0 ethvxlan0
    ip link set up dev ethvxlan0
fi
EOF

chmod +x /sbin/ifup-local

# Transit Gateway requires IGMP version 2
echo "net.ipv4.conf.$interface_name.force_igmp_version=2" >> /etc/sysctl.conf
/sbin/sysctl -p

echo "Restarting the network service"
systemctl restart network

# CloudStack prereqs
install_cloudstack_prereqs "$cloudstack_version"

# Database connector
echo "Installing MySQL connector..."
yum -y install mysql-connector-python

# Install CloudStack management
echo "Installing CloudStack..."
yum -y install cloudstack-management

# Database
if [[ $use_existing_database == true ]]
then
    echo "Using existing database..."
    cloudstack-setup-databases "$rds_service_username:$rds_service_password@$rds_endpoint:$rds_port"
else
    echo "Creating database user and schema..."
    cloudstack-setup-databases "$rds_service_username:$rds_service_password@$rds_endpoint:$rds_port" --deploy-as "$rds_admin_username:$rds_admin_password"
fi

# Limit log files
[[ $limit_log_files != true ]] || limit_log_files true false

# Configure and start CloudStack management
echo "Starting the CloudStack management service..."
cloudstack-setup-management

# Create the storage directories for the zone
echo "Mounting storage..."
yum install -y nfs-utils
mkdir -p /mnt/efs
echo "$efs_endpoint:/ /mnt/efs nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport,_netdev 0 0" >> /etc/fstab
mount /mnt/efs
echo "Ensuring the storage directories exist for the zone..."
mkdir -p "/mnt/efs/$zone_dir/primary"
mkdir -p "/mnt/efs/$zone_dir/secondary"

# Wait for the management service to fully start
wait_for_cloudstack_management "$overlay_host_ip_address"

# Done
echo
echo "The installation is complete and CloudStack is running."
