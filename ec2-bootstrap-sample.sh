#!/bin/bash

# bootstrap.sh - This is an example ec2 userdata template that can be used in
# a terraform script template for bootstrapping an ec2 instance to run a
# Gopherbot robot. It assumes, among other things, that the ec2 instance
# has an appropriate instance profile for reading ssm parameters and using
# an EIP, and also that the EIP and parameters exist.

echo "Running $0 ..."

# Uses precious RAM, not useful
echo "Disabling sssd (unused) ..."
systemctl stop sssd
systemctl disable sssd

echo "Setting up swap file (${swap_file_size}) ..."
# Create a swap file
fallocate -l ${swap_file_size} /swapfile
chmod 600 /swapfile
mkswap /swapfile

# Enable the swap file across reboots
echo '/swapfile swap swap defaults 0 0' | sudo tee -a /etc/fstab > /dev/null
swapon -a

yum -y upgrade
yum -y install jq git ruby python3-pip iptables wireguard-tools

echo "Getting secrets from SSM"
GOPHER_ENCRYPTION_KEY=$(aws ssm get-parameter --name "/robots/${bot_name}/encryption_key" --with-decryption --output text --query Parameter.Value)
GOPHER_DEPLOY_KEY=$(aws ssm get-parameter --name "/robots/${bot_name}/deploy_key" --with-decryption --output text --query Parameter.Value)
WG_PRIVATE=$(aws ssm get-parameter --name "/robots/${bot_name}/wg_key" --with-decryption --output text --query Parameter.Value)

echo "Associating static ip ..."
EIP_ALLOCATION_ID="${allocation_id}"
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -v http://169.254.169.254/latest/meta-data/instance-id)
AWS_REGION=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -v http://169.254.169.254/latest/meta-data/placement/region)
NETWORK_INTERFACE_ID=$(aws ec2 describe-instances --instance-id $INSTANCE_ID --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text --region $AWS_REGION)
aws ec2 associate-address --region $AWS_REGION --allocation-id $EIP_ALLOCATION_ID --network-interface-id $NETWORK_INTERFACE_ID

echo "Configuring WireGuard"
cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = ${vpn_cidr}
PrivateKey = $WG_PRIVATE
ListenPort = ${wireguard_port}
PostUp = /etc/wireguard/start-nat.sh
PostDown = /etc/wireguard/stop-nat.sh
EOF

cat > /etc/wireguard/start-nat.sh << 'EOF'
#!/bin/bash
echo 1 > /proc/sys/net/ipv4/ip_forward
ETHERNET_INT=$(ip -brief link show | awk '$1 ~ /^e/ {print $1; exit}')

# Create new chain
/sbin/iptables -N ALLOW_VPN

/sbin/iptables -t nat -I POSTROUTING 1 -s ${vpn_cidr} -o $ETHERNET_INT -j MASQUERADE
/sbin/iptables -I INPUT 1 -i wg0 -j ACCEPT
/sbin/iptables -I FORWARD 1 -i $ETHERNET_INT -o wg0 -j ACCEPT
/sbin/iptables -I FORWARD 1 -i wg0 -o $ETHERNET_INT -j ACCEPT
%{ if enable_firewall ~}
# NOTE: We're (I)nserting, so reverse order here
/sbin/iptables -I INPUT 1 -i $ETHERNET_INT -p udp --dport ${wireguard_port} -j DROP
/sbin/iptables -I INPUT 1 -i $ETHERNET_INT -p udp --dport ${wireguard_port} -j ALLOW_VPN
%{ endif ~}
EOF

cat > /etc/wireguard/stop-nat.sh << 'EOF'
#!/bin/bash
echo 0 > /proc/sys/net/ipv4/ip_forward
ETHERNET_INT=$(ip -brief link show | awk '$1 ~ /^e/ {print $1; exit}')
/sbin/iptables -t nat -D POSTROUTING -s ${vpn_cidr} -o $ETHERNET_INT -j MASQUERADE
/sbin/iptables -D INPUT -i wg0 -j ACCEPT
/sbin/iptables -D FORWARD -i $ETHERNET_INT -o wg0 -j ACCEPT
/sbin/iptables -D FORWARD -i wg0 -o $ETHERNET_INT -j ACCEPT
/sbin/iptables -D INPUT -i $ETHERNET_INT -p udp --dport ${wireguard_port} -j ACCEPT
EOF

chmod +x /etc/wireguard/*-nat.sh

systemctl start wg-quick@wg0

# Install latest Gopherbot
echo "Installing Gopherbot ..."
GBDL=/root/gopherbot.tar.gz
GB_LATEST=$(curl --silent https://api.github.com/repos/lnxjedi/gopherbot/releases/latest | jq -r .tag_name)
curl -s -L -o $GBDL https://github.com/lnxjedi/gopherbot/releases/download/$GB_LATEST/gopherbot-linux-amd64.tar.gz
cd /opt
tar xzf $GBDL
rm $GBDL

mkdir -p /var/lib/robots
useradd -d /var/lib/robots/${bot_name} -r -m -c "${bot_name} gopherbot" ${bot_name}
cat > /var/lib/robots/${bot_name}/.env << EOF
GOPHER_CUSTOM_REPOSITORY=${bot_repo}
GOPHER_DEPLOY_KEY=$GOPHER_DEPLOY_KEY
GOPHER_ENCRYPTION_KEY=$GOPHER_ENCRYPTION_KEY
GOPHER_PROTOCOL=${protocol}
GOPHER_BOTNAME=${bot_name}
EOF
chown ${bot_name}:${bot_name} /var/lib/robots/${bot_name}/.env
chmod 0600 /var/lib/robots/${bot_name}/.env
cat > /etc/systemd/system/${bot_name}.service <<EOF
[Unit]
Description=${bot_name} - Gopherbot DevOps Chatbot
Documentation=https://lnxjedi.github.io/gopherbot
After=syslog.target
After=network.target

[Service]
Type=simple
User=${bot_name}
Group=${bot_name}
WorkingDirectory=/var/lib/robots/${bot_name}
ExecStart=/opt/gopherbot/gopherbot -plainlog
Restart=on-failure
Environment=HOSTNAME=%H

KillMode=process
## Give the robot plenty of time to finish plugins currently executing;
## no new plugins will start after SIGTERM is caught.
TimeoutStopSec=600

[Install]
WantedBy=default.target
EOF

cat > /etc/sudoers.d/${bot_name}-user << EOF
# User rules for robot
${bot_name} ALL=(ALL) NOPASSWD:ALL
EOF

systemctl daemon-reload
systemctl enable ${bot_name}

echo "Starting the robot (${bot_name}) ..."
systemctl start ${bot_name}