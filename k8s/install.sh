#!/bin/bash

set -o errexit
set -o pipefail

set -e

err_report() {
    echo "Error on line $1"
}

trap 'err_report $LINENO' ERR

START_TIME=`date +%s`

echo "Creating cluster for Testground..."
echo

CLUSTER_SPEC_TEMPLATE=$1

echo "Name: $NAME"
echo "Public key: $PUBKEY"
echo "Worker nodes: $WORKER_NODES"
echo

# Set default options (can be over-ridden by setting environment vars)
if [ -z "$ULIMIT_NOFILE" ]
then
	export ULIMIT_NOFILE="1048576:1048576"
fi

export TEAM=${TEAM:=default-team}
export PROJECT=${PROJECT:=default-project}
CLUSTER_SPEC=$(mktemp)
envsubst <$CLUSTER_SPEC_TEMPLATE >$CLUSTER_SPEC
cat $CLUSTER_SPEC

# Verify with the user before continuing.
echo
echo "The output above is the cluster I will create for you."
echo -n "Does this look about right to you? [y/n]: "
read response

if [ "$response" != "y" ]
then
  echo "Canceling ."
  exit 2
fi

# The remainder of this script creates the cluster using the generated template

kops create -f $CLUSTER_SPEC
kops create secret --name $NAME sshpublickey admin -i $PUBKEY
kops update cluster $NAME --yes

# Wait for worker nodes and master to be ready
kops validate cluster --wait 20m

echo "Cluster nodes are Ready"
echo

echo "Install default container limits"
echo

kubectl apply -f ./limit-range/limit-range.yaml


echo "Install EFS..."

vpcId=`aws ec2 describe-vpcs --region=$AWS_REGION --filters Name=tag:Name,Values=$NAME --output text | awk '/VPCS/ { print $8 }'`

if [[ -z ${vpcId} ]]; then
  echo "Couldn't detect AWS VPC created by `kops`"
  exit 1
fi

echo "Detected VPC: $vpcId"

securityGroupId=`aws ec2 describe-security-groups --region=$AWS_REGION --output text | awk '/nodes.'$NAME'/ && /SECURITYGROUPS/ { print $6 };'`

if [[ -z ${securityGroupId} ]]; then
  echo "Couldn't detect AWS Security Group created by `kops`"
  exit 1
fi

echo "Detected Security Group ID: $securityGroupId"

subnetIdZoneA=`aws ec2 describe-subnets --region=$AWS_REGION --output text | awk '/'$vpcId'/ { print $12 }' | sort | head -1`
subnetIdZoneB=`aws ec2 describe-subnets --region=$AWS_REGION --output text | awk '/'$vpcId'/ { print $12 }' | sort | tail -1`

echo "Detected Subnet: $subnetIdZoneA"
echo "Detected Subnet: $subnetIdZoneB"

pushd efs-terraform

# extract s3 bucket from kops state store
S3_BUCKET="${KOPS_STATE_STORE:5:100}"

terraform init -backend-config=bucket=$S3_BUCKET \
               -backend-config=key=tf-efs-$NAME \
               -backend-config=region=$AWS_REGION

terraform apply -var aws_region=$AWS_REGION -var fs_subnet_id_zone_a=$subnetIdZoneA -var fs_subnet_id_zone_b=$subnetIdZoneB -var fs_sg_id=$securityGroupId -auto-approve

export EFS_DNSNAME=`terraform output dns_name`

fsId=`terraform output filesystem_id`

popd

echo "Install EFS Kubernetes provisioner..."

kubectl create configmap efs-provisioner \
--from-literal=file.system.id=$fsId \
--from-literal=aws.region=$AWS_REGION \
--from-literal=provisioner.name=testground.io/aws-efs

EFS_MANIFEST_SPEC=$(mktemp)
envsubst <./efs/manifest.yaml.spec >$EFS_MANIFEST_SPEC

kubectl apply -f ./efs/rbac.yaml \
              -f $EFS_MANIFEST_SPEC

echo "Install Weave, CNI-Genie, Sidecar Daemonset..."
echo

kubectl apply -f ./kops-weave/weave.yml \
              -f ./kops-weave/genie-plugin.yaml \
              -f ./kops-weave/dummy.yml \
              -f ./sidecar.yaml

echo "Installing Prometheus"
pushd prometheus-operator
helm install prometheus-operator stable/prometheus-operator -f values.yaml
popd

echo "Installing InfluxDB"
pushd influxdb
helm install influxdb influxdata/influxdb -f ./values.yaml
popd

echo "Installing Redis and Grafana dashboards"
pushd testground-infra
helm dep build
helm install testground-infra .
popd

echo "Install Weave service monitor..."
echo

kubectl apply -f ./kops-weave/weave-metrics-service.yml \
              -f ./kops-weave/weave-service-monitor.yml

echo "Install Testground daemon..."
echo
kubectl apply -f ./testground-daemon/config-map-env-toml.yml
kubectl apply -f ./testground-daemon/service-account.yml
kubectl apply -f ./testground-daemon/role-binding.yml
kubectl apply -f ./testground-daemon/deployment.yml -f ./testground-daemon/service.yml

echo "Wait for Sidecar to be Ready..."
echo
RUNNING_SIDECARS=0
while [ "$RUNNING_SIDECARS" -ne "$WORKER_NODES" ]; do RUNNING_SIDECARS=$(kubectl get pods | grep testground-sidecar | grep Running | wc -l || true); echo "Got $RUNNING_SIDECARS running sidecar pods"; sleep 5; done;

echo "Wait for EFS provisioner to be Running..."
echo
RUNNING_EFS=0
while [ "$RUNNING_EFS" -ne 1 ]; do RUNNING_EFS=$(kubectl get pods | grep efs-provisioner | grep Running | wc -l || true); echo "Got $RUNNING_EFS running efs-provisioner pods"; sleep 5; done;

echo "Testground cluster is ready"
echo

END_TIME=`date +%s`
echo "Execution time was `expr $END_TIME - $START_TIME` seconds"
