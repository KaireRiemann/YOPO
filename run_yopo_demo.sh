#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER="${YOPO_CONTAINER:-ros1_noetic}"
MASTER_URI="${YOPO_ROS_MASTER_URI:-http://127.0.0.1:11312}"
LOG_DIR="${YOPO_LOG_DIR:-/tmp/yopo_run}"
TRIAL="${YOPO_TRIAL:-1}"
EPOCH="${YOPO_EPOCH:-50}"

USE_RVIZ=1
DETACHED=0
USE_GPU_YOPO=0
MODE="start"

usage() {
  cat <<EOF
Usage:
  ./run_yopo_demo.sh [options]

Options:
  --no-rviz       Start controller/simulator/YOPO without RViz.
  --detached      Start everything and exit instead of tailing logs.
  --gpu-yopo      Do not disable CUDA for the ROS-side YOPO planner. This requires a compatible PyTorch inside the ROS container, not only .venv_gpu.
  --stop          Stop the YOPO demo processes started on ${MASTER_URI}.
  --status        Show YOPO demo nodes, topics, and processes.
  -h, --help      Show this help.

Environment overrides:
  YOPO_CONTAINER       Docker container name. Default: ${CONTAINER}
  YOPO_ROS_MASTER_URI  ROS master URI. Default: ${MASTER_URI}
  YOPO_LOG_DIR         Log directory inside the container. Default: ${LOG_DIR}
  YOPO_TRIAL           Model trial number. Default: ${TRIAL}
  YOPO_EPOCH           Model epoch number. Default: ${EPOCH}
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-rviz)
      USE_RVIZ=0
      ;;
    --detached)
      DETACHED=1
      ;;
    --gpu-yopo)
      USE_GPU_YOPO=1
      ;;
    --stop)
      MODE="stop"
      ;;
    --status)
      MODE="status"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
  shift
done

container_bash() {
  docker exec "${CONTAINER}" bash -lc "$1"
}

ensure_container() {
  if ! docker ps --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
    echo "Docker container '${CONTAINER}' is not running." >&2
    echo "Start it first, or set YOPO_CONTAINER to the ROS1 container name." >&2
    exit 1
  fi
}

stop_demo() {
  echo "Stopping YOPO demo on ${MASTER_URI}..."
  container_bash "
    export ROS_MASTER_URI='${MASTER_URI}'
    source /opt/ros/noetic/setup.bash
    rosnode kill /yopo_net /sensor_simulator_node /network_controller_node /quadrotor_simulator_so3 2>/dev/null || true
    pkill -INT -f '[t]est_yopo_ros.py --trial=.*--epoch=.*' 2>/dev/null || true
    pkill -INT -f '[s]ensor_simulator/sensor_simulator_cuda' 2>/dev/null || true
    pkill -INT -f '[s]imulator_attitude_control.launch' 2>/dev/null || true
    pkill -INT -f '[r]viz -d yopo.rviz' 2>/dev/null || true
    sleep 2
    pkill -TERM -f '[t]est_yopo_ros.py --trial=.*--epoch=.*' 2>/dev/null || true
    pkill -TERM -f '[s]ensor_simulator/sensor_simulator_cuda' 2>/dev/null || true
    pkill -TERM -f '[s]imulator_attitude_control.launch' 2>/dev/null || true
    pkill -TERM -f '[r]viz -d yopo.rviz' 2>/dev/null || true
    true
  " || true
}

status_demo() {
  container_bash "
    export ROS_MASTER_URI='${MASTER_URI}'
    source /opt/ros/noetic/setup.bash
    echo '== ROS nodes =='
    rosnode list 2>/dev/null | sort || echo 'ROS master is not reachable.'
    echo
    echo '== Key topics =='
    rostopic list 2>/dev/null | egrep '(^/depth_image$|^/lidar_points$|^/sim/odom$|^/so3_control/pos_cmd$|^/yopo_net)' | sort || true
    echo
    echo '== Processes =='
    ps -eo pid,etime,pcpu,pmem,cmd | egrep 'test_yopo_ros|sensor_simulator_cuda|simulator_attitude_control|rviz -d yopo.rviz' | grep -v egrep || true
  "
}

wait_for_node() {
  local node="$1"
  local timeout="${2:-30}"
  for _ in $(seq 1 "${timeout}"); do
    if container_bash "export ROS_MASTER_URI='${MASTER_URI}'; source /opt/ros/noetic/setup.bash; rosnode list 2>/dev/null | grep -qx '${node}'"; then
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for ROS node ${node}." >&2
  return 1
}

