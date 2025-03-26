# CoFunc Artifact

This repository contains the artifact of the paper "Serverless Functions Made Confidential and Efficient with Split Containers".

The artifact includes the following components:
* The source code of CoFunc system, including the CVM OS code (`cvm_os`), the shadow container code (`shadow_container`) and the patches for the host Linux/QEMU (`patches`).
* The serverless functions utilized for the evaluation (`testcases/testcases`).
* The scripts for conducting the experiments (`scripts` and `testcases/tools`).

Users of this artifact can evaluate the performance of serverless functions under different container runtimes,
including split containers (CoFunc), CVM-based Kata Containers (Kata-CVM), and native lean containers (Native).

## Hardware dependencies

The artifact requires AMD CPUs with SEV-SNP support.
It has been tested on an EPYC-7T83 machine.
At least 96 CPU cores and 180GB of memory are required.
A test server is available for AE reviewers.
Please refer to the HotCRP submission for the SSH command and the private key.

## Software dependencies

The artifact works on an SEV-SNP version of the Linux kernel ([link](https://github.com/AMDESE/linux.git), branch `svsm-preview-hv-v2`), along with the modifications in `patches/linux.patch`.
The following dependencies are required for building the artifact and running the experiments: Docker, screen, Python 3 (with matplotlib, numpy, boto3, pandas, CouchDB) and gcc.

## Set-up

### Installation

For reviewers using the test server, the artifact is already installed, and no further steps are required.

For other users, the artifact can be installed with the following steps:

1. Download the host kernel code and apply the patch.

2. Build the kernel and reboot the machine with the new kernel. Ensure that cgroup v2 is enabled with the following kernel parameter:

```
systemd.unified_cgroup_hierarchy=1
```

3. Build CVM OS, shadow container, serverless functions and some other components with the script `scripts/build.sh`.

4. Enable transparent huge pages with the following command.

```Bash
echo always | sudo tee /sys/kernel/mm/transparent_hugepage/shmem_enabled
```

4. Create tap devices for Kata Containers with the following command. Experiment (E1) only requires one tap device, while experiment (E2) requires 200 tap devices.

```Bash
sudo scripts/init_tap.sh [physical NIC name] [number of tap devices]
```

<!-- 5. Fill the configuration file `config.json` with the IP of the host machine (`host_ip` field) and a static IP in your local network for Kata-CVM containers (`cntr_ip` field). -->

### Basic Test

Run the script `scripts/run_simple.sh`, which executes a serverless function using split container (without lean container optimization).
The script will output the function's running time as follows.

```
{
    "timestamp": 1739355161.0195742,
    "t_boot": 1.0877048969268799,
    "t_exec": 0.6204202175140381
}
```

## Evaluation Workflow

### Major Claims

(C1): For the 28 evaluated functions, CoFunc demonstrates significant performance improvements (up to 60x) compared with Kata-CVM, while incurring <14% performance overhead compared with Native. This is proven by the experiment (E1) described in Section 7.1, whose results are illustrated in Figure 11.

(C2): CoFunc outperforms Kata-CVM on FINRA application by 31x when 200 auditing functions start concurrently. This is proven by the experiment (E2) described in Section 7.4 whose results are reported in Section 7.4.

### Experiments

(E1): [1.5 compute-hours] Evaluate the end-to-end latency of handling a single request for the functions with CVM, Kata-CVM, and Native.

Run the script `scripts/run_fig11.sh`. This script executes the functions with different runtimes and outputs the latencies to the `log` directory. The script will generate a table at `plots/fig11.txt` that contains the function latencies and the overhead/optimization of CoFunc compared with Native/Kata-CVM. Additionally, the script will generate a figure at `plots/fig11.pdf`, which can be compared with Figure 11.

(E2): [10 compute-minutes] Evaluate the end-to-end latency of FINRA application with 200 concurrent auditing functions using CoFunc and Kata-CVM.

Run the script `scripts/run_finra.sh`. This script executes FINRA application with different runtimes and outputs the latencies to the `log` directory. The end-to-end application latencies and the optimization of CoFunc compared with Kata-CVM can be found in `plots/finra.txt`.

Before running the experiments, the `plots` directories contain the expected results generated on the authors' machine. New experiments will overwrite these data.
