#include <common/kprint.h>
#include "snapshot.h"
#include <object/cap_group.h>
#include <split-container/split_container.h>
#include <object/memory.h>
#include <mm/vmspace.h>
#include <common/util.h>
#include <arch/mmu.h>
#include <arch/machine/smp.h>
#include <sched/fpu.h>
#include <object/thread.h>
#include <ipc/notification.h>

static struct cap_group *g_image;

extern int cap_group_init(struct cap_group *cap_group, unsigned int size, badge_t badge);
extern int vmspace_init(struct vmspace *vmspace, unsigned long pcid);

static int snapshot_prepare(void)
{
        struct thread *thread;
        struct cap_group *cap_group = current_cap_group;

        lock(&cap_group->threads_lock);

        for_each_in_list (thread, struct thread, node,
                          &cap_group->thread_list) {
                if (thread != current_thread &&
                    thread->thread_ctx->state != TS_WAITING) {
                        unlock(&cap_group->threads_lock);
                        return -EAGAIN;
                }
        }

        unlock(&cap_group->threads_lock);
        printk("snapshot prepare done\n");
        return 0;
}

int snapshot(bool prepare)
{
        struct cap_group *cap_group;
        struct per_cpu_info *per_cpu_info;
        struct thread *fpu_owner;
        bool fpu_disable;

        if (prepare) {
                return snapshot_prepare();
        }

        cap_group = current_cap_group;
        BUG_ON(cap_group->sc_active_vcpus != 1);

        current_thread->thread_ctx->tls_base_reg[TLS_FS] =
                        __builtin_ia32_rdfsbase64();

        per_cpu_info = &cpu_info[smp_get_cpu_id()];
        fpu_owner = per_cpu_info->fpu_owner;
        fpu_disable = per_cpu_info->fpu_disable;
        if (fpu_owner) {
                BUG_ON(fpu_owner->cap_group != cap_group);
                if (fpu_disable) {
                        enable_fpu_usage();
                }
                save_fpu_state(fpu_owner);
                fpu_owner->thread_ctx->is_fpu_owner = -1;
                if (fpu_disable) {
                        disable_fpu_usage();
                }
        }

        g_image = cap_group;
        printk("snapshot done\n");
        split_container_vcpu_pause();
        
        return 0;
}

void check_image_slot_table(struct cap_group *image)
{
        cap_t slot_id;
        struct slot_table *slot_table;
        struct object_slot *slot;
        
        slot_table = &image->slot_table;

        for_each_set_bit (
                slot_id, slot_table->slots_bmp, slot_table->slots_size) {
                slot = get_slot(image, slot_id);
                switch (slot->object->type) {
                case TYPE_CAP_GROUP:
                        BUG_ON(slot_id != CAP_GROUP_OBJ_ID);
                        break;
                case TYPE_VMSPACE:
                        BUG_ON(slot_id != VMSPACE_OBJ_ID);
                        break;
                case TYPE_PMO:
                case TYPE_THREAD:
                case TYPE_NOTIFICATION:
                        break;
                default:
                        BUG_ON(1);
                        break;
                }
        }
}

struct cap_group *copy_cap_group(struct cap_group *src_cap_group, badge_t badge)
{
        struct cap_group *dst_cap_group;
        
        dst_cap_group = obj_alloc(TYPE_CAP_GROUP, sizeof(*dst_cap_group));
        cap_group_init(dst_cap_group, BASE_OBJECT_NUM, badge);

        BUG_ON(cap_alloc(dst_cap_group, dst_cap_group) != CAP_GROUP_OBJ_ID);
	memcpy(dst_cap_group->cap_group_name, src_cap_group->cap_group_name,
	       MAX_GROUP_NAME_LEN);

        dst_cap_group->sc_t_accept = 0;
        dst_cap_group->sc_n_accept = 0;
        dst_cap_group->sc_t_pgfault = 0;
        dst_cap_group->sc_n_pgfault = 0;
        
        return dst_cap_group;
}

void copy_pmos(struct cap_group *dst_cap_group, struct cap_group *src_cap_group)
{
        cap_t slot_id;
        struct slot_table *slot_table;
        struct object_slot *slot;
        struct pmobject *pmo, *new_pmo;
        void *new_va;
        
        slot_table = &src_cap_group->slot_table;

        for_each_set_bit (
                slot_id, slot_table->slots_bmp, slot_table->slots_size) {
                slot = get_slot(src_cap_group, slot_id);

                if (slot->object->type != TYPE_PMO) {
                        continue;
                }

                pmo = (struct pmobject *)slot->object->opaque;

                if (pmo->type != PMO_DATA && pmo->type != PMO_ANONYM &&
                    pmo->type != PMO_FORBID) {
                        BUG_ON(pmo->type != PMO_SC_SHM);
                        
                        new_pmo = obj_alloc(TYPE_PMO, sizeof(*new_pmo));
                        BUG_ON(!new_pmo);
                        new_pmo->type = PMO_SC_SHM;
                        new_pmo->size = pmo->size;
                        BUG_ON(pmo->size != (1UL << 12 << 9));
                        new_va = split_container_get_pages(9, 0);
                        BUG_ON(!new_va);
                        new_pmo->start = virt_to_phys(new_va);
                        new_pmo->private = (void *)(long)slot_id;

                        pmo = new_pmo;
                }

                BUG_ON(cap_alloc_at(dst_cap_group, pmo, slot_id) < 0);
        }
}

