#!/bin/bash
#
# A script to collect tcpdumps of traffic between two pods.
# Currently only tested on OpenShiftSDN.
#
# DO NOT RUN IN PRODUCTION
#
# Following is the workflow:
#   1- Create "serving" pod on the first node running a minimal (python) http server.
#   2- Create "client" pod on the second node that will be used to curl the first pod.
#   3- Create "host-capture" pods on each node to capture host network traffic (tun0, veth etc.)
#   4- Send start signal to the pods that will trigger them to start simulating traffic (curl)
#      and collecting tcpdumps from the relevant interfaces.
#   5- Wait for the duration defined.
#   6- Send stop signal to the pods that will trigger the pods to stop the simulation/collection.
#   7- Collect the collected logs.
#
# Following log files are collected:
#   *-pod-tcpdump.pcap: tcpdump of eth0 interface from inside the pod.
#   veth*-tcpdump.pcap: tcpdump of the serving/client pod from the host interface.
#   tun0-tcpdump.pcap: tcpdump of tun0 interface on the hosts.
#   *-def_int-tcpdump.pcap: tcpdump of default interface on the hosts.
#   ovs-info.txt: ovs bridge and flows on the hosts.
#   web-server.log: Python webserver logs for each curl received.
#   curl.log: verbose curl ouptut for each curl call
#   *.run.log files: Runtime info from the pods/scripts.
#   iflink_*: iflink number of the pod interface (ignore)
#   
# Author: Khizer Naeem (knaeem@redhat.com)
# 14 Aug 2021

export SDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

err() {
    echo; echo;
    echo -e "\e[97m\e[101m[ERROR]\e[0m ${1}"; shift; echo;
    while [[ $# -gt 0 ]]; do echo "    $1"; shift; done
    echo; exit 1;
}


while [[ $# -gt 0 ]]
do
key="$1"
case $key in
    -s|--serving-node)
    S_NODE="$2"
    shift
    shift
    ;;
    -s=*|--serving-node=*)
    S_NODE="${key#*=}"
    shift
    ;;
    -c|--client-node)
    C_NODE="$2"
    shift
    shift
    ;;
    -c=*|--client-node=*)
    C_NODE="${key#*=}"
    shift
    ;;
    -d|--duration)
    DURATION="$2"
    shift
    shift
    ;;
    -d=*|--duration=*)
    DURATION="${key#*=}"
    shift
    ;;
    -p|--project)
    PROJECT_NAME="$2"
    shift
    shift
    ;;
    -p=*|--project=*)
    PROJECT_NAME="${key#*=}"
    shift
    ;;
    -i|--image)
    IMG_NET_TOOLS="$2"
    shift
    shift
    ;;
    -i=*|--image=*)
    IMG_NET_TOOLS="${key#*=}"
    shift
    ;;
    -h|--help)
    SHOW_HELP="yes"
    shift
    ;;
    -y|--yes)
    YES="yes"
    shift
    ;;
    *)
    echo "ERROR: Invalid argument $key"
    exit 1
    ;;
esac
done

# Show help if -h/--help is passed
if [ -n "${SHOW_HELP}" ]; then
    cat "${SDIR}/README.md"
    exit 0
fi

# Set the default project name if not set
if [ -z "${PROJECT_NAME}" ]; then
    echo "===> Setting default project name:"
    PROJECT_NAME="sdn-traffic-bw-nodes"
    echo "Done (${PROJECT_NAME})"
    echo
fi

