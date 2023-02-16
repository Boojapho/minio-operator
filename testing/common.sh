#!/usr/bin/env bash
# Copyright (C) 2022, MinIO, Inc.
#
# This code is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License, version 3,
# as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License, version 3,
# along with this program.  If not, see <http://www.gnu.org/licenses/>

## this enables :dev tag for minio/operator container image.
CI="true"
export CI
ARCH=`{ case "$(uname -m)" in "x86_64") echo -n "amd64";; "aarch64") echo -n "arm64";; *) echo -n "$(uname -m)";; esac; }`
OS=$(uname | awk '{print tolower($0)}')

DEV_TEST=$OPERATOR_DEV_TEST

# Set OPERATOR_DEV_TEST to skip downloading these dependencies
if [[ -z "${DEV_TEST}" ]]; then
  ## Make sure to install things if not present already
  sudo curl -#L "https://dl.k8s.io/release/v1.23.1/bin/$OS/$ARCH/kubectl" -o /usr/local/bin/kubectl
  sudo chmod +x /usr/local/bin/kubectl

  sudo curl -#L "https://dl.min.io/client/mc/release/${OS}-${ARCH}/mc" -o /usr/local/bin/mc
  sudo chmod +x /usr/local/bin/mc

  ## Install yq
  sudo wget -qO /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_${OS}_${ARCH}
  sudo chmod a+x /usr/local/bin/yq
fi

yell() { echo "$0: $*" >&2; }

die() {
  yell "$*"
  (kind delete cluster || true) && exit 111
}

try() { "$@" || die "cannot $*"; }

function setup_kind() {
  if [ "$TEST_FLOOR" = "true" ]; then
    try kind create cluster --config "${SCRIPT_DIR}/kind-config-floor.yaml"
  else
    try kind create cluster --config "${SCRIPT_DIR}/kind-config.yaml"
  fi
  echo "Kind is ready"
  try kubectl get nodes
}

function install_operator() {

  # To compile current branch
  echo "Compiling Current Branch Operator"
  (cd "${SCRIPT_DIR}/.." && TAG=minio/operator:noop make docker) # will not change your shell's current directory

  echo 'start - load compiled image so we can use it later on'
  kind load docker-image minio/operator:noop
  echo 'end - load compiled image so we can use it later on'

  if [ "$1" = "helm" ]; then

    echo "Change the version accordingly for image to be found within the cluster"
    yq -i '.operator.image.tag = "noop"' "${SCRIPT_DIR}/../helm/operator/values.yaml"

    echo "Installing Current Operator via HELM"
    helm install \
      --namespace minio-operator \
      --create-namespace \
      minio-operator ./helm/operator

    echo "key, value for pod selector in helm test"
    key=app.kubernetes.io/name
    value=operator
  else
    echo "Installing Current Operator"
    # Created an overlay to use that image version from dev folder
    try kubectl apply -k "${SCRIPT_DIR}/../testing/dev"

    echo "key, value for pod selector in kustomize test"
    key=name
    value=minio-operator
  fi

  echo "Scaling down MinIO Operator Deployment"
  try kubectl -n minio-operator scale deployment minio-operator --replicas=1

  # Reusing the wait for both, Kustomize and Helm
  echo "Waiting for k8s api"
  sleep 10

  kubectl get ns

  kubectl -n minio-operator get deployments
  kubectl -n minio-operator get pods

  echo "Waiting for Operator Pods to come online (2m timeout)"
  try kubectl wait --namespace minio-operator \
    --for=condition=ready pod \
    --selector $key=$value \
    --timeout=120s

  echo "start - get data to verify proper image is being used"
  kubectl get pods --namespace minio-operator
  kubectl describe pods -n minio-operator | grep Image
  echo "end - get data to verify proper image is being used"
}

