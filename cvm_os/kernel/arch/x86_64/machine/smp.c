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

#include <common/vars.h>
#include <common/kprint.h>
#include <common/types.h>
#include <common/macro.h>
#include <common/util.h>
#include <mm/mm.h>
#include <mm/kmalloc.h>
#include <arch/drivers/acpi.h>
#include <arch/machine/smp.h>
#include <arch/x2apic.h>
#include <arch/tools.h>
#include <arch/mmu.h>
#include <machine.h>
#include <seg.h>
#include <memlayout.h>
#include <irq/ipi.h>
#ifdef CHCORE_PLAT_AMD_SEV
#include <sev.h>
#endif /* CHCORE_PLAT_AMD_SEV */

struct per_cpu_info cpu_info[PLAT_CPU_NUM] __attribute__((aligned(64)));
ALIGN(STACK_ALIGNMENT)
char cpu_stacks[PLAT_CPU_NUM][CPU_STACK_SIZE];
char *cur_cpu_stack;
u32 cur_cpu_id;

void init_per_cpu_info(u32 cpuid)
{
	u32 gdt_tss_lo;
	u32 gdt_tss_hi;
	struct desc_ptr gdt_descr;

	cpu_info[cpuid].cur_syscall_no = 0;
	cpu_info[cpuid].cur_exec_ctx = 0;
	cpu_info[cpuid].fpu_owner = NULL;
	cpu_info[cpuid].fpu_disable = 0;
	cpu_info[cpuid].cpu_id = cpuid;
	cpu_info[cpuid].cpu_stack = (char *)(KSTACKx_ADDR(cpuid) + CPU_STACK_SIZE);
	cpu_info[cpuid].apic_id = (u32)get_cpu_apic_id(cpuid);
	cpu_info[cpuid].cpu_status = cpu_run;

	gdt_tss_lo = GDT_TSS_BASE_LO + cpuid * 2;
	gdt_tss_hi = GDT_TSS_BASE_HI + cpuid * 2;

	/* for setting interrupt stack, set up per cpu gdt TSS seg */
	bootgdt[gdt_tss_lo] = (struct segdesc)
				      SEGDESC((u64)&(cpu_info[cpuid].tss),
				      sizeof(cpu_info[cpuid].tss) - 1,
				      SEG_P|SEG_TSS64A);

	bootgdt[gdt_tss_hi] = (struct segdesc)
				      SEGDESCHI((u64)&(cpu_info[cpuid].tss));
	/* TDVF's GDT is used now, cannot set the task register */
#ifndef CHCORE_PLAT_INTEL_TDX
	asm volatile ("ltr %0" : : "r" ((u16)(gdt_tss_lo << 3)));
#endif /* CHCORE_PLAT_INTEL_TDX */

	/* Done during GHCB init on AMD-SEV platform */
#ifndef CHCORE_PLAT_AMD_SEV
	asm volatile ("wrmsr"::
		      "a" ((u32) ((u64) & cpu_info[cpuid])),
		      "d"((u32) ((u64) & cpu_info[cpuid] >> 32)),
		      "c"(MSR_GSBASE));
	asm volatile ("swapgs");
#endif /* CHCORE_PLAT_AMD_SEV */

	gdt_descr.size = sizeof(bootgdt) - 1;
	gdt_descr.address = (u64)&bootgdt;
	asm volatile("lgdt (%0)" : : "r" (&gdt_descr) : "memory");

	/* Set the task register after switching to ChCore's GDT */
#ifdef CHCORE_PLAT_INTEL_TDX
	asm volatile ("ltr %0" : : "r" ((u16)(gdt_tss_lo << 3)));
#endif /* CHCORE_PLAT_INTEL_TDX */
}

void enable_smp_cores(void)
{
	int cpuid;
#ifndef CHCORE_PLAT_INTEL_TDX
	u64 mp_code;

        /* check secondary boot size */
        BUG_ON((u64)(&text) < MP_BOOT_ADDR + (u64)(&_mp_start_end) - (u64)(&_mp_start));

        mp_code = phys_to_virt(MP_BOOT_ADDR);
        memmove((void *)mp_code, (void *)(&_mp_start), (u64)(&_mp_start_end) - (u64)(&_mp_start));
#endif /* CHCORE_PLAT_INTEL_TDX */

	/*
	 * TODO: Since we can detect the real CPU number by reading the MADT,
	 * we can avoid using the static PLAT_CPU_NUM.
	 */
	for (cpuid = 1; cpuid < PLAT_CPU_NUM; cpuid ++)
	{
		/* Set kernel stack */
		cur_cpu_stack = cpu_stacks[cpuid] + CPU_STACK_SIZE;
		cur_cpu_id = cpuid;

		/* should use lapic to pass the physical boot address */
		/* XXX: Should get the real hwid and pass it to x2apic_sipi */
		asm volatile("mfence");
		/* use apic id to specify ipi destination */
#if defined(CHCORE_PLAT_AMD_SEV)
		sev_snp_wakeup_cpu(get_cpu_apic_id(cpuid), (u64)virt_to_phys((void *)mp_code));
#elif defined(CHCORE_PLAT_INTEL_TDX)
		madt_wakeup_cpu(get_cpu_apic_id(cpuid), (u64)&_mp_start - KCODE);
#else
		x2apic_sipi(get_cpu_apic_id(cpuid), (u64)virt_to_phys((void *)mp_code));
#endif
		kdebug("[SMP] send sipi to core %d\n", cpuid);
		while (cpu_info[cpuid].cpu_status != cpu_run);
		kinfo("[SMP] CPU %d is running\n", cpuid);
		/* check target cpu status */
	}

	init_ipi_data();
}

inline u32 smp_get_cpu_id(void)
{
	u32 cpuid;

	/*
	 * %c: Require a constant operand and
	 * print the constant expression with no punctuation.
	 *
	 * We do not use offsetof since it cannot be used in
	 * irq_entry.S.
	 */
	asm volatile ("mov %%gs:%c1, %0"
		      : "=r"(cpuid)
		      : "i"(OFFSET_LOCAL_CPU_ID)
		      : "memory");
	return cpuid;
}
