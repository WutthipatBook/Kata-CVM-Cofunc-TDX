#define _GNU_SOURCE
#include <stdio.h>
#include <sched.h>
#include <fcntl.h>
#include <unistd.h>
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <errno.h>
#include <pthread.h>
#include <sys/uio.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <linux/io_uring.h>
#include "config.h"
#if defined(CONFIG_PLAT_INTEL_TDX)
#include "kvm_tdx.h"
#elif defined(CONFIG_PLAT_AMD_SEV)
#include "kvm_sev.h"
#endif
#include <sys/ioctl.h>
#include "split_container.h"

#define HPAGE_SIZE (1UL << 9 << 12)

#define MIN(x, y) ((x) < (y) ? (x) : (y))
#define MAX(x, y) ((x) > (y) ? (x) : (y))

#define ALIGN_DOWN(n, m) ((n) / (m) * (m))
#define ALIGN_UP(n, m) ALIGN_DOWN((n) + (m) - 1, (m))

#define __syscall(n, ...) ({ \
        long ret = syscall(n, ##__VA_ARGS__); \
        ret == -1 ? -errno : ret; \
})

#define debug(fmt, ...) //printf(fmt, ##__VA_ARGS__)

#define MAX_PTHREAD_CNT 32
pthread_t pthreads[MAX_PTHREAD_CNT];
static int pthread_cnt = 0;

#define MAX_POLLING_SHM_CNT 32
struct sc_shm *polling_shms[MAX_POLLING_SHM_CNT];
static int __polling_shm_cnt = 0;
static volatile int polling_shm_cnt = 0;

#define POLLING_VCPU_PIN        0
#define POLLING_HOST_PIN        2

static int kvm_dev_fd;
static int kvm_vm_fd;
static int kvm_vcpu_mmap_size;
static unsigned slot;
static unsigned long mem_size = 2048UL * 1024 * 1024; // fake
static int small_shared_pool = 0;
static unsigned long gpa;
static void *anon;
#if defined(CONFIG_PLAT_AMD_SEV)
static int memfd;
#endif
static int argc;
static char **argv;
static const char *mem_file = NULL;
static int enable_sync = 1;
static unsigned vm_slot_id = 0;

static int finish = 0;

static void pin(int cpu)
{
        cpu_set_t cpuset;

        CPU_ZERO(&cpuset);
        CPU_SET(cpu, &cpuset);

        int ret = sched_setaffinity(0, sizeof(cpuset), &cpuset);
        printf("pin: %s\n", ret ? "fail" : "success");
        sched_yield();
}

static double get_time(void)
{
        struct timespec tp;
        clock_gettime(CLOCK_REALTIME, &tp);
        return tp.tv_sec + tp.tv_nsec / 1000000000.0;
}

static void print_time(const char *str)
{ 
        printf("%s %f\n", str, get_time());
}

#if defined(CONFIG_PLAT_INTEL_TDX)
static long get_vmcall_op(struct kvm_run *run)
{
        return run->tdx.u.vmcall.subfunction;
}

static long get_vmcall_arg1(struct kvm_run *run)
{
        return run->tdx.u.vmcall.in_r12;
}

static long get_vmcall_arg2(struct kvm_run *run)
{
        return run->tdx.u.vmcall.in_r13;
}

static long get_vmcall_arg3(struct kvm_run *run)
{
        return run->tdx.u.vmcall.in_r14;
}

static void set_vmcall_ret(struct kvm_run *run, long ret)
{
        run->tdx.u.vmcall.out_r11 = ret;
}
#elif defined(CONFIG_PLAT_AMD_SEV)
static long get_vmcall_op(struct kvm_run *run)
{
        return run->hypercall.nr;
}

static long get_vmcall_arg1(struct kvm_run *run)
{
        return run->hypercall.args[0];
}

static long get_vmcall_arg2(struct kvm_run *run)
{
        return run->hypercall.args[1];
}

static long get_vmcall_arg3(struct kvm_run *run)
{
        return run->hypercall.args[2];
}

static void set_vmcall_ret(struct kvm_run *run, long ret)
{
        run->hypercall.ret = ret;
}
#endif


