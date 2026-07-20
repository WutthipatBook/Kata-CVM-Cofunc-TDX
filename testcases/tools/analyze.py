#!/bin/python
import json
import time
import argparse


parser = argparse.ArgumentParser()
parser.add_argument("-l", "--log")
args = parser.parse_args()


mode = ""
data = {}
with open("exec_log", "r") as log_file:
    for line in log_file:
        if line.startswith("t_"):
            tag, val = line[:-1].split()
            if tag in data:
                data[tag] = max(data[tag], float(val))
            else:
                data[tag] = float(val)
        elif line.startswith("dsys_") or line.startswith("io_") or line.startswith("n_"):
            tag, val = line[:-1].split()
            data[tag] = int(val)
        elif line.startswith("mode"):
            mode = line.strip().split()[1]


def report(result, log_filename):
    if log_filename:
        with open(log_filename, "a") as log:
            log.write(f"{json.dumps(result)}\n")
    
    print("\n---------------------------------\n")
    print(json.dumps(result, indent=4))


result = {"timestamp": time.time()}

def handle_others():
    global result, data
    for key in data:
        if "t_end" in key:
            result["t_e2e"] = data["t_end"] - data["t_begin"]
    if len(result) > 1:
        report(result, args.log)
        exit(0)

    result["t_runc_init"] = data["t_runc_init"] - data["t_begin"]
    if "t_sc_init" in data:
        result["t_sc_init"] = data["t_sc_init"] - data["t_shadow_begin"] - data["t_sc_init_overhead"] / 1000000000
        result["t_import"] = data["t_import_done"] - data["t_sc_init"]
    elif "t_fork_begin" in data:
        result["t_import"] = data["t_import_done"] - data["t_fork_begin"]
    else:
        result["t_import"] = data["t_import_done"] - data["t_runc_init"]
    # if "t_network" in data:
    #     result["t_network"] = data["t_network"]
    #     result["t_exec"] = data["t_func_done"] - data["t_import_done"] - data["t_network"]
    # else:
    #     result["t_exec"] = data["t_func_done"] - data["t_import_done"]
    if "t_redirect,import_done" in data:
        result["t_redirect,exec"] = (data["t_redirect,func_done"] - data["t_redirect,import_done"]) / 10**9
    result["t_exec"] = data["t_func_done"] - data["t_import_done"]
    result["t_other,import"] = result["t_import"]
    result["t_other,exec"] = result["t_exec"]
    if "t_sc_init" in data:
    #     result["dsys_cnt_lib"] = data["dsys_cnt_lib"]
    #     result["dsys_cnt_tmp"] = data["dsys_cnt_tmp"]
    #     result["dsys_cnt_net"] = data["dsys_cnt_net"]
    #     result["dsys_cnt_other"] = data["dsys_cnt_all"] - data["dsys_cnt_lib"] - data["dsys_cnt_tmp"] - data["dsys_cnt_net"]
    #     result["io_cnt_lib"] = data["io_cnt_lib"]
    #     result["io_cnt_tmp"] = data["io_cnt_tmp"]
    #     result["io_cnt_net"] = data["io_cnt_net"]
        for s in ["t_delegate", "t_attest", "t_encrypt", "t_accept"]:
            result[f"{s},import"] = data[f"{s},import_done"] / 10**9
            result[f"{s},exec"] = (data[f"{s},func_done"] - data[f"{s},import_done"]) / 10**9
            result["t_other,import"] -= result[f"{s},import"]
            result["t_other,exec"] -= result[f"{s},exec"]


def handle_lean_fork():
    result["t_boot"] = data["t_import_done"] - data["t_fork_begin"]
    result["t_exec"] = data["t_func_done"] - data["t_import_done"]
    result["t_e2e"] = data["t_func_done"] - data["t_fork_begin"]


def handle_lean_launch():
    result["t_boot"] = data["t_import_done"] - data["t_launch_begin"]
    result["t_exec"] = data["t_func_done"] - data["t_import_done"]
    result["t_e2e"] = data["t_func_done"] - data["t_launch_begin"]


