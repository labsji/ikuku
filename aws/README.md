# Frappe V16 on AWS Spot ARM - Personal Site

A minimal Frappe V16 deployment optimized for cost, running on an AWS Graviton (ARM64) Spot Instance with SQLite as the database backend.

## Architecture

```
                    Internet
                       |
                 [Elastic IP]
                       |
         [Lambda: EIP Reassigner]
                       |
          [EventBridge: instance running]
                       |
             [ASG: min=1, max=1]
                       |
           [t4g.nano Spot Instance]
                       |
    +------------------+------------------+
    |                  |                  |
  Caddy           Frappe Bench        Redis
  (HTTPS)         (gunicorn:8000)     (cache)
                  (socketio:9000)
                       |
                    SQLite
                  (local file)
```

## Cost Estimate

| Resource | Monthly Cost |
|----------|-------------|
| t4g.nano Spot Instance | ~$1.50 |
| Elastic IP (attached to running instance) | $0.00 |
| Elastic IP (when instance is stopped, ~few min/month) | ~$0.01 |
| EBS Volume (8 GB gp3) | ~$0.64 |
| Lambda invocations (< 100/month) | ~$0.00 |
| **Total** | **~$2.15/month** |

> Note: EIPs are free when attached to a running instance. Cost only accrues during the brief seconds between spot interruption and new instance launch.

## Why SQLite?

- **Single user**: This is a personal site, no concurrent write pressure
- **No RDS cost**: Eliminates the $15+/month cost of the smallest RDS instance
- **Simpler stack**: No database server to manage, patch, or monitor
- **Data persists on EBS**: The SQLite file lives on the instance's EBS volume which survives spot interruptions (instance is stopped, not terminated)

## Apps Included

- **Frappe V16** - The web framework
- **Wiki** - Knowledge base / documentation (frappe/wiki)
- **Bind** - AI agent integration (labsji/bind)
- **Kiro CLI** - Development assistant CLI tool

## Deployment

### Prerequisites

- AWS Account
- An EC2 Key Pair (for SSH access)
- A VPC with at least one public subnet

### Deploy via AWS Console

1. Go to **CloudFormation** in the AWS Console
2. Click **Create Stack** > **With new resources**
3. Upload `aws/cloudformation.yml`
4. Fill in the parameters:
   - **KeyPairName**: Your EC2 key pair
   - **VpcId**: Your VPC
   - **SubnetId**: A public subnet in the VPC
   - **DomainName** (optional): Your domain (e.g., `santosh.example.com`)
   - **InstanceType**: Leave as `t4g.nano` for lowest cost
5. Click through and create the stack

### Deploy via AWS CLI

```bash
aws cloudformation create-stack \
  --stack-name frappe-personal \
  --template-body file://aws/cloudformation.yml \
  --capabilities CAPABILITY_IAM \
  --parameters \
    ParameterKey=KeyPairName,ParameterValue=my-key \
    ParameterKey=VpcId,ParameterValue=vpc-12345678 \
    ParameterKey=SubnetId,ParameterValue=subnet-12345678 \
    ParameterKey=DomainName,ParameterValue=santosh.example.com
```

### DNS Setup (if using a domain)

After the stack creates, point your domain's A record to the Elastic IP shown in the stack outputs. Caddy will automatically provision a Let's Encrypt certificate.

## SSH Access

```bash
# Get the EIP from CloudFormation outputs
ssh -i my-key.pem ec2-user@<ElasticIP>

# Switch to frappe user
sudo su - frappe

# Check bench status
cd ~/frappe-bench
bench --site frappe.localhost doctor
```

## Updating Apps

```bash
ssh -i my-key.pem ec2-user@<ElasticIP>
sudo su - frappe
cd ~/frappe-bench

# Update all apps
bench update

# Or update a specific app
bench update --pull --app wiki

# Restart after update
sudo systemctl restart frappe-bench
```

## EIP Reassignment Pattern

The key cost-saving mechanism is using Spot Instances with automatic EIP reassignment:

1. **Spot Instance** runs the Frappe site at a ~70% discount vs On-Demand
2. When AWS reclaims the spot capacity, the instance is **stopped** (not terminated)
3. The ASG detects the stopped instance and launches a new one
4. **EventBridge** fires an event when the new instance enters the `running` state
5. **Lambda** picks up the event, verifies the instance belongs to our ASG, and reassigns the EIP
6. **Downtime**: Typically under 2 minutes (just the time for a new instance to launch and bootstrap)

Since the EBS volume persists across spot interruptions (the instance is stopped/started, not terminated), no data is lost. The SQLite database and all site files remain intact.

## Troubleshooting

### Check service status
```bash
sudo systemctl status frappe-bench
sudo systemctl status caddy
sudo systemctl status redis6
```

### View logs
```bash
# Frappe bench logs
sudo journalctl -u frappe-bench -f

# Caddy logs
sudo journalctl -u caddy -f
```

### Restart services
```bash
sudo systemctl restart frappe-bench
sudo systemctl restart caddy
```

### Manual bench start (for debugging)
```bash
sudo su - frappe
cd ~/frappe-bench
bench start
```