static void grant_mem(void)
{
        int ret;
#if defined(CONFIG_PLAT_INTEL_TDX)
        struct kvm_userspace_memory_region mem;
#elif defined(CONFIG_PLAT_AMD_SEV)
        struct kvm_userspace_memory_region2 mem;
#endif
        
        debug("[SC-H] grant_mem: slot=%u, GPA=0x%lx\n", slot, gpa);

#ifndef CONFIG_PLAT_AMD_SEV
        if (!mem_file) {
#endif
                anon = mmap(0, mem_size + HPAGE_SIZE, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
                if (anon == MAP_FAILED) {
                        perror("mmap anon");
                        exit(EXIT_FAILURE);
                }

                ret = madvise(anon, mem_size + HPAGE_SIZE, MADV_HUGEPAGE);
                if (ret < 0) {
                        perror("madvise");
                        exit(EXIT_FAILURE);
                }
#ifndef CONFIG_PLAT_AMD_SEV
        } else {
                int fd;
                
                fd = open(mem_file, O_RDWR);
                if (fd < 0) {
                        printf("%s\n", mem_file);
                        perror("open mem file");
                        exit(EXIT_FAILURE);
                }
                
                anon = mmap(0, mem_size, PROT_READ | PROT_WRITE,
                            MAP_SHARED | MAP_POPULATE, fd, 0);
                if (anon == MAP_FAILED) {
                        perror("mmap mem file");
                        exit(EXIT_FAILURE);
                }
        }
#endif

        anon = (void *)ALIGN_UP((unsigned long)anon, HPAGE_SIZE);

        mem.userspace_addr = (unsigned long)anon;
        mem.guest_phys_addr = gpa;
        mem.slot = slot;
        mem.flags = 0;
        mem.memory_size = mem_size;

#if defined(CONFIG_PLAT_AMD_SEV)
        memfd = syscall(451, 0); // __NR_memfd_restricted
        if (memfd < 0) {
                perror("create memfd");
                exit(EXIT_FAILURE);
        }
        
        mem.flags = KVM_MEM_PRIVATE;
        mem.restrictedmem_fd = memfd;
        mem.restrictedmem_offset = 0;
#endif

#if defined(CONFIG_PLAT_INTEL_TDX)
        ret = ioctl(kvm_vm_fd, KVM_SET_USER_MEMORY_REGION, &mem);
#elif defined(CONFIG_PLAT_AMD_SEV)
        ret = ioctl(kvm_vm_fd, KVM_SET_USER_MEMORY_REGION2, &mem);
#endif

        if (ret < 0) {
                perror("grant memory");
                exit(EXIT_FAILURE);
        }

        debug("[SC-H] grant_mem: HVA=%p\n", anon);
}

static void remove_mem(void)
{
        int ret;
#if defined(CONFIG_PLAT_INTEL_TDX)
        struct kvm_userspace_memory_region mem;
#elif defined(CONFIG_PLAT_AMD_SEV)
        struct kvm_userspace_memory_region2 mem;
#endif

        if (!slot) {
                return;
        }

        mem.userspace_addr = (unsigned long long)anon;
        mem.guest_phys_addr = gpa;
        mem.slot = slot;
        mem.flags = 0;
        mem.memory_size = 0;
#if defined(CONFIG_PLAT_AMD_SEV)
        mem.restrictedmem_fd = memfd;
        mem.restrictedmem_offset = 0;
#endif

#if defined(CONFIG_PLAT_INTEL_TDX)
        ret = ioctl(kvm_vm_fd, KVM_SET_USER_MEMORY_REGION, &mem);
#elif defined(CONFIG_PLAT_AMD_SEV)
        ret = ioctl(kvm_vm_fd, KVM_SET_USER_MEMORY_REGION2, &mem);
#endif

        if (ret < 0) {
                perror("remove memory");
                exit(EXIT_FAILURE);
        }

        debug("[SC-H] remove mem\n");
}

static void __assert(int x)
{
        if (!x) {
                debug("error!\n");
                remove_mem();
                exit(EXIT_FAILURE);
        }
}
#undef assert
#define assert __assert

double t_shadow_begin;
double t_sc_init;

static void handle_shm_req_get_arg(struct sc_shm *shm)
{
        int i;
        unsigned long offset, remain, n;

        // if (!getenv("SILENT")) {
        //         print_time("t_sc_init");
        //         printf("t_shadow_begin %f\n", t_shadow_begin);
        //         printf("t_sc_init_overhead %lu\n", shm->time);
        // }
        // printf("t: %f\n", get_time() - t_xxx);

        assert(argc <= SC_SHM_MAX_ARGC);
        shm->get_arg.argc = argc;
        
        offset = 0;
        remain = SC_SHM_MAX_DATA_LEN;
        for (i = 0; i < argc; i++) {
                n = strlen(argv[i]) + 1;
                assert(n <= remain);
                strcpy(shm->data + offset, argv[i]);
                shm->get_arg.argv[i] = offset;
                offset += n;
                remain -= n;
        }

        t_sc_init = get_time();
}

static void handle_shm_write(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_write,
                               shm->write.fd,
                               shm->data,
                               shm->write.count);
}

