#pragma once
#include "config.h"
#include <poll.h>
#include <signal.h>
#include <semaphore.h>
#include <sys/uio.h>
#include <sys/types.h>
#include <sys/socket.h>


#define KVM_SC_GET_VM		_IO(KVMIO,    0x10)
#define KVM_SC_ALLOC_VCPU	_IO(KVMIO,    0x11)

#if defined(CONFIG_PLAT_INTEL_TDX)
#define VMCALL_SC_VCPU_IDLE     0x10010
#define VMCALL_SC_REQUEST       0x10011
#elif defined(CONFIG_PLAT_AMD_SEV)
#define VMCALL_SC_VCPU_IDLE     100
#define VMCALL_SC_REQUEST       101
#endif

#define SC_REQ_DEBUG_PUTC       1
#define SC_REQ_GET_MEM_SIZE     2
#define SC_REQ_GRANT_MEM        3
#define SC_REQ_WITH_SHM         4
#define SC_REQ_VCPU_PAUSE       5
#define SC_REQ_ACTIVATE_THREAD  6
#define SC_REQ_MAP_GPA          7
#define SC_REQ_START_POLLING    8
#define SC_REQ_ADD_POLLING      9
#define SC_REQ_GET_TID          10
#define SC_REQ_WAKE_THREAD      11
#define SC_REQ_SYNC_IS_ENABLED  12
#define SC_REQ_SEM_POST         13
#define SC_REQ_WAIT_FINISH      14

#define SC_SHM_SIZE              0x200000
#define SC_SHM_MAX_ARGC          16
#define SC_SHM_MAX_DATA_LEN      (SC_SHM_SIZE - sizeof(struct sc_shm))

enum sc_shm_req {
        SC_SHM_REQ_GET_ARG,
        SC_SHM_REQ_START_THREAD,
        SC_SHM_REQ_WRITE,
        SC_SHM_REQ_OPEN,
        SC_SHM_REQ_READ,
        SC_SHM_REQ_PREAD,
        SC_SHM_REQ_LSEEK,
        SC_SHM_REQ_STAT,
        SC_SHM_REQ_LSTAT,
        SC_SHM_REQ_GETDENTS64,
        SC_SHM_REQ_FSTAT,
        SC_SHM_REQ_RENAME,
        SC_SHM_REQ_CLOSE,
        SC_SHM_REQ_FCNTL,
        SC_SHM_REQ_IOCTL,
        SC_SHM_REQ_READLINK,
        SC_SHM_REQ_MKDIR,
        SC_SHM_REQ_EPOLL_CREATE1,
        SC_SHM_REQ_SCHED_GETAFFINITY,
        SC_SHM_REQ_EPOLL_PWAIT,
        SC_SHM_REQ_EPOLL_CTL,
        SC_SHM_REQ_PIPE2,
        SC_SHM_REQ_EVENTFD2,
        SC_SHM_REQ_CAPGET,
        SC_SHM_REQ_DUP3,
        SC_SHM_REQ_STATX,
        SC_SHM_REQ_SOCKET,
        SC_SHM_REQ_CONNECT,
        SC_SHM_REQ_BIND,
        SC_SHM_REQ_SHUTDOWN,
        SC_SHM_REQ_SETSOCKOPT,
        SC_SHM_REQ_POLL,
        SC_SHM_REQ_RECVFROM,
        SC_SHM_REQ_SENDTO,
        SC_SHM_REQ_GETCWD,
        SC_SHM_REQ_ACCESS,
        SC_SHM_REQ_SCHED_GETATTR,
        SC_SHM_REQ_SCHED_SETATTR,
        SC_SHM_REQ_UMASK,
        SC_SHM_REQ_FTRUNCATE,
        SC_SHM_REQ_UNLINK,
        SC_SHM_REQ_GETSOCKNAME,
        SC_SHM_REQ_GETPEERNAME,
        SC_SHM_REQ_GETSOCKOPT,
        SC_SHM_REQ_CLOCK_GETTIME,
        SC_SHM_REQ_CLOCK_GETRES,
        SC_SHM_REQ_SCHED_SETAFFINITY,
        SC_SHM_REQ_SYSINFO,
        SC_SHM_REQ_LISTEN,
        SC_SHM_REQ_ACCEPT4,
        SC_SHM_REQ_SETITIMER,
        SC_SHM_REQ_IO_URING_ENTER,
        SC_SHM_REQ_CHMOD,
        SC_SHM_REQ_TIMES,
        SC_SHM_REQ_GETUID,
        SC_SHM_REQ_GETEUID,
        SC_SHM_REQ_GETGID,
        SC_SHM_REQ_GETEGID,
        SC_SHM_REQ_SETUID,
        SC_SHM_REQ_SETGID,
        SC_SHM_REQ_GETGROUPS,
        SC_SHM_REQ_SETGROUPS,
        SC_SHM_REQ_GETPID,
        SC_SHM_REQ_DUP2,
        SC_SHM_REQ_RT_SIGTIMEDWAIT,
        SC_SHM_REQ_SEM_INIT,
        SC_SHM_REQ_SEM_WAIT,
        SC_SHM_REQ_SEM_TRYWAIT,
        SC_SHM_REQ_SEM_TIMEDWAIT,
        SC_SHM_REQ_SEM_POST,
        SC_SHM_REQ_DUP,
        SC_SHM_REQ_SELECT,
        SC_SHM_REQ_NR,
};

