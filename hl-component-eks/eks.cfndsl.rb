CloudFormation do

  Description "#{component_name} - #{component_version}"

  az_conditions_resources('SubnetCompute', maximum_availability_zones)

  Condition('IsScalingEnabled', FnEquals(Ref('EnableScaling'), 'true'))
  Condition("SpotPriceSet", FnNot(FnEquals(Ref('SpotPrice'), '')))

  asg_eks_tags = []
  asg_eks_tags << { Key: 'Name', Value: FnJoin('-', [ Ref(:EnvironmentName), component_name, 'xx' ]), PropagateAtLaunch: true }
  asg_eks_tags << { Key: 'Environment', Value: Ref(:EnvironmentName), PropagateAtLaunch: true}
  asg_eks_tags << { Key: 'EnvironmentType', Value: Ref(:EnvironmentType), PropagateAtLaunch: true }
  asg_eks_tags << { Key: 'Role', Value: "eks", PropagateAtLaunch: true }

  asg_eks_extra_tags = []
  eks_extra_tags.each { |key,value| asg_eks_extra_tags << { Key: "#{key}", Value: value, PropagateAtLaunch: true } } if defined? eks_extra_tags


  asg_eks_tags = (asg_eks_extra_tags + asg_eks_tags).uniq { |h| h[:Key] }


  EKS_Cluster('EksCluster') {
    ClusterName FnSub("${EnvironmentName}-#{cluster_name}") if defined? cluster_name
  }

  EC2_SecurityGroup('SecurityGroupEks') do
    GroupDescription FnJoin(' ', [ Ref('EnvironmentName'), component_name ])
    VpcId Ref('VPCId')
  end

  EC2_SecurityGroupIngress('LoadBalancerIngressRule') do
    Description 'Ephemeral port range for EKS'
    IpProtocol 'tcp'
    FromPort '32768'
    ToPort '65535'
    GroupId FnGetAtt('SecurityGroupEks','GroupId')
    SourceSecurityGroupId Ref('SecurityGroupLoadBalancer')
  end

  EC2_SecurityGroupIngress('BastionIngressRule') do
    Description 'SSH access from bastion'
    IpProtocol 'tcp'
    FromPort '22'
    ToPort '22'
    GroupId FnGetAtt('SecurityGroupEks','GroupId')
    SourceSecurityGroupId Ref('SecurityGroupBastion')
  end

  policies = []
  iam_policies.each do |name,policy|
    policies << iam_policy_allow(name,policy['action'],policy['resource'] || '*')
  end if defined? iam_policies

  Role('Role') do
    AssumeRolePolicyDocument service_role_assume_policy('ec2')
    Path '/'
    Policies(policies)
  end

  InstanceProfile('InstanceProfile') do
    Path '/'
    Roles [Ref('Role')]
  end

  user_data = []
  user_data << "#!/bin/bash\n"
  user_data << "INSTANCE_ID=$(/opt/aws/bin/ec2-metadata --instance-id|/usr/bin/awk '{print $2}')\n"
  user_data << "hostname "
  user_data << Ref("EnvironmentName")
  user_data << "-eks-${INSTANCE_ID}\n"
  user_data << "sed '/HOSTNAME/d' /etc/sysconfig/network > /tmp/network && mv -f /tmp/network /etc/sysconfig/network && echo \"HOSTNAME="
  user_data << Ref('EnvironmentName')
  user_data << "-eks-${INSTANCE_ID}\" >>/etc/sysconfig/network && /etc/init.d/network restart\n"
  user_data << "echo EKS_CLUSTER="
  user_data << Ref("EksCluster")
  user_data << " >> /etc/eks/eks.config\n"
  if enable_efs
    user_data << "mkdir /efs\n"
    user_data << "yum install -y nfs-utils\n"
    user_data << "mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 "
    user_data << Ref("FileSystem")
    user_data << ".efs."
    user_data << Ref("AWS::Region")
    user_data << ".amazonaws.com:/ /efs\n"
  end

  eks_agent_extra_config.each do |key, value|
    user_data << "echo #{key}=#{value}"
    user_data << " >> /etc/eks/eks.config\n"
  end if defined? eks_agent_extra_config

  eks_additional_userdata.each do |user_data_line|
    user_data << "#{user_data_line}\n"
  end if defined? eks_additional_userdata

  volumes = []
  volumes << {
    DeviceName: '/dev/xvda',
    Ebs: {
      VolumeSize: volume_size
    }
  } if defined? volume_size

  LaunchConfiguration('LaunchConfig') do
    ImageId Ref('Ami')
    BlockDeviceMappings volumes if defined? volume_size
    InstanceType Ref('InstanceType')
    AssociatePublicIpAddress false
    IamInstanceProfile Ref('InstanceProfile')
    KeyName Ref('KeyName')
    SecurityGroups [ Ref('SecurityGroupEks') ]
    SpotPrice FnIf('SpotPriceSet', Ref('SpotPrice'), Ref('AWS::NoValue'))
    UserData FnBase64(FnJoin('',user_data))
  end


  AutoScalingGroup('AutoScaleGroup') do
    UpdatePolicy(asg_update_policy.keys[0], asg_update_policy.values[0]) if defined? asg_update_policy
    LaunchConfigurationName Ref('LaunchConfig')
    HealthCheckGracePeriod '500'
    MinSize Ref('AsgMin')
    MaxSize Ref('AsgMax')
    VPCZoneIdentifier az_conditional_resources('SubnetCompute', maximum_availability_zones)
    Tags asg_eks_tags
  end

  Logs_LogGroup('LogGroup') {
    LogGroupName Ref('AWS::StackName')
    RetentionInDays "#{log_group_retention}"
  }

  if defined?(eks_autoscale)

    if eks_autoscale.has_key?('memory_high')

      Resource("MemoryReservationAlarmHigh") {
        Condition 'IsScalingEnabled'
        Type 'AWS::CloudWatch::Alarm'
        Property('AlarmDescription', "Scale-up if MemoryReservation > #{eks_autoscale['memory_high']}% for 2 minutes")
        Property('MetricName','MemoryReservation')
        Property('Namespace','AWS/EKS')
        Property('Statistic', 'Maximum')
        Property('Period', '60')
        Property('EvaluationPeriods', '2')
        Property('Threshold', eks_autoscale['memory_high'])
        Property('AlarmActions', [ Ref('ScaleUpPolicy') ])
        Property('Dimensions', [
          {
            'Name' => 'ClusterName',
            'Value' => Ref('EksCluster')
          }
        ])
        Property('ComparisonOperator', 'GreaterThanThreshold')
      }

      Resource("MemoryReservationAlarmLow") {
        Condition 'IsScalingEnabled'
        Type 'AWS::CloudWatch::Alarm'
        Property('AlarmDescription', "Scale-down if MemoryReservation < #{eks_autoscale['memory_low']}%")
        Property('MetricName','MemoryReservation')
        Property('Namespace','AWS/EKS')
        Property('Statistic', 'Maximum')
        Property('Period', '60')
        Property('EvaluationPeriods', '2')
        Property('Threshold', eks_autoscale['memory_low'])
        Property('AlarmActions', [ Ref('ScaleDownPolicy') ])
        Property('Dimensions', [
          {
            'Name' => 'ClusterName',
            'Value' => Ref('EksCluster')
          }
        ])
        Property('ComparisonOperator', 'LessThanThreshold')
      }
    
    end

    if eks_autoscale.has_key?('cpu_high')

      Resource("CPUReservationAlarmHigh") {
        Condition 'IsScalingEnabled'
        Type 'AWS::CloudWatch::Alarm'
        Property('AlarmDescription', "Scale-up if CPUReservation > #{eks_autoscale['cpu_high']}%")
        Property('MetricName','CPUReservation')
        Property('Namespace','AWS/EKS')
        Property('Statistic', 'Maximum')
        Property('Period', '60')
        Property('EvaluationPeriods', '2')
        Property('Threshold', eks_autoscale['cpu_high'])
        Property('AlarmActions', [ Ref('ScaleUpPolicy') ])
        Property('Dimensions', [
          {
            'Name' => 'ClusterName',
            'Value' => Ref('EksCluster')
          }
        ])
        Property('ComparisonOperator', 'GreaterThanThreshold')
      }
    
      Resource("CPUReservationAlarmLow") {
        Condition 'IsScalingEnabled'
        Type 'AWS::CloudWatch::Alarm'
        Property('AlarmDescription', "Scale-up if CPUReservation < #{eks_autoscale['cpu_low']}%")
        Property('MetricName','CPUReservation')
        Property('Namespace','AWS/EKS')
        Property('Statistic', 'Maximum')
        Property('Period', '60')
        Property('EvaluationPeriods', '2')
        Property('Threshold', eks_autoscale['cpu_low'])
        Property('AlarmActions', [ Ref('ScaleDownPolicy') ])
        Property('Dimensions', [
          {
            'Name' => 'ClusterName',
            'Value' => Ref('EksCluster')
          }
        ])
        Property('ComparisonOperator', 'LessThanThreshold')
      }
    
    end

    Resource("ScaleUpPolicy") {
      Condition 'IsScalingEnabled'
      Type 'AWS::AutoScaling::ScalingPolicy'
      Property('AdjustmentType', 'ChangeInCapacity')
      Property('AutoScalingGroupName', Ref('AutoScaleGroup'))
      Property('Cooldown','300')
      Property('ScalingAdjustment', eks_autoscale['scale_up_adjustment'])
    }

    Resource("ScaleDownPolicy") {
      Condition 'IsScalingEnabled'
      Type 'AWS::AutoScaling::ScalingPolicy'
      Property('AdjustmentType', 'ChangeInCapacity')
      Property('AutoScalingGroupName', Ref('AutoScaleGroup'))
      Property('Cooldown','300')
      Property('ScalingAdjustment', eks_autoscale['scale_down_adjustment'])
    }
  end

  Output("EksCluster") {
    Value(Ref('EksCluster'))
    Export FnSub("${EnvironmentName}-#{component_name}-EksCluster")
  }
  Output("EksClusterArn") {
    Value(FnGetAtt('EksCluster','Arn'))
    Export FnSub("${EnvironmentName}-#{component_name}-EksClusterArn")
  }
  Output('EksSecurityGroup') {
    Value(Ref('SecurityGroupEks'))
    Export FnSub("${EnvironmentName}-#{component_name}-EksSecurityGroup")
  }

end