static void handle_shm_open(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_open,
                               shm->data,
                               shm->open.flags,
                               shm->open.mode);
}

static void handle_shm_read(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_read,
                               shm->read.fd,
                               shm->data,
                               shm->read.count);
}

static void handle_shm_pread(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_pread64,
                               shm->pread.fd,
                               shm->data,
                               shm->pread.count,
                               shm->pread.offset);
}

static void handle_shm_lseek(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_lseek,
                               shm->lseek.fd,
                               shm->lseek.offset,
                               shm->lseek.whence);
}

static void handle_shm_stat(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_stat,
                               shm->data,
                               shm->data);
}

static void handle_shm_lstat(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_lstat,
                               shm->data,
                               shm->data);
}

static void handle_shm_getdents64(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_getdents64,
                               shm->getdents64.fd,
                               shm->data,
                               shm->getdents64.count);
}

static void handle_shm_fstat(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_fstat,
                               shm->fstat.fd,
                               shm->data);
}

static void handle_shm_rename(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_rename,
                               shm->data + shm->rename.oldpath,
                               shm->data + shm->rename.newpath);
}

static void handle_shm_close(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_close,
                               shm->close.fd);
}

static void handle_shm_fcntl(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_fcntl,
                               shm->fcntl.fd,
                               shm->fcntl.cmd,
                               shm->fcntl.arg);
}

static void handle_shm_ioctl(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_ioctl,
                               shm->ioctl.fd,
                               shm->ioctl.request,
                               shm->data);
}

static void handle_shm_readlink(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_readlink,
                               shm->data,
                               shm->data,
                               shm->readlink.bufsiz);
}

static void handle_shm_mkdir(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_mkdir,
                               shm->data,
                               shm->mkdir.mode);
}

static void handle_shm_epoll_create1(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_epoll_create1,
                               shm->epoll_create1.flags);
}

static void handle_shm_sched_getaffinity(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_sched_getaffinity,
                               shm->sched_getaffinity.pid,
                               shm->sched_getaffinity.cpusetsize,
                               shm->data);
}

static void handle_shm_epoll_pwait(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_epoll_pwait,
                               shm->epoll_pwait.epfd,
                               shm->data,
                               shm->epoll_pwait.maxevents,
                               shm->epoll_pwait.timeout,
                               NULL);
}

static void handle_shm_epoll_ctl(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_epoll_ctl,
                               shm->epoll_ctl.epfd,
                               shm->epoll_ctl.op,
                               shm->epoll_ctl.fd,
                               shm->data);
}

static void handle_shm_pipe2(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_pipe2,
                               shm->pipe2.pipefd,
                               shm->pipe2.flags);
}

static void handle_shm_eventfd2(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_eventfd2,
                               shm->eventfd2.initval,
                               shm->eventfd2.flags);
}

static void handle_shm_capget(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_capget,
                               shm->data,
                               shm->data);
}

static void handle_shm_dup3(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_dup3,
                               shm->dup3.oldfd,
                               shm->dup3.newfd,
                               shm->dup3.flags);
}

static void handle_shm_statx(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_statx,
                               shm->statx.dirfd,
                               shm->data,
                               shm->statx.flags,
                               shm->statx.mask,
                               shm->data);
}

static void handle_shm_socket(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_socket,
                               shm->socket.domain,
                               shm->socket.type,
                               shm->socket.protocol);
}

static void handle_shm_connect(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_connect,
                               shm->connect.sockfd,
                               shm->data,
                               shm->connect.addrlen);
}

static void handle_shm_bind(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_bind,
                               shm->bind.sockfd,
                               shm->data,
                               shm->bind.addrlen);
}

static void handle_shm_shutdown(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_shutdown,
                               shm->shutdown.sockfd,
                               shm->shutdown.how);
}

static void handle_shm_setsockopt(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_setsockopt,
                               shm->setsockopt.sockfd,
                               shm->setsockopt.level,
                               shm->setsockopt.optname,
                               shm->data,
                               shm->setsockopt.optlen);
}

static void handle_shm_poll(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_poll,
                               shm->data,
                               shm->poll.nfds,
                               shm->poll.timeout);
}