void copy_vmspace(struct cap_group *dst_cap_group, struct cap_group *src_cap_group, unsigned long pcid)
{
        struct vmspace *src_vmspace;
        struct vmspace *dst_vmspace;
        
        dst_vmspace = obj_alloc(TYPE_VMSPACE, sizeof(*dst_vmspace));
        BUG_ON(cap_alloc(dst_cap_group, dst_vmspace) != VMSPACE_OBJ_ID);
	vmspace_init(dst_vmspace, pcid);

        src_vmspace = obj_get(src_cap_group, VMSPACE_OBJ_ID, TYPE_VMSPACE);
        vmspace_clone(dst_vmspace, src_vmspace, dst_cap_group);
        obj_put(src_vmspace);
}

void copy_threads(struct cap_group *dst_cap_group, struct cap_group *src_cap_group)
{
        cap_t slot_id;
        struct slot_table *slot_table;
        struct object_slot *slot;
        struct thread *src_thread;
        struct thread *dst_thread;

        slot_table = &src_cap_group->slot_table;

        for_each_set_bit (
                slot_id, slot_table->slots_bmp, slot_table->slots_size) {
                slot = get_slot(src_cap_group, slot_id);

                if (slot->object->type != TYPE_THREAD) {
                        continue;
                }

                src_thread = (struct thread *)slot->object->opaque;

                if (src_thread->general_ipc_config) {
                        dst_thread = src_thread;
                } else {
                        BUG_ON(src_thread->cap_group != src_cap_group);
                        dst_thread = obj_alloc(TYPE_THREAD, sizeof(*dst_thread));
                        BUG_ON(!dst_thread);
                        thread_clone(dst_thread, src_thread, dst_cap_group);
                }

                dst_thread->cap = cap_alloc_at(dst_cap_group, dst_thread, slot_id);
                BUG_ON(dst_thread->cap < 0);
        }
}

void copy_notifcs(struct cap_group *dst_cap_group, struct cap_group *src_cap_group)
{
        cap_t slot_id;
        struct slot_table *slot_table;
        struct object_slot *slot;
        struct notification *src_notifc;
        struct notification *dst_notifc;

        slot_table = &src_cap_group->slot_table;

        for_each_set_bit (
                slot_id, slot_table->slots_bmp, slot_table->slots_size) {
                slot = get_slot(src_cap_group, slot_id);

                if (slot->object->type != TYPE_NOTIFICATION) {
                        continue;
                }

                src_notifc = (struct notification *)slot->object->opaque;

                dst_notifc = obj_alloc(TYPE_NOTIFICATION, sizeof(*dst_notifc));
                BUG_ON(!dst_notifc);
                notifc_clone(dst_notifc, src_notifc, dst_cap_group);

                BUG_ON(cap_alloc_at(dst_cap_group, dst_notifc, slot_id) < 0);
        }
}

long signal_all_notifcs(struct cap_group *cap_group)
{
        cap_t slot_id;
        struct slot_table *slot_table;
        struct object_slot *slot;
        struct notification *notifc;

        slot_table = &cap_group->slot_table;

        read_lock(&slot_table->table_guard);

        for_each_set_bit (
                slot_id, slot_table->slots_bmp, slot_table->slots_size) {
                slot = get_slot(cap_group, slot_id);

                if (slot->object->type != TYPE_NOTIFICATION) {
                        continue;
                }

                notifc = (struct notification *)slot->object->opaque;
                while (notifc->waiting_threads_count)
                        signal_notific(notifc);
        }

        read_unlock(&slot_table->table_guard);

        return 0;
}

void activate_threads(struct cap_group *cap_group)
{
        struct thread *thread;

        lock(&cap_group->threads_lock);

        for_each_in_list (thread, struct thread, node,
                          &cap_group->thread_list) {
                if (thread->thread_ctx->state == TS_WAITING) {
#ifdef CHCORE_SPLIT_CONTAINER_SYNC
                        split_container_activate_thread(thread, false);
#else /* CHCORE_SPLIT_CONTAINER_SYNC */
                        split_container_activate_thread(thread, true);
                        while (!cap_group->sc_enable_sync &&
                               *(volatile unsigned int *)&thread->thread_ctx->sc->sc_aff == NO_AFF);
#endif /* CHCORE_SPLIT_CONTAINER_SYNC */
                }
        }

        for_each_in_list (thread, struct thread, node,
                          &cap_group->thread_list) {
                if (thread->thread_ctx->state == TS_INTER) {
                        split_container_activate_thread(thread, false);
                }
        }

        unlock(&cap_group->threads_lock);
}

cap_t restore(badge_t badge, unsigned long pcid)
{
        struct cap_group *image;
        struct cap_group *cap_group;
        cap_t cap;
        
        image = g_image;
        BUG_ON(image == NULL);

        // printk("restore begin\n");

        check_image_slot_table(image);

        cap_group = copy_cap_group(image, badge);
        copy_pmos(cap_group, image);
        copy_vmspace(cap_group, image, pcid);
        copy_threads(cap_group, image);
        copy_notifcs(cap_group, image);

        cap = cap_copy(cap_group, current_cap_group, CAP_GROUP_OBJ_ID);
        BUG_ON(cap < 0);

        // printk("restore done\n");

        activate_threads(cap_group);

        return cap;
}
