if [ -f "${PWD}/run_uvm_suite.py" ]; then
    export HEVC_UVM_DIR=${PWD}
elif [ -f "${PWD}/../run_uvm_suite.py" ]; then
    export HEVC_UVM_DIR=$(cd "${PWD}/.." && pwd)
elif [ -f "${PWD}/uvm/run_uvm_suite.py" ]; then
    export HEVC_UVM_DIR=$(cd "${PWD}/uvm" && pwd)
else
    export HEVC_UVM_DIR=${PWD}
fi
export HEVC_ROOT_DIR=$(cd "${HEVC_UVM_DIR}/.." && pwd)
