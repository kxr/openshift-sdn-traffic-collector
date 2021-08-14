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
#   web-server.log: Python webserver logs for each curl received.
#   curl.log: verbose curl ouptut for each curl call
#   *.pod.log files: Runtime info from the pods/scripts.
#   iflink_*: iflink number of the pod interface (ignore)
#   
# Author: Khizer Naeem (knaeem@redhat.com)
# 14 Aug 2021

# Project Name to be used - Should not exist
PROJECT_NAME="sdn-traffic-bw-nodes"

# Serving Node name (pod with a webserver will run on this node)
S_NODE="worker-1.aram4748.h1.kxr.me"
# Client Node name (pod on this node will curl the pod on serving node)
C_NODE="worker-2.aram4748.h1.kxr.me"
# Note: Same node in S_NODE & C_NODE should work

# Duration for traffic simulation/capture
# Any value that can be passed to `sleep <..>`
DURATION="5m"

#
# Donot Change below, unless you know what you are doing
#

IMG_NET_TOOLS="registry.redhat.io/openshift4/network-tools-rhel8"
TS=$(date +%d%h%y-%H%M%S)
# Directory variables should not have / at the end
DIR_NAME="${PROJECT_NAME}-${TS}"
HOST_TMPDIR="/host/tmp/${DIR_NAME}"