# Random node selection if not set
if [ -z "${S_NODE}" -o -z "${C_NODE}" ]; then
    
    READY_NODES=($(oc get nodes -o 'go-template={{range .items}}{{$ready:=""}}{{range .status.conditions}}{{if eq .type "Ready"}}{{$ready = .status}}{{end}}{{end}}{{if eq $ready "True"}}{{.metadata.name}}{{" "}}{{end}}{{end}}'))
    READY_NODES=(${READY_NODES[@]/$S_NODE})
    READY_NODES=(${READY_NODES[@]/$C_NODE})
    test "${#READY_NODES[@]}" -lt "1" && err "Not enough ready node(s) found!"

    # Pick random serving node if not set
    if [ -z "${S_NODE}" ]; then
        echo "===> Selecting random serving node:"
        S_NODE=${READY_NODES[ $RANDOM % ${#READY_NODES[@]} ]}
        READY_NODES=(${READY_NODES[@]/$S_NODE})
        echo "Done (${S_NODE})"
        echo
    fi

    # Pick random client node if not set
    if [ -z "${C_NODE}" ]; then
        echo "===> Selected random client node:"
        C_NODE=${READY_NODES[ $RANDOM % ${#READY_NODES[@]} ]}
        echo "Done (${C_NODE})"
        echo
    fi
fi

# Set default duration if not set
if [ -z "${DURATION}" ]; then
    echo "===> Setting default testing duration:"
    DURATION="5m"
    echo "Done (${DURATION})"
    echo

fi

# Set default image if not set
if [ -z "${IMG_NET_TOOLS}" ]; then
    echo "===> Setting default network-tools image:"
    IMG_NET_TOOLS="registry.redhat.io/openshift4/network-tools-rhel8"
    echo "Done (${IMG_NET_TOOLS})"
    echo
fi

# Timestamp
TS=$(date +%d%h%y-%H%M%S)
# Directory variables should not have / at the end
DIR_NAME="${PROJECT_NAME}-${TS}"
HOST_TMPDIR="/host/tmp/${DIR_NAME}"


# Ensure we can make new directory
mkdir "${DIR_NAME}" && rmdir "${DIR_NAME}" \
    || err "Cannot make new directory in current working directory!"

# Ensure oc binary is present
builtin type -P oc &> /dev/null \
    || err "oc not found"

# Ensure oc is authenticated
OC_USER=$(oc whoami 2> /dev/null) \
    || err "oc not authenticated"

# Ensure nodes are present and ready
for node in $(echo -e "${S_NODE}\n${C_NODE}" | uniq); do
    oc get node "${node}" &> /dev/null \
        || err "Node ${node} not found!"
    ready=$(oc get node ${node} -o jsonpath='{.status.conditions[?(@.type == "Ready")].status}')
    test "$ready" = "True" \
        || err "Node ${node} not Ready!"
done

# Ensure that current user can create project
oc auth can-i create project &> /dev/null \
    || err "Current user (${OC_USER}) cannot create subscription in ns/openshift-operators"

# Ensure we don't already have the project
oc get project "${PROJECT_NAME}" -o name &> /dev/null \
    && err "project ${PROJECT_NAME} already exists." \
    "Please clean up before running again or use a different project name (-p/--project)"

# Show summary of selection
echo "===> Summary:"
echo
echo
echo -e "\tSERVING NODE:    ${S_NODE}"
echo -e "\tCLIENT NODE:     ${C_NODE}"
echo -e "\tPROJECT NAME:    ${PROJECT_NAME}"
echo -e "\tTEST DURATION:   ${DURATION}"
echo -e "\tCONTAINER IMAGE: ${IMG_NET_TOOLS}"
echo -e "\tTIME STAMP:      ${TS}"
echo
echo

# Check if we can continue
if [ -z "${YES}" ]; then
    echo
    echo -n "Press [Enter] to continue, [Ctrl]+C to abort: "
    read userinput;
    echo
fi


# Create project
echo "===> Creating new project:"
oc new-project "${PROJECT_NAME}" &> /dev/null \
    || err "Error creating new project ${PROJECT_NAME}"
echo "Done (${PROJECT_NAME})"
echo

# Add privileges to default sa
echo "===> Adding privileges to default service account"
oc adm policy add-scc-to-user privileged -z default -n ${PROJECT_NAME} &> /dev/null \
    || err "Cannot add privileged scc to default service account"
echo "Done (scc: privilged)"
oc adm policy add-role-to-user view -z default -n ${PROJECT_NAME} &> /dev/null \
    || err "Cannot add view role to default service account"
echo "Done (role: view)" 
echo

# Serving Pod on Serving Node
echo "===> Creating serving pod on ${S_NODE}:"
cat <<EOF | oc create -f - 
apiVersion: v1
kind: Pod
metadata:
  name: serving-pod
  namespace: ${PROJECT_NAME} 
spec:
  nodeName: ${S_NODE}
  restartPolicy: Never
  containers:
  - name: serving-pod
    image: ${IMG_NET_TOOLS}
    imagePullPolicy: IfNotPresent
    command:
    - bash
    - -c
    - |
      rm -f /host/tmp/start; rm -f /host/tmp/stop
      mkdir -p "${HOST_TMPDIR}"
      echo "===> Running \$(hostname) on ${S_NODE} at \$(date)" > "${HOST_TMPDIR}/serving-pod.run.log"
      echo "===> ip addr on this pod shows:" >> "${HOST_TMPDIR}/serving-pod.run.log"
      ip a >> "${HOST_TMPDIR}/serving-pod.run.log"
      cat /sys/class/net/eth0/iflink >> "${HOST_TMPDIR}/iflink_serving-pod"      
      mkdir /tmp/http
      echo "This is webserver on pod \$(hostname) on node ${S_NODE}" > /tmp/http/index.html
      cd /tmp/http
      python -u -m http.server 8000 &> "${HOST_TMPDIR}/web-server.log" &
      while [ ! -f "/host/tmp/start" ]; do continue; done
      echo "Starting traffic simulation at \$(date)" >> "${HOST_TMPDIR}/serving-pod.run.log"
      tcpdump -nn -i any -w "${HOST_TMPDIR}/serving-pod-tcpdump.pcap" &>> "${HOST_TMPDIR}/serving-pod.run.log" &
      while [ ! -f "/host/tmp/stop" ]; do continue; done
      killall tcpdump
      echo "Stopped traffic simulation at \$(date)" >> "${HOST_TMPDIR}/serving-pod.run.log"
      killall -s SIGINT python
      sync
      exit 0
    securityContext:
      privileged: true
      runAsUser: 0
    ports:
    - containerPort: 8000
      protocol: TCP
    volumeMounts:
    - name: host
      mountPath: /host
  volumes:
  - name: host
    hostPath:
      path: /
      type: Directory
EOF
test "$?" -eq "0" || err "Failed creating serving pod"
echo

echo "===> Waiting for serving pod to become ready:"
oc wait --timeout="1h" -n ${PROJECT_NAME} --for=condition=Ready pod/serving-pod \
    || err "Timed out waiting for serving pod to become ready"
echo

# Client Pod on Client Node
echo "===> Creating client pod on ${C_NODE}:"
cat <<EOF | oc create -f -
apiVersion: v1
kind: Pod
metadata:
  name: client-pod
  namespace: ${PROJECT_NAME} 
spec:
  nodeName: ${C_NODE}
  restartPolicy: Never
  containers:
  - name: client-pod
    image: ${IMG_NET_TOOLS}
    imagePullPolicy: IfNotPresent
    command:
    - bash
    - -c
    - |
      rm -f /host/tmp/start; rm -f /host/tmp/stop
      mkdir -p "${HOST_TMPDIR}"
      echo "===> Running \$(hostname) on ${C_NODE} at \$(date)" > "${HOST_TMPDIR}/client-pod.run.log"
      echo "===> ip addr on this pod shows:" >> "${HOST_TMPDIR}/client-pod.run.log"
      ip a >> "${HOST_TMPDIR}/client-pod.run.log"
      cat /sys/class/net/eth0/iflink >> "${HOST_TMPDIR}/iflink_client-pod"
      s_ip=\$(oc get pod serving-pod -n ${PROJECT_NAME} -o jsonpath='{.status.podIP}')
      echo "I will be curling \${s_ip}" >> "${HOST_TMPDIR}/client-pod.run.log"
      while [ ! -f "/host/tmp/start" ]; do continue; done
      echo "Starting traffic simulation at \$(date)" >> "${HOST_TMPDIR}/client-pod.run.log"
      tcpdump -nn -i any -w "${HOST_TMPDIR}/client-pod-tcpdump.pcap" &>> "${HOST_TMPDIR}/client-pod.run.log" &
      while [ ! -f "/host/tmp/stop" ]; do
        echo "===> curl -v \${s_ip}:8000 at \$(date)" >> "${HOST_TMPDIR}/curl.log"
        curl -qsv "\${s_ip}:8000" &>> "${HOST_TMPDIR}/curl.log"
        sleep 1
      done
      killall tcpdump
      echo "Stopped traffic simulation at \$(date)" >> "${HOST_TMPDIR}/client-pod.run.log"
      sync
      exit 0
    securityContext:
      privileged: true
      runAsUser: 0
    ports:
    - containerPort: 8000
      protocol: TCP
    volumeMounts:
    - name: host
      mountPath: /host
  volumes:
  - name: host
    hostPath:
      path: /
      type: Directory
EOF
test "$?" -eq "0" || err "Failed creating client pod"
echo

echo "===> Waiting for client pod to become ready:"
oc wait --timeout="1h" -n ${PROJECT_NAME} --for=condition=Ready pod/client-pod \
    || err "Timed out waiting for serving pod to become ready"
echo


# Traffic Capture on Hosts
for node in $(echo -e "${S_NODE}\n${C_NODE}" | uniq); do
echo "===> Creating host capture pod on ${node}:"
cat <<EOF | oc create -f -
apiVersion: v1
kind: Pod
metadata:
  name: host-capture-${node}
  namespace: ${PROJECT_NAME} 
spec:
  nodeName: ${node}
  restartPolicy: Never
  hostNetwork: true
  hostPID: true
  containers:
  - name: host-capture
    image: ${IMG_NET_TOOLS}
    imagePullPolicy: IfNotPresent
    command:
    - bash
    - -c
    - |
      rm -f /host/tmp/start; rm -f /host/tmp/stop
      mkdir -p "${HOST_TMPDIR}"
      echo "Running \$(hostname) on ${node} at \$(date)" > "${HOST_TMPDIR}/host_capture_${node}.run.log"
      echo "ip addr on this pod shows:" >> "${HOST_TMPDIR}/host_capture_${node}.run.log"
      ip a >> "${HOST_TMPDIR}/host_capture_${node}.run.log"
      list_br=\$(chroot /host ovs-vsctl list-br)
      echo "### ovs-vsctl list-br: \${list_br}" &>> "${HOST_TMPDIR}/ovs-info.txt"
      echo "### ovs-ofctl -O OpenFlow13 dump-ports-desc \${list_br}" &>> "${HOST_TMPDIR}/ovs-info.txt"
      chroot /host ovs-ofctl -O OpenFlow13 dump-ports-desc "\${list_br}" &>> "${HOST_TMPDIR}/ovs-info.txt"
      echo "### ovs-ofctl -O OpenFlow13 dump-flows \${list_br}" &>> "${HOST_TMPDIR}/ovs-info.txt"
      chroot /host ovs-ofctl -O OpenFlow13 dump-flows "\${list_br}" &>> "${HOST_TMPDIR}/ovs-info.txt"
      while [ ! -f "/host/tmp/start" ]; do continue; done
      def_int=\$(awk '\$2 == 00000000 { print \$1 }' /proc/net/route)
      echo "Starting \${def_int} traffic capture at \$(date)" >> "${HOST_TMPDIR}/host_capture_${node}.run.log"
      tcpdump -nn -i "\${def_int}" -w "${HOST_TMPDIR}/\${def_int}-def_int-tcpdump.pcap" &>> "${HOST_TMPDIR}/host_capture_${node}.run.log" &
      echo "Starting tun0 traffic capture at \$(date)" >> "${HOST_TMPDIR}/host_capture_${node}.run.log"
      tcpdump -nn -i tun0 -w "${HOST_TMPDIR}/tun0-tcpdump.pcap" &>> "${HOST_TMPDIR}/host_capture_${node}.run.log" &
      for iflink in ${HOST_TMPDIR}/iflink_*; do
        ifl=\$(cat \${iflink})
        veth=\$(grep -wR "\${ifl}" /sys/class/net/veth*/ifindex | cut -d "/" -f5)
        echo "Starting \${veth} traffic capture at \$(date)" >> "${HOST_TMPDIR}/host_capture_${node}.run.log"
        tcpdump -nn -i "\${veth}" -w "${HOST_TMPDIR}/\${veth}-tcpdump.pcap" &>> "${HOST_TMPDIR}/host_capture_${node}.run.log" &
      done
      while [ ! -f "/host/tmp/stop" ]; do continue; done
      killall tcpdump
      echo "Stopped host traffic capture at \$(date)" >> "${HOST_TMPDIR}/host_capture_${node}.run.log"
      sync
      sleep infinity
      exit 0
    securityContext:
      privileged: true
      runAsUser: 0
    ports:
    - containerPort: 8000
      protocol: TCP
    volumeMounts:
    - name: host
      mountPath: /host
  volumes:
  - name: host
    hostPath:
      path: /
      type: Directory
EOF
test "$?" -eq "0" || err "Failed creating host capture pod on ${node}"
echo

echo "===> Waiting for host capture pod to become ready:"
oc wait --timeout="1h" -n ${PROJECT_NAME} --for=condition=Ready "pod/host-capture-${node}" \
    || err "Timed out waiting for serving pod to become ready"
echo
done

sleep 5

echo "===> Sending start signal:"
for node in $(echo -e "${S_NODE}\n${C_NODE}" | uniq); do
    host_pod="host-capture-${node}"
    (oc -n ${PROJECT_NAME} exec ${host_pod} -- touch /host/tmp/start && echo "Done (${node})") &
done
wait
echo

echo "===> Waiting for ${DURATION} while the traffic simulation/capture runs:"
sleep "${DURATION}" && echo "Done"
echo

echo "====> Sending stop signal:"
for node in $(echo -e "${S_NODE}\n${C_NODE}" | uniq); do
    host_pod="host-capture-${node}"
    (oc -n ${PROJECT_NAME} exec ${host_pod} -- touch /host/tmp/stop && echo "Done (${node})") &
done
wait
echo

echo "===> Waiting for the serving/client pods to complete"
for pod in "serving-pod" "client-pod"; do
    while [ $(oc get pods "${pod}" -o jsonpath='{.status.conditions[?(@.type == "Ready")].status}') == "True" ]; do sleep 5; done
    echo "Done (${pod})"
done
echo

echo "===> Collecting data in local directory ./${DIR_NAME}:"
for node in $(echo -e "${S_NODE}\n${C_NODE}" | uniq); do
    host_pod="host-capture-${node}"
    mkdir -p "${DIR_NAME}/${node}"
    oc -n ${PROJECT_NAME} exec "${host_pod}" -- tar -P -C /host/tmp -cf - "${DIR_NAME}" | tar -xf - -C "${DIR_NAME}/${node}" && echo "Done ($node)"
    oc -n ${PROJECT_NAME} exec "${host_pod}" -- killall sleep
done
echo

echo "===> Waiting for host capture pods to complete:"
for node in $(echo -e "${S_NODE}\n${C_NODE}" | uniq); do
    host_pod="host-capture-${node}"
    while [ $(oc get pods "${host_pod}" -o jsonpath='{.status.conditions[?(@.type == "Ready")].status}') == "True" ]; do sleep 5; done
    echo "Done (${host_pod})"
done
echo

echo "===> Collecting project level info:"
oc get nodes -o wide > "${DIR_NAME}/nodes-o-wide.txt" && echo "Done (nodes)"
oc get pods -n ${PROJECT_NAME} -o wide > "${DIR_NAME}/pods-o-wide.txt" && echo "Done (pods)"
oc get events -n ${PROJECT_NAME} > "${DIR_NAME}/events.txt" && echo "Done (events)"
echo

echo "END OF SCRIPT"