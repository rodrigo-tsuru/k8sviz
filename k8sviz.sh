#! /bin/bash

#### Constants ####
NS_IMG=./icons/ns-128.png
SVC_IMG=./icons/svc-128.png
PVC_IMG=./icons/pvc-128.png
POD_IMG=./icons/pod-128.png
STS_IMG=./icons/sts-128.png
DS_IMG=./icons/ds-128.png
RS_IMG=./icons/rs-128.png
DEPLOY_IMG=./icons/deploy-128.png
JOB_IMG=./icons/job-128.png

declare -A IMGS=( ["ns"]="${NS_IMG}" ["svc"]="${SVC_IMG}" ["pvc"]="${PVC_IMG}" ["pod"]="${POD_IMG}" ["sts"]="${STS_IMG}" ["ds"]="${DS_IMG}" ["rs"]="${RS_IMG}" ["deploy"]="${DEPLOY_IMG}" ["job"]="${JOB_IMG}")
declare -A NAMES=( ["ns"]="namespace" ["svc"]="service" ["pvc"]="persistentvolumeclaim" ["pod"]="po" ["sts"]="statefulset" ["ds"]="daemonset" ["rs"]="replicaset" ["deploy"]="deployment" ["job"]="job")
declare -a RESOURCES=("deploy job" "sts ds rs" "pod" "pvc" "svc")

#### Variables ####
NAME=$(basename $0 | tr - ' ')
NAMESPACE="default"
OUTFILE="k8sviz.out"
TYPE="dot"

#### Functions ####
function help () {
  cat << EOF
Generate Kubernetes architecture diagrams from the actual state in a namespace
Usage:
  $NAME [options]
Options:
  -h, --help                 Displays the help text
  -n, --namespace            The namespace to visualize. Default is ${NAMESPACE}
  -o, --outfile              The filename to output. Default is ${OUTFILE}
  -t, --type                 The type of output. Default is ${TYPE}
EOF
}

function escape_name () {
  local name=$1
  # dot file doesn't allow . and - for names, so escaping them with _.
  # TODO: Improve this, for this might cause collision of names.
  echo ${name} | tr '.-' '__'
}

function normalize_kind () {
  local kind=$1
  local lower_kind=$(echo $kind | tr '[:upper:]' '[:lower:]')
 
  for nname in "${!NAMES[@]}";do
    if [ "${lower_kind}" == "${nname}" ];then
      echo ${nname}
      return
    fi

    if [ "${lower_kind}" == "${NAMES[${nname}]}" ];then
      echo ${nname}
      return
    fi
  done

  # TODO: Need to handle an error that no kind was matched.
}

function start_digraph () {
  local name=$1
  local namespace=$2
  cat << EOF
/*
 *  This dot file is generated by using ${NAME} for namespace ${namespace}.
 */
digraph ${name} {
  rankdir=TD;
EOF
}

function end_digraph () {
  cat << EOF
}
EOF
}

function start_namespace () {
  local namespace=$1
  local escaped_namespace=$(escape_name ${namespace})
  cat << EOF
  subgraph cluster_${escaped_namespace} {
    label=<<TABLE BORDER="0"><TR><TD><IMG SRC="${NS_IMG}" /></TD></TR><TR><TD>${namespace}</TD></TR></TABLE>>;
    labeljust="l";
    graph[style=dotted];
EOF
}

function end_namespace () {
  cat << EOF
  }
EOF
}

function start_same_rank () {
  local level=$1
  cat << EOF
    {
      rank=same;
      $level [style=invis, height=0, width=0, margin=0];
EOF
}

function end_same_rank () {
  cat << EOF
    }
EOF
}

function add_resource () {
  local namespace=$1
  local resource=$2
  local img=$3

  cat << EOF
      // ${resource} in namespace ${namespace}.
EOF
  kubectl get ${resource} -n ${namespace} --no-headers=true -o custom-columns=NAME:metadata.name |\
  while read name;do
    escaped_name=$(escape_name ${name})
    cat << EOF
      ${resource}_${escaped_name} [label=<<TABLE BORDER="0"><TR><TD><IMG SRC="${img}" /></TD></TR><TR><TD>${name}</TD></TR></TABLE>>, penwidth=0]
EOF
  done
}