def handle_lean_sc_fork():
    result["t_boot_lean"] = data["t_shadow_begin"] - data["t_launch_begin"]
    result["t_boot_sc"] = data["t_sc_init"] - data["t_shadow_begin"]
    result["t_boot_func"] = data["t_import_done"] - data["t_sc_init"]
    result["t_exec"] = data["t_func_done"] - data["t_import_done"]
    result["t_e2e"] = data["t_func_done"] - data["t_launch_begin"]
    for key in ["n_hcalls_exec", "n_cow"]:
        result[key] = data[key]
    for key in ["t_encrypt_exec", "t_grant_exec", "t_delegate_exec", "t_attest_import", "t_grant_import", "t_delegate_import"]:
        result[key] = data[key] / 10 ** 9


def handle_lean_sc_launch():
    result["t_boot"] = data["t_import_done"] - data["t_launch_begin"]
    result["t_exec"] = data["t_func_done"] - data["t_import_done"]
    result["t_e2e"] = data["t_func_done"] - data["t_launch_begin"]
    for key in ["n_hcalls_exec", "n_cow"]:
        result[key] = data[key]
    for key in ["t_encrypt_exec", "t_grant_exec", "t_delegate_exec", "t_attest_import", "t_grant_import", "t_delegate_import"]:
        result[key] = data[key] / 10 ** 9


def handle_kata_launch():
    result["t_boot_cntr"] = data["t_import_begin"] - data["t_launch_begin"]
    result["t_boot_func"] = data["t_import_done"] - data["t_import_begin"]
    result["t_exec"] = data["t_func_done"] - data["t_import_done"]
    result["t_e2e"] = data["t_func_done"] - data["t_launch_begin"]


def handle_runc_sc():
    result["t_boot"] = data["t_import_done"] - data["t_begin"]
    result["t_exec"] = data["t_func_done"] - data["t_import_done"]
    for key in ["t_encrypt_exec", "t_attest_import", "t_grant_import", "t_delegate_import"]:
        result[key] = data[key] / 10 ** 9


def handle_runc_linux_fork():
    result["t_boot"] = data["t_import_done"] - data["t_fork_begin"]


if mode == "lean-fork":
    handle_lean_fork()
elif mode == "lean-launch":
    handle_lean_launch()
elif mode == "lean-sc-fork":
    handle_lean_sc_fork()
elif mode == "lean-sc-launch":
    handle_lean_sc_launch()
elif mode == "kata-launch":
    handle_kata_launch()
elif mode == "runc-sc":
    handle_runc_sc()
elif mode == "runc-linux-fork":
    handle_runc_linux_fork()
else:
    handle_others()


report(result, args.log)

# print("RunC Init: {}".format(data["t_runc_init"] - data["t_begin"]))
# if "t_sc_init" in data:
#     print("Split Container Init: {}".format(data["t_sc_init"] - data["t_runc_init"]))
#     print("Import Libraries: {}".format(data["t_import_done"] - data["t_sc_init"]))
# else:
#     print("Import Libraries: {}".format(data["t_import_done"] - data["t_runc_init"]))
# print("Function Network: {}".format(data["t_network"]))
# print("Function Exec: {}".format(data["t_func_done"] - data["t_import_done"] - data["t_network"]))
# if "t_sc_init" in data:
#     print("Delegated Syscalls (Code): {}".format(data["dsys_cnt_lib"]))
#     print("Delegated Syscalls (Tmpfs): {}".format(data["dsys_cnt_tmp"]))
#     print("Delegated Syscalls (Network): {}".format(data["dsys_cnt_net"]))
#     print("Delegated Syscalls (Other): {}".format(data["dsys_cnt_all"] - data["dsys_cnt_lib"] - data["dsys_cnt_tmp"] - data["dsys_cnt_net"]))
#     print("IO Data (Code): {}".format(data["io_cnt_lib"]))
#     print("IO Data (Tmpfs): {}".format(data["io_cnt_tmp"]))
#     print("IO Data (Network): {}".format(data["io_cnt_net"]))


