
Usage: openshift-sdn-traffic-collector.sh [OPTIONS]

Description:
A script to collect tcpdumps of traffic between two pods/nodes.
Currently only tested on OpenShift 4.x / OpenShiftSDN.

DO NOT RUN IN PRODUCTION

Following is the workflow:
  1- Create "serving" pod on the first node running a minimal (python) http server.
  2- Create "client" pod on the second node that will be used to curl the first pod.
  3- Create "host-capture" pods on each node to capture host network traffic (tun0, veth etc.)
  4- Send start signal to the pods that will trigger them to start simulating traffic (curl)
     and collecting tcpdumps from the relevant interfaces.
  5- Wait for the duration defined.
  6- Send stop signal to the pods that will trigger the pods to stop the simulation/collection.
  7- Collect the collected logs.

Following log files are collected from each node:
  *-pod-tcpdump.pcap: tcpdump of eth0 interface from inside the pod.
  veth*-tcpdump.pcap: tcpdump of the serving/client pod from the host interface.
  tun0-tcpdump.pcap: tcpdump of tun0 interface on the hosts.
  *-def_int-tcpdump.pcap: tcpdump of default interface on the hosts.
  ovs-info.txt: ovs bridge and flows on the hosts.
  web-server.log: Python webserver logs for each curl received.
  curl.log: verbose curl ouptut for each curl call
  *.run.log files: Runtime info from the pods/scripts.
  iflink_*: iflink number of the pod interface (ignore)

Author: Khizer Naeem (knaeem@redhat.com)
14 Aug 2021

Options:
-s, --serving-node <node-name>
    OpenShift node that will host the serving-pod.
    Default: random node

-c, --client-node <node-name>
    OpenShift node that will host the client-pod.
    Default: random node

-p, --project <project-name>
    Project name that will be created to host the pods.
    Default: sdn-traffic-bw-nodes

-d, --duration <duration>
    Duration for which the traffic will be simulated/captured.
    Use any value that can be passed to the sleep command.
    Default: 5m

-i, --image <image>
    Container image to be used to run the tests.
    This image must have tools like: python, tcpdump, killall.
    Default: registry.redhat.io/openshift4/network-tools-rhel8

-y, --yes
    If this is set, script will not ask for confirmation
    Default: Not set

-h, --help
    Shows help
    Default: Not set


