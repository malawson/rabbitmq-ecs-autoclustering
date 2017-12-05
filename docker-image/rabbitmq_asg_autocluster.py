#!/usr/bin/python 

"""
Automation of Rabbitmq clustering in Amazon EC2 Container Service based on AWS Auto Scaling group membership.
Requirements:
    - the rabbitmq cluster is deployed within a single AWS Auto Scaling group
    - use the 'host' docker networking mode to cause the containers to inherit the
    private short dns names of the ECS instances as their hostnames this way rabbitmq
    uses these DNS names for node discovery during the clustering process
    - the ECS instances must be assigned the following IAM policies:
    "autoscaling:DescribeAutoScalingInstances",
    "autoscaling:DescribeAutoScalingGroups",
    "ec2:DescribeInstances"
    - set environment variable AWS_ASG_AUTOCLUSTER="true" when starting the container
"""

from subprocess import Popen, PIPE
from time import sleep
import re
try:
    import boto3
except ImportError:
    import pip
    pip.main(['install', 'boto3'])
    import boto3

# initialize boto client and ec2 resource
client_asg = boto3.client('autoscaling', region_name='us-east-1')
ec2 = boto3.resource('ec2', region_name='us-east-1')

def run(cmd):
    """
    executes shell commands and returns stdout & stderr
    """

    print "Executing: ", cmd
    p = Popen(cmd, shell=True, stdout=PIPE, stderr=PIPE, close_fds=True)
    stdout, stderr = p.communicate()
    if p.returncode != 0:
        print "Error while running: ", cmd, "\n", stderr, "\n"
        print "Exit code: ", p.returncode

    return stdout, stderr


def get_instance_id():
    """
    returns ECS instance id
    """
    cmd = "curl http://169.254.169.254/latest/meta-data/instance-id"
    instance_id, stderr = run(cmd)

    return str(instance_id)


def get_asg_name():
    """
    returns ASG name, type string
    """
    response = client_asg.describe_auto_scaling_instances(
        InstanceIds=[
            get_instance_id(),
        ]
    )
    asg_instance = response['AutoScalingInstances'][0]

    return asg_instance['AutoScalingGroupName'] 


def get_asg_instance_ids():
    """
    returns a list object of InstanceIds corresponding to the healthy ASG nodes
    """
    response = client_asg.describe_auto_scaling_groups(
        AutoScalingGroupNames=[
            get_asg_name(),
        ]
    )
    asg = response['AutoScalingGroups'][0]
    asg_instances = asg['Instances']
    asg_instance_ids = []

    for instance in asg_instances:
        # cluster only instances that are in-service & healthy
        if instance['LifecycleState'] == 'InService' and instance['HealthStatus'] == 'Healthy':
            asg_instance_ids.append(instance['InstanceId'])
        else:
            print "Instance ", instance, " cannot be clustered\n"
            print "LifecycleState: ", instance['LifecycleState'], "\n", "HealthStatus: ", instance['HealthStatus']

    return asg_instance_ids


def get_asg_instance_private_dnsnames():
    """
    returns a list object of the private dns names of the ASG's healthy nodes
    i.e. ['ip-10-200-22-148', 'ip-10-200-13-105', 'ip-10-200-2-39']
    """

    private_short_dnsnames = []
    for instance_id in get_asg_instance_ids():
        instance = ec2.Instance(instance_id)
        private_short_dnsnames.append(re.sub('.ec2.internal', '', instance.private_dns_name))

    return private_short_dnsnames


def get_node_list():
    """
    returns a list object of rabbitmq nodes in the ASG that are in-service & healthy, which should
    join the cluster i.e. ['rabbit@ip-10-200-22-148', 'rabbit@ip-10-200-13-105', 'rabbit@ip-10-200-2-39']
    """

    node_list = []
    for hostname in get_asg_instance_private_dnsnames():
        # build node list based on rabbitmqctl cluster_status format
        node_list.append('rabbit@' + hostname)

    return node_list


