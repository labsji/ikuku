# ERPNext on Elastic Beanstalk — CloudFormation Template

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  VPC (10.0.0.0/16)                                  │
│                                                     │
│  ┌──────────────┐  ┌──────────────┐                 │
│  │ Public Subnet │  │ Public Subnet │                │
│  │  10.0.1.0/24 │  │  10.0.2.0/24 │                │
│  │  (AZ-a)      │  │  (AZ-b)      │                │
│  │  ┌────────┐  │  │              │                 │
│  │  │  EB    │  │  │              │                 │
│  │  │  EC2   │  │  │              │                 │
│  │  └────────┘  │  │              │                 │
│  └──────────────┘  └──────────────┘                 │
│                                                     │
│  ┌──────────────┐  ┌──────────────┐                 │
│  │ Private Sub  │  │ Private Sub  │                 │
│  │  10.0.3.0/24 │  │  10.0.4.0/24 │                │
│  │  (AZ-a)      │  │  (AZ-b)      │                │
│  │  ┌────────┐  │  │  ┌────────┐  │                │
│  │  │  RDS   │  │  │  │  RDS   │  │                │
│  │  │ MariaDB│  │  │  │(standby)│ │                │
│  │  └────────┘  │  │  └────────┘  │                │
│  └──────────────┘  └──────────────┘                 │
│                                                     │
│  ElastiCache Redis (private subnet)                 │
└─────────────────────────────────────────────────────┘
```

## Components

| Service | Purpose | Spec |
|---------|---------|------|
| Elastic Beanstalk | Frappe/ERPNext app + worker | Docker, t3.medium |
| RDS MariaDB | Database | db.t3.micro, 20GB |
| ElastiCache Redis | Cache + queue | cache.t3.micro |
| VPC | Network isolation | 2 AZs, public + private subnets |

## Cost Estimate (always-on, ap-south-1)

| Resource | Monthly |
|----------|---------|
| t3.medium (EB) | ~$30 |
| db.t3.micro (RDS) | ~$15 |
| cache.t3.micro | ~$12 |
| EBS 20GB | ~$2 |
| **Total** | **~$59/month** |

## Usage

```bash
# Deploy
aws cloudformation create-stack \
  --stack-name erpnext-eval \
  --template-body file://beanstalk-erpnext.yaml \
  --parameters ParameterKey=AdminPassword,ParameterValue=changeme123 \
  --capabilities CAPABILITY_IAM

# Get URL
aws elasticbeanstalk describe-environments \
  --environment-names erpnext-eval \
  --query 'Environments[0].CNAME' --output text
```