function install_operator_version() {
  # Obtain release
  version="$1"
  if [ -z "$version" ]; then
    version=$(curl https://api.github.com/repos/minio/operator/releases/latest | jq --raw-output '.tag_name | "\(.[1:])"')
  fi
  echo "Target operator release: $version"
  # Set OPERATOR_DEV_TEST to skip downloading these dependencies
  if [[ -z "${DEV_TEST}" ]]; then
    sudo curl -#L "https://github.com/minio/operator/releases/download/v${version}/kubectl-minio_${version}_${OS}_${ARCH}" -o /usr/local/bin/kubectl-minio
    sudo chmod +x /usr/local/bin/kubectl-minio
  fi

  # Initialize the MinIO Kubernetes Operator
  kubectl minio init

  echo "Scaling down MinIO Operator Deployment"
  try kubectl -n minio-operator scale deployment minio-operator --replicas=1

  # Verify installation of the plugin
  echo "Installed operator release: $(kubectl minio version)"

  if [ "$1" = "helm" ]; then
    echo "key, value for pod selector in helm test"
    key=app.kubernetes.io/name
    value=operator
  else
    echo "key, value for pod selector in kustomize test"
    key=name
    value=minio-operator
  fi

  # Reusing the wait for both, Kustomize and Helm
  echo "Waiting for k8s api"
  sleep 10

  kubectl get ns

  kubectl -n minio-operator get deployments
  kubectl -n minio-operator get pods

  echo "Waiting for Operator Pods to come online (2m timeout)"
  try kubectl wait --namespace minio-operator \
    --for=condition=ready pod \
    --selector $key=$value \
    --timeout=120s

  echo "start - get data to verify proper image is being used"
  kubectl get pods --namespace minio-operator
  kubectl describe pods -n minio-operator | grep Image
  echo "end - get data to verify proper image is being used"
}

function destroy_kind() {
  # To allow the execution without killing the cluster at the end of the test
  # Use below statement to automatically test and kill cluster at the end:
  # `unset OPERATOR_DEV_TEST`
  # Use below statement to test and keep cluster alive at the end!:
  # `export OPERATOR_DEV_TEST="ON"`
  if [[ -z "${DEV_TEST}" ]]; then
    echo "Cluster not destroyed due to manual testing"
  else
    kind delete cluster
  fi
}

function wait_for_resource() {
  waitdone=0
  totalwait=0
  echo "command to wait on:"
  command_to_wait="kubectl -n $1 get pods -l $3=$2 --no-headers"
  echo $command_to_wait

  while true; do
    waitdone=$($command_to_wait | wc -l)
    if [ "$waitdone" -ne 0 ]; then
      echo "Found $waitdone pods"
      break
    fi
    sleep 5
    totalwait=$((totalwait + 5))
    if [ "$totalwait" -gt 305 ]; then
      echo "Unable to get resource after 5 minutes, exiting."
      try false
    fi
  done
}

function check_tenant_status() {
  # Check MinIO is accessible
  key=v1.min.io/tenant
  if [ $# -ge 3 ]; then
    echo "Third argument provided, then set key value"
    key=$3
  else
    echo "No third argument provided, using default key"
  fi

  wait_for_resource $1 $2 $key

  echo "Waiting for pods to be ready. (5m timeout)"

  if [ $# -ge 4 ]; then
    echo "Fourth argument provided, then get secrets from helm"
    USER=$(kubectl get secret minio1-secret -o jsonpath="{.data.accesskey}" | base64 --decode)
    PASSWORD=$(kubectl get secret minio1-secret -o jsonpath="{.data.secretkey}" | base64 --decode)
  else
    echo "No fourth argument provided, using default USER and PASSWORD"
    TENANT_CONFIG_SECRET=$(kubectl -n $1 get tenants.minio.min.io $2 -o jsonpath="{.spec.configuration.name}")
    USER=$(kubectl -n $1 get secrets "$TENANT_CONFIG_SECRET" -o go-template='{{index .data "config.env"|base64decode }}' | grep 'export MINIO_ROOT_USER="' | sed -e 's/export MINIO_ROOT_USER="//g' | sed -e 's/"//g')
    PASSWORD=$(kubectl -n $1 get secrets "$TENANT_CONFIG_SECRET" -o go-template='{{index .data "config.env"|base64decode }}' | grep 'export MINIO_ROOT_PASSWORD="' | sed -e 's/export MINIO_ROOT_PASSWORD="//g' | sed -e 's/"//g')
  fi

  try kubectl wait --namespace $1 \
    --for=condition=ready pod \
    --selector=$key=$2 \
    --timeout=300s

  if [ $# -ge 4 ]; then
    # make sure no rollout is happening
    try kubectl -n $1 rollout status sts/minio1-pool-0
  else
    # make sure no rollout is happening
    try kubectl -n $1 rollout status sts/$2-pool-0
  fi

  echo "Tenant is created successfully, proceeding to validate 'mc admin info minio/'"

  try kubectl get pods --namespace $1

  if [ "$4" = "helm" ]; then
    # File: operator/helm/tenant/values.yaml
    # Content: s3.bucketDNS: false
    echo "In helm values by default bucketDNS.s3 is disabled, skipping mc validation on helm test"
  else
    kubectl run admin-mc -i --tty --image quay.io/minio/mc \
      --env="MC_HOST_minio=https://${USER}:${PASSWORD}@minio.${1}.svc.cluster.local" \
      --command -- bash -c "until (mc admin info minio/); do echo 'waiting... for 5secs' && sleep 5; done"
  fi

  echo "Done."
}

# Install tenant function is being used by deploy-tenant and check-prometheus
function install_tenant() {
  # Check if we are going to install helm, lastest in this branch or a particular version
  if [ "$1" = "helm" ]; then
    echo "Installing tenant from Helm"
    echo "This test is intended for helm only not for KES, there is another kes test, so let's remove KES here"
    yq -i eval 'del(.tenant.kes)' "${SCRIPT_DIR}/../helm/tenant/values.yaml"

    try helm lint "${SCRIPT_DIR}/../helm/tenant" --quiet

    namespace=default
    key=app
    value=minio
    try helm install --namespace $namespace \
      --create-namespace tenant ./helm/tenant
  elif [ "$1" = "logs" ]; then
    namespace="tenant-lite"
    key=v1.min.io/tenant
    value=storage-lite
    echo "Installing lite tenant from current branch"

    try kubectl apply -k "${SCRIPT_DIR}/../testing/tenant-logs"
  elif [ "$1" = "prometheus" ]; then
    namespace="tenant-lite"
    key=v1.min.io/tenant
    value=storage-lite
    echo "Installing lite tenant from current branch"

    try kubectl apply -k "${SCRIPT_DIR}/../testing/tenant-prometheus"
  elif [ -e $1 ]; then
    namespace="tenant-lite"
    key=v1.min.io/tenant
    value=storage-lite
    echo "Installing lite tenant from current branch"

    try kubectl apply -k "${SCRIPT_DIR}/../testing/tenant"
  else
    namespace="tenant-lite"
    key=v1.min.io/tenant
    value=storage-lite
    echo "Installing lite tenant for version $1"

    try kubectl apply -k "github.com/minio/operator/testing/tenant\?ref\=$1"
  fi

  echo "Waiting for the tenant statefulset, this indicates the tenant is being fulfilled"
  echo $namespace
  echo $value
  echo $key
  wait_for_resource $namespace $value $key

  echo "Waiting for tenant pods to come online (5m timeout)"
  try kubectl wait --namespace $namespace \
    --for=condition=ready pod \
    --selector $key=$value \
    --timeout=300s

  echo "Build passes basic tenant creation"

}

# Port forward
function port_forward() {
  namespace=$1
  tenant=$2
  svc=$3
  localport=$4

  totalwait=0
  echo 'Validating tenant pods are ready to serve'
  for pod in `kubectl --namespace $namespace --selector=v1.min.io/tenant=$tenant get pod -o json |  jq '.items[] | select(.metadata.name|contains("'$tenant'"))| .metadata.name' | sed 's/"//g'`; do
    while true; do
      if kubectl --namespace $namespace -c minio logs pod/$pod | grep --quiet 'All MinIO sub-systems initialized successfully'; then
        echo "$pod is ready to serve" && break
      fi
      sleep 5
      totalwait=$((totalwait + 5))
      if [ "$totalwait" -gt 305 ]; then
        echo "Unable to validate pod $pod after 5 minutes, exiting."
        try false
      fi
    done
  done

  echo "Killing any current port-forward"
  for pid in $(lsof -i :$localport | awk '{print $2}' | uniq | grep -o '[0-9]*')
  do
    if [ -n "$pid" ]
    then
      kill -9 $pid
      echo "Killed previous port-forward process using port $localport: $pid"
    fi
  done

  echo "Establishing port-forward"
  kubectl port-forward service/$svc -n $namespace $localport &

  echo 'start - wait for port-forward to be completed'
  sleep 15
  echo 'end - wait for port-forward to be completed'
}