static void handle_shm_recvfrom(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_recvfrom,
                               shm->recvfrom.sockfd,
                               shm->data + shm->recvfrom.addrlen,
                               shm->recvfrom.len,
                               shm->recvfrom.flags,
                               shm->data,
                               &shm->recvfrom.addrlen);
}

static void handle_shm_sendto(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_sendto,
                               shm->sendto.sockfd,
                               shm->data + shm->sendto.addrlen,
                               shm->sendto.len,
                               shm->sendto.flags,
                               shm->data,
                               shm->sendto.addrlen);
}

static void handle_shm_getcwd(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_getcwd,
                               shm->data,
                               shm->getcwd.size);
}

static void handle_shm_access(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_access,
                               shm->data,
                               shm->access.mode);
}

static void handle_shm_sched_setattr(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_sched_setattr,
                               shm->sched_getattr.pid,
                               shm->data,
                               shm->sched_setattr.flags);
}

static void handle_shm_sched_getattr(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_sched_getattr,
                               shm->sched_getattr.pid,
                               shm->data,
                               shm->sched_getattr.size,
                               shm->sched_getattr.flags);
}

static void handle_shm_ftruncate(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_ftruncate,
                               shm->ftruncate.fd,
                               shm->ftruncate.length);
}

static void handle_shm_umask(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_umask,
                               shm->umask.mask);
}

static void handle_shm_unlink(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_unlink,
                               shm->data);
}

static void handle_shm_getsockname(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_getsockname,
                               shm->getsockname.sockfd,
                               shm->data,
                               &shm->getsockname.addrlen);
}

static void handle_shm_getpeername(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_getpeername,
                               shm->getpeername.sockfd,
                               shm->data,
                               &shm->getpeername.addrlen);
}

static void handle_shm_getsockopt(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_getsockopt,
                               shm->getsockopt.sockfd,
                               shm->getsockopt.level,
                               shm->getsockopt.optname,
                               shm->data,
                               &shm->getsockopt.optlen);
}

static void handle_shm_clock_gettime(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_clock_gettime,
                               shm->clock_gettime.clk_id,
                               shm->data);
}

static void handle_shm_clock_getres(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_clock_getres,
                               shm->clock_getres.clk_id,
                               shm->data);
}

static void handle_shm_sched_setaffinity(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_sched_setaffinity,
                               shm->sched_setaffinity.pid,
                               shm->sched_setaffinity.cpusetsize,
                               shm->data);
}

static void handle_shm_sysinfo(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_sysinfo,
                               shm->data);
}

static void handle_shm_listen(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_listen,
                               shm->listen.sockfd,
                               shm->listen.backlog);
}

static void handle_shm_accept4(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_accept4,
                               shm->accpet4.sockfd,
                               shm->data,
                               &shm->accpet4.addrlen,
                               shm->accpet4.flags);
}

static void handle_shm_setitimer(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_setitimer,
                               shm->setitimer.which,
                               shm->data,
                               shm->data);
}

static void handle_shm_io_uring_enter(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_io_uring_enter,
                               shm->io_uring_enter.fd,
                               shm->io_uring_enter.to_submit,
                               shm->io_uring_enter.min_complete,
                               shm->io_uring_enter.flags,
                               NULL, 0);
}

static void handle_shm_chmod(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_chmod,
                               shm->data,
                               shm->chmod.mode);
}

static void handle_shm_times(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_times,
                               shm->data);
}

static void handle_shm_getuid(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_getuid);
}

static void handle_shm_geteuid(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_geteuid);
}

static void handle_shm_getgid(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_getgid);
}

static void handle_shm_getegid(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_getegid);
}

static void handle_shm_setuid(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_setuid, 0); // fake implementation
}

static void handle_shm_setgid(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_setgid,
                               shm->setgid.gid);
}

static void handle_shm_getgroups(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_getgroups,
                               shm->getgroups.size,
                               shm->data);
}

static void handle_shm_setgroups(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_setgroups,
                               shm->setgroups.size,
                               shm->data);
}

static void handle_shm_getpid(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_getpid);
}

static void handle_shm_dup2(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_dup2,
                               shm->dup2.oldfd,
                               shm->dup2.newfd);
}

static void handle_shm_rt_sigtimedwait(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_rt_sigtimedwait,
                               shm->data,
                               shm->data,
                               NULL,
                               shm->rt_sigtimedwait.sigsetsize);
}

static void handle_shm_sem_init(struct sc_shm *shm)
{
        int ret;
        sem_t *sem;

        sem = malloc(sizeof(*sem));
        if (sem == NULL) {
                goto out;
        }

        ret = sem_init(sem, shm->sem_init.pshared, shm->sem_init.value);
        if (ret < 0) {
                free(sem);
                sem = NULL;
        }

out:
        shm->ret = (long)sem;
}

