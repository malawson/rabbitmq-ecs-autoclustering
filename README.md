Rabbitmq Auto Clustering in Amazon ECS (EC2 Container Service)
========================================================

Automation of Rabbitmq clustering in Amazon EC2 Container Service based on AWS Auto Scaling group membership. This has been tested with small to medium size rabbitmq clusters, and is essentially using the rabbitmq docker image definition from [upstream](https://github.com/docker-library/rabbitmq/blob/4761fd0c03b8ca4e81967019e564d0659e4b7b74/3.6/debian/Dockerfile). For example a cluster of 3 nodes would be able to withstand up to 2 node failures; meaning if 2 ECS instances/tasks were to die they would be replaced by new instances/tasks (based on the desired count of 3 set for the Auto Scaling group or the ECS service) and these new nodes will rejoin the existing cluster. All of the code for handling cluster formation and recovery is in docker-image/rabbitmq_asg_autocluster.py

**Requirements:**

- the rabbitmq cluster is deployed within a single AWS Auto Scaling group
- only run one rabbitmq container per ECS instance and deploy odd numbers of rabbitmq instances i.e. 3, 5, 7, etc [More On Rabbitmq Clustering](https://www.rabbitmq.com/clustering.html)
- use the 'host' docker networking mode when running the containers to cause them to inherit the private short dns names of the ECS instances as their hostnames; this way rabbitmq
uses these DNS names for node discovery during the clustering process
- the ECS instances must be assigned the following IAM policies:
"autoscaling:DescribeAutoScalingInstances",
"autoscaling:DescribeAutoScalingGroups",
"ec2:DescribeInstances"
- set environment variable AWS_ASG_AUTOCLUSTER="true" when starting the container


Deployment
----------
Below are some main steps for building and deploying these auto clustering rabbitmq docker images in ECS; adjust as you see fit.

- IAM Policy for ECS Instances

Make sure the IAM policy for the ECS instances include these: "autoscaling:DescribeAutoScalingInstances", "autoscaling:DescribeAutoScalingGroups", "ec2:DescribeInstances"

```
  InstanceRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Statement:
        - Effect: Allow
          Principal:
            Service: [ec2.amazonaws.com]
          Action: ['sts:AssumeRole']
      Path: /
      Policies:
      - PolicyName: Rabbitmq-ECS-Auto-Clustering
        PolicyDocument:
          Statement:
          - Effect: Allow
            Action: ['autoscaling:DescribeAutoScalingInstances', 'autoscaling:DescribeAutoScalingGroups', 'ec2:DescribeInstances]
            Resource: '*'
  InstanceProfile:
    Type: AWS::IAM::InstanceProfile
    Properties:
      Path: /
      Roles: [!Ref 'InstanceRole']
```


- Build & push the docker image to the ECR registry.

```
    aws ecr get-login --region us-east-1
    cd <path-to>/rabbitmq-ecs-autoclustering/docker-image
    docker build -t arnaud/rabbitmq-asg-autocluster .
    docker tag arnaud/rabbitmq-asg-autocluster:latest ${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/arnaud/rabbitmq-asg-autocluster:latest

```
- Deploy the containers in ECS

Here are sample AWS ECS Task & Sevice definitions in YAML syntax for running these containers. Modify as necessary and set relevant values for any of the AWS Cloudformation Parameters - i.e. QueueUser, QueuePass, etc. 

```
  TaskDefinition:
    Type: AWS::ECS::TaskDefinition
    Properties:
      ServiceToken: !Ref 'TaskDefinitionServiceToken'
      Family: !Ref 'AWS::StackName'
      Volumes:
      - Host:
          SourcePath: /var/lib/rabbitmq-asg-autocluster
        Name: rabbitmq-database
      # important for rabbit node discovery as containers inherit the host's hostname that is in DNS 
      NetworkMode: 'host'
      ContainerDefinitions:
      - Name: rabbit
        Image: ${AWS_ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com/arnaud/rabbitmq-asg-autocluster:latest
        MountPoints:
        - SourceVolume: rabbitmq-database
          ContainerPath: /var/lib/rabbitmq
        Cpu: '512'
        Memory: !Ref 'RabbitHardMemoryLimit'
        MemoryReservation: !Ref 'RabbitSoftMemoryLimit'
        PortMappings:
        - HostPort: 5672
          ContainerPort: 5672
          Protocol: tcp
        - HostPort: !Ref 15672
          ContainerPort: 15672
          Protocol: tcp
        - HostPort: 4369
          ContainerPort: 4369
          Protocol: tcp
        - HostPort: 25672
          ContainerPort: 25672
          Protocol: tcp
        Environment:
        - Name: RABBITMQ_DEFAULT_VHOST
          Value: !Ref 'QueueVHost'
        - Name: RABBITMQ_DEFAULT_USER
          Value: !Ref 'QueueUser'
        - Name: RABBITMQ_DEFAULT_PASS
          Value: !Ref 'QueuePass'
        - Name: RABBITMQ_DEFAULT_PORT
          Value: 5672
        - Name: RABBITMQ_VM_MEMORY_HIGH_WATERMARK
          Value: 0.85
        - Name: AWS_DEFAULT_REGION
          Value: !Ref 'AWS::Region'
        - Name: AWS_ASG_AUTOCLUSTER
          Value: 'true'
        # using a random erlang cookie
        - Name: RABBITMQ_ERLANG_COOKIE
          Value: 'ALWEDHDBZTQYWTJGTXWV'
        - Name: RABBITMQ_QUEUE_MASTER_LOCATOR
          Value: min-masters       
        LogConfiguration:
          LogDriver: awslogs
          Options:
            awslogs-group: !Ref 'RabbitAutoClusterLogGroup'
            awslogs-region: !Ref 'AWS::Region'
            awslogs-stream-prefix: logs
        ReadonlyRootFilesystem: 'false'
        Privileged: 'true'
        Ulimits:
        - Name: nofile
          SoftLimit: 10240
          HardLimit: 32768
  Service:
    Type: AWS::ECS::Service
    Properties:
      ServiceToken: !Ref 'ServiceDefinitionServiceToken'
      ServiceName: !Ref 'AWS::StackName'
      Cluster: !Ref 'Cluster'
      DesiredCount: 3
      DeploymentConfiguration:
        MaximumPercent: 100
        MinimumHealthyPercent: 66
      TaskDefinition: !Ref 'TaskDefinition'
      PlacementConstraints:
      - Type: distinctInstance
      PlacementStrategy:
      - type: spread
        field: attribute:ecs.availability-zone
```
