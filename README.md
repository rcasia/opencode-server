# opencode-server

Terraform infra for an agentic coding EC2 server on AWS (`eu-west-1`, `t3.micro` default).

Provisions: VPC + public subnet + IGW, security group (SSH + opencode 4096), IAM role for SSM, EC2 (AL2023) with Docker + Node 22 + opencode via user-data, Elastic IP.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# edit allowed_ssh_cidr to YOUR_IP/32
terraform init
terraform fmt -recursive
terraform validate
terraform plan
terraform apply
```

Connect:
```bash
# keyless (SSM)
aws ssm start-session --region eu-west-1 --target $(terraform output -raw instance_id)
# or SSH if ssh_public_key set
```
