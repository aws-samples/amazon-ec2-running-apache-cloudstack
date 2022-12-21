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
hostname='cloudstack-router'
interface_name='eth0'
multicast_ip=
nat=false
nat_exception=
overlay_host_ip_address=
overlay_netmask='255.255.0.0'

help() {
    echo "Configures an EC2 instance to act as a router for a VXLAN subnet.  Must be run as root."
    echo
    echo "Prereqs:"
    echo " - Nitro EC2 instance with x86_64 or ARM64 architecture"
    echo " - CentOS 7 or Amazon Linux 2"
    echo " - Internet access"
    echo
    echo "OPTIONS"
    echo "  --hostname <hostname>            Hostname to set on the server (default = $hostname)"
    echo "  --interface <interface name>     Machine's physical network interface name (default = $interface_name)"
    echo "  --multicast-ip <x.x.x.x>         Multicast IP address VXLAN should use"
    echo "  --nat                            Enable NAT"
    echo "  --nat-exception <x.x.x.x/xx>     Skip NAT when the destination is in this CIDR range"
    echo "  --overlay-host-ip <x.x.x.x>      IP address that should be assigned to the host on the overlay network"
    echo "  --overlay-netmask <x.x.x.x>      Netmask for the overlay network (default = $overlay_netmask)"
    echo
    exit 1
}


##################################
# Parse the command line arguments
##################################

[[ $# -ne 0 ]] || help

long_opts=help,hostname:,interface:,multicast-ip:,nat,nat-exception:,overlay-host-ip:,overlay-netmask:

! parsed_opts=$(getopt --options "" --longoptions=$long_opts --name "$0" -- "$@")
[[ ${PIPESTATUS[0]} -eq 0 ]] || help

eval set -- "$parsed_opts"

while true; do
    case "$1" in
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
        --multicast-ip)
            multicast_ip="$2"
            shift 2
            ;;
        --nat)
            nat=true
            shift
            ;;
        --nat-exception)
            nat_exception="$2"
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

verify_not_blank "$hostname" "hostname"
verify_not_blank "$interface_name" "network interface name"
verify_ip_address_format "$multicast_ip" "VLXAN multicast address"
verify_ip_address_format "$overlay_host_ip_address" "overlay network host IP address"
verify_ip_address_format "$overlay_netmask" "overlay network netmask"
[[ -z $nat_exception ]] || verify_cidr_format "$nat_exception" "NAT exception"


#############################
# Check resource availability
#############################

verify_network_interface "$interface_name"


###############################
# Start of system configuration
###############################

# Hostname
echo "Setting the machine's hostname to $hostname..."
hostnamectl set-hostname "$hostname"

# Network
echo "Configuring the network..."
yum install -y net-tools

# Enable IP forwarding
echo "Enabling IPv4 forwarding..."
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
/sbin/sysctl -p

cat << EOF > /sbin/ifup-local
#!/bin/bash
# Set up VXLAN once cloudbr0 is available.
if [[ \$1 == "$interface_name" ]]
then
    ip link add ethvxlan0 type vxlan id 100 dstport 4789 group "$multicast_ip" dev "$interface_name"
    ip address add "$overlay_host_ip_address/$overlay_netmask" dev ethvxlan0
    ip link set up dev ethvxlan0
fi
EOF

chmod +x /sbin/ifup-local

# Transit Gateway requires IGMP version 2
echo "net.ipv4.conf.$interface_name.force_igmp_version=2" >> /etc/sysctl.conf
/sbin/sysctl -p

echo "Restarting the network service"
systemctl restart network

# Network Address Translation
# You normally shouldn't need NAT, but it's necessary for software installation on the management and host instances.  That's
# because the installation happens before the user can manually update the AWS route tables.  Unlike the simple setup, adding
# NAT here isn't enough for the secondary storage VM to download templates, because a route in the local subnet is needed
# before the VM can access EFS.  Once that route is added, restarting the secondary storage VM will allow it to succeed.
#
# You could get rid of NAT once the route tables are configured, but it's also not going to hurt to leave it in place.  NAT
# won't be used for any addresses in the $nat_exception CIDR range.
if [[ $nat == true ]]
then
    yum install -y iptables-services
    systemctl enable iptables
    [[ -z $nat_exception ]] || iptables --table nat --append POSTROUTING --out-interface "$interface_name" --destination "$nat_exception" -j ACCEPT
    iptables --table nat --append POSTROUTING --out-interface "$interface_name" -j MASQUERADE
    service iptables save
fi

# Done
echo
echo "The configuration is complete."
