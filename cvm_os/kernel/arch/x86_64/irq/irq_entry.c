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

#include "irq_entry.h"
#include <arch/x2apic.h>
#include <seg.h>
#include <machine.h>
#include <common/kprint.h>
#include <common/util.h>
#include <common/macro.h>
#include <arch/sched/arch_sched.h>
#include <arch/io.h>
#include <arch/time.h>
#include <irq/timer.h>
#include <object/thread.h>
#include <object/irq.h>
#include <object/recycle.h>
#include <object/ptrace.h>
#include <irq/irq.h>
#include <irq/ipi.h>
#include <sched/sched.h>
#include <sched/fpu.h>
#include <mm/vmspace.h>
#ifdef CHCORE_PLAT_AMD_SEV
#include <sev.h>
#endif /* CHCORE_PLAT_AMD_SEV */

/* idt and idtr */
struct gate_desc idt[T_NUM] __attribute__((aligned(16)));
struct pseudo_desc idtr = { sizeof(idt) - 1, (u64) idt };

/* record irq is handled by kernel or user */
u8 irq_handle_type[MAX_IRQ_NUM];

void arch_enable_irq(void)
{
	asm volatile("sti");
}

void arch_disable_irq(void)
{
	asm volatile("cli");
}

#define PIC1_BASE 0x20
#define PIC2_BASE 0xa0

void initpic(void)
{
	put8(PIC1_BASE + 1, 0xff);
	put8(PIC2_BASE + 1, 0xff);
}

void arch_enable_irqno(int irq)
{
	BUG("Not impl.");
}

void arch_disable_irqno(int irq)
{
	BUG("Not impl.");
}

void arch_interrupt_init_per_cpu(void)
{
	u32 eax, ebx, ecx, edx;

	cpuid(1, &eax, &ebx, &ecx, &edx);
	if (ecx & FEATURE_ECX_X2APIC)
		x2apic_init();
	else if (edx & FEATURE_EDX_XAPIC)
		BUG("xapic init not implemented\n");
	else
		BUG("not apic detected\n");
	arch_disable_irq();
	initpic();
	asm volatile("lidt (%0)" : : "r" (&idtr));
}

void arch_interrupt_init(void)
{
        int i = 0;

        /* Set up interrupt gates */
        for (i = 0; i < T_NUM; i ++)
        {
                /* Set all gate to interrupt gate to be effected by eflags.interrupt_enable */
                if (i == T_BP) {
                        set_gate(idt[i], GT_INTR_GATE, KCSEG64, idt_entry[i], 3);
                } else {
                        set_gate(idt[i], GT_INTR_GATE, KCSEG64, idt_entry[i], 0);
                }
        }
        arch_interrupt_init_per_cpu();

	memset(irq_handle_type, HANDLE_KERNEL, MAX_IRQ_NUM);
}

/* Mark the end of an IRQ */
void arch_ack_irq(void)
{
	x2apic_eoi();
}

/*
 * This interface is only for the common interface across different
 * architectures.
 */
void plat_ack_irq(int irq)
{
	arch_ack_irq();
}

void plat_set_next_timer(u64 tick_delta)
{
#ifndef CHCORE_PLAT_AMD_SEV
	u64 tsc;
	tsc = get_cycles();
	wrmsr(MSR_IA32_TSC_DEADLINE, tsc + tick_delta);
#endif /* CHCORE_PLAT_AMD_SEV */
}

void plat_handle_timer_irq(u64 tick_delta)
{
	plat_set_next_timer(tick_delta);
	arch_ack_irq();
}

void plat_disable_timer(void)
{
	x2apic_disable_timer();
}

void plat_enable_timer(void)
{
	x2apic_enable_timer();
}

void handle_irq(int irqno)
{
	int r;

	BUG_ON(irqno >= MAX_IRQ_NUM);
	if (irq_handle_type[irqno] == HANDLE_USER) {
		r = user_handle_irq(irqno);
		BUG_ON(r);
		return;
	}

	switch (irqno) {
	case IRQ_TIMER:
		handle_timer_irq();

		/* Start the scheduler */
		sched_periodic();
		eret_to_thread(switch_context());
		return;

	case IRQ_IPI_TLB:
	case IRQ_IPI_RESCHED:
		// kinfo("CPU %d: receive IPI on TLB.\n", smp_get_cpu_id());
		handle_ipi();
		arch_ack_irq();
		return;

	default:
		kwarn("Unkown Exception\n");
	}
}

