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
hostname='cloudstack-worker'
interface_name='eth0'
limit_log_files=false
multicast_ip=
overlay_gateway_ip=
overlay_host_ip_address=
overlay_netmask='255.255.0.0'

help() {
    echo "Installs Apache CloudStack agent and KVM on an EC2 instance using a VXLAN subnet.  Must be run as root."
    echo
    echo "WARNING: If you're using a remote connection to run this script, you must either use nohup, or connect from a machine"
    echo "on the same subnet.  Otherwise, the script will fail during network configuration."
    echo
    echo "Prereqs:"
    echo " - Bare metal Nitro EC2 instance with x86_64 architecture"
    echo " - CentOS 7"
    echo " - Set a password for root if you plan on using password auth in CloudStack when configuring the host."
    echo " - Internet access"
    echo
    echo "OPTIONS"
    echo "  --allow-ssh-password-auth        Enable password auth for SSH (necessary for CloudStack versions below 4.16)"
    echo "  --cloudstack-version <x.x>       CloudStack version to install (default=$cloudstack_version)"
    echo "  --dns-ip <x.x.x.x>               DNS server IP address"
    echo "  --hostname <hostname>            Hostname to set on the server (default = $hostname)"
    echo "  --interface <interface name>     Physical network interface name (default = $interface_name)"
    echo "  --limit-log-files                Configure CloudStack logging to limit the sizes of the log files"
    echo "  --multicast-ip <x.x.x.x>         Multicast IP address VXLAN should use"
    echo "  --overlay-gateway-ip <x.x.x.x>   Gateway IP address for the overlay network"
    echo "  --overlay-host-ip <x.x.x.x>      IP address that should be assigned to the host on the overlay network"
    echo "  --overlay-netmask <x.x.x.x>      Netmask for the overlay network (default = $overlay_netmask)"
    echo
    exit 1
}


##################################
# Parse the command line arguments
##################################

[[ $# -ne 0 ]] || help

long_opts=allow-ssh-password-auth,cloudstack-version:,dns-ip:,help,hostname:,interface:,limit-log-files,multicast-ip:,overlay-gateway-ip:,overlay-host-ip:,overlay-netmask:

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
verify_ip_address_format "$multicast_ip" "VLXAN multicast address"
verify_ip_address_format "$overlay_gateway_ip" "overlay network gateway address"
verify_ip_address_format "$overlay_host_ip_address" "overlay network host IP address"
verify_ip_address_format "$overlay_netmask" "overlay network netmask"


#############################
# Check resource availability
#############################

verify_connectivity "$dns_ip_address" 53 "DNS server"
verify_network_interface "$interface_name"

if [ "$allow_ssh_password_auth" = true ] && [[ $(passwd --status root) != *"Password set"* ]]
then
    bad_input "Root password needs to be set for SSH password authentication to work"
fi


#######################
# Start of installation
#######################

# Hostname and IP address
# The CloudStack agent needs the machine to have a FQDN, not just a plain hostname.
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

# Limit log files
[[ $limit_log_files != true ]] || limit_log_files false true

# SSH password auth
if [ "$allow_ssh_password_auth" = true ]
then
    echo "Enabling SSH password authentication..."
    sed -i -e 's/^PasswordAuthentication .*$/PasswordAuthentication yes/g' /etc/ssh/sshd_config
    systemctl restart sshd
fi

# Done
echo
echo "The installation is complete.  You may now add this host to CloudStack."