wait_for_topic() {
  local topic="$1"
  local timeout="${2:-30}"
  for _ in $(seq 1 "${timeout}"); do
    if container_bash "export ROS_MASTER_URI='${MASTER_URI}'; source /opt/ros/noetic/setup.bash; rostopic list 2>/dev/null | grep -qx '${topic}'"; then
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for ROS topic ${topic}." >&2
  return 1
}

launch_controller() {
  echo "Starting controller and quadrotor dynamics..."
  docker exec -d "${CONTAINER}" bash -lc "
    export ROS_MASTER_URI='${MASTER_URI}'
    export PATH=/usr/local/cuda/bin:\$PATH
    export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\${LD_LIBRARY_PATH:-}
    source /opt/ros/noetic/setup.bash
    source /root/ws/YOPO/Controller/devel/setup.bash
    cd /root/ws/YOPO/Controller
    exec roslaunch so3_quadrotor_simulator simulator_attitude_control.launch > '${LOG_DIR}/controller.log' 2>&1
  "
  wait_for_node "/quadrotor_simulator_so3" 30
  wait_for_node "/network_controller_node" 30
}

launch_sensor() {
  echo "Starting CUDA sensor simulator..."
  docker exec -d "${CONTAINER}" bash -lc "
    export ROS_MASTER_URI='${MASTER_URI}'
    export PATH=/usr/local/cuda/bin:\$PATH
    export LD_LIBRARY_PATH=/usr/local/cuda/lib64:\${LD_LIBRARY_PATH:-}
    source /opt/ros/noetic/setup.bash
    source /root/ws/YOPO/Simulator/devel/setup.bash
    cd /root/ws/YOPO/Simulator
    exec rosrun sensor_simulator sensor_simulator_cuda > '${LOG_DIR}/sensor.log' 2>&1
  "
  wait_for_node "/sensor_simulator_node" 60
  wait_for_topic "/depth_image" 60
}

launch_yopo() {
  echo "Starting YOPO planner..."
  local cuda_line="export CUDA_VISIBLE_DEVICES="
  if [[ "${USE_GPU_YOPO}" -eq 1 ]]; then
    cuda_line="true"
  fi
  docker exec -d "${CONTAINER}" bash -lc "
    export ROS_MASTER_URI='${MASTER_URI}'
    ${cuda_line}
    source /opt/ros/noetic/setup.bash
    source /root/ws/YOPO/Controller/devel/setup.bash
    source /root/yopo_venv/bin/activate
    cd /root/ws/YOPO/YOPO
    exec python -u test_yopo_ros.py --trial='${TRIAL}' --epoch='${EPOCH}' > '${LOG_DIR}/yopo.log' 2>&1
  "
  wait_for_node "/yopo_net" 90
  wait_for_topic "/so3_control/pos_cmd" 90
}

launch_rviz() {
  if [[ "${USE_RVIZ}" -eq 0 ]]; then
    return 0
  fi
  echo "Starting RViz..."
  docker exec -d "${CONTAINER}" bash -lc "
    export ROS_MASTER_URI='${MASTER_URI}'
    source /opt/ros/noetic/setup.bash
    source /root/ws/YOPO/Controller/devel/setup.bash
    source /root/ws/YOPO/Simulator/devel/setup.bash
    cd /root/ws/YOPO/YOPO
    exec rviz -d yopo.rviz > '${LOG_DIR}/rviz.log' 2>&1
  "
}

start_demo() {
  echo "Preparing YOPO demo on ${MASTER_URI}..."
  container_bash "mkdir -p '${LOG_DIR}' && rm -f '${LOG_DIR}'/*.log"
  stop_demo
  launch_controller
  launch_sensor
  launch_yopo
  launch_rviz
  echo
  echo "YOPO demo is running."
  echo "Logs are inside ${CONTAINER}:${LOG_DIR}"
  echo "Use './run_yopo_demo.sh --status' to inspect it."
  echo "Use './run_yopo_demo.sh --stop' to stop it."
}

ensure_container

case "${MODE}" in
  stop)
    stop_demo
    status_demo
    exit 0
    ;;
  status)
    status_demo
    exit 0
    ;;
  start)
    start_demo
    ;;
esac

if [[ "${DETACHED}" -eq 1 ]]; then
  exit 0
fi

cleanup_on_exit() {
  stop_demo
}

trap cleanup_on_exit INT TERM EXIT

echo
echo "Tailing logs. Press Ctrl+C to stop the demo."
container_bash "touch '${LOG_DIR}/controller.log' '${LOG_DIR}/sensor.log' '${LOG_DIR}/yopo.log' '${LOG_DIR}/rviz.log'; tail -n +1 -F '${LOG_DIR}/controller.log' '${LOG_DIR}/sensor.log' '${LOG_DIR}/yopo.log' '${LOG_DIR}/rviz.log'" || true
