#include <split-container/split_container.h>
#include <uapi/split_container_op.h>
#include <arch/machine/smp.h>
#include <mm/buddy.h>
#include <mm/mm.h>
#include <mm/uaccess.h>
#include <common/macro.h>
#include <common/util.h>
#include <common/lock.h>
#include <arch/mmu.h>
#include <ipc/notification.h>
#include <object/memory.h>
#include <arch/time.h>
#include <arch/sync.h>
#if defined(CHCORE_PLAT_INTEL_TDX)
#include <tdx.h>
#elif defined(CHCORE_PLAT_AMD_SEV)
#include <sev.h>
#endif
#include "snapshot.h"

#define FAST_SHARED_POOL 1

#define CYCLE_PER_NS 1UL

#define HPAGE_SIZE (1UL << (9 + 12))
#define SHARED_POOL_SIZE (48UL * 1024 * 1024)
#define SMALL_SHARED_POOL_SIZE (4UL * 1024 * 1024)

#define debug(fmt, ...) //printk(fmt, ##__VA_ARGS__)

struct mem_meta {
        u64 mem_size, slot, gpa;
#ifdef FAST_SHARED_POOL
        u64 next_shared;
#endif /* FAST_SHARED_POOL */
        unsigned long shared_pool_size;
        struct phys_mem_pool *shared_mem_pool;
        struct phys_mem_pool *private_mem_pool;
};

struct {
        u64 thread_cnt;
#ifndef CHCORE_SPLIT_CONTAINER_SYNC
        int tid;
        struct lock tlb_lock_ipi, tlb_lock_req;
        int tlb_pcid, tlb_start_va, tlb_page_cnt;
#endif /* CHCOER_SPLIT_CONTAINER_SYNC */
        struct mem_meta mm;
        struct cap_group *cap_group;
} sc_cpus[PLAT_CPU_NUM];
#define sc_cpu (&sc_cpus[smp_get_cpu_id()])

static long hypercall(u32 nr, u64 p1, u64 p2, u64 p3)
{
#if defined(CHCORE_PLAT_INTEL_TDX)
        return tdx_do_hypercall(TDX_HYPERCALL_STANDARD, nr, p1, p2, p3);
#elif defined(CHCORE_PLAT_AMD_SEV)
        return sev_snp_do_hypercall(nr, p1, p2, p3);
#else
#error not supported
#endif
}

static void change_phys_state(paddr_t start, paddr_t end, bool enc)
{
#if defined(CHCORE_PLAT_INTEL_TDX)
        BUG_ON(!tdx_enc_status_changed_phys(start, end, enc));
#elif defined(CHCORE_PLAT_AMD_SEV)
        BUG_ON(!sev_snp_enc_status_changed_phys(start, end, enc));
#else
#error not_supported
#endif
}

long split_container_request(int op, long a, long b)
{
        __sync_fetch_and_add(&current_cap_group->sc_n_hcall, 1);
        return hypercall(VMCALL_SC_REQUEST, op, a, b);
}

static long vcpu_idle(void)
{
        long thread;

        if (sc_cpu->cap_group) {
                __sync_fetch_and_sub(&sc_cpu->cap_group->sc_active_vcpus, 1);
                sc_cpu->cap_group = NULL;
        }

#ifndef CHCORE_SPLIT_CONTAINER_SYNC
        while (try_lock(&sc_cpu->tlb_lock_ipi)) {
                extern void handle_ipi(void);
                handle_ipi();
        }
#endif /* CHCORE_SPLIT_CONTAINER_SYNC */
        thread = hypercall(VMCALL_SC_VCPU_IDLE, 0, 0, 0);
        if (thread && thread < KBASE)
                thread += KBASE;
#ifndef CHCORE_SPLIT_CONTAINER_SYNC
        unlock(&sc_cpu->tlb_lock_ipi);
#endif /* CHCORE_SPLIT_CONTAINER_SYNC */

        flush_tlb_all();
        
#ifndef CHCORE_SPLIT_CONTAINER_SYNC
        sc_cpu->tid = split_container_request(SC_REQ_GET_TID, 0, 0);
#endif /* CHCORE_SPLIT_CONTAINER_SYNC */

        debug("[SC-G] vcpu_idle: thread=%d\n", thread);
        
        return thread;
}

