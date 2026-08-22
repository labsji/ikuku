"""
EIP Reassignment Lambda Handler

Monitors EC2 instance state-change events via EventBridge and reassigns
a dedicated Elastic IP to the currently running spot instance in the ASG.

Environment Variables:
    EIP_ALLOCATION_ID: The Allocation ID of the Elastic IP to manage
    ASG_NAME: The name of the Auto Scaling Group to monitor
"""

import boto3
import os
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2 = boto3.client('ec2')
autoscaling = boto3.client('autoscaling')


def handler(event, context):
    """Handle EC2 instance state-change events and reassign EIP.

    Args:
        event: EventBridge event with EC2 state-change notification
        context: Lambda context object

    Returns:
        dict with statusCode and body describing the action taken
    """
    logger.info(f"Received event: {event}")

    detail = event.get('detail', {})
    instance_id = detail.get('instance-id')
    state = detail.get('state')

    if state != 'running':
        logger.info(f"Instance {instance_id} state is '{state}', not 'running'. Skipping.")
        return {'statusCode': 200, 'body': 'Not a running state event'}

    # Verify instance belongs to our ASG
    asg_name = os.environ['ASG_NAME']
    asg_response = autoscaling.describe_auto_scaling_groups(
        AutoScalingGroupNames=[asg_name]
    )

    asg_groups = asg_response.get('AutoScalingGroups', [])
    if not asg_groups:
        logger.error(f"ASG {asg_name} not found")
        return {'statusCode': 404, 'body': 'ASG not found'}

    asg_instance_ids = [
        inst['InstanceId']
        for inst in asg_groups[0].get('Instances', [])
    ]

    if instance_id not in asg_instance_ids:
        logger.info(f"Instance {instance_id} not in ASG {asg_name}. Skipping.")
        return {'statusCode': 200, 'body': 'Instance not in ASG'}

    # Get current EIP association
    allocation_id = os.environ['EIP_ALLOCATION_ID']
    addresses = ec2.describe_addresses(AllocationIds=[allocation_id])
    address = addresses['Addresses'][0]

    # Disassociate if currently associated with another instance
    association_id = address.get('AssociationId')
    if association_id:
        logger.info(f"Disassociating EIP from previous instance: {association_id}")
        ec2.disassociate_address(AssociationId=association_id)

    # Associate EIP with new running instance
    logger.info(f"Associating EIP {allocation_id} with instance {instance_id}")
    ec2.associate_address(
        AllocationId=allocation_id,
        InstanceId=instance_id
    )

    logger.info(f"EIP successfully reassigned to {instance_id}")
    return {'statusCode': 200, 'body': f'EIP assigned to {instance_id}'}
