Rabbitmq Auto Clustering in Amazon EC2 Container Service
========================================================

Automation of Rabbitmq clustering in Amazon EC2 Container Service based on AWS Auto Scaling group membership.

***Requirements:***

    * the rabbitmq cluster is deployed within a single AWS Auto Scaling group
    * only run one rabbitmq container per ECS instance and run odd numbers of rabbitmq instance i.e. 3, 5, 7, etc
    * use the 'host' docker networking mode when running the containers to cause them to inherit the private short dns names of the ECS instances as their hostnames this way rabbitmq
    uses these DNS names for node discovery during the clustering process
    * the ECS instances must be assigned the following IAM policies:
    "autoscaling:DescribeAutoScalingInstances",
    "autoscaling:DescribeAutoScalingGroups",
    "ec2:DescribeInstances"
    * set environment variable AWS_ASG_AUTOCLUSTER="true" when starting the container


Deployment
----------

