Rabbitmq Auto Clustering in Amazon EC2 Container Service
========================================================

Automation of Rabbitmq clustering in Amazon EC2 Container Service based on AWS Auto Scaling group membership.

**Requirements:**

- the rabbitmq cluster is deployed within a single AWS Auto Scaling group
- only run one rabbitmq container per ECS instance and deploy odd numbers of rabbitmq instance i.e. 3, 5, 7, etc
- use the 'host' docker networking mode when running the containers to cause them to inherit the private short dns names of the ECS instances as their hostnames this way rabbitmq
uses these DNS names for node discovery during the clustering process
- the ECS instances must be assigned the following IAM policies:
"autoscaling:DescribeAutoScalingInstances",
"autoscaling:DescribeAutoScalingGroups",
"ec2:DescribeInstances"
- set environment variable AWS_ASG_AUTOCLUSTER="true" when starting the container


Deployment
----------
Below are some main steps for building and deploying these auto clustering rabbitmq containers in ECS; adjust as you see fit.

* Build and push the container to the registry (ECR).

```
    aws ecr get-login --region us-east-1
    cd <path-to>/rabbitmq-ecs-autoclustering/docker-image
    docker build -t arnaud/rabbitmq-asg-autocluster .
    docker tag arnaud/rabbitmq-asg-autocluster:latest 761145510729.dkr.ecr.us-east-1.amazonaws.com/arnaud/rabbitmq-asg-autocluster:latest

```

Here is a sample AWS TaskDefinition for running these 


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
        Image: !Ref 'AppImageTag'
        MountPoints:
        - SourceVolume: rabbitmq-database
          ContainerPath: /var/lib/rabbitmq
        Cpu: '512'
        Memory: !Ref 'RabbitHardMemoryLimit'
        MemoryReservation: !Ref 'RabbitSoftMemoryLimit'
        PortMappings:
        - HostPort: !Ref 'ContainerPort1'
          ContainerPort: !Ref 'ContainerPort1'
          Protocol: tcp
        - HostPort: !Ref 'ContainerPort2'
          ContainerPort: !Ref 'ContainerPort2'
          Protocol: tcp
        - HostPort: !Ref 'ContainerPort3'
          ContainerPort: !Ref 'ContainerPort3'
          Protocol: tcp
        - HostPort: !Ref 'ContainerPort4'
          ContainerPort: !Ref 'ContainerPort4'
          Protocol: tcp
        Environment:
        - Name: RABBITMQ_DEFAULT_VHOST
          Value: !Ref 'QueueVHost'
        - Name: RABBITMQ_DEFAULT_USER
          Value: !Ref 'QueueUser'
        - Name: RABBITMQ_DEFAULT_PASS
          Value: !Ref 'QueuePass'
        - Name: RABBITMQ_DEFAULT_PORT
          Value: !Ref 'ContainerPort1'
        - Name: RABBITMQ_VM_MEMORY_HIGH_WATERMARK
          Value: !Ref 'HighMemoryWaterMark'
        - Name: MEMORY
          Value: !Ref 'RabbitHardMemoryLimit'
        - Name: MEMORY_RESERVATION
          Value: !Ref 'RabbitSoftMemoryLimit'
        - Name: STAGE
          Value: !Ref 'Stage'
        - Name: COMPONENT
          Value: !Ref 'Component'
        - Name: AWS_DEFAULT_REGION
          Value: !Ref 'AWS::Region'
        - Name: AWS_ASG_AUTOCLUSTER
          Value: 'true'
        - Name: RABBITMQ_ERLANG_COOKIE
          Value: 'ALWEDHDBZTQYWTJGTXWV'
        - Name: RABBITMQ_QUEUE_MASTER_LOCATOR
          Value: !Ref 'RabbitQueueMasterLocator'
        - Name: AWS_DEFAULT_REGION
          Value: 'us-east-1'        
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
    Type: Custom::Service
    Properties:
      ServiceToken: !Ref 'ServiceDefinitionServiceToken'
      ServiceName: !Ref 'AWS::StackName'
      Cluster: !Ref 'Cluster'
      DesiredCount: !Ref 'DesiredCount'
      DeploymentConfiguration:
        MaximumPercent: 100
        MinimumHealthyPercent: 66
      TaskDefinition: !Ref 'TaskDefinition'
      PlacementConstraints:
      - Type: distinctInstance
      PlacementStrategy:
      - type: spread
        field: attribute:ecs.availability-zone

    



  sets:
    rabbit-autocluster:
      service:
        cf_template: cf/rabbitmq-autocluster/service.cfn.yaml
        secrets:
          QueuePass: rabbit.default.pass
        params:
          ContainerPort1    : 5672
          ContainerPort2    : 15672
          ContainerPort3    : 4369
          ContainerPort4    : 25672
          RabbitHardMemoryLimit: 3600
          RabbitSoftMemoryLimit: 500
          RabbitErlangCookie: ALWEDHDBZTQYWTJGTXWV
          RabbitQueueMasterLocator: min-masters
          #AppImageTag : {{ECR_ROOT}}/gavinmroy/alpine-rabbitmq-autocluster
          AppImageTag : 761145510729.dkr.ecr.us-east-1.amazonaws.com/arnaud/rabbitmq-asg-autocluster
          QueueVHost : /hbase
          HighMemoryWaterMark : 0.8
          QueueUser  : meetup
          DesiredCount      : 3