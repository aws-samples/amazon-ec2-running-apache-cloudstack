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
allow_ssh_password_auth=false
cloudstack_version='4.17'
dns_ip_address=
hostname='cloudstack'
interface_name='eth0'
limit_log_files=false
nat=false
nat_exception=
virtual_ip_address=
virtual_netmask='255.255.0.0'

help() {
    echo "Installs Apache CloudStack management and agent on a single EC2 instance using local storage.  Must be run as root."
    echo
    echo "This script is based on the steps described at https://docs.cloudstack.apache.org/en/4.14.1.0/quickinstallationguide/qig.html"
    echo "with some customizations."
    echo
    echo "WARNING: If you're using a remote connection to run this script, you must either use nohup, or connect from a machine"
    echo "on the same subnet.  Otherwise, the script will fail during network configuration."
    echo
    echo "Prereqs:"
    echo " - Bare metal Nitro EC2 instance with x86_64 architecture"
    echo " - CentOS 7"
    echo " - Set a password for root if you plan on using password auth in CloudStack when configuring the host."
    echo " - Sufficient space on the root volume for the database and CloudStack storage"
    echo " - Internet access"
    echo
    echo "OPTIONS"
    echo "  --allow-ssh-password-auth        Enable password auth for SSH (necessary for CloudStack versions below 4.16)"
    echo "  --cloudstack-version <x.x>       CloudStack version to install (default=$cloudstack_version)"
    echo "  --dns-ip <x.x.x.x>               DNS server address"
    echo "  --hostname <hostname>            Hostname to set on the server (default = $hostname)"
    echo "  --interface <interface name>     Physical network interface name (default = $interface_name)"
    echo "  --limit-log-files                Configure CloudStack logging to limit the sizes of the log files"
    echo "  --nat                            Enable NAT"
    echo "  --nat-exception <x.x.x.x/xx>     Skip NAT when the destination is in this CIDR range"
    echo "  --virtual-host-ip <x.x.x.x>      IP address that should be assigned to the host on the virtual subnet"
    echo "  --virtual-netmask <x.x.x.x>      Netmask for the virtual subnet (default = $virtual_netmask)"
    echo
    exit 1
}


##################################
# Parse the command line arguments
##################################

[[ $# -ne 0 ]] || help

long_opts=allow-ssh-password-auth,cloudstack-version:,dns-ip:,help,hostname:,interface:,limit-log-files,nat,nat-exception:,virtual-gateway:,virtual-host-ip:,virtual-netmask:

! parsed_opts=$(getopt --options "" --longoptions=$long_opts --name "$0" -- "$@")
[[ ${PIPESTATUS[0]} -eq 0 ]] || help

eval set -- "$parsed_opts"

while true; do
    case "$1" in
        --allow-ssh-password-auth)
            allow_ssh_password_auth=true
            shift
            ;;
        --cloudstack-version)
            cloudstack_version="$2"
            shift 2
            ;;
        --dns-ip)
            dns_ip_address="$2"
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
        --nat)
            nat=true
            shift
            ;;
        --nat-exception)
            nat_exception="$2"
            shift 2
            ;;
        --virtual-host-ip)
            virtual_ip_address="$2"
            shift 2
            ;;
        --virtual-netmask)
            virtual_netmask="$2"
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


#########################################
# Make sure all provided values look good
#########################################

verify_cloudstack_version "$cloudstack_version"
verify_ip_address_format "$dns_ip_address" "DNS address"
verify_not_blank "$hostname" "hostname"
verify_not_blank "$interface_name" "network interface name"
[[ -z $nat_exception ]] || verify_cidr_format "$nat_exception" "NAT exception"
verify_ip_address_format "$virtual_ip_address" "virtual IP address"
verify_ip_address_format "$virtual_netmask" "virtual netmask"


#############################
# Check resource availability
#############################

verify_connectivity "$dns_ip_address" 53 "DNS server"
verify_network_interface "$interface_name"

if [[ $allow_ssh_password_auth = true ]] && [[ $(passwd --status root) != *"Password set"* ]]
then
    bad_input "Root password needs to be set for SSH password authentication to work"
fi


#######################
# Start of installation
#######################

# Hostname
# The CloudStack agent needs the machine to have a FQDN, not just a plain hostname.
fqdn="$hostname.localdomain"
echo "Setting the machine's hostname to $fqdn..."
hostnamectl set-hostname "$fqdn"
echo "$virtual_ip_address $fqdn" >> /etc/hosts

# Die if 'hostname --fqdn' doesn't return the right name.  CloudStack needs this to work.
if [[ $(hostname --fqdn) != "$fqdn" ]]
then
    echo "The hostname is configured incorrectly." >&2
    exit 1
fi

# SELinux
if [[ $(getenforce) = "Enforcing" ]]
then
    echo "Disabling SELinux..."
    setenforce 0
    sed -i -e 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
fi

# Network
echo "Configuring the network..."
yum install -y bridge-utils net-tools

# Enable IP forwarding
echo "Enabling IP forwarding..."
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
/sbin/sysctl -p

# Create a network bridge
echo "Configuring the network bridge..."

