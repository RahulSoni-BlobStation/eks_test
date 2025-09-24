# deployment-instructions.md
# EKS Deployment Instructions

This guide will help you deploy a complete EKS cluster with CI/CD pipeline, monitoring, and a sample application.

## Prerequisites

1. **AWS CLI configured** with appropriate permissions
2. **Terraform** installed (version >= 1.4)
3. **kubectl** installed
4. **AWS Key Pair** created in your region
5. **GitHub repository** set up for your application
6. **Docker** installed for local testing

## File Structure

```
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── vpc.tf
│   ├── security_groups.tf
│   ├── iam.tf
│   ├── eks.tf
│   ├── bastion.tf
│   ├── bastion-userdata.sh
│   ├── ecr.tf
│   └── outputs.tf
├── k8s/
│   ├── manifests.yaml
│   ├── load-balancer-controller.yaml
│   ├── ingress.yaml
│   └── monitoring.yaml
├── .github/workflows/
│   └── deploy.yml
├── Dockerfile
└── README.md
```

## Step 1: Update Variables

1. Edit `terraform/variables.tf` and update:
   - `allowed_cidr_blocks`: Your IP address for bastion access
   - `key_pair_name`: Your AWS key pair name
   - `github_org`: Your GitHub organization/username
   - `github_repo`: Your repository name

## Step 2: Deploy Infrastructure

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

**Wait for completion (approximately 15-20 minutes)**

## Step 3: Configure kubectl Access

### Option A: From Bastion Host (Recommended)
```bash
# Get bastion public IP from terraform output
BASTION_IP=$(terraform output -raw bastion_public_ip)

# SSH to bastion
ssh -i ~/.ssh/your-key.pem ec2-user@$BASTION_IP

# On bastion host - kubectl should already be configured
kubectl get nodes
```

### Option B: From Local Machine
```bash
# Get cluster name from terraform output
CLUSTER_NAME=$(terraform output -raw cluster_name)
AWS_REGION="ap-south-1"  # or your region

# Update kubeconfig
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

# Test connection
kubectl get nodes
```

## Step 4: Deploy AWS Load Balancer Controller

1. **Get values from Terraform outputs:**
```bash
cd terraform
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLUSTER_NAME=$(terraform output -raw cluster_name)
VPC_ID=$(terraform output -raw vpc_id)
AWS_REGION="ap-south-1"
PROJECT_NAME="my-project"
LBC_ROLE_ARN=$(terraform output -raw aws_load_balancer_controller_role_arn)
```

2. **Update the Load Balancer Controller YAML:**
```bash
cd ../k8s
sed -i "s/YOUR_ACCOUNT_ID/$ACCOUNT_ID/g" load-balancer-controller.yaml
sed -i "s/YOUR_PROJECT_NAME/$PROJECT_NAME/g" load-balancer-controller.yaml
sed -i "s/YOUR_CLUSTER_NAME/$CLUSTER_NAME/g" load-balancer-controller.yaml
sed -i "s/YOUR_VPC_ID/$VPC_ID/g" load-balancer-controller.yaml
sed -i "s/YOUR_AWS_REGION/$AWS_REGION/g" load-balancer-controller.yaml
```

3. **Deploy the controller:**
```bash
# Install cert-manager first
kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# Wait for cert-manager to be ready
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s

# Deploy Load Balancer Controller
kubectl apply -f load-balancer-controller.yaml

# Verify deployment
kubectl get deployment -n kube-system aws-load-balancer-controller
```

## Step 5: Deploy Sample Application

```bash
# Deploy application manifests
kubectl apply -f manifests.yaml

# Deploy ingress
kubectl apply -f ingress.yaml

# Check deployments
kubectl get all -n sample-app

# Get ALB URL
kubectl get ingress -n sample-app
```

## Step 6: Setup GitHub Actions CI/CD

1. **Get GitHub Actions role ARN:**
```bash
cd terraform
GITHUB_ROLE_ARN=$(terraform output -raw github_actions_role_arn)
echo "GitHub Actions Role ARN: $GITHUB_ROLE_ARN"
```

2. **Add secrets to your GitHub repository:**
   - Go to GitHub repository → Settings → Secrets and Variables → Actions
   - Add secret: `AWS_ROLE_TO_ASSUME` with value: `$GITHUB_ROLE_ARN`

3. **Update workflow file:**
   - Edit `.github/workflows/deploy.yml`
   - Update `EKS_CLUSTER_NAME` and `ECR_REPOSITORY` values

4. **Commit and push to trigger deployment:**
```bash
git add .
git commit -m "Initial EKS setup"
git push origin main
```

## Step 7: Deploy Monitoring

```bash
# Deploy metrics server
kubectl apply -f monitoring.yaml

# Verify metrics server
kubectl top nodes
kubectl top pods -n sample-app
```

## Step 8: Verify Everything Works

1. **Check cluster status:**
```bash
kubectl get nodes
kubectl get pods -A
```

2. **Check application:**
```bash
kubectl get pods -n sample-app
kubectl get ingress -n sample-app
```

3. **Test load balancer:**
```bash
# Get ALB DNS name
ALB_URL=$(kubectl get ingress backend-app-ingress-test -n sample-app -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Application URL: http://$ALB_URL"

# Test the application
curl -I http://$ALB_URL
```

## Step 9: Access Applications

### Bastion Host Access
```bash
# SSH to bastion
ssh -i ~/.ssh/your-key.pem ec2-user@$(terraform output -raw bastion_public_ip)

# Or use Session Manager (no key required)
aws ssm start-session --target $(terraform output -raw bastion_instance_id)
```

### Application Access
- **Via Load Balancer:** Use the ALB DNS name from ingress
- **Via Port Forward:** `kubectl port-forward -n sample-app svc/backend-app-service 8080:80`

## Cleanup

To destroy all resources:
```bash
cd terraform
terraform destroy
```

## Troubleshooting

### Common Issues:

1. **Bastion host can't access EKS:**
   - Check security groups
   - Verify IAM role permissions
   - Update kubeconfig: `aws eks update-kubeconfig --region ap-south-1 --name cluster-name`

2. **Load Balancer Controller not working:**
   - Check IAM role annotations in service account
   - Verify cert-manager is running
   - Check controller logs: `kubectl logs -n kube-system deployment/aws-load-balancer-controller`

3. **GitHub Actions failing:**
   - Verify OIDC provider setup
   - Check GitHub secrets
   - Ensure role trust policy is correct

4. **Pods not starting:**
   - Check node resources: `kubectl describe nodes`
   - Check pod events: `kubectl describe pod -n sample-app`
   - Verify ECR permissions

## Next Steps

1. **Configure SSL/TLS** for your application
2. **Setup custom domain** and Route 53 records
3. **Configure monitoring** with CloudWatch or Prometheus
4. **Setup log aggregation** with CloudWatch Logs or ELK stack
5. **Implement backup strategies** for stateful applications
6. **Configure autoscaling** for nodes and pods

## Security Considerations

1. **Update allowed_cidr_blocks** to restrict bastion access to your IP only
2. **Enable encryption** for EBS volumes and ECR repositories  
3. **Use AWS Secrets Manager** for sensitive application data
4. **Enable GuardDuty** and Security Hub for security monitoring
5. **Regular security updates** for all components
6. **Network policies** to restrict pod-to-pod communication
7. **Pod security policies** or Pod Security Standards