static void handle_shm_sem_wait(struct sc_shm *shm)
{
        shm->ret = sem_wait(shm->sem_wait.sem);
}

static void handle_shm_sem_trywait(struct sc_shm *shm)
{
        shm->ret = sem_trywait(shm->sem_trywait.sem);
}

static void handle_shm_sem_timedwait(struct sc_shm *shm)
{
        struct timespec tp;
        struct timespec *delta;

        clock_gettime(CLOCK_MONOTONIC, &tp);
        delta = (struct timespec *)shm->data;
        tp.tv_nsec += delta->tv_nsec;
        tp.tv_sec += delta->tv_sec;
        tp.tv_sec += delta->tv_nsec / 1000000000UL;
        tp.tv_nsec %= 1000000000UL;

        shm->ret = sem_timedwait(shm->sem_timedwait.sem, &tp);
}

static void handle_shm_sem_post(struct sc_shm *shm)
{
        shm->ret = sem_post(shm->sem_post.sem);
}

static void handle_shm_dup(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_dup, shm->dup.oldfd);
}

static void handle_shm_select(struct sc_shm *shm)
{
        shm->ret = __syscall(SYS_select,
                             shm->select.nfds,
                             shm->data,
                             shm->data + sizeof(fd_set),
                             NULL, NULL);
}

