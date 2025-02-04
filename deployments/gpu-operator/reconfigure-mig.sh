#!/usr/bin/env bash

# Copyright (c) 2021, NVIDIA CORPORATION.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

WITH_REBOOT="false"
WITH_SHUTDOWN_HOST_GPU_CLIENTS="false"
HOST_ROOT_MOUNT=""
HOST_NVIDIA_DIR=""
HOST_MIG_MANAGER_STATE_FILE=""
HOST_GPU_CLIENT_SERVICES=""
HOST_KUBELET_SERVICE=""
NODE_NAME=""
MIG_CONFIG_FILE=""
SELECTED_MIG_CONFIG=""
DEFAULT_GPU_CLIENTS_NAMESPACE=""

export SYSTEMD_LOG_LEVEL="info"

function usage() {
  echo "USAGE:"
  echo "    ${0} -h "
  echo "    ${0} -n <node> -f <config-file> -c <selected-config> -p <default-gpu-clients-namespace> [ -m <host-root-mount> -i <host-nvidia-dir> -o <host-mig-manager-state-file> -g <host-gpu-client-services> -k <host-kubelet-service> -r -s ]"
  echo ""
  echo "OPTIONS:"
  echo "    -h                                   Display this help message"
  echo "    -r                                   Automatically reboot the node if changing the MIG mode fails for any reason"
  echo "    -d                                   Automatically shutdown/restart any required host GPU clients across a MIG configuration"
  echo "    -n <node>                            The kubernetes node to change the MIG configuration on"
  echo "    -f <config-file>                     The mig-parted configuration file"
  echo "    -c <selected-config>                 The selected mig-parted configuration to apply to the node"
  echo "    -m <host-root-mount>                 Container path where host root directory is mounted"
  echo "    -i <host-nvidia-dir>                 Host path of the directory where NVIDIA managed software directory is typically located"
  echo "    -o <host-mig-manager-state-file>     Host path where the systemd mig-manager state file is located"
  echo "    -g <host-gpu-client-services>        Comma separated list of host systemd services to shutdown/restart across a MIG reconfiguration"
  echo "    -k <host-kubelet-service>            Name of the host's 'kubelet' systemd service which may need to be shutdown/restarted across a MIG mode reconfiguration"
  echo "    -p <default-gpu-clients-namespace>   Default name of the Kubernetes Namespace in which the GPU client Pods are installed in"
}

while getopts "hrdn:f:c:m:i:o:g:k:p:" opt; do
  case ${opt} in
    h ) # process option h
      usage; exit 0
      ;;
    r ) # process option r
      WITH_REBOOT="true"
      ;;
    d ) # process option d
      WITH_SHUTDOWN_HOST_GPU_CLIENTS="true"
      ;;
    n ) # process option n
      NODE_NAME=${OPTARG}
      ;;
    f ) # process option f
      MIG_CONFIG_FILE=${OPTARG}
      ;;
    c ) # process option c
      SELECTED_MIG_CONFIG=${OPTARG}
      ;;
    m ) # process option m
      HOST_ROOT_MOUNT=${OPTARG}
      ;;
    i ) # process option i
      HOST_NVIDIA_DIR=${OPTARG}
      ;;
    o ) # process option o
      HOST_MIG_MANAGER_STATE_FILE=${OPTARG}
      ;;
    g ) # process option g
      HOST_GPU_CLIENT_SERVICES=${OPTARG}
      ;;
    k ) # process option k
      HOST_KUBELET_SERVICE=${OPTARG}
      ;;
    p ) # process option p
      DEFAULT_GPU_CLIENTS_NAMESPACE=${OPTARG}
      ;;
    \? ) echo "Usage: ${0} -n <node> -f <config-file> -c <selected-config> -p <default-gpu-clients-namespace> [ -m <host-root-mount> -i <host-nvidia-dir> -o <host-mig-manager-state-file> -g <host-gpu-client-services> -k <host-kubelet-service> -r -s ]"
      ;;
  esac
done

if [ "${NODE_NAME}" = "" ]; then
  echo "ERROR: missing -n <node> flag"
  usage; exit 1
fi
if [ "${MIG_CONFIG_FILE}" = "" ]; then
  echo "Error: missing -f <config-file> flag"
  usage; exit 1