struct sc_shm {
        int req;
        volatile int pending;
        long ret;
        unsigned long time;
        union {
        struct {
                int argc;
                off_t argv[SC_SHM_MAX_ARGC];
        } get_arg;
        struct {
                int cpuid;
        } start_thread;
        struct {
                int fd;
                size_t count;
        } write;
        struct {
                int flags;
                mode_t mode;
        } open;
        struct {
                int fd;
                size_t count;
        } read;
        struct {
                int fd;
                size_t count;
                off_t offset;
        } pread;
        struct {
                int fd;
                off_t offset;
                int whence;
        } lseek;
        struct {
                /* nothing */
        } stat;
        struct {
                /* nothing */
        } lstat;
        struct {
                int fd;
                size_t count;
        } getdents64;
        struct {
                int fd;
        } fstat;
        struct {
                off_t oldpath;
                off_t newpath;
        } rename;
        struct {
                int fd;
        } close;
        struct {
                int fd;
                int cmd;
                long arg;
        } fcntl;
        struct {
                int fd;
                unsigned long request;
        } ioctl;
        struct {
                size_t bufsiz;
        } readlink;
        struct {
                mode_t mode;
        } mkdir;
        struct {
                int flags;
        } epoll_create1;
        struct {
                pid_t pid;
                size_t cpusetsize;
        } sched_getaffinity;
        struct {
                int epfd;
                int maxevents;
                int timeout;
        } epoll_pwait;
        struct {
                int epfd;
                int op;
                int fd;
        } epoll_ctl;
        struct {
                int pipefd[2];
                int flags;
        } pipe2;
        struct {
                unsigned int initval;
                int flags;
        } eventfd2;
        struct {
                /* nothing */
        } capget;
        struct {
                int oldfd;
                int newfd;
                int flags;
        } dup3;
        struct {
                int dirfd;
                int flags;
                unsigned int mask;
        } statx;
        struct {
                int domain;
                int type;
                int protocol;
        } socket;
        struct {
                int sockfd;
                socklen_t addrlen;
        } bind;
        struct {
                int sockfd;
                size_t len;
                int flags;
                socklen_t addrlen;
        } sendto;
        struct {
                nfds_t nfds;
                int timeout;
        } poll;
        struct {
                int sockfd;
                size_t len;
                int flags;
                socklen_t addrlen;
        } recvfrom;
        struct {
                int sockfd;
                socklen_t addrlen;
        } connect;
        struct {
                int sockfd;
                int level;
                int optname;
                socklen_t optlen;
        } setsockopt;
        struct {
                int sockfd;
                int how;
        } shutdown;
        struct {
                size_t size;
        } getcwd;
        struct {
                int mode;
        } access;
        struct {
                pid_t pid;
                unsigned int flags;
        } sched_setattr;
        struct {
                pid_t pid;
                unsigned int size;
                unsigned int flags;
        } sched_getattr;
        struct {
                int fd;
                off_t length;
        } ftruncate;
        struct {
                mode_t mask;
        } umask;
        struct {
                /* nothing */
        } unlink;
        struct {
                int sockfd;
                socklen_t addrlen;
        } getsockname;
        struct {
                int sockfd;
                socklen_t addrlen;
        } getpeername;
        struct {
                int sockfd;
                int level;
                int optname;
                socklen_t optlen;
        } getsockopt;
        struct {
                clockid_t clk_id;
        } clock_gettime;
        struct {
                clockid_t clk_id;
        } clock_getres;
        struct {
                pid_t pid;
                size_t cpusetsize;
        } sched_setaffinity;
        struct {
                /* nothing */
        } sysinfo;
        struct {
                int sockfd;
                int backlog;
        } listen;
        struct {
                int sockfd;
                socklen_t addrlen;
                int flags;
        } accpet4;
        struct {
                int which;
        } setitimer;
        struct {
                int fd;
                unsigned to_submit;
                unsigned min_complete;
                unsigned flags;
        } io_uring_enter;
        struct {
                mode_t mode;
        } chmod;
        struct {
                /* nothing */
        } times;
        struct {
                /* nothing */
        } getuid;
        struct {
                /* nothing */
        } geteuid;
        struct {
                /* nothing */
        } getgid;
        struct {
                /* nothing */
        } getegid;
        struct {
                uid_t uid;
        } setuid;
        struct {
                gid_t gid;
        } setgid;
        struct {
                int size;
        } getgroups;
        struct {
                size_t size;
        } setgroups;
        struct {
                /* nothing */
        } getpid;
        struct {
                int oldfd;
                int newfd;
        } dup2;
        struct {
                size_t sigsetsize;
        } rt_sigtimedwait;
        struct {
                int pshared;
                unsigned value;
        } sem_init;
        struct {
                sem_t *sem;
        } sem_wait;
        struct {
                sem_t *sem;
        } sem_trywait;
        struct {
                sem_t *sem;
        } sem_timedwait;
        struct {
                sem_t *sem;
        } sem_post;
        struct {
                int oldfd;
        } dup;
        struct {
                int nfds;
        } select;
        };
        char data[0];
};