def process_cluster_status_output(output):
    """
    returns a list object representing the output of the cluster_status command
    """
    output = output.replace(' ', '')
    output = output.replace('\n', '')
    status = output.split('},')

    return status


def cluster_status():
    """
    checks the rabbitmq cluster status and returns a dictionary containing key-value pairs for
    disc_nodes, running_nodes & cluster_name
    """

    cluster_info = dict()
    pattern = re.compile(r'[\'|\"]rabbit@.*[\'|\"]')
    cmd = "rabbitmqctl cluster_status |tail -n +2"
    status, stderr = run(cmd)
    processed_status = process_cluster_status_output(status)

    for line in processed_status:
        match = pattern.search(line)

        if "disc" in line and match:
            cluster_info['disc_nodes'] = match.group().replace("'", "").split(',')

        elif "running_nodes" in line and match:
            cluster_info['running_nodes'] = match.group().replace("'", "").split(',')

        elif "cluster_name" in line and match:
            cluster_info['cluster_name'] = match.group().replace('"', "").split(',')

    return cluster_info

def cluster_formed():
    """
    boolean function that returns True if the cluster is already formed by all healthy
    nodes in the ASG and if the cluster is in the following state:
    asg_node_list_content == running_nodes_content == disc_nodes_content
    asg_cluster_size == running_nodes_size and disc_nodes_size >= asg_cluster_size:
    False otherwise
    """
    # assume cluster hasn't been formed yet
    val = False
    # get cluster status
    clusterstatus = cluster_status()

    # ensure those dict keys exist, meaning clusterring has started
    if 'running_nodes' in clusterstatus and 'cluster_name' in clusterstatus:
        asg_node_list = get_node_list()
        asg_cluster_size = len(asg_node_list)
        running_nodes_size = len(clusterstatus['running_nodes'])
        disc_nodes_size = len(clusterstatus['disc_nodes'])

        # let's hit all conditions for val to be true
        for node in asg_node_list:
            if node in clusterstatus['disc_nodes'] and node in clusterstatus['running_nodes']:
                if asg_cluster_size == running_nodes_size and disc_nodes_size >= asg_cluster_size:
                    # cluster formed
                    val = True

    # cluster hasn't been formed/started yet
    else:
        val = False

    print "Cluster Formed? {}".format(val)
    return val

def join_cluster():
    """
    normal rabbitmq clustering process
    """

    hostname, stderr = run("hostname")
    my_nodename = "rabbit@" + hostname
    node_list = get_node_list()

    for node in node_list:
        # strip string elements of any leading/trailing chars for comparison - it breaks otherwise
        if node.strip() != my_nodename.strip():
            # find a remote node with which to cluster in the ASG
            remote_node = node
            print "Found a remote node: ", remote_node
            break

    run("rabbitmqctl stop_app")
    run("rabbitmqctl join_cluster {}".format(remote_node))
    run("rabbitmqctl start_app")


def cleanup():
    """
    this is useful for removing nodes from the cluster when they go away
    i.e. an instance fails and a new one comes in service
    """

    nodes_to_remove = []
    clusterstatus = cluster_status()
    asg_node_list = get_node_list()

    # dead node removal only happens after the cluster is formed
    if cluster_formed():
        for node in clusterstatus['disc_nodes']:
            if node not in clusterstatus['running_nodes'] and node not in asg_node_list:
                nodes_to_remove.append(node)

    if len(nodes_to_remove) > 0:
        for node in nodes_to_remove:
            print "removing node {} from cluster".format(node)
            run("rabbitmqctl forget_cluster_node {}".format(node))

def main():
    """
    main method
    """

    while not cluster_formed():
        join_cluster()

    # to be safe, do cleanup only after the cluster has been formed
    cleanup()

    # reference: https://www.rabbitmq.com/ha.html
    # i.e. declaring policy "ha-all" that matches all queue names & configures mirroring to all nodes
    # using ${VHOST} environment variable
    # run('rabbitmqctl set_policy ha-all ".*" \'{"ha-mode":"all"}\' -p ${VHOST}')

if __name__ == "__main__":

    # delay start for the rabbit app to start
    sleep(20)
    main()