fi
if [ "${SELECTED_MIG_CONFIG}" = "" ]; then
  echo "Error: missing -c <selected-config> flag"
  usage; exit 1
fi
if [ "${DEFAULT_GPU_CLIENTS_NAMESPACE}" = "" ]; then
  echo "Error: missing -p <default-gpu-clients-namespace> flag"
  usage; exit 1
fi

HOST_GPU_CLIENT_SERVICES=(${HOST_GPU_CLIENT_SERVICES//,/ })
HOST_GPU_CLIENT_SERVICES_STOPPED=()

if [ "${WITH_SHUTDOWN_HOST_GPU_CLIENTS}" = "true" ]; then
	mkdir -p "${HOST_ROOT_MOUNT}/${HOST_NVIDIA_DIR}/mig-manager/"
	cp "$(which nvidia-mig-parted)" "${HOST_ROOT_MOUNT}/${HOST_NVIDIA_DIR}/mig-manager/"
	cp "${MIG_CONFIG_FILE}" "${HOST_ROOT_MOUNT}/${HOST_NVIDIA_DIR}/mig-manager/config.yaml"
	shopt -s expand_aliases
	alias nvidia-mig-parted="chroot ${HOST_ROOT_MOUNT} ${HOST_NVIDIA_DIR}/mig-manager/nvidia-mig-parted"
	MIG_CONFIG_FILE="${HOST_NVIDIA_DIR}/mig-manager/config.yaml"
fi

function __set_state_and_exit() {
	local state="${1}"
	local exit_code="${2}"

	if [ "${WITH_SHUTDOWN_HOST_GPU_CLIENTS}" = "true" ]; then
		if [ "${NO_RESTART_HOST_SYSTEMD_SERVICES_ON_EXIT}" != "true" ]; then
			echo "Restarting any GPU clients previously shutdown on the host by restarting their systemd services"
			host_start_systemd_services
			if [ "${?}" != "0" ]; then
				echo "Unable to restart host systemd services"
				exit_code=1
			fi
		fi
	fi

	if [ "${NO_RESTART_K8S_DAEMONSETS_ON_EXIT}" != "true" ]; then
		echo "Restarting any GPU clients previously shutdown in Kubernetes by reenabling their component-specific nodeSelector labels"
		kubectl label --overwrite \
			node ${NODE_NAME} \
			nvidia.com/gpu.deploy.device-plugin=$(maybe_set_true ${PLUGIN_DEPLOYED}) \
			nvidia.com/gpu.deploy.gpu-feature-discovery=$(maybe_set_true ${GFD_DEPLOYED}) \
			nvidia.com/gpu.deploy.dcgm-exporter=$(maybe_set_true ${DCGM_EXPORTER_DEPLOYED}) \
			nvidia.com/gpu.deploy.dcgm=$(maybe_set_true ${DCGM_DEPLOYED})
			if [ "${?}" != "0" ]; then
				echo "Unable to bring up GPU client pods by setting their daemonset labels"
				exit_code=1
			fi
	fi

	echo "Changing the 'nvidia.com/mig.config.state' node label to '${state}'"
	kubectl label --overwrite  \
		node ${NODE_NAME} \
		nvidia.com/mig.config.state="${state}"
	if [ "${?}" != "0" ]; then
		echo "Unable to set 'nvidia.com/mig.config.state' to \'${state}\'"
		echo "Exiting with incorrect value in 'nvidia.com/mig.config.state'"
		exit_code=1
	fi

	exit ${exit_code}
}	

function exit_success() {
	__set_state_and_exit "success" 0
}	

function exit_failed() {
	__set_state_and_exit "failed" 1
}

# Only return 'paused-*' if the value passed in is != 'false'. It should only
# be 'false' if some external entity has forced it to this value, at which point
# we want to honor it's existing value and not change it.
function maybe_set_paused() {
	local current_value="${1}"
	if [  "${current_value}" = "false" ]; then
		echo "false"
	else
		echo "paused-for-mig-change"
	fi
}

# Only return 'true' if the value passed in is != 'false'. It should only
# be 'false' if some external entity has forced it to this value, at which point
# we want to honor it's existing value and not change it.
function maybe_set_true() {
	local current_value="${1}"
	if [  "${current_value}" = "false" ]; then
		echo "false"
	else
		echo "true"
	fi
}

function host_stop_systemd_services() {
	for s in ${HOST_GPU_CLIENT_SERVICES[@]}; do
		# If the service is "active"" we will attempt to shut it down and (if
		# successful) we will track it to restart it later.
		chroot ${HOST_ROOT_MOUNT} systemctl -q is-active "${s}"
		if [ "${?}" = "0" ]; then
			echo "Stopping "${s}" (active, will-restart)"
			chroot ${HOST_ROOT_MOUNT} systemctl stop "${s}"
			if [ "${?}" != "0" ]; then
				return 1
			fi
			HOST_GPU_CLIENT_SERVICES_STOPPED=("${s}" ${HOST_GPU_CLIENT_SERVICES_STOPPED[@]})
			continue
		fi

		# If the service is inactive, then we may or may not still want to track
		# it to restart it later. The logic below decides when we should or not.

		local err="$(chroot ${HOST_ROOT_MOUNT} systemctl -q is-enabled "${s}" 2>&1)"
		if [ "${err}" != "" ]; then
			echo "Skipping "${s}" (no-exist)"
			continue
		fi

		chroot ${HOST_ROOT_MOUNT} systemctl -q is-failed "${s}"
		if [ "${?}" = "0" ]; then
			echo "Skipping "${s}" (is-failed, will-restart)"
			HOST_GPU_CLIENT_SERVICES_STOPPED=("${s}" ${HOST_GPU_CLIENT_SERVICES_STOPPED[@]})
			continue
		fi

		chroot ${HOST_ROOT_MOUNT} systemctl -q is-enabled "${s}"
		if [ "${?}" != "0" ]; then
			echo "Skipping "${s}" (disabled)"
			continue
		fi

		local type="$(chroot ${HOST_ROOT_MOUNT} systemctl show --property=Type "${s}")"
		if [ "${type}" = "Type=oneshot" ]; then
			echo "Skipping "${s}" (inactive, oneshot, no-restart)"
			continue
		fi

		echo "Skipping "${s}" (inactive, will-restart)"
		HOST_GPU_CLIENT_SERVICES_STOPPED=("${s}" ${HOST_GPU_CLIENT_SERVICES_STOPPED[@]})
	done
	return 0
}

function host_start_systemd_services() {
	local ret=0

	# If HOST_GPU_CLIENT_SERVICES_STOPPED is empty, then it's possible that
	# host_stop_systemd_services was never called, so let's double check to see
	# if there's anything we should actually restart.
	if [ "${#HOST_GPU_CLIENT_SERVICES_STOPPED[@]}" = "0" ]; then
		for s in ${HOST_GPU_CLIENT_SERVICES[@]}; do
			chroot ${HOST_ROOT_MOUNT} systemctl -q is-active "${s}"
			if [ "${?}" = "0" ]; then
				continue
			fi

			local err="$(chroot ${HOST_ROOT_MOUNT} systemctl -q is-enabled "${s}" 2>&1)"
			if [ "${err}" != "" ]; then
				continue
			fi

			chroot ${HOST_ROOT_MOUNT} systemctl -q is-failed "${s}"
			if [ "${?}" = "0" ]; then
				HOST_GPU_CLIENT_SERVICES_STOPPED=("${s}" ${HOST_GPU_CLIENT_SERVICES_STOPPED[@]})
				continue
			fi

			chroot ${HOST_ROOT_MOUNT} systemctl -q is-enabled "${s}"
			if [ "${?}" != "0" ]; then
				continue
			fi

			local type="$(chroot ${HOST_ROOT_MOUNT} systemctl show --property=Type "${s}")"
			if [ "${type}" = "Type=oneshot" ]; then
				continue
			fi

			HOST_GPU_CLIENT_SERVICES_STOPPED=("${s}" ${HOST_GPU_CLIENT_SERVICES_STOPPED[@]})
		done
	fi

	for s in ${HOST_GPU_CLIENT_SERVICES_STOPPED[@]}; do
		echo "Starting "${s}""
		chroot ${HOST_ROOT_MOUNT} systemctl start "${s}"
		if [ "${?}" != "0" ]; then
			echo "Error Starting "${s}": skipping, but continuing..."
			ret=1
		fi
	done

	return ${ret}
}

function host_persist_config() {
local config=$(cat << EOF
[Service]
Environment="MIG_PARTED_SELECTED_CONFIG=${SELECTED_MIG_CONFIG}"
EOF
)
	chroot ${HOST_ROOT_MOUNT} bash -c "
		echo \"${config}\" > ${HOST_MIG_MANAGER_STATE_FILE};
		systemctl daemon-reload"
	if [ "${?}" != "0" ]; then
		return 1
	fi
	return 0
}

echo "Getting current value of the 'nvidia.com/gpu.deploy.device-plugin' node label"
PLUGIN_DEPLOYED=$(kubectl get nodes ${NODE_NAME} -o=jsonpath='{$.metadata.labels.nvidia\.com/gpu\.deploy\.device-plugin}')
if [ "${?}" != "0" ]; then
	echo "Unable to get the value of the 'nvidia.com/gpu.deploy.device-plugin' label"
	exit_failed
fi
echo "Current value of 'nvidia.com/gpu.deploy.device-plugin=${PLUGIN_DEPLOYED}'"

echo "Getting current value of the 'nvidia.com/gpu.deploy.gpu-feature-discovery' node label"
GFD_DEPLOYED=$(kubectl get nodes ${NODE_NAME} -o=jsonpath='{$.metadata.labels.nvidia\.com/gpu\.deploy\.gpu-feature-discovery}')
if [ "${?}" != "0" ]; then
	echo "Unable to get the value of the 'nvidia.com/gpu.deploy.gpu-feature-discovery' label"
	exit_failed
fi
echo "Current value of 'nvidia.com/gpu.deploy.gpu-feature-discovery=${GFD_DEPLOYED}'"

echo "Getting current value of the 'nvidia.com/gpu.deploy.dcgm-exporter' node label"
DCGM_EXPORTER_DEPLOYED=$(kubectl get nodes ${NODE_NAME} -o=jsonpath='{$.metadata.labels.nvidia\.com/gpu\.deploy\.dcgm-exporter}')
if [ "${?}" != "0" ]; then
	echo "Unable to get the value of the 'nvidia.com/gpu.deploy.dcgm-exporter' label"
	exit_failed
fi
echo "Current value of 'nvidia.com/gpu.deploy.dcgm-exporter=${DCGM_EXPORTER_DEPLOYED}'"

echo "Getting current value of the 'nvidia.com/gpu.deploy.dcgm' node label"
DCGM_DEPLOYED=$(kubectl get nodes ${NODE_NAME} -o=jsonpath='{$.metadata.labels.nvidia\.com/gpu\.deploy\.dcgm}')
if [ "${?}" != "0" ]; then
	echo "Unable to get the value of the 'nvidia.com/gpu.deploy.dcgm' label"
	exit_failed
fi
echo "Current value of 'nvidia.com/gpu.deploy.dcgm=${DCGM_DEPLOYED}'"

echo "Getting current value of the 'nvidia.com/gpu.deploy.nvsm' node label"
NVSM_DEPLOYED=$(kubectl get nodes ${NODE_NAME} -o=jsonpath='{$.metadata.labels.nvidia\.com/gpu\.deploy\.nvsm}')
if [ "${?}" != "0" ]; then
	echo "Unable to get the value of the 'nvidia.com/gpu.deploy.nvsm' label"
	exit_failed
fi
echo "Current value of 'nvidia.com/gpu.deploy.nvsm=${NVSM_DEPLOYED}'"

echo "Asserting that the requested configuration is present in the configuration file"
nvidia-mig-parted assert --valid-config -f ${MIG_CONFIG_FILE} -c ${SELECTED_MIG_CONFIG}
if [ "${?}" != "0" ]; then
	echo "Unable to validate the selected MIG configuration"
	exit_failed
fi

echo "Getting current value of the 'nvidia.com/mig.config.state' node label"
STATE=$(kubectl get node "${NODE_NAME}" -o=jsonpath='{.metadata.labels.nvidia\.com/mig\.config\.state}')
if [ "${?}" != "0" ]; then
	echo "Unable to get the value of the 'nvidia.com/mig.config.state' label"
	exit_failed
fi
echo "Current value of 'nvidia.com/mig.config.state=${STATE}'"

echo "Checking if the selected MIG config is currently applied or not"
nvidia-mig-parted assert -f ${MIG_CONFIG_FILE} -c ${SELECTED_MIG_CONFIG}
if [ "${?}" = "0" ]; then
	exit_success
fi

if [ "${HOST_ROOT_MOUNT}" != "" ] && [ "${HOST_MIG_MANAGER_STATE_FILE}" != "" ]; then
	if [ -f "${HOST_ROOT_MOUNT}/${HOST_MIG_MANAGER_STATE_FILE}" ]; then
		echo "Persisting ${SELECTED_MIG_CONFIG} to ${HOST_MIG_MANAGER_STATE_FILE}"
		host_persist_config
		if [ "${?}" != "0" ]; then
			echo "Unable to persist ${SELECTED_MIG_CONFIG} to ${HOST_MIG_MANAGER_STATE_FILE}"
			exit_failed
		fi
	fi
fi

echo "Checking if the MIG mode setting in the selected config is currently applied or not"
echo "If the state is 'rebooting', we expect this to always return true"
nvidia-mig-parted assert --mode-only -f ${MIG_CONFIG_FILE} -c ${SELECTED_MIG_CONFIG}
if [ "${?}" != "0" ]; then
	if [ "${STATE}" = "rebooting" ]; then
		echo "MIG mode change did not take effect after rebooting"
		exit_failed
	fi
	if [ "${WITH_SHUTDOWN_HOST_GPU_CLIENTS}" = "true" ]; then
		HOST_GPU_CLIENT_SERVICES+=(${HOST_KUBELET_SERVICE})
	fi
	MIG_MODE_CHANGE_REQUIRED="true"
fi

echo "Changing the 'nvidia.com/mig.config.state' node label to 'pending'"
kubectl label --overwrite  \
	node ${NODE_NAME} \
	nvidia.com/mig.config.state="pending"
if [ "${?}" != "0" ]; then
	echo "Unable to set the value of 'nvidia.com/mig.config.state' to 'pending'"
	exit_failed
fi

echo "Shutting down all GPU clients in Kubernetes by disabling their component-specific nodeSelector labels"
kubectl label --overwrite \
	node ${NODE_NAME} \
	nvidia.com/gpu.deploy.device-plugin=$(maybe_set_paused ${PLUGIN_DEPLOYED}) \
	nvidia.com/gpu.deploy.gpu-feature-discovery=$(maybe_set_paused ${GFD_DEPLOYED}) \
	nvidia.com/gpu.deploy.dcgm-exporter=$(maybe_set_paused ${DCGM_EXPORTER_DEPLOYED}) \
	nvidia.com/gpu.deploy.dcgm=$(maybe_set_paused ${DCGM_DEPLOYED}) \
	nvidia.com/gpu.deploy.nvsm=$(maybe_set_paused ${NVSM_DEPLOYED})
if [ "${?}" != "0" ]; then
	echo "Unable to tear down GPU client pods by setting their daemonset labels"
	exit_failed
fi

echo "Waiting for the device-plugin to shutdown"
kubectl wait --for=delete pod \
	--timeout=5m \
	--field-selector "spec.nodeName=${NODE_NAME}" \
	-n "${DEFAULT_GPU_CLIENTS_NAMESPACE}" \
	-l app=nvidia-device-plugin-daemonset

echo "Waiting for gpu-feature-discovery to shutdown"
kubectl wait --for=delete pod \
	--timeout=5m \
	--field-selector "spec.nodeName=${NODE_NAME}" \
	-n "${DEFAULT_GPU_CLIENTS_NAMESPACE}" \
	-l app=gpu-feature-discovery

echo "Waiting for dcgm-exporter to shutdown"
kubectl wait --for=delete pod \
	--timeout=5m \
	--field-selector "spec.nodeName=${NODE_NAME}" \
	-n "${DEFAULT_GPU_CLIENTS_NAMESPACE}" \
	-l app=nvidia-dcgm-exporter

echo "Waiting for dcgm to shutdown"
kubectl wait --for=delete pod \
	--timeout=5m \
	--field-selector "spec.nodeName=${NODE_NAME}" \
	-n "${DEFAULT_GPU_CLIENTS_NAMESPACE}" \
	-l app=nvidia-dcgm

echo "Removing the cuda-validator pod"
kubectl delete pod \
	--field-selector "spec.nodeName=${NODE_NAME}" \
	-n "${DEFAULT_GPU_CLIENTS_NAMESPACE}" \
	-l app=nvidia-cuda-validator

echo "Removing the plugin-validator pod"
kubectl delete pod \
	--field-selector "spec.nodeName=${NODE_NAME}" \
	-n "${DEFAULT_GPU_CLIENTS_NAMESPACE}" \
	-l app=nvidia-device-plugin-validator

if [ "${WITH_SHUTDOWN_HOST_GPU_CLIENTS}" = "true" ]; then
	echo "Shutting down all GPU clients on the host by stopping their systemd services"
	host_stop_systemd_services
	if [ "${?}" != "0" ]; then
		echo "Unable to shutdown GPU clients on host by stopping their systemd services"
		exit_failed
	fi
	if [ "${MIG_MODE_CHANGE_REQUIRED}" = "true" ]; then
		# This is a hack to accommodate for observed behaviour. Once we shut
		# down the above services, there appears to be some settling time
		# before we are able to reconnect to the fabric-manager to run the
		# required GPU reset when changing MIG mode. It is unknown why this
		# problem only appears when shutting down systemd services on the host
		# with pre-installed drivers, and not when running with operator
		# managed drivers.
		sleep 30
	fi
fi

echo "Applying the MIG mode change from the selected config to the node (and double checking it took effect)"
echo "If the -r option was passed, the node will be automatically rebooted if this is not successful"
nvidia-mig-parted -d apply --mode-only -f ${MIG_CONFIG_FILE} -c ${SELECTED_MIG_CONFIG}
nvidia-mig-parted -d assert --mode-only -f ${MIG_CONFIG_FILE} -c ${SELECTED_MIG_CONFIG}
if [ "${?}" != "0" ] && [ "${WITH_REBOOT}" = "true" ]; then
	echo "Changing the 'nvidia.com/mig.config.state' node label to 'rebooting'"
	kubectl label --overwrite  \
		node ${NODE_NAME} \
		nvidia.com/mig.config.state="rebooting"
	if [ "${?}" != "0" ]; then
		echo "Unable to set the value of 'nvidia.com/mig.config.state' to 'rebooting'"
		echo "Exiting so as not to reboot multiple times unexpectedly"
		exit_failed
	fi
	chroot ${HOST_ROOT_MOUNT} reboot
	exit 0
fi

echo "Applying the selected MIG config to the node"
nvidia-mig-parted -d apply -f ${MIG_CONFIG_FILE} -c ${SELECTED_MIG_CONFIG}
if [ "${?}" != "0" ]; then
	exit_failed
fi

if [ "${WITH_SHUTDOWN_HOST_GPU_CLIENTS}" = "true" ]; then
	echo "Restarting all GPU clients previously shutdown on the host by restarting their systemd services"
	NO_RESTART_HOST_SYSTEMD_SERVICES_ON_EXIT=true
	host_start_systemd_services
	if [ "${?}" != "0" ]; then
		echo "Unable to restart GPU clients on host by restarting their systemd services"
		exit_failed
	fi
fi

echo "Restarting all GPU clients previously shutdown in Kubernetes by reenabling their component-specific nodeSelector labels"
NO_RESTART_K8S_DAEMONSETS_ON_EXIT=true
kubectl label --overwrite \
	node ${NODE_NAME} \
	nvidia.com/gpu.deploy.device-plugin=$(maybe_set_true ${PLUGIN_DEPLOYED}) \
	nvidia.com/gpu.deploy.gpu-feature-discovery=$(maybe_set_true ${GFD_DEPLOYED}) \
	nvidia.com/gpu.deploy.dcgm-exporter=$(maybe_set_true ${DCGM_EXPORTER_DEPLOYED}) \
	nvidia.com/gpu.deploy.dcgm=$(maybe_set_true ${DCGM_DEPLOYED}) \
	nvidia.com/gpu.deploy.nvsm=$(maybe_set_true ${NVSM_DEPLOYED})
if [ "${?}" != "0" ]; then
	echo "Unable to bring up GPU client components by setting their daemonset labels"
	exit_failed
fi

echo "Restarting validator pod to re-run all validations"
kubectl delete pod \
	--field-selector "spec.nodeName=${NODE_NAME}" \
	-n "${DEFAULT_GPU_CLIENTS_NAMESPACE}" \
	-l app=nvidia-operator-validator

exit_success
