#!/bin/bash

function svc_exist {
        kubectl get deployments.apps $1 -n default >/dev/null 2>&1
}

SERVICE_NAME='k3s'
CONSUL_API_URL='http://127.0.0.1:8500/v1'

echo $APPS_TO_RESTART

interface=$1 status=$2

case $1 in
    docker0|cni0)
        exit 0
    ;;
esac

case $status in

    up|down|hostname|dhcp4-change)
	

        echo " "
        echo "Interface: $interface, in state: $status, restarting k3s";
        echo " "
        systemctl restart ${SERVICE_NAME}

        while [[ "`systemctl is-active ${SERVICE_NAME}`" != "active" ]]; do
            sleep 1
        done
        
        sleep 5

        HOST_IP=`kubectl get nodes -o wide | awk {'print $6'} | tail -n +2`
        
        echo "Updating consul static host ip keys in dc ${DC_NAME} ..."
        echo " "
        curl -s --request PUT --data ${HOST_IP} ${CONSUL_API_URL}/kv/webrtc-streamer/HOST_IP > /dev/null
        curl -s --request PUT --data ${HOST_IP} ${CONSUL_API_URL}/kv/webrtc-streamer/APIGATEWAY_IP > /dev/null
        curl -s --request PUT --data ${HOST_IP} ${CONSUL_API_URL}/kv/webrtc-streamer/WEBRTC_HOST > /dev/null
        curl -s --request PUT --data "${HOST_IP}:3478" ${CONSUL_API_URL}/kv/webrtc-streamer/STUN_URL > /dev/null
        curl -s --request PUT --data "webrtc:webrtc@${HOST_IP}:3478" ${CONSUL_API_URL}/kv/webrtc-streamer/TURN_URL > /dev/null

        if [[ $(svc_exist "hq") != 0 ]] ; then
            curl -s --request PUT --data ${HOST_IP} ${CONSUL_API_URL}/kv/api-master-env/MONGO_DB_IP > /dev/null
            curl -s --request PUT --data ${HOST_IP} ${CONSUL_API_URL}/kv/api-master-env/RMQ_EXCHANGE_HOST > /dev/null
        fi

        if [[ $(svc_exist "dslr-dashboard-bt") != 0 ]] ; then
            curl -s --request PUT --data ${HOST_IP} ${CONSUL_API_URL}/kv/dsl-dashboard-bt/API_IP > /dev/null
        fi

        declare -a APPS_TO_RESTART=("edge")

        for app in ${APPS_TO_RESTART[@]}; do
            kubectl delete pod -l app=$app -n default --grace-period=0
        done


    ;;

esac
