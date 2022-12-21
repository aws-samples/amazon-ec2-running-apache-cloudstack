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

# Installs things needed to verify that the installation script was given the right information.  These are prereqs
# for the checks that run prior to the start of the actual installation.  When adding to this function, please keep it
# idempotent because it might need to run multiple times while the user figures out the right command line arguments.
install_common_prereqs() {
    echo "Installing common prereqs"
    if command -v amazon-linux-extras > /dev/null
    then
        amazon-linux-extras install -y epel
        yum -y install nc
    else
        yum -y install epel-release
        yum -y install netcat
    fi
    yum -y install wget
}

# Installs the mysql repo.  This is sometimes a prereq for the checks that run prior to the start of the actual
# installation.  When adding to this function, please keep it idempotent because it might need to run multiple times
# while the user figures out the right command line arguments.
install_mysql_repo() {
    wget https://repo.mysql.com/mysql-community-release-el7-5.noarch.rpm
    # Force the rpm installation so it doesn't cause an error if the package was already installed.
    rpm -ivh --force mysql-community-release-el7-5.noarch.rpm
}

# Installs the AWS CLI.  This is sometimes a prereq for the checks that run prior to the start of the actual
# installation.  When adding to this function, please keep it idempotent because it might need to run multiple times
# while the user figures out the right command line arguments.
install_aws_cli() {
    if ! command -v /usr/local/bin/aws > /dev/null
    then
        yum install -y unzip
        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
        unzip awscliv2.zip
        aws/install
    fi
}

bad_input() {
    echo >&2
    echo "$1" >&2
    echo "Please correct this issue and run the script again." >&2
    echo >&2
    exit 1
}

verify_not_blank() {
    local content="$1"
    local label="$2"
    [[ -n $content ]] || bad_input "Missing $label"
}

verify_ip_address_format() {
    local address="$1"
    local label="$2"
    verify_not_blank "$address" "$label"
    # For simplicity, only check for the most common IPv4 address format and ignore the fact that octets can be > 255 or non-decimal.
    [[ $address =~ ^[0-9]{1,3}([.][0-9]{1,3}){3}$ ]] || bad_input "$label isn't in an acceptable format: $address"
}

verify_cidr_format() {
    local cidr="$1"
    local label="$2"
    verify_not_blank "$cidr" "$label"
    # For simplicity, only check for the most common IPv4 address format and ignore the fact that octets can be > 255 or non-decimal.
    # Accept any 1 or 2 digit number after the slash.
    [[ $cidr =~ ^[0-9]{1,3}([.][0-9]{1,3}){3}/[0-9]{1,2}$ ]] || bad_input "$label isn't in an acceptable format: $cidr"
}

verify_cloudstack_version() {
    local cloudstack_version=$1
    [[ $cloudstack_version =~ ^[0-9]+[.][0-9]+$ ]] || bad_input "CloudStack version doesn't look like a valid version number."
}

require_root() {
    [[ $UID = 0 ]] || bad_input "This script needs to be run as root."
}

verify_network_interface() {
    local interface_name=$1
    ! /sbin/ip -4 -br address | grep --quiet "^$interface_name[ ]\+UP[ ]"
    [[ ${PIPESTATUS[1]} -eq 0 ]] || bad_input "Network interface \"$interface_name\" doesn't exist or isn't up"
}

verify_connectivity() {
    local host="$1"
    local port="$2"
    local label="$3"
    echo "Checking connection to $host:$port..."
    ! nc -z -w 5 "$host" "$port"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || bad_input "Can't connect to $label at $host:$port"
}

wait_for_cloudstack_management() {
    local ip_address="$1"
    local url="http://$ip_address:8080/client/"
    echo "Waiting for CloudStack to be available at $url..."
    ! timeout 10m bash -c 'until [[ $(curl -s -o /dev/null -w "%{http_code}" '$url') -eq 200 ]]; do sleep 5; done'
    if [[ ${PIPESTATUS[0]} -ne 0 ]]
    then
        echo "Timed out while waiting for the CloudStack managment service to be ready."
        exit 1
    fi
    echo "The CloudStack management service is ready."
}