function order_ranks () {
  local min=$1
  local max=$2

  echo "    // dummy edge to order ranks correctly."
  echo -n "    "

  for i in $(seq ${min} ${max});do
    if [ ${i} -eq ${max} ];then
      echo "${i} [style=invis];"
    else
      echo -n "${i} -> "
    fi
  done
}

function connect_pvc_pod () {
  local namespace=$1

  echo "    // Edges between PVC and pod"

  kubectl get pod -n ${namespace} --no-headers -o custom-columns=NAME:.metadata.name,PVC:.spec.volumes | grep persistentVolumeClaim | awk '{print $1}' |\
  while read pod;do
    escaped_pod_name=$(escape_name ${pod})
    kubectl get pod -n ${namespace} $pod --no-headers -o custom-columns=PVC:.spec.volumes | tr ' ' '\n' | awk -F ':' '/persistentVolumeClaim:map\[claimName/{print $3}' | tr -d ']' |\
    while read pvc;do 
      escaped_pvc_name=$(escape_name ${pvc})
      echo "    pod_${escaped_pod_name} -> pvc_${escaped_pvc_name} [dir=none];"
    done
  done
}

function connect_svc_pod () {
  local namespace=$1

  echo "    // Edges between svc and pod"

  kubectl get svc -n ${namespace} --no-headers=true -o custom-columns=NAME:metadata.name |\
  while read name;do
    escaped_name=$(escape_name ${name})
    labels=$(kubectl get svc ${name} -n ${namespace} --no-headers -o custom-columns=SELECTOR:spec.selector | sed -e 's/^map\[//' -e 's/\]//' | tr ': ' '=,')
    if [ -z "${labels}" ] || [ "${labels}" == "<none>" ] ;then
      continue
    fi 
    kubectl get pod -n ${namespace} -l ${labels} --no-headers=true -o custom-columns=NAME:metadata.name |\
    while read pod_name;do
      escaped_pod_name=$(escape_name ${pod_name})
      echo "    pod_${escaped_pod_name} -> svc_${escaped_name} [dir=back];"
    done
  done
}

function connect_resource () {
  local namespace=$1

  for resource in pod rs;do
    echo "    // Edges between ${resource} and its managed resource"
    kubectl get ${resource} -n ${namespace} --no-headers -o custom-columns=NAME:metadata.name |\
    while read name;do
      owner=$(kubectl get ${resource} -n ${namespace} ${name} -o jsonpath='{.metadata.ownerReferences}')
      if [ -n "${owner}" ];then
        escaped_name=$(escape_name ${name})
        owner_name=$(echo "${owner}" | sed -E 's/.* name:([^ ]*) .*/\1/')
        escaped_owner_name=$(escape_name ${owner_name})
        kind=$(echo "${owner}" | sed -E 's/.* kind:([^ ]*) .*/\1/')
        normalized_kind=$(normalize_kind ${kind})
        echo "    ${normalized_kind}_${escaped_owner_name} -> ${resource}_${escaped_name} [style=dashed];"
      fi
    done
  done
}

function generate_dot () {
  local namespace=$1

  start_digraph "G" ${namespace}
  start_namespace ${namespace}

  for ((rank=0;rank<${#RESOURCES[@]};rank++));do
    start_same_rank ${rank} 
    for resource in ${RESOURCES[$rank]};do
      add_resource ${namespace} ${resource} ${IMGS[$resource]}
    done
    end_same_rank
  done

  order_ranks 0 $((${#RESOURCES[@]}-1))

  connect_resource ${namespace}
  connect_pvc_pod ${namespace}
  connect_svc_pod ${namespace}

  end_namespace
  end_digraph
}

#### Main ####
# Parse Options
OPTS=$(getopt --options hn:o:t: --longoptions help,namespace:,outfile:,type: --name "$NAME" -- "$@")
[[ $? != 0 ]] && echo "Failed parsing options" >&2 && exit 1
eval set -- "$OPTS"

while true;do
  case "$1" in
    -h | --help)
      help
      exit 0
      ;;
    -n | --namespace)
      NAMESPACE="${2:-$NAMESPACE}"
      shift 2
      ;;
    -o | --outfile)
      OUTFILE="${2:-$OUTFILE}"
      shift 2
      ;;
    -t | --type)
      TYPE="${2:-$TYPE}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
  esac
done

if [ ${TYPE} != "dot" ];then
  generate_dot ${NAMESPACE} | dot -T${TYPE} -o ${OUTFILE}
else
  generate_dot ${NAMESPACE} > ${OUTFILE}
fi