void trap_c(struct arch_exec_context *ec)
{
        int trapno = ec->reg[TRAPNO];
        int errorcode = ec->reg[EC];

#ifdef CHCORE_PLAT_AMD_SEV
	if (trapno == T_VC) {
		sev_snp_handle_vc(ec);
		return;
	}
#endif /* CHCORE_PLAT_AMD_SEV */

	/*
	 * When received IRQ in kernel
	 * When current_thread == TYPE_IDLE
	 * 	We should handle everything like user thread.
	 * Otherwice
	 * 	We should ignore the timer, handle other IRQ as normal.
	 */
	if (ec->reg[CS] == KCSEG64 &&	/* Trigger IRQ in kernel */
		current_thread ) {	/* Has running thread */
		BUG_ON(!current_thread->thread_ctx);
		if (current_thread->thread_ctx->type != TYPE_IDLE) {
			/* And the thread is not the IDLE thread */
			if (trapno == IRQ_TIMER) {
				/* We do not allow kernel preemption */
				/* TODO: dynamic high resulution timer */
				plat_handle_timer_irq(TICK_MS * 1000 * tick_per_us);
				return;
			}
		}
	}

	if (trapno == T_GP) {
		static int cnt = 0;
		if (cnt == 0) {
			cnt += 1;
			kinfo("General Protection Fault\n");
			kinfo("Current thread %p\n", current_thread);
			kinfo("Trap from 0x%lx EC %d Trap No. %d\n", ec->reg[RIP], errorcode, trapno);
			kinfo("DS 0x%x, CS 0x%x, RSP 0x%lx, SS 0x%x\n", ec->reg[DS], ec->reg[CS], ec->reg[RSP], ec->reg[SS]);
			kinfo("rax: 0x%lx, rdx: 0x%lx, rdi: 0x%lx\n", ec->reg[RAX], ec->reg[RDX], ec->reg[RDI]);
			kinfo("rcx: 0x%lx\n", ec->reg[RCX]);

			kprint_vmr(current_thread->vmspace);
			while(1);
		}
		// kinfo("General Protection Fault\n");
		while(1);
	}

	/* Just for kernel tracing and debugging */
	if ((trapno != IRQ_TIMER) &&
	    (trapno != T_DB) &&
	    (trapno != T_BP) &&
	    (trapno != T_PF) &&
	    (trapno != IRQ_IPI_TLB) &&
	    (trapno != IRQ_IPI_RESCHED) &&
#ifdef CHCORE_PLAT_INTEL_TDX
	    (trapno != T_VE) &&
#endif /* CHCORE_PLAT_INTEL_TDX */
	    (trapno != T_NM)) {
		kinfo("Trap from 0x%lx EC %d Trap No. %d\n", ec->reg[RIP], errorcode, trapno);
		kinfo("DS 0x%x, CS 0x%x, RSP 0x%lx, SS 0x%x\n", ec->reg[DS], ec->reg[CS], ec->reg[RSP], ec->reg[SS]);
		kinfo("rax: 0x%lx, rdx: 0x%lx, rdi: 0x%lx\n", ec->reg[RAX], ec->reg[RDX], ec->reg[RDI]);
	}

        switch(trapno)
        {
                case T_DE:
                        kinfo("Divide Error\n");
			backtrace();
			sys_exit_group(-1);
                        break;
                case T_DB:
                        handle_singlestep();
                        break;
                case T_NMI:
                        kinfo("Non-maskable Interrupt\n");
                        break;
                case T_BP:
                        handle_breakpoint();
                        break;
                case T_OF:
                        kinfo("Overflow\n");
                        break;
                case T_BR:
                        kinfo("Bounds Range Check\n");
                        break;
                case T_UD:
                        kinfo("Undefined Opcode\n");
                        break;
                case T_NM:
#if FPU_SAVING_MODE == LAZY_FPU_MODE
			change_fpu_owner();
			return;
#else
			break;
#endif
                case T_DF:
                        kinfo("Double Fault\n");
                        break;
                case T_CSO:
                        kinfo("Coprocessor Segment Overrun\n");
                        break;
                case T_TS:
                        kinfo("Invalid Task Switch Segment\n");
                        break;
                case T_NP:
                        kinfo("Segment Not Present\n");
                        break;
                case T_SS:
                        kinfo("Stack Exception\n");
                        break;
                case T_GP: {
			kinfo("General Protection Fault\n");
                        while(1);
                        break;
		}
                case T_PF: {
                        /* Page Fault Handler Here! */
#ifdef CHCORE_SPLIT_CONTAINER
			unsigned long t0 = get_cycles();
                        do_page_fault(errorcode, ec->reg[RIP]);
			unsigned long t1 = get_cycles();
			current_cap_group->sc_t_pgfault += t1 - t0;
			if (current_cap_group->sc_u_t_pgfault) {
			        *current_cap_group->sc_u_t_pgfault = current_cap_group->sc_t_pgfault;
			}
#else /* CHCORE_SPLIT_CONTAINER */
			do_page_fault(errorcode, ec->reg[RIP]);
#endif /* CHCORE_SPLIT_CONTAINER */
			return;
		}
                case T_MF:
                        kinfo("Floating Point Error\n");
                        break;
                case T_AC:
                        kinfo("Alignment Check\n");
                        break;
                case T_MC:
                        kinfo("Machine Check\n");
                        break;
                case T_XM:
                        kinfo("SIMD Floating Point Error\n");
                        break;
                case T_VE:
#ifndef CHCORE_PLAT_INTEL_TDX
                        kinfo("Virtualization Exception\n");
#else /* CHCORE_PLAT_INTEL_TDX */
			tdx_handle_ve(ec);
#endif /* CHCORE_PLAT_INTEL_TDX */
                        break;
                default:
			handle_irq(trapno);
			return;
        }

	/*
	 * After handling the interrupts,
	 * we directly resume the execution.
	 *
	 * Rescheduling only happens after IRQ_TIMER or IRQ_IPI_RESCHED.
	 */
	return;
}

void __eret_to_thread(unsigned long sp)
{
        struct thread_ctx *cur_thread = (struct thread_ctx *)sp;
        arch_exec_ctx_t *cur_thread_ctx = &cur_thread->ec;

        switch(cur_thread_ctx->reg[EC]){
                case EC_SYSEXIT:
                        eret_to_thread_through_sys_exit(sp);
                break;
                default:
                        eret_to_thread_through_trap_exit(sp);
                break;
        }
        /* Non-reachable here */
}