static void __handle_request_with_shm(struct sc_shm *shm)
{
        struct timespec tp;
        unsigned long t0, t1;

        clock_gettime(CLOCK_MONOTONIC, &tp);
        t0 = tp.tv_sec * 1000000000UL + tp.tv_nsec;

        switch (shm->req) {
        case SC_SHM_REQ_GET_ARG:
                handle_shm_req_get_arg(shm);
                break;
        case SC_SHM_REQ_WRITE:
                handle_shm_write(shm);
                break;
        case SC_SHM_REQ_OPEN:
                handle_shm_open(shm);
                break;
        case SC_SHM_REQ_READ:
                handle_shm_read(shm);
                break;
        case SC_SHM_REQ_PREAD:
                handle_shm_pread(shm);
                break;
        case SC_SHM_REQ_LSEEK:
                handle_shm_lseek(shm);
                break;
        case SC_SHM_REQ_STAT:
                handle_shm_stat(shm);
                break;
        case SC_SHM_REQ_LSTAT:
                handle_shm_lstat(shm);
                break;
        case SC_SHM_REQ_GETDENTS64:
                handle_shm_getdents64(shm);
                break;
        case SC_SHM_REQ_FSTAT:
                handle_shm_fstat(shm);
                break;
        case SC_SHM_REQ_RENAME:
                handle_shm_rename(shm);
                break;
        case SC_SHM_REQ_CLOSE:
                handle_shm_close(shm);
                break;
        case SC_SHM_REQ_FCNTL:
                handle_shm_fcntl(shm);
                break;
        case SC_SHM_REQ_IOCTL:
                handle_shm_ioctl(shm);
                break;
        case SC_SHM_REQ_READLINK:
                handle_shm_readlink(shm);
                break;
        case SC_SHM_REQ_MKDIR:
                handle_shm_mkdir(shm);
                break;
        case SC_SHM_REQ_EPOLL_CREATE1:
                handle_shm_epoll_create1(shm);
                break;
        case SC_SHM_REQ_SCHED_GETAFFINITY:
                handle_shm_sched_getaffinity(shm);
                break;
        case SC_SHM_REQ_EPOLL_PWAIT:
                handle_shm_epoll_pwait(shm);
                break;
        case SC_SHM_REQ_EPOLL_CTL:
                handle_shm_epoll_ctl(shm);
                break;
        case SC_SHM_REQ_PIPE2:
                handle_shm_pipe2(shm);
                break;
        case SC_SHM_REQ_EVENTFD2:
                handle_shm_eventfd2(shm);
                break;
        case SC_SHM_REQ_CAPGET:
                handle_shm_capget(shm);
                break;
        case SC_SHM_REQ_DUP3:
                handle_shm_dup3(shm);
                break;
        case SC_SHM_REQ_STATX:
                handle_shm_statx(shm);
                break;
        case SC_SHM_REQ_SOCKET:
                handle_shm_socket(shm);
                break;
        case SC_SHM_REQ_CONNECT:
                handle_shm_connect(shm);
                break;
        case SC_SHM_REQ_BIND:
                handle_shm_bind(shm);
                break;
        case SC_SHM_REQ_SHUTDOWN:
                handle_shm_shutdown(shm);
                break;
        case SC_SHM_REQ_SETSOCKOPT:
                handle_shm_setsockopt(shm);
                break;
        case SC_SHM_REQ_POLL:
                handle_shm_poll(shm);
                break;
        case SC_SHM_REQ_RECVFROM:
                handle_shm_recvfrom(shm);
                break;
        case SC_SHM_REQ_SENDTO:
                handle_shm_sendto(shm);
                break;
        case SC_SHM_REQ_GETCWD:
                handle_shm_getcwd(shm);
                break;
        case SC_SHM_REQ_ACCESS:
                handle_shm_access(shm);
                break;
        case SC_SHM_REQ_SCHED_GETATTR:
                handle_shm_sched_getattr(shm);
                break;
        case SC_SHM_REQ_SCHED_SETATTR:
                handle_shm_sched_setattr(shm);
                break;
        case SC_SHM_REQ_UMASK:
                handle_shm_umask(shm);
                break;
        case SC_SHM_REQ_FTRUNCATE:
                handle_shm_ftruncate(shm);
                break;
        case SC_SHM_REQ_UNLINK:
                handle_shm_unlink(shm);
                break;
        case SC_SHM_REQ_GETSOCKNAME:
                handle_shm_getsockname(shm);
                break;
        case SC_SHM_REQ_GETPEERNAME:
                handle_shm_getpeername(shm);
                break;
        case SC_SHM_REQ_GETSOCKOPT:
                handle_shm_getsockopt(shm);
                break;
        case SC_SHM_REQ_CLOCK_GETTIME:
                handle_shm_clock_gettime(shm);
                break;
        case SC_SHM_REQ_CLOCK_GETRES:
                handle_shm_clock_getres(shm);
                break;
        case SC_SHM_REQ_SCHED_SETAFFINITY:
                handle_shm_sched_setaffinity(shm);
                break;
        case SC_SHM_REQ_SYSINFO:
                handle_shm_sysinfo(shm);
                break;
        case SC_SHM_REQ_SETITIMER:
                handle_shm_setitimer(shm);
                break;
        case SC_SHM_REQ_LISTEN:
                handle_shm_listen(shm);
                break;
        case SC_SHM_REQ_ACCEPT4:
                handle_shm_accept4(shm);
                break;
        case SC_SHM_REQ_IO_URING_ENTER:
                handle_shm_io_uring_enter(shm);
                break;
        case SC_SHM_REQ_CHMOD:
                handle_shm_chmod(shm);
                break;
        case SC_SHM_REQ_TIMES:
                handle_shm_times(shm);
                break;
        case SC_SHM_REQ_GETUID:
                handle_shm_getuid(shm);
                break;
        case SC_SHM_REQ_GETEUID:
                handle_shm_geteuid(shm);
                break;
        case SC_SHM_REQ_GETGID:
                handle_shm_getgid(shm);
                break;
        case SC_SHM_REQ_GETEGID:
                handle_shm_getegid(shm);
                break;
        case SC_SHM_REQ_SETUID:
                handle_shm_setuid(shm);
                break;
        case SC_SHM_REQ_SETGID:
                handle_shm_setgid(shm);
                break;
        case SC_SHM_REQ_GETGROUPS:
                handle_shm_getgroups(shm);
                break;
        case SC_SHM_REQ_SETGROUPS:
                handle_shm_setgroups(shm);
                break;
        case SC_SHM_REQ_GETPID:
                handle_shm_getpid(shm);
                break;
        case SC_SHM_REQ_DUP2:
                handle_shm_dup2(shm);
                break;
        case SC_SHM_REQ_RT_SIGTIMEDWAIT:
                handle_shm_rt_sigtimedwait(shm);
                break;
        case SC_SHM_REQ_SEM_INIT:
                handle_shm_sem_init(shm);
                break;
        case SC_SHM_REQ_SEM_WAIT:
                handle_shm_sem_wait(shm);
                break;
        case SC_SHM_REQ_SEM_TRYWAIT:
                handle_shm_sem_trywait(shm);
                break;
        case SC_SHM_REQ_SEM_TIMEDWAIT:
                handle_shm_sem_timedwait(shm);
                break;
        case SC_SHM_REQ_SEM_POST:
                handle_shm_sem_post(shm);
                break;
        case SC_SHM_REQ_DUP:
                handle_shm_dup(shm);
                break;
        case SC_SHM_REQ_SELECT:
                handle_shm_select(shm);
                break;
        default:
                assert(0);
                break;
        }

        clock_gettime(CLOCK_MONOTONIC, &tp);
        t1 = tp.tv_sec * 1000000000UL + tp.tv_nsec;
        shm->time = t1 - t0;
}