/* Simple allocation */
#define SLOT_MAX        0xffff
#define SLOT_BASE       100
static u32 mem_alloc_slot(void)
{
        u32 cpuid = smp_get_cpu_id();
        u32 slot = SLOT_BASE + cpuid;

        BUG_ON(slot > SLOT_MAX);

        return slot;
}

static void mem_free_slot(u32 slot)
{
        /* Do nothing */
}

/* Simple allocation */
#define GPA_MAX         0x7D00000000UL
#define GPA_BASE        0x180000000UL
#define GPA_STEP        0x80000000UL
static u64 mem_alloc_gpa(u32 mem_size)
{
        u32 cpuid = smp_get_cpu_id();
        u64 gpa = GPA_BASE + cpuid * GPA_STEP;

        BUG_ON(gpa >= GPA_MAX);

        return gpa;
}

static void mem_free_gpa(u64 gpa, u32 mem_size)
{
        /* Do nothing */
}

static unsigned long init_mem_pool(paddr_t base, size_t size, int enc)
{
        u64 npages, npages1, free_page_start;
        struct page *page_meta_start;
        struct phys_mem_pool *mem_pool;
        unsigned long t0, t1;
        unsigned long t = 0;

        mem_pool = kmalloc(sizeof(*mem_pool));

        npages = size / (PAGE_SIZE + sizeof(struct page));
        free_page_start = ROUND_UP(base + npages * sizeof(struct page), HPAGE_SIZE);
        npages1 = (base + size - free_page_start) / PAGE_SIZE;
        npages = npages < npages1 ? npages : npages1;
        page_meta_start = (struct page *)phys_to_virt(base);

        t0 = get_cycles();
        change_phys_state(base, free_page_start, 1);
        t1 = get_cycles();
        if (!enc) {
                t = t1 - t0;
        }

        if (!enc) {
                t0 = get_cycles();
                change_phys_state(free_page_start, base + size, enc);
                t1 = get_cycles();
                t += t1 - t0;
        }

        t0 = get_cycles();
        init_buddy(mem_pool, page_meta_start, phys_to_virt(free_page_start), npages);
        t1 = get_cycles();
        if (!enc) {
                t += t1 - t0;
        }

        if (enc) {
                sc_cpu->mm.private_mem_pool = mem_pool;
        } else {
                sc_cpu->mm.shared_mem_pool = mem_pool;
        }

        return t;
}

static long init_mem(void)
{
        u64 mem_size, gpa, slot;
        unsigned long t, t0, t1;
        unsigned long shared_pool_size;

        t0 = get_cycles();
        mem_size = split_container_request(SC_REQ_GET_MEM_SIZE, 0, 0);
        if (mem_size & 1UL) {
                shared_pool_size = SMALL_SHARED_POOL_SIZE;
                mem_size &= ~1UL;
        } else {
                shared_pool_size = SHARED_POOL_SIZE;
        }
        debug("[SC-G] init_mem: mem_size=0x%x\n", mem_size);
        mem_size -= HPAGE_SIZE;
        t1 = get_cycles();
        t = t1 - t0;

        slot = mem_alloc_slot();
        gpa = mem_alloc_gpa(mem_size);
        debug("[SC-G] init_mem: slot=%u, GPA=0x%lx\n", slot, gpa);

        split_container_request(SC_REQ_GRANT_MEM, slot, gpa);

        sc_cpu->mm.mem_size = mem_size;
        sc_cpu->mm.gpa = gpa;
        sc_cpu->mm.slot = slot;
        BUG_ON(mem_size < shared_pool_size);
#ifdef FAST_SHARED_POOL
        sc_cpu->mm.next_shared = 0;
        change_phys_state(gpa, gpa + shared_pool_size, 0);
#else /* FAST_SHARED_POOL */
        t += init_mem_pool(gpa, shared_pool_size, 0);
#endif /* FAST_SHARED_POOL */
        t += init_mem_pool(gpa + shared_pool_size, mem_size - shared_pool_size, 1);

        sc_cpu->mm.shared_pool_size = shared_pool_size;

        debug("[SC-G] init_mem: init_buddy done\n");

        return t;
}