get_databases() {
    local host="$1"
    local port="$2"
    local username="$3"
    local password="$4"
    mysql -u "$username" "-p$password" -h "$host" -P "$port" -s -N -e "SHOW DATABASES;" || true
}

install_cloudstack_prereqs() {
    local cloudstack_version=$1

    # Java -- CloudStack needs version 11
    echo "Installing and configuring Java..."
    rpm --import https://yum.corretto.aws/corretto.key
    curl -L -o /etc/yum.repos.d/corretto.repo https://yum.corretto.aws/corretto.repo
    yum install -y java-11-amazon-corretto-devel
    local java_path=$(alternatives --list | grep '/java-11-amazon-corretto/bin/java\b' | awk '{print $3}')
    alternatives --set java "$java_path"

    # It's a good idea to set Java's DNS cache TTL when you have long running processes.
    local java_security_path="$(dirname $(dirname $(readlink -f $(which java))))/conf/security/java.security"
    ! grep --quiet '^[ ]*networkaddress.cache.ttl\b' "$java_security_path"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || echo 'networkaddress.cache.ttl=60' >> "$java_security_path"

    # NTP
    echo "Installing and starting NTP..."
    yum -y install ntp
    systemctl enable ntpd
    systemctl start ntpd

    # CloudStack repository
    echo "Adding CloudStack repository..."
cat << EOF > /etc/yum.repos.d/cloudstack.repo
[cloudstack]
name=cloudstack
baseurl=https://download.cloudstack.org/\$contentdir/\$releasever/$cloudstack_version/
enabled=1
gpgcheck=0
EOF
}