static void handle_request_with_shm(unsigned long shm_gpa)
{        
        __handle_request_with_shm(anon + (shm_gpa - gpa));
}

void vcpu_pause(void)
{
        pause();
}

static void *shadow_thread_routine(void *args);
void activate_thread(long thread)
{
        pthread_t pthread;
        int idx;

        pthread_create(&pthread, NULL, shadow_thread_routine, (void *)thread);

        idx = __sync_fetch_and_add(&pthread_cnt, 1);
        assert(idx < MAX_PTHREAD_CNT);
        pthreads[idx] = pthread;
}

#if defined(CONFIG_PLAT_AMD_SEV)
#define C_BIT (1UL << 51)
void map_gpa(unsigned long start, unsigned long size)
{
        struct kvm_memory_attributes attr;
        int enc = !!(start & C_BIT);
        int ret;

        if (enc) {
                start &= ~C_BIT;
        }

        attr.attributes = enc ? KVM_MEMORY_ATTRIBUTE_PRIVATE : 0;
        attr.address = start;
        attr.size = size;
        attr.flags = 0;
        ret = ioctl(kvm_vm_fd, KVM_SET_MEMORY_ATTRIBUTES, &attr);
        assert(!ret && !attr.size);
}
#endif


void *polling_routine(void *arg)
{
        int i;

        pin(POLLING_HOST_PIN);
        
        for (;;) {
                for (i = 0; i < polling_shm_cnt; i++) {
                        if (polling_shms[i]->pending) {
                                __handle_request_with_shm(polling_shms[i]);
                                polling_shms[i]->pending = 0;
                        }
                }
        }

        return NULL;
}

void start_polling(void)
{
        pthread_t pthread;

        pin(POLLING_VCPU_PIN);

        pthread_create(&pthread, NULL, polling_routine, NULL);
}

void add_polling(unsigned long shm_gpa)
{
        int idx;
        struct sc_shm *shm = anon + (shm_gpa - gpa);

        idx = __sync_fetch_and_add(&__polling_shm_cnt, 1);
        assert(idx < MAX_POLLING_SHM_CNT);
        polling_shms[idx] = shm;

        __sync_fetch_and_add(&polling_shm_cnt, 1);
}

// void wake_thread(int tid)
// {
//         syscall(SYS_tkill, tid, SIGUSR2);
// }

void wait_finish(void)
{
        while (!finish) {
                sleep(1);
        }
}

static void handle_request(struct kvm_run *run)
{
        switch (get_vmcall_arg1(run)) {
        case SC_REQ_DEBUG_PUTC:
                putchar(get_vmcall_arg2(run));
                fflush(stdout);
                break;
        case SC_REQ_GET_MEM_SIZE:
                set_vmcall_ret(run, mem_size | small_shared_pool);
                break;
        case SC_REQ_GRANT_MEM:
                slot = get_vmcall_arg2(run);
                gpa = get_vmcall_arg3(run);
                grant_mem();
                break;
        case SC_REQ_WITH_SHM:
                handle_request_with_shm(get_vmcall_arg2(run));
                break;
        case SC_REQ_VCPU_PAUSE:
                vcpu_pause();
                break;
        case SC_REQ_ACTIVATE_THREAD:
                activate_thread(get_vmcall_arg2(run));
                break;
        case SC_REQ_START_POLLING:
                start_polling();
                break;
        case SC_REQ_ADD_POLLING:
                add_polling(get_vmcall_arg2(run));
                break;
#if defined(CONFIG_PLAT_AMD_SEV)
        case SC_REQ_MAP_GPA:
                map_gpa(get_vmcall_arg2(run), get_vmcall_arg3(run));
                break;
#endif
        case SC_REQ_GET_TID:
                set_vmcall_ret(run, gettid());
                break;
        // case SC_REQ_WAKE_THREAD:
        //         wake_thread(get_vmcall_arg2(run));
        //         break;
        case SC_REQ_SYNC_IS_ENABLED:
                set_vmcall_ret(run, enable_sync);
                break;
        case SC_REQ_SEM_POST:
                sem_post((void *)get_vmcall_arg2(run));
                break;
        case SC_REQ_WAIT_FINISH:
                wait_finish();
                break;
        default:
                assert(0);
                break;
        }
}