static long deinit_mem(void)
{
        kfree(sc_cpu->mm.private_mem_pool);
#ifndef FAST_SHARED_POOL
        kfree(sc_cpu->mm.shared_mem_pool);
#endif /* FAST_SHARED_POOL */
        mem_free_slot(sc_cpu->mm.slot);
        mem_free_gpa(sc_cpu->mm.gpa, sc_cpu->mm.mem_size);
        debug("[SC-G] deinit_mem\n");
        return 0;
}

extern struct page *__buddy_get_pages(struct phys_mem_pool *, int order);
extern void __buddy_free_pages(struct phys_mem_pool *, struct page *page);

#ifdef CHCORE_SPLIT_CONTAINER_HPAGE
#define ACCEPT_PAGE_SIZE HPAGE_SIZE
#else /* CHCORE_SPLIT_CONTAINER_HPAGE */
#define ACCEPT_PAGE_SIZE PAGE_SIZE
#endif /* CHCORE_SPLIT_CONTAINER_HPAGE */
void *split_container_get_pages(int order, int enc)
{
        struct page *page, *hpage;
        void *addr, *haddr;
        u64 gpa, size, offset;
        struct phys_mem_pool *mem_pool;
        unsigned long t0, t1;

        if (smp_get_cpu_id() < PLAT_CPU_POOL_BASE ||
            (enc && !current_cap_group->sc_recycle_notifc)) {
                return NULL;
        }

#ifdef FAST_SHARED_POOL
        if (!enc) {
                unsigned long id;
                id = __sync_fetch_and_add(&sc_cpu->mm.next_shared, 1);
                gpa = sc_cpu->mm.gpa + HPAGE_SIZE * id;
                return (void *)phys_to_virt(gpa);
        }
#endif /* FAST_SHARED_POOL */

        mem_pool = enc ? sc_cpu->mm.private_mem_pool : sc_cpu->mm.shared_mem_pool;

        lock(&mem_pool->buddy_lock);

        page = __buddy_get_pages(mem_pool, order);
        BUG_ON(!page);
        addr = page_to_virt(page);

        if (!enc) {
                goto out;
        }

        haddr = (void *)ROUND_DOWN((u64)addr, ACCEPT_PAGE_SIZE);
        size = 1UL << BUDDY_PAGE_SIZE_ORDER << order;
        for (offset = 0; offset < size; offset += ACCEPT_PAGE_SIZE) {
                hpage = __virt_to_page(mem_pool, haddr + offset);
                if (!hpage->sc_accepted) {
                        gpa = virt_to_phys(haddr + offset);
                        t0 = get_cycles();
                        change_phys_state(gpa, gpa + ACCEPT_PAGE_SIZE, enc);
                        t1 = get_cycles();
                        hpage->sc_accepted = 1;
                        if (enc) {
                                current_cap_group->sc_t_accept += t1 - t0;
                                current_cap_group->sc_n_accept++;
                        }
                }
        }

out:
        unlock(&mem_pool->buddy_lock);
        return addr;
}

