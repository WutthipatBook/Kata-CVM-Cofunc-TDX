/*
 * Copyright (c) 2023 Institute of Parallel And Distributed Systems (IPADS), Shanghai Jiao Tong University (SJTU)
 * Licensed under the Mulan PSL v2.
 * You can use this software according to the terms and conditions of the Mulan PSL v2.
 * You may obtain a copy of Mulan PSL v2 at:
 *     http://license.coscl.org.cn/MulanPSL2
 * THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR
 * PURPOSE.
 * See the Mulan PSL v2 for more details.
 */

#include <common/types.h>
#include <common/kprint.h>
#include <common/lock.h>
#include <mm/mm.h>
#include <sched/sched.h>
#include <sched/fpu.h>
#include <arch/machine/smp.h>
#include <arch/machine/machine.h>
#include <arch/drivers/multiboot2.h>
#include <arch/drivers/acpi.h>
#include <arch/pci.h>
#include <arch/mmu.h>
#include <arch/tools.h>
#include <io/uart.h>
#include <irq/irq.h>
#include <irq/timer.h>
#include <object/thread.h>
#include <common/vars.h>
#ifdef CHCORE_PLAT_AMD_SEV
#include <sev.h>
#endif /* CHCORE_PLAT_AMD_SEV */
// #include <tdx.h>
// #include <arch/time.h>

/* Global big kernel lock */
struct lock big_kernel_lock;

void run_test(void);
void init_fpu_owner_locks(void);

// void evaluate_vmexit(void)
// {
//         int i;
//         u64 t0, t1;
// 	u64 cc = 1000000;
//         u64 c = 1000;
// 	for (i = 0; i < cc; i++)
//                 // tdx_do_hypercall(0, 0x1ffff, 0, 0, 0);
// 		sev_snp_do_hypercall(13, 0, 0, 0);
//         t0 = get_cycles();
//         for (i = 0; i < c; i++)
//                 // tdx_do_hypercall(0, 0x1ffff, 0, 0, 0);
//                 sev_snp_do_hypercall(13, 0, 0, 0);
//         t1 = get_cycles();
        
//         printk("hypercall cycle: %lu\n", (t1 - t0) / c);
// 	while (1);
// }

void main(u64 mbmagic, paddr_t mbaddr)
{
	u32 ret = 0;

#ifdef CHCORE_PLAT_AMD_SEV
	sev_snp_init_per_cpu_ghcb(0);
#endif /* CHCORE_PLAT_AMD_SEV */

	uart_init();
	kinfo("[ChCore] uart init finished\n");

	// evaluate_vmexit();

	parse_mb2_info(mbmagic, phys_to_virt(mbaddr));
	kinfo("[ChCore] parse multiboot2 info finished\n");

	/*
	 * Multiboot2 will pass the ACPI information
	 * and ChCore now retreives the MADT from it for getting APIC info.
	 */
	parse_acpi_info((void *)get_mb2_acpi()->rsdp);
	kinfo("[ChCore] parse acpi info finished\n");

	init_per_cpu_info(0);	/* should passed from boot? */
	kinfo("[ChCore] per cpu info init finished\n");

	arch_interrupt_init();
	timer_init();
	kinfo("[ChCore] interrupt init finished\n");

	/* Configure the syscall entry */
	arch_syscall_init();
	kinfo("[ChCore] SYSCALL init finished\n");

	mm_init((void *)get_mb2_mmap());
	kinfo("[ChCore] mm init finished\n");
	
	/* Mapping KSTACK into kernel page table. */
	map_range_in_pgtbl_kernel((void*)((unsigned long)CHCORE_PGD), 
			KSTACKx_ADDR(0),
			(unsigned long)(cpu_stacks[0]) - KCODE, 
			CPU_STACK_SIZE, VMR_READ | VMR_WRITE);

	/* Configure CPU features: setting per_core registers */
	arch_cpu_init();

	/* Init big kernel lock */
	ret = lock_init(&big_kernel_lock);
	kinfo("[ChCore] lock init finished\n");
	BUG_ON(ret != 0);

#if defined(CHCORE_KERNEL_SCHED_PBFIFO)
	sched_init(&pbfifo);
#elif defined(CHCORE_KERNEL_RT)
	sched_init(&pbrr);
#else
	sched_init(&rr);
#endif
	kinfo("[ChCore] sched init finished\n");

	enable_smp_cores();
	kinfo("[ChCore] boot smp\n");

	init_fpu_owner_locks();

	/* Test should be done when IRQ is not enabled */
#ifdef CHCORE_KERNEL_TEST
	kinfo("[ChCore] kernel tests start\n");
	run_test();
	kinfo("[ChCore] kernel tests done\n");
#endif /* CHCORE_KERNEL_TEST */

#if FPU_SAVING_MODE == LAZY_FPU_MODE
	disable_fpu_usage();
#endif

        /* Flush all tlbs during boot (kernel uses the lower addresses at boot time) */
	flush_tlb_all();

	/* Create the first user thread */
	create_root_thread();
	kinfo("[ChCore] create initial thread done\n");

#ifdef CHCORE_PLAT_INTEL
	pci_init();
#endif /* CHCORE_PLAT_INTEL */

	sched();
	eret_to_thread(switch_context());
	BUG("Should never be here!\n");
}

/* For booting smp cores */
void secondary_start(u32 cpuid)
{
#ifdef CHCORE_PLAT_AMD_SEV
	sev_snp_init_per_cpu_ghcb(cpuid);
#endif /* CHCORE_PLAT_AMD_SEV */

	arch_interrupt_init_per_cpu();
	init_per_cpu_info(cpuid);
	timer_init();

	/* Mapping KSTACK into kernel page table. */
	map_range_in_pgtbl_kernel((void*)((unsigned long)CHCORE_PGD), 
			KSTACKx_ADDR(cpuid),
			(unsigned long)(cpu_stacks[cpuid]) - KCODE, 
			CPU_STACK_SIZE, VMR_READ | VMR_WRITE);

	/* Configure the syscall entry */
	arch_syscall_init();
	/* Configure CPU features: setting per_core registers */
	arch_cpu_init();

	/* Test should be done when IRQ is not enabled */
#ifdef CHCORE_KERNEL_TEST
	run_test();
#endif /* CHCORE_KERNEL_TEST */

#if FPU_SAVING_MODE == LAZY_FPU_MODE
	disable_fpu_usage();
#endif

        /* Flush all tlbs during boot (kernel uses the lower addresses at boot time) */
	flush_tlb_all();

	/* Run the scheduler on the current CPU core */
	sched();
	eret_to_thread(switch_context());
	BUG("Should never be here!\n");
}