static void *shadow_thread_routine(void *args)
{
        int kvm_vcpu_fd, ret;
        struct kvm_run *run;
        long thread = (long)args;

        kvm_vcpu_fd = ioctl(kvm_vm_fd, KVM_SC_ALLOC_VCPU);
        if (kvm_vcpu_fd < 0) {
                perror("get vcpu");
                exit(EXIT_FAILURE);
        }

        run = mmap(NULL, kvm_vcpu_mmap_size, PROT_READ | PROT_WRITE, MAP_SHARED,
                   kvm_vcpu_fd, 0);
        if (run == NULL) {
                perror("map kvm_run");
                exit(EXIT_FAILURE);
        }

        set_vmcall_ret(run, thread);
        for (;;) {
                ret = ioctl(kvm_vcpu_fd, KVM_RUN, 0);
                if (ret < 0 && errno == EINTR) {
                        continue;
                }
                if (ret < 0) {
                        perror("kvm run");
                        exit(EXIT_FAILURE);
                }

                switch (get_vmcall_op(run)) {
                case VMCALL_SC_VCPU_IDLE:
                        goto out;
                case VMCALL_SC_REQUEST:
                        handle_request(run);
                        break;
                default:
                        assert(0);
                        break;
                }
        }

out:
        return NULL;
}

void sigusr1_handler(int signum)
{
    if (signum == SIGUSR1)
    {
        int i;
        if (getpid() != gettid()) {
                pthread_exit(NULL);
        }
        for (i = 0; i < pthread_cnt; i++) {
                pthread_kill(pthreads[i], SIGUSR1);
                pthread_join(pthreads[i], NULL);
        }
        debug("Received SIGUSR1!\n");
        remove_mem();
        exit(EXIT_FAILURE);
    }
}

void sigusr2_handler(int signum)
{
        if (signum == SIGUSR2) {
                finish = 1;
                return;
        }
}

static void parse_mem_params(void)
{
        if (argc < 3) {
                return;
        }

        if (strcmp(argv[0], "-m")) {
                return;
        }

        mem_file = argv[1];

        mem_size = atoi(argv[2]);
        if (mem_size < 8 || mem_size > 2048) {
                printf("strange mem size\n");
                exit(EXIT_FAILURE);
        }
        mem_size *= 1024UL * 1024UL;

        argc -= 3;
        argv += 3;

        if (!argc || strcmp(argv[0], "--small-shared-pool")) {
                return;
        }

        small_shared_pool = 1;

        argc -= 1;
        argv += 1;
}

static void parse_config_params(void)
{
        if (argc < 1) {
                return;
        }

        if (!strcmp(argv[0], "--disable-sync")) {
                enable_sync = 1;
        } else {
                return;
        }

        argc -= 1;
        argv += 1;
}

static void parse_vm_slot_params(void)
{
        if (argc < 2) {
                return;
        }

        if (strcmp(argv[0], "--slot")) {
                return;
        }

        vm_slot_id = atoi(argv[1]);

        argc -= 2;
        argv += 2;
}

int main(int __argc, char *__argv[])
{       
        struct sigaction sa;

        argc = __argc - 1;
        argv = __argv + 1;

        parse_mem_params();
        parse_config_params();
        parse_vm_slot_params();

        t_shadow_begin = get_time();
        
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = 0;
        sa.sa_handler = sigusr1_handler;
        sigaction(SIGUSR1, &sa, 0);
        sa.sa_handler = sigusr2_handler;
        sigaction(SIGUSR2, &sa, 0);

        kvm_dev_fd = open("/dev/kvm", O_RDWR);
        if (kvm_dev_fd < 0) {
                perror("open /dev/kvm");
                exit(EXIT_FAILURE);
        }

        kvm_vm_fd = ioctl(kvm_dev_fd, KVM_SC_GET_VM, vm_slot_id);
        if (kvm_vm_fd < 0) {
                perror("get vm");
                exit(EXIT_FAILURE);
        }

        kvm_vcpu_mmap_size = ioctl(kvm_dev_fd, KVM_GET_VCPU_MMAP_SIZE, 0);
        if (kvm_vcpu_mmap_size < 0) {
                perror("get vcpu mmap size");
                exit(EXIT_FAILURE);
        }

        shadow_thread_routine(NULL);

        remove_mem();

        if (!getenv("SILENT")) {
                printf("t_sc_init %f\n", t_sc_init);
                printf("t_shadow_begin %f\n", t_shadow_begin);
        }

        return 0;
}