int split_container_free_pages(void *addr)
{
        struct page *page;
        u64 gpa = virt_to_phys(addr);
        struct phys_mem_pool *mem_pool;

        if (smp_get_cpu_id() < PLAT_CPU_POOL_BASE) {
                return -1;
        }

        if (gpa < sc_cpu->mm.gpa ||
            gpa >= sc_cpu->mm.gpa + sc_cpu->mm.mem_size) {
                return -1;
        }

#ifdef FAST_SHARED_POOL
        if (gpa < sc_cpu->mm.gpa + sc_cpu->mm.shared_pool_size) {
                return 0;
        }
#endif /* FAST_SHARED_POOL */

        mem_pool = gpa < sc_cpu->mm.gpa + sc_cpu->mm.shared_pool_size ?
                sc_cpu->mm.shared_mem_pool : sc_cpu->mm.private_mem_pool;

        page = __virt_to_page(mem_pool, addr);
        buddy_free_pages(mem_pool, page);

        return 0;
}

static long wait_idle(void)
{
        if (sc_cpu->thread_cnt > 0) {
                return -EAGAIN;
        } else {
                debug("[SC-G] wait_idle: ok\n");
                return 0;
        }
}

static long recycle_wait(cap_t cap_group_cap)
{
        struct cap_group *cap_group;
        
        cap_group = obj_get(current_cap_group, cap_group_cap, TYPE_CAP_GROUP);
        if (!cap_group || !cap_group->sc_active_vcpus) {
                return -ECAPBILITY;
        }
        obj_put(cap_group);

        return wait_notific(cap_group->sc_recycle_notifc, 1, NULL);
}

long is_enclave(void)
{
        return current_cap_group->sc_recycle_notifc != NULL;
}

long shm_req(cap_t pmo_cap)
{
        struct pmobject *pmo;
        long ret;

        pmo = obj_get(current_cap_group, pmo_cap, TYPE_PMO);
        BUG_ON(!pmo);

#ifndef CHCORE_SPLIT_CONTAINER_SYNC
        while (try_lock(&sc_cpu->tlb_lock_ipi)) {
                extern void handle_ipi(void);
                handle_ipi();
        }
#endif /* CHCORE_SPLIT_CONTAINER_SYNC */
        ret = split_container_request(SC_REQ_WITH_SHM, pmo->start, 0);
#ifndef CHCORE_SPLIT_CONTAINER_SYNC
        unlock(&sc_cpu->tlb_lock_ipi);
        lock(&sc_cpu->tlb_lock_req);
        if (sc_cpu->tlb_pcid == -1) {
                flush_tlb_all();
                sc_cpu->tlb_pcid = 0;
        } else if (sc_cpu->tlb_pcid) {
                flush_local_tlb_opt(sc_cpu->tlb_start_va, sc_cpu->tlb_page_cnt, sc_cpu->tlb_pcid);
                sc_cpu->tlb_pcid = 0;
        }
        unlock(&sc_cpu->tlb_lock_req);
#endif /* CHCORE_SPLIT_CONTAINER_SYNC */

        obj_put(pmo);
        return ret;
}

long bind_thread(struct thread *thread)
{
        struct cap_group *cap_group = thread->cap_group;

        thread->thread_ctx->sc->sc_aff = smp_get_cpu_id();

        __sync_fetch_and_add(&sc_cpu->thread_cnt, 1);
        debug("thread++: %llu\n", sc_cpu->thread_cnt);

        if (cap_group->sc_main_aff != smp_get_cpu_id()) {
                sc_cpu->mm = sc_cpus[cap_group->sc_main_aff].mm;
                sc_cpu->cap_group = cap_group;
                __sync_fetch_and_add(&cap_group->sc_active_vcpus, 1);
        }

        if (thread->thread_ctx->state == TS_INTER) {
                BUG_ON(sched_enqueue(thread));
        } else {
                BUG_ON(thread->thread_ctx->state != TS_WAITING);
        }

        return 0;
}

long print_stat(const char *s)
{
        char s_k[64];

        copy_string_from_user(s_k, s, 64);

        printk("t_accept,%s %lu\n", s_k, current_cap_group->sc_t_accept);
        printk("n_accept,%s %lu\n", s_k, current_cap_group->sc_n_accept);
        printk("t_pgfault,%s %lu\n", s_k, current_cap_group->sc_t_pgfault);
        printk("n_cow,%s %lu\n", s_k, current_cap_group->sc_n_cow);

        return 0;
}