cat << EOF > /etc/sysconfig/network-scripts/ifcfg-cloudbr0
DEVICE=cloudbr0
TYPE=Bridge
ONBOOT=yes
BOOTPROTO=none
IPV6INIT=no
IPV6_AUTOCONF=no
DELAY=5
STP=yes
USERCTL=no
NM_CONTROLLED=no
IPADDR=$virtual_ip_address
NETMASK=$virtual_netmask
DNS1=$dns_ip_address
EOF

# Create a dummy interface for CloudStack to use when it connects to the bridge.  Without this, CloudStack will create an interface named vnet1,
# and then it won't be able to find the interface later because the name doesn't match what it's looking for.  The result would be that instances
# wouldn't be able to start on isolated networks.
cat << EOF > /etc/sysconfig/modules/dummy.modules
#!/bin/sh
/sbin/modprobe dummy numdummies=1
/sbin/ip link set name ethdummy0 dev dummy0
EOF

chmod +x /etc/sysconfig/modules/dummy.modules
/etc/sysconfig/modules/dummy.modules

cat << EOF > /etc/sysconfig/network-scripts/ifcfg-ethdummy0
TYPE=Ethernet
BOOTPROTO=none
NAME=ethdummy0
DEVICE=ethdummy0
ONBOOT=yes
BRIDGE=cloudbr0
EOF

# Must kill dhclient or the network service won't restart properly.
# A reboot would also work, but that's really inconvenient in the middle of a script.
pkill dhclient

echo "Restarting the network service"
systemctl restart network

# Network Address Translation
# You normally shouldn't need NAT, but it's convenient when the CloudStack system VMs start running before the AWS route tables are updated. If
# provides a way for the secondary storage VM to download templates without those routes being in place.  You could get rid of NAT once the
# route tables are configured, but it's also not going to hurt to leave it in place.  NAT won't be used for any addresses in the $nat_exception
# CIDR range.
if [[ $nat == true ]]
then
    yum install -y iptables-services
    systemctl enable iptables
    [[ -z $nat_exception ]] || iptables --table nat --append POSTROUTING --out-interface "$interface_name" --destination "$nat_exception" -j ACCEPT
    iptables --table nat --append POSTROUTING --out-interface "$interface_name" -j MASQUERADE
    service iptables save
fi

# CloudStack prereqs
install_cloudstack_prereqs "$cloudstack_version"

# NFS
echo "Installing NFS and creating CloudStack storage..."
yum -y install nfs-utils

# TODO: Make sure these directories are in a path that has enough storage space.
mkdir -p /export/primary
mkdir -p /export/secondary

cat << EOF > /etc/exports
/export/secondary *(rw,async,no_root_squash,no_subtree_check)
/export/primary *(rw,async,no_root_squash,no_subtree_check)
EOF

echo 'Domain = cloud.priv' >> /etc/idmapd.conf

cat << EOF >> /etc/sysconfig/nfs
LOCKD_TCPPORT=32803
LOCKD_UDPPORT=32769
MOUNTD_PORT=892
RQUOTAD_PORT=875
STATD_PORT=662
STATD_OUTGOING_PORT=2020
EOF

systemctl enable rpcbind
systemctl enable nfs
systemctl start rpcbind
systemctl start nfs

# CloudStack agent
echo "Installing CloudStack agent..."
yum -y install cloudstack-agent
sed -i -e 's/\#vnc_listen.*$/vnc_listen = "0.0.0.0"/g' /etc/libvirt/qemu.conf
sed -i -e 's/^#\s*LIBVIRTD_ARGS\s*=.*/LIBVIRTD_ARGS="--listen"/' /etc/sysconfig/libvirtd

cat << EOF >> /etc/libvirt/libvirtd.conf
listen_tls=0
listen_tcp=1
tcp_port = "16509"
mdns_adv = 0
auth_tcp = "none"
EOF

systemctl restart libvirtd

# Database
echo "Installing MySQL..."
install_mysql_repo
yum -y install mysql-server
sed -i -e 's/\[mysqld\]/[mysqld]\ninnodb_rollback_on_timeout=1\ninnodb_lock_wait_timeout=600\nmax_connections=350/' /etc/my.cnf
systemctl enable mysqld
systemctl start mysqld
yum -y install mysql-connector-python

# CloudStack management
echo "Installing CloudStack..."
yum -y install cloudstack-management

# Set up the database
db_password=$(pwmake 128)
cloudstack-setup-databases "cloud:$db_password@localhost" --deploy-as=root

# Limit log files
[[ $limit_log_files != true ]] || limit_log_files true true

# Configure and start CloudStack management
echo "Starting the CloudStack management service..."
cloudstack-setup-management

# SSH password auth
if [[ $allow_ssh_password_auth = true ]]
then
    echo "Enabling SSH password authentication..."
    sed -i -e 's/^PasswordAuthentication .*$/PasswordAuthentication yes/g' /etc/ssh/sshd_config
    systemctl restart sshd
fi

# Wait for the management service to fully start
wait_for_cloudstack_management "$virtual_ip_address"

# SSH key auth
cat /var/cloudstack/management/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys

# Done
echo
echo "The installation is complete and CloudStack is running."
