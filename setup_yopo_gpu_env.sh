#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${YOPO_GPU_VENV:-${ROOT_DIR}/.venv_gpu}"
PYTHON_BIN="${YOPO_GPU_PYTHON:-python3}"
PYTORCH_INDEX="${YOPO_PYTORCH_INDEX:-https://download.pytorch.org/whl/cu130}"

echo "Creating YOPO GPU environment at: ${VENV_DIR}"
rm -rf "${VENV_DIR}"
if ! "${PYTHON_BIN}" -m venv "${VENV_DIR}" 2>/tmp/yopo_venv_error.log; then
  echo "python venv is unavailable; falling back to virtualenv."
  "${PYTHON_BIN}" -m virtualenv "${VENV_DIR}"
fi
source "${VENV_DIR}/bin/activate"

python -m pip install --upgrade pip setuptools wheel
python -m pip install torch==2.10.0 torchvision==0.25.0 torchaudio==2.10.0 --index-url "${PYTORCH_INDEX}"
python -m pip install -r "${ROOT_DIR}/YOPO/requirements-gpu.txt"

echo
echo "Verifying CUDA and YOPO forward pass..."
cd "${ROOT_DIR}/YOPO"
python - <<'PY'
import torch
import cv2
import scipy
import numpy as np
from policy.yopo_network import YopoNetwork
from policy.state_transform import StateTransform

print("torch:", torch.__version__)
print("torch cuda:", torch.version.cuda)
print("cuda available:", torch.cuda.is_available())
if not torch.cuda.is_available():
    raise SystemExit("CUDA is not available in this environment.")

print("gpu:", torch.cuda.get_device_name(0))
print("capability:", torch.cuda.get_device_capability(0))

x = torch.randn((1024, 1024), device="cuda")
y = x @ x
torch.cuda.synchronize()
print("cuda matmul ok:", tuple(y.shape), y.dtype)

print("cv2:", cv2.__version__, "scipy:", scipy.__version__, "numpy:", np.__version__)

policy = YopoNetwork().to("cuda")
state_dict = torch.load("saved/YOPO_1/epoch50.pth", map_location="cuda", weights_only=True)
policy.load_state_dict(state_dict)
policy.eval()

depth = torch.zeros((1, 1, 96, 160), dtype=torch.float32, device="cuda")
obs = torch.zeros((1, 9), dtype=torch.float32, device="cuda")
obs_input = StateTransform().prepare_input(obs).to("cuda")
with torch.inference_mode():
    endstate, score = policy(depth, obs_input)
torch.cuda.synchronize()
print("YOPO forward ok:", tuple(endstate.shape), tuple(score.shape))
PY

echo
echo "YOPO GPU environment is ready."
echo "Activate it with:"
echo "  source ${VENV_DIR}/bin/activate"