long reg_t_accept(vaddr_t va)
{
        struct vmspace *vmspace;
        paddr_t pa;
        int ret;

        vmspace = current_thread->vmspace;
        lock(&vmspace->pgtbl_lock);
        ret = query_in_pgtbl(vmspace->pgtbl, va, &pa, NULL);
        unlock(&vmspace->pgtbl_lock);

        BUG_ON(ret);

        current_cap_group->sc_u_t_pgfault = (void *)phys_to_virt(pa);

        return 0;
}

long reg_defer_sched(vaddr_t va)
{
        struct vmspace *vmspace;
        paddr_t pa;
        int ret;

        vmspace = current_thread->vmspace;
        lock(&vmspace->pgtbl_lock);
        ret = query_in_pgtbl(vmspace->pgtbl, va, &pa, NULL);
        unlock(&vmspace->pgtbl_lock);

        BUG_ON(ret);

        current_thread->sc_u_defer_sched = (void *)phys_to_virt(pa);

        return 0;
}

long start_polling(void)
{
        split_container_request(SC_REQ_START_POLLING, 0, 0);

        return 0;
}

long add_polling(cap_t pmo_cap)
{
        struct pmobject *pmo;
        long ret;

        pmo = obj_get(current_cap_group, pmo_cap, TYPE_PMO);
        BUG_ON(!pmo);

        ret = split_container_request(SC_REQ_ADD_POLLING, pmo->start, 0);

        obj_put(pmo);
        return ret;
}

#define STAT_N_HCALLS   0x1
#define STAT_N_COWS     0x2
#define STAT_T_GRANT    0x5
#define STAT_T_FORK     0x6
long get_stat(int stat)
{
        switch (stat) {
        case STAT_N_HCALLS:
                return current_cap_group->sc_n_hcall;
        case STAT_N_COWS:
                return current_cap_group->sc_n_cow;
        case STAT_T_GRANT:
                return current_cap_group->sc_t_accept;
        // case STAT_T_FORK:
        //         return current_cap_group->sc_t_fork;
        default:
                return -1;
        }
}

long wait_finish(void)
{
        return split_container_request(SC_REQ_WAIT_FINISH, 0, 0);
}

#ifndef CHCORE_SPLIT_CONTAINER_SYNC
long set_sem(cap_t notifc_cap, void *sem)
{
        struct notification *notifc;

        notifc = obj_get(current_cap_group, notifc_cap, TYPE_NOTIFICATION);
        
        if (!notifc) {
                return -ECAPBILITY;
        }

        atomic_cmpxchg_64((void *)&notifc->sc_sem, 0, (long)sem);

        obj_put(notifc);

        return 0;
}

long get_sem(cap_t notifc_cap, int notify)
{
        struct notification *notifc;
        void *sem;

        notifc = obj_get(current_cap_group, notifc_cap, TYPE_NOTIFICATION);
        if (!notifc) {
                return -ECAPBILITY;
        }

        sem = notifc->sc_sem;

        obj_put(notifc);

        return (long)sem;
}

long sync_is_enabled(void)
{
        return current_cap_group->sc_enable_sync;
}

extern long signal_all_notifcs(struct cap_group *cap_group);

