import sys, ctypes, time, os, json, sc
import urllib.parse, urllib.request
libc = ctypes.CDLL(None)
sys.dont_write_bytecode = True

SYS_SC_SNAPSHOT       = 0x1000
SYS_SC_PRINT_STAT     = 0x1001
SYS_SC_DEFER_ENCRYPT  = 0x1003
SYS_SC_GET_STAT       = 0x1004

STAT_N_HCALLS   = 0x1
STAT_N_COWS     = 0x2
STAT_T_ATTEST   = 0x3
STAT_T_ENCRYPT  = 0x4
STAT_T_GRANT    = 0x5
STAT_T_DELEGATE = 0x6


def get_param(fn_name):
    data = urllib.parse.urlencode({"fn_name": fn_name})
    data = data.encode('ascii')
    req = urllib.request.Request('http://127.0.0.1:8888/get_param', data)
    with urllib.request.urlopen(req) as resp:
        data = resp.read()
    data = data.replace(b'hostname', b'127.0.0.1')
    return json.loads(data)


def set_retval(fn_name, retval):
    data = urllib.parse.urlencode({"fn_name": fn_name, "retval": json.dumps(retval)})
    data = data.encode('ascii')
    req = urllib.request.Request('http://127.0.0.1:8888/set_retval', data)
    with urllib.request.urlopen(req) as resp:
        data = resp.read()
    assert data == b'OK'


with open("/func/prewarm.py") as file:
    exec(file.read())


def criu_snapshot():
    flag = 0
    with open("/criu/restore_flag", "r") as file:
        while not flag:
            file.seek(0, 0)
            flag = int(file.read())


t_fork_begin = None
if len(sys.argv) == 1:
    pass
elif sys.argv[1] == "--sc-snapshot":
    libc.syscall(SYS_SC_SNAPSHOT)
elif sys.argv[1] == "--criu-snapshot":
    print("criu checkpoint")
    criu_snapshot()
elif sys.argv[1] == "--linux-fork":
    t_fork_begin = time.time()
    if os.fork():
        os.wait()
        os._exit(0)
elif sys.argv[1] == "--lean-fork":
    assert len(sys.argv) == 3
    name = sys.argv[2] + "_1"
    t_fork_begin = time.time()
    pid = sc.fork_lean_container(name, f"/root/.rootfs/{name}")
    if pid:
        os.wait()
        os._exit(0)

with open("/func/execute.py") as file:
    fn_code = file.read()

t_attest_after_import = libc.syscall(SYS_SC_GET_STAT, STAT_T_ATTEST)
t_import_done = time.time()

t_network = 0
# libc.syscall(SYS_SC_PRINT_STAT, b"import_done\0")

# libc.syscall(SYS_SC_DEFER_ENCRYPT, 1)
n_hcalls_before_exec = libc.syscall(SYS_SC_GET_STAT, STAT_N_HCALLS)
t_encrypt_before_exec = libc.syscall(SYS_SC_GET_STAT, STAT_T_ENCRYPT)
t_grant_before_exec = libc.syscall(SYS_SC_GET_STAT, STAT_T_GRANT)
t_delegate_before_exec = libc.syscall(SYS_SC_GET_STAT, STAT_T_DELEGATE)
exec(fn_code)
param = get_param(fn_name)
retval = handler(param)
set_retval(fn_name, retval)
n_hcalls_after_exec = libc.syscall(SYS_SC_GET_STAT, STAT_N_HCALLS)
t_encrypt_after_exec = libc.syscall(SYS_SC_GET_STAT, STAT_T_ENCRYPT)
t_grant_after_exec = libc.syscall(SYS_SC_GET_STAT, STAT_T_GRANT)
t_delegate_after_exec = libc.syscall(SYS_SC_GET_STAT, STAT_T_DELEGATE)
n_cow = libc.syscall(SYS_SC_GET_STAT, STAT_N_COWS)
# libc.syscall(SYS_SC_DEFER_ENCRYPT, 0)

t_func_done = time.time()

# libc.syscall(SYS_SC_PRINT_STAT, b"func_done\0")
print(f"t_import_done {t_import_done}")
# print(f"t_network {t_network}")
print(f"t_func_done {t_func_done}")
if t_fork_begin is not None:
    print(f"t_fork_begin {t_fork_begin}")
if n_hcalls_before_exec >= 0:
    print(f"n_hcalls_exec {n_hcalls_after_exec - n_hcalls_before_exec}")
    print(f"t_encrypt_exec {t_encrypt_after_exec - t_encrypt_before_exec}")
    print(f"t_grant_exec {t_grant_after_exec - t_grant_before_exec}")
    print(f"t_delegate_exec {t_delegate_after_exec - t_delegate_before_exec}")
    print(f"t_attest_import {t_attest_after_import}")
    print(f"t_grant_import {t_grant_before_exec}")
    print(f"t_delegate_import {t_delegate_before_exec}")
    print(f"n_cow {n_cow}")
