#!/bin/bash
# terraform/bastion-userdata.sh
set -e

# Update system
yum update -y

# Install required packages
yum install -y curl wget unzip git docker

# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf awscliv2.zip aws/

# Install kubectl
curl -o kubectl https://s3.us-west-2.amazonaws.com/amazon-eks/1.29.3/2024-04-19/bin/linux/amd64/kubectl
chmod +x ./kubectl
mkdir -p /usr/local/bin
mv ./kubectl /usr/local/bin/

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
mv /tmp/eksctl /usr/local/bin

# Start Docker service
systemctl enable docker
systemctl start docker

# Add ec2-user to docker group
usermod -a -G docker ec2-user

# Create .kube directory for ec2-user
mkdir -p /home/ec2-user/.kube
chown ec2-user:ec2-user /home/ec2-user/.kube

# Configure kubectl for ec2-user
sudo -u ec2-user aws eks update-kubeconfig --region ${region} --name ${cluster_name}

# Create a script to easily update kubeconfig
cat > /home/ec2-user/update-kubeconfig.sh << 'EOF'
#!/bin/bash
aws eks update-kubeconfig --region ${region} --name ${cluster_name}
echo "Kubeconfig updated for cluster ${cluster_name}"
EOF

chmod +x /home/ec2-user/update-kubeconfig.sh
chown ec2-user:ec2-user /home/ec2-user/update-kubeconfig.sh

# Create useful aliases
cat >> /home/ec2-user/.bashrc << 'EOF'
alias k=kubectl
alias kgp='kubectl get pods'
alias kgs='kubectl get services'
alias kgd='kubectl get deployments'
alias kgi='kubectl get ingress'
export KUBECONFIG=/home/ec2-user/.kube/config
EOF

# Install session manager plugin
yum install -y https://s3.amazonaws.com/session-manager-downloads/plugin/latest/linux_64bit/session-manager-plugin.rpm

# Install additional useful tools
yum install -y htop tree jq

echo "Bastion host setup completed" > /home/ec2-user/setup-complete.txt
chown ec2-user:ec2-user /home/ec2-user/setup-complete.txt