long wake_all(cap_t cap_group_cap)
{
        cap_t slot_id;
        struct slot_table *slot_table;
        struct object_slot *slot;
        struct notification *notifc;
        struct cap_group *cap_group;

        cap_group = obj_get(current_cap_group, cap_group_cap, TYPE_CAP_GROUP);
        if (!cap_group) {
                return -ECAPBILITY;
        }

        slot_table = &cap_group->slot_table;
        read_lock(&slot_table->table_guard);

        for_each_set_bit (
                slot_id, slot_table->slots_bmp, slot_table->slots_size) {
                slot = get_slot(cap_group, slot_id);

                if (slot->object->type != TYPE_NOTIFICATION) {
                        continue;
                }

                notifc = (struct notification *)slot->object->opaque;
                if (notifc->sc_sem) {
                        split_container_request(SC_REQ_SEM_POST, (long)notifc->sc_sem, 0);
                }
        }

        read_unlock(&slot_table->table_guard);

        obj_put(cap_group);

        return 0;
}

#endif /* CHCORE_SPLIT_CONTAINER_SYNC */

long sys_split_container(int op, long a, long b, long c, long d)
{
        switch (op) {
        case SYS_SC_OP_VCPU_IDLE:
                return vcpu_idle();
        case SYS_SC_OP_INIT_MEM:
                return init_mem();
        case SYS_SC_OP_DEINIT_MEM:
                return deinit_mem();
        case SYS_SC_OP_WAIT_IDLE:
                return wait_idle();
        case SYS_SC_OP_RECYCLE_WAIT:
                return recycle_wait(a);
        case SYS_SC_OP_IS_ENCLAVE:
                return is_enclave();
        case SYS_SC_OP_SHM_REQ:
                return shm_req(a);
        case SYS_SC_OP_SNAPSHOT:
                return snapshot(a);
        case SYS_SC_OP_RESTORE:
                return restore(a, b);
        case SYS_SC_OP_BIND_THREAD:
                return bind_thread((void *)a);
        case SYS_SC_OP_PRINT_STAT:
                return print_stat((void *)a);
        case SYS_SC_OP_REG_T_PGFAULT:
                return reg_t_accept(a);
        case SYS_SC_OP_START_POLLING:
                return start_polling();
        case SYS_SC_OP_ADD_POLLING:
                return add_polling(a);
        case SYS_SC_OP_REG_DEFER_SCHED:
                return reg_defer_sched(a);
        case SYS_SC_OP_GET_STAT:
                return get_stat(a);
#ifndef CHCORE_SPLIT_CONTAINER_SYNC
        case SYS_SC_OP_SET_SEM:
                return set_sem(a, (void *)b);
        case SYS_SC_OP_GET_SEM:
                return get_sem(a, b);
        case SYS_SC_OP_SYNC_IS_ENABLED:
                return sync_is_enabled();
        case SYS_SC_OP_SIGNAL_ALL_NOTIFCS:
                return signal_all_notifcs(current_cap_group);
        case SYS_SC_OP_WAKE_ALL:
                return wake_all(a);
        case SYS_SC_OP_WAIT_FINISH:
                return wait_finish();
#endif /* CHCORE_SPLIT_CONTAINER_SYNC */
        default:
                BUG_ON(1);
                break;
        }
}

void split_container_thread_init(struct thread *thread)
{
        if (thread->thread_ctx->sc) {
                thread->thread_ctx->sc->sc_aff = NO_AFF;
        }
        thread->sc_u_defer_sched = NULL;
        // if (smp_get_cpu_id() >= 4) {
        //         thread->thread_ctx->ec.reg[RFLAGS] = EFLAGS_1;
        // }
}

void split_container_thread_deinit(struct thread *thread)
{
        s32 sc_aff;

        if (!thread->thread_ctx->sc) {
                return;
        }
        sc_aff = thread->thread_ctx->sc->sc_aff;
        if (sc_aff == NO_AFF) {
                return;
        }

        __sync_fetch_and_sub(&sc_cpus[sc_aff].thread_cnt, 1);
        debug("thread--: %llu\n", sc_cpu->thread_cnt);
}

long split_container_activate_thread(struct thread *thread, bool new_vcpu)
{
        if (smp_get_cpu_id() < PLAT_CPU_POOL_BASE) {
                return sched_enqueue(thread);
        } else if (new_vcpu && !thread->cap_group->sc_enable_sync) {
                return split_container_request(SC_REQ_ACTIVATE_THREAD, (long)thread, 0);
        } else {
                return bind_thread(thread);
        }
}