limit_log_files() {
    local management_server=$1
    local agent=$2

    echo "Installing XML editing tool..."
    yum -y install xmlstarlet

    if [[ $management_server = true ]]
    then
        echo "Configuring CloudStack management server logging..."
        # Back up log config file, just in case this script breaks things with a future CloudStack version.
        cp /etc/cloudstack/management/log4j.xml /etc/cloudstack/management/log4j.xml.original

        xmlstarlet ed --pf -L \
        --delete '/log4j:configuration/appender[@name="FILE"]/rollingPolicy' \
        --subnode '/log4j:configuration/appender[@name="FILE"]' --type elem --name rollingPolicy \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy' --type attr --name class --value org.apache.log4j.rolling.FixedWindowRollingPolicy \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy' --type elem --name param \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy' --type elem --name param \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy' --type elem --name param \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy' --type elem --name param \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy/param[1]' --type attr --name name --value ActiveFileName \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy/param[1]' --type attr --name value --value '/var/log/cloudstack/management/management-server.log' \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy/param[2]' --type attr --name name --value FileNamePattern \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy/param[2]' --type attr --name value --value '/var/log/cloudstack/management/management-server.log.%i.gz' \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy/param[3]' --type attr --name name --value MinIndex \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy/param[3]' --type attr --name value --value '1' \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy/param[4]' --type attr --name name --value MaxIndex \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy/param[4]' --type attr --name value --value '10' \
        --subnode '/log4j:configuration/appender[@name="FILE"]' --type elem --name triggeringPolicy \
        --subnode '/log4j:configuration/appender[@name="FILE"]/triggeringPolicy' --type attr --name class --value org.apache.log4j.rolling.SizeBasedTriggeringPolicy \
        --subnode '/log4j:configuration/appender[@name="FILE"]/triggeringPolicy' --type elem --name param \
        --subnode '/log4j:configuration/appender[@name="FILE"]/triggeringPolicy/param' --type attr --name name --value MaxFileSize \
        --subnode '/log4j:configuration/appender[@name="FILE"]/triggeringPolicy/param' --type attr --name value --value '10485760' \
        --delete '/log4j:configuration/appender[@name="APISERVER"]/rollingPolicy' \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]' --type elem --name rollingPolicy \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/rollingPolicy' --type attr --name class --value org.apache.log4j.rolling.FixedWindowRollingPolicy \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/rollingPolicy' --type elem --name param \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/rollingPolicy' --type elem --name param \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/rollingPolicy' --type elem --name param \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/rollingPolicy' --type elem --name param \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/rollingPolicy/param[1]' --type attr --name name --value ActiveFileName \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/rollingPolicy/param[1]' --type attr --name value --value '/var/log/cloudstack/management/apilog.log' \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/rollingPolicy/param[2]' --type attr --name name --value FileNamePattern \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/rollingPolicy/param[2]' --type attr --name value --value '/var/log/cloudstack/management/apilog.log.%i.gz' \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/rollingPolicy/param[3]' --type attr --name name --value MinIndex \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/rollingPolicy/param[3]' --type attr --name value --value '1' \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/rollingPolicy/param[4]' --type attr --name name --value MaxIndex \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/rollingPolicy/param[4]' --type attr --name value --value '10' \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]' --type elem --name triggeringPolicy \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/triggeringPolicy' --type attr --name class --value org.apache.log4j.rolling.SizeBasedTriggeringPolicy \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/triggeringPolicy' --type elem --name param \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/triggeringPolicy/param' --type attr --name name --value MaxFileSize \
        --subnode '/log4j:configuration/appender[@name="APISERVER"]/triggeringPolicy/param' --type attr --name value --value '10485760' \
        /etc/cloudstack/management/log4j.xml

cat << EOF > /etc/cron.daily/truncate_cloudstack_tomcat_log
#!/bin/bash
truncate --size 0 /var/log/cloudstack/management/access.log
EOF

        chmod +x /etc/cron.daily/truncate_cloudstack_tomcat_log
    fi

    if [[ $agent = true ]]
    then
        echo "Configuring CloudStack agent logging..."
        # Back up log config file, just in case this script breaks things with a future CloudStack version.
        cp /etc/cloudstack/agent/log4j-cloud.xml /etc/cloudstack/agent/log4j-cloud.xml.original

        xmlstarlet ed --pf -L \
        --delete '/log4j:configuration/appender[@name="FILE"]/rollingPolicy' \
        --subnode '/log4j:configuration/appender[@name="FILE"]' --type elem --name rollingPolicy \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy' --type attr --name class --value org.apache.log4j.rolling.FixedWindowRollingPolicy \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy' --type elem --name param \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy' --type elem --name param \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy' --type elem --name param \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy' --type elem --name param \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy/param[1]' --type attr --name name --value ActiveFileName \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy/param[1]' --type attr --name value --value '/var/log/cloudstack/agent/agent.log' \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy/param[2]' --type attr --name name --value FileNamePattern \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy/param[2]' --type attr --name value --value '/var/log/cloudstack/agent/agent.log.%i.gz' \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy/param[3]' --type attr --name name --value MinIndex \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy/param[3]' --type attr --name value --value '1' \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy/param[4]' --type attr --name name --value MaxIndex \
        --subnode '/log4j:configuration/appender[@name="FILE"]/rollingPolicy/param[4]' --type attr --name value --value '10' \
        --subnode '/log4j:configuration/appender[@name="FILE"]' --type elem --name triggeringPolicy \
        --subnode '/log4j:configuration/appender[@name="FILE"]/triggeringPolicy' --type attr --name class --value org.apache.log4j.rolling.SizeBasedTriggeringPolicy \
        --subnode '/log4j:configuration/appender[@name="FILE"]/triggeringPolicy' --type elem --name param \
        --subnode '/log4j:configuration/appender[@name="FILE"]/triggeringPolicy/param' --type attr --name name --value MaxFileSize \
        --subnode '/log4j:configuration/appender[@name="FILE"]/triggeringPolicy/param' --type attr --name value --value '10485760' \
        /etc/cloudstack/agent/log4j-cloud.xml
    fi
}