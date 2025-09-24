#!/bin/bash
# setup-eks.sh
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running from correct directory
if [ ! -f "terraform/main.tf" ]; then
    print_error "Please run this script from the root directory containing terraform/ folder"
    exit 1
fi

print_status "Starting EKS cluster setup..."

# Step 1: Initialize and apply Terraform
print_status "Step 1: Deploying infrastructure with Terraform..."
cd terraform

# Initialize Terraform
terraform init

# Plan deployment
print_status "Creating Terraform plan..."
terraform plan -out=eks-plan

# Apply deployment
print_warning "About to create AWS resources. This will take 15-20 minutes."
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_error "Deployment cancelled by user"
    exit 1
fi

terraform apply eks-plan

if [ $? -ne 0 ]; then
    print_error "Terraform apply failed"
    exit 1
fi

print_success "Infrastructure deployment completed"

# Get outputs
CLUSTER_NAME=$(terraform output -raw cluster_name)
BASTION_IP=$(terraform output -raw bastion_public_ip)
ECR_REPO_URL=$(terraform output -raw ecr_repository_url)
LBC_ROLE_ARN=$(terraform output -raw aws_load_balancer_controller_role_arn)
GITHUB_ROLE_ARN=$(terraform output -raw github_actions_role_arn)
VPC_ID=$(terraform output -raw vpc_id)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

print_success "Cluster created: $CLUSTER_NAME"
print_success "Bastion host IP: $BASTION_IP"
print_success "ECR repository: $ECR_REPO_URL"

# Step 2: Configure kubectl
print_status "Step 2: Configuring kubectl..."
cd ..
aws eks update-kubeconfig --region ap-south-1 --name $CLUSTER_NAME

# Wait for nodes to be ready
print_status "Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

if [ $? -eq 0 ]; then
    print_success "All nodes are ready"
    kubectl get nodes
else
    print_error "Timeout waiting for nodes to be ready"
    exit 1
fi

# Step 3: Deploy cert-manager
print_status "Step 3: Installing cert-manager..."
kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.13.0/cert-manager.yaml

print_status "Waiting for cert-manager to be ready..."
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s

if [ $? -eq 0 ]; then
    print_success "cert-manager is ready"
else
    print_error "cert-manager deployment failed"
    exit 1
fi

# Step 4: Update and deploy Load Balancer Controller
print_status "Step 4: Deploying AWS Load Balancer Controller..."
cd k8s

# Update load balancer controller YAML with actual values
sed -i.bak "s/YOUR_ACCOUNT_ID/$ACCOUNT_ID/g" load-balancer-controller.yaml
sed -i.bak "s/YOUR_PROJECT_NAME/my-project/g" load-balancer-controller.yaml
sed -i.bak "s/YOUR_CLUSTER_NAME/$CLUSTER_NAME/g" load-balancer-controller.yaml
sed -i.bak "s/YOUR_VPC_ID/$VPC_ID/g" load-balancer-controller.yaml
sed -i.bak "s/YOUR_AWS_REGION/ap-south-1/g" load-balancer-controller.yaml

kubectl apply -f load-balancer-controller.yaml

print_status "Waiting for Load Balancer Controller to be ready..."
kubectl wait --for=condition=Available deployment/aws-load-balancer-controller -n kube-system --timeout=300s

if [ $? -eq 0 ]; then
    print_success "AWS Load Balancer Controller is ready"
else
    print_error "AWS Load Balancer Controller deployment failed"
    exit 1
fi

# Step 5: Deploy sample application
print_status "Step 5: Deploying sample application..."
kubectl apply -f manifests.yaml

print_status "Waiting for application deployment..."
kubectl wait --for=condition=Available deployment/backend-app -n sample-app --timeout=300s

if [ $? -eq 0 ]; then
    print_success "Sample application deployed successfully"
else
    print_error "Sample application deployment failed"
    exit 1
fi

# Step 6: Deploy ingress
print_status "Step 6: Deploying ingress..."
kubectl apply -f ingress.yaml

print_status "Waiting for load balancer to be provisioned..."
sleep 30

# Step 7: Deploy monitoring
print_status "Step 7: Deploying monitoring..."
kubectl apply -f monitoring.yaml

print_status "Waiting for metrics server..."
kubectl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=300s

if [ $? -eq 0 ]; then
    print_success "Monitoring deployed successfully"
else
    print_warning "Monitoring deployment may have issues, check manually"
fi

# Step 8: Display final information
print_success "EKS cluster setup completed successfully!"
echo
print_status "=== CLUSTER INFORMATION ==="
echo "Cluster Name: $CLUSTER_NAME"
echo "Bastion Host IP: $BASTION_IP"
echo "ECR Repository: $ECR_REPO_URL"
echo
print_status "=== GITHUB ACTIONS SETUP ==="
echo "Add this as a secret in your GitHub repository:"
echo "Secret Name: AWS_ROLE_TO_ASSUME"
echo "Secret Value: $GITHUB_ROLE_ARN"
echo
print_status "=== ACCESS INSTRUCTIONS ==="
echo "SSH to bastion: ssh -i ~/.ssh/your-key.pem ec2-user@$BASTION_IP"
echo "Update local kubectl: aws eks update-kubeconfig --region ap-south-1 --name $CLUSTER_NAME"
echo
print_status "=== APPLICATION STATUS ==="
kubectl get pods -n sample-app
echo
print_status "=== GETTING LOAD BALANCER URL ==="
kubectl get ingress -n sample-app

# Get ALB URL
ALB_URL=$(kubectl get ingress backend-app-ingress-test -n sample-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "Still provisioning...")
if [ "$ALB_URL" != "Still provisioning..." ]; then
    print_success "Application accessible at: http://$ALB_URL"
else
    print_warning "Load balancer still provisioning. Check again in a few minutes with:"
    echo "kubectl get ingress -n sample-app"
fi

print_success "Setup completed! Check the deployment-instructions.md file for detailed next steps."