err() {
    echo; echo;
    echo -e "\e[97m\e[101m[ERROR]\e[0m ${1}"; shift; echo;
    while [[ $# -gt 0 ]]; do echo "    $1"; shift; done
    echo; exit 1;
}

# Ensure we can make new directory
mkdir "${DIR_NAME}" && rmdir "${DIR_NAME}" \
  || err "Cannot make new directory in current working directory!"

# Ensure oc binary is present
builtin type -P oc &> /dev/null \
    || err "oc not found"

# Ensure oc is authenticated
OC_USER=$(oc whoami 2> /dev/null) \
    || err "oc not authenticated"

# Ensure that current user can create project
oc auth can-i create project &> /dev/null \
    || err "Current user (${OC_USER}) cannot create subscription in ns/openshift-operators"

# Ensure we don't already have the project
oc get project "${PROJECT_NAME}" -o name &> /dev/null \
    && err "project ${PROJECT_NAME} already exists. Please clean up before running again."
    
# Create project
echo
echo "===> Creating new project ${PROJECT_NAME}:"
oc new-project "${PROJECT_NAME}" &> /dev/null && echo "Done" \
  || err "Error creating new project ${PROJECT_NAME}"

# Give privileged scc to default sa 
oc adm policy add-scc-to-user privileged -z default -n ${PROJECT_NAME} &> /dev/null \
    || err "Cannot add privileged scc to service account default"

# Give view role to default sa
oc adm  policy add-role-to-user view -z default -n ${PROJECT_NAME} &> /dev/null \
    || err "Cannot add view role to service account default"




# Serving Pod on Serving Node
echo
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
      echo "===> Running \$(hostname) on ${S_NODE} at \$(date)" > "${HOST_TMPDIR}/serving-pod.pod.log"
      echo "===> ip addr on this pod shows:" >> "${HOST_TMPDIR}/serving-pod.pod.log"
      ip a >> "${HOST_TMPDIR}/serving-pod.pod.log"
      cat /sys/class/net/eth0/iflink >> "${HOST_TMPDIR}/iflink_serving-pod"      
      mkdir /tmp/http
      echo "This is webserver on pod \$(hostname) on node ${S_NODE}" > /tmp/http/index.html
      cd /tmp/http
      python -u -m http.server 8000 &> "${HOST_TMPDIR}/web-server.log" &
      while [ ! -f "/host/tmp/start" ]; do continue; done
      echo "Starting traffic simulation at \$(date)" >> "${HOST_TMPDIR}/serving-pod.pod.log"
      tcpdump -nn -i any -w "${HOST_TMPDIR}/serving-pod-tcpdump.pcap" &
      while [ ! -f "/host/tmp/stop" ]; do continue; done
      killall tcpdump
      echo "Stopped traffic simulation at \$(date)" >> "${HOST_TMPDIR}/serving-pod.pod.log"
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

echo
echo "===> Waiting for serving pod to become ready:"
oc wait --timeout="1h" -n ${PROJECT_NAME} --for=condition=Ready pod/serving-pod

echo
echo "===> Creating client pod on ${C_NODE}:"
# Client Pod on Client Node
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
      echo "===> Running \$(hostname) on ${C_NODE} at \$(date)" > "${HOST_TMPDIR}/client-pod.pod.log"
      echo "===> ip addr on this pod shows:" >> "${HOST_TMPDIR}/client-pod.pod.log"
      ip a >> "${HOST_TMPDIR}/client-pod.pod.log"
      cat /sys/class/net/eth0/iflink >> "${HOST_TMPDIR}/iflink_client-pod"
      s_ip=\$(oc get pod serving-pod -n ${PROJECT_NAME} -o jsonpath='{.status.podIP}')
      echo "I will be curling \${s_ip}" >> "${HOST_TMPDIR}/client-pod.pod.log"
      while [ ! -f "/host/tmp/start" ]; do continue; done
      echo "Starting traffic simulation at \$(date)" >> "${HOST_TMPDIR}/client-pod.pod.log"
      tcpdump -nn -i any -w "${HOST_TMPDIR}/client-pod-tcpdump.pcap" &
      while [ ! -f "/host/tmp/stop" ]; do
        echo "===> curl -v \${s_ip}:8000 at \$(date)" >> "${HOST_TMPDIR}/curl.log"
        curl -qsv "\${s_ip}:8000" &>> "${HOST_TMPDIR}/curl.log"
        sleep 1
      done
      killall tcpdump
      echo "Stopped traffic simulation at \$(date)" >> "${HOST_TMPDIR}/client-pod.pod.log"
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

echo
echo "===> Waiting for client pod to become ready:"
oc wait --timeout="1h" -n ${PROJECT_NAME} --for=condition=Ready pod/client-pod


# tun0 Traffic Capture on Hosts
for node in $(echo -e "${S_NODE}\n${C_NODE}" | uniq); do
echo
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
      echo "Running \$(hostname) on ${node} at \$(date)" > "${HOST_TMPDIR}/host_capture_${node}.pod.log"
      echo "ip addr on this pod shows:" >> "${HOST_TMPDIR}/host_capture_${node}.pod.log"
      ip a >> "${HOST_TMPDIR}/host_capture_${node}.pod.log"
      while [ ! -f "/host/tmp/start" ]; do continue; done
      echo "Starting tun0 traffic capture at \$(date)" >> "${HOST_TMPDIR}/host_capture_${node}.pod.log"
      tcpdump -nn -i tun0 -w "${HOST_TMPDIR}/tun0-tcpdump.pcap" &
      for iflink in ${HOST_TMPDIR}/iflink_*; do
        ifl=\$(cat \${iflink})
        veth=\$(grep -wR "\${ifl}" /sys/class/net/veth*/ifindex | cut -d "/" -f5)
        echo "Starting \${veth} traffic capture at \$(date)" >> "${HOST_TMPDIR}/host_capture_${node}.pod.log"
        tcpdump -nn -i "\${veth}" -w "${HOST_TMPDIR}/\${veth}-tcpdump.pcap" &
      done
      while [ ! -f "/host/tmp/stop" ]; do continue; done
      killall tcpdump
      echo "Stopped host traffic capture at \$(date)" >> "${HOST_TMPDIR}/host_capture_${node}.pod.log"
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

echo
echo "===> Waiting for host capture pod to become ready:"
oc wait --timeout="1h" -n ${PROJECT_NAME} --for=condition=Ready pod/host-capture-${node}
done

sleep 5

echo
echo "===> Sending start signal:"
oc -n ${PROJECT_NAME} exec serving-pod -- touch /host/tmp/start && echo "Done (serving-pod)"
oc -n ${PROJECT_NAME} exec client-pod -- touch /host/tmp/start && echo "Done (client-pod)"

echo
echo "===> Waiting for ${DURATION} while the traffic simulation/capture runs:"
sleep "${DURATION}" && echo "Done"

echo
echo "====> Sending stop signal:"
oc -n ${PROJECT_NAME} exec serving-pod -- touch /host/tmp/stop && echo "Done (serving-pod)"
oc -n ${PROJECT_NAME} exec client-pod -- touch /host/tmp/stop && echo "Done (client-pod)"

sleep 1

echo
echo "===> Collecting data in local directory ./${DIR_NAME}"
for node in $(echo -e "${S_NODE}\n${C_NODE}" | uniq); do
  host_pod="host-capture-${node}"
  mkdir -p "${DIR_NAME}/${node}"
  oc -n ${PROJECT_NAME} exec "${host_pod}" -- tar -P -C /host/tmp -cf - "${DIR_NAME}" | tar -xf - -C "${DIR_NAME}/${node}" && echo "Done ($node)"
  oc -n ${PROJECT_NAME} exec "${host_pod}" -- killall sleep
done
echo