void split_container_cap_group_init(struct cap_group *cap_group)
{
        cap_group->sc_main_aff = NO_AFF;
        cap_group->sc_active_vcpus = 0;
        cap_group->sc_recycle_notifc = NULL; 
        
        if (smp_get_cpu_id() < PLAT_CPU_POOL_BASE) {
                return;
        }

        BUG_ON(sc_cpu->cap_group);

        cap_group->sc_main_aff = smp_get_cpu_id();
        cap_group->sc_active_vcpus = 1;
        cap_group->sc_recycle_notifc = kmalloc(sizeof(struct notification));
        init_notific(cap_group->sc_recycle_notifc);
        cap_group->sc_t_accept = 0;
        cap_group->sc_n_accept = 0;
        cap_group->sc_t_pgfault = 0;
        cap_group->sc_u_t_pgfault = NULL;
        cap_group->sc_n_hcall = 0;
        cap_group->sc_n_cow = 0;

        cap_group->sc_enable_sync = split_container_request(SC_REQ_SYNC_IS_ENABLED, 0, 0);
        
        sc_cpu->cap_group = cap_group;
}

void split_container_cap_group_deinit(struct cap_group *cap_group)
{
        if (cap_group->sc_active_vcpus == 0) {
                return;
        }

        BUG_ON(cap_group != sc_cpu->cap_group);

        debug("[SC-G] sc_cap_group_deinit: waiting ...\n");
        while (cap_group->sc_active_vcpus > 1);
        debug("[SC-G] sc_cap_group_deinit: waiting ... done\n");

        kfree(cap_group->sc_recycle_notifc);

        sc_cpu->cap_group = NULL;
}

int split_container_notify_recycler(struct cap_group *cap_group)
{
        if (!cap_group->sc_recycle_notifc) {
                return -EINVAL;
        }

        debug("[SC-G] sc_notify_recycler\n");

        return signal_notific(cap_group->sc_recycle_notifc);
}

void split_container_vcpu_pause(void)
{
        split_container_request(SC_REQ_VCPU_PAUSE, 0, 0);
}

#ifndef CHCORE_SPLIT_CONTAINER_SYNC
void split_container_wake_vcpu(u32 cpuid)
{
        if (cpuid < PLAT_CPU_POOL_BASE) {
                return;
        }

        split_container_request(SC_REQ_WAKE_THREAD, sc_cpus[cpuid].tid, 0);
}

extern void flush_remote_tlb_with_ipi(u32 target_cpu, vaddr_t start_va,
				      u64 page_cnt, u64 pcid, u64 vmspace);
void split_container_flush_remote_tlb(u32 target_cpu, vaddr_t start_va,
				      u64 page_cnt, u64 pcid, u64 vmspace)
{
        if (!try_lock(&sc_cpus[target_cpu].tlb_lock_ipi)) {
                goto lock_success;
        }

        lock(&sc_cpus[target_cpu].tlb_lock_req);
        if (!sc_cpus[target_cpu].tlb_pcid) {
                sc_cpus[target_cpu].tlb_pcid = pcid;
                sc_cpus[target_cpu].tlb_start_va = start_va;
                sc_cpus[target_cpu].tlb_page_cnt = page_cnt;
        } else {
                sc_cpus[target_cpu].tlb_pcid = -1;
        }
        unlock(&sc_cpus[target_cpu].tlb_lock_req);

        if (try_lock(&sc_cpus[target_cpu].tlb_lock_ipi)) {
                return;
        }

lock_success:
        flush_remote_tlb_with_ipi(target_cpu, start_va, page_cnt, pcid, vmspace);
        unlock(&sc_cpus[target_cpu].tlb_lock_ipi);
}
#endif /* CHCORE_SPLIT_CONTAINER_SYNC */
