#include <tdx.h>
#include <machine.h>
#include <common/types.h>
#include <common/macro.h>
#include <arch/time.h>
static u64 _tdx_hypercall(u64 fn, u64 r12, u64 r13, u64 r14,
		u64 r15)
{
	struct tdx_hypercall_args args = {
		.r10 = TDX_HYPERCALL_STANDARD,
		.r11 = fn,
		.r12 = r12,
		.r13 = r13,
		.r14 = r14,
		.r15 = r15,
	};

	return __tdx_hypercall(&args, 0);
}

/*
 * Used for TDX guests to make calls directly to the TD module.  This
 * should only be used for calls that have no legitimate reason to fail
 * or where the kernel can not survive the call failing.
 */
static inline void tdx_module_call(u64 fn, u64 rcx, u64 rdx, u64 r8, u64 r9,
				   struct tdx_module_output *out)
{
	BUG_ON(__tdx_module_call(fn, rcx, rdx, r8, r9, out));
}

unsigned int tdx_do_in(int size, u16 port)
{
	struct tdx_hypercall_args args = {
		.r10 = TDX_HYPERCALL_STANDARD,
		.r11 = EXIT_REASON_IO_INSTRUCTION,
		.r12 = size,
		.r13 = 0,
		.r14 = port,
	};

	BUG_ON(__tdx_hypercall(&args, TDX_HCALL_HAS_OUTPUT));

	return args.r11;
}

void tdx_do_out(int size, u16 port, u32 value)
{
	struct tdx_hypercall_args args = {
		.r10 = TDX_HYPERCALL_STANDARD,
		.r11 = EXIT_REASON_IO_INSTRUCTION,
		.r12 = size,
		.r13 = 1,
		.r14 = port,
		.r15 = value,
	};

	BUG_ON(__tdx_hypercall(&args, 0));
}

static bool msr_need_tdcall(u64 msr)
{
        switch (msr) {
        case MSR_GSBASE:
        case MSR_STAR:
        case MSR_LSTAR:
        case MSR_SFMASK:
	case 0x80b: // IA32_X2APIC_EOI
                return false;
        }

        return true;
}

u64 tdx_do_rdmsr(u64 msr)
{
	struct tdx_hypercall_args args = {
		.r10 = TDX_HYPERCALL_STANDARD,
		.r11 = EXIT_REASON_MSR_READ,
		.r12 = msr,
	};

	if (!msr_need_tdcall(msr)) {
		return __rdmsr(msr);
	}

	/*
	 * Emulate the MSR read via hypercall. More info about ABI
	 * can be found in TDX Guest-Host-Communication Interface
	 * (GHCI), section titled "TDG.VP.VMCALL<Instruction.RDMSR>".
	 */
	BUG_ON(__tdx_hypercall(&args, TDX_HCALL_HAS_OUTPUT));

	return args.r11;
}

void tdx_do_wrmsr(u64 msr, u64 value)
{
	struct tdx_hypercall_args args = {
		.r10 = TDX_HYPERCALL_STANDARD,
		.r11 = EXIT_REASON_MSR_WRITE,
		.r12 = msr,
		.r13 = value,
	};

	if (!msr_need_tdcall(msr)) {
		__wrmsr(msr, value);
		return;
	}

	/*
	 * Emulate the MSR write via hypercall. More info about ABI
	 * can be found in TDX Guest-Host-Communication Interface
	 * (GHCI) section titled "TDG.VP.VMCALL<Instruction.WRMSR>".
	 */
	BUG_ON(__tdx_hypercall(&args, 0));
}

long tdx_do_hypercall(u32 nr, u64 p1, u64 p2, u64 p3, u64 p4)
{
	struct tdx_hypercall_args args = {
		.r10 = nr,
		.r11 = p1,
		.r12 = p2,
		.r13 = p3,
		.r14 = p4,
	};

	__tdx_hypercall(&args, TDX_HCALL_HAS_OUTPUT);

	return args.r11;
}

enum pg_level {
	PG_LEVEL_NONE,
	PG_LEVEL_4K,
	PG_LEVEL_2M,
	PG_LEVEL_1G,
	PG_LEVEL_512G,
	PG_LEVEL_NUM
};

#define PAGE_SHIFT      12
#define PTE_SHIFT       9

static inline int page_level_shift(enum pg_level level)
{
	return (PAGE_SHIFT - PTE_SHIFT) + level * PTE_SHIFT;
}

static inline unsigned long page_level_size(enum pg_level level)
{
	return 1UL << page_level_shift(level);
}

static unsigned long try_accept_one(paddr_t start, unsigned long len,
				    enum pg_level pg_level)
{
	unsigned long accept_size = page_level_size(pg_level);
	u64 tdcall_rcx;
	u8 page_size;
	unsigned long ret;

	if (!IS_ALIGNED(start, accept_size))
		return 0;

	if (len < accept_size)
		return 0;

	/*
	 * Pass the page physical address to the TDX module to accept the
	 * pending, private page.
	 *
	 * Bits 2:0 of RCX encode page size: 0 - 4K, 1 - 2M, 2 - 1G.
	 */
	switch (pg_level) {
	case PG_LEVEL_4K:
		page_size = 0;
		break;
	case PG_LEVEL_2M:
		page_size = 1;
		break;
	case PG_LEVEL_1G:
		page_size = 2;
		break;
	default:
		return 0;
	}

	tdcall_rcx = start | page_size;
	if ((ret = __tdx_module_call(TDX_ACCEPT_PAGE, tdcall_rcx, 0, 0, 0, NULL))) {
		if ((ret >> 32) == 0xB0A)
			return accept_size;
		printk("2M reject reason: 0x%lx, 0x%lx, %d\n", ret, start, (int)page_size);
		return 0;
	}

	return accept_size;
}

bool tdx_enc_status_changed_phys(paddr_t start, paddr_t end, bool enc)
{
        if (!enc) {
		/* Set the shared (decrypted) bits: */
		start |= BIT(51);
		end   |= BIT(51);
	}

	/*
	 * Notify the VMM about page mapping conversion. More info about ABI
	 * can be found in TDX Guest-Host-Communication Interface (GHCI),
	 * section "TDG.VP.VMCALL<MapGPA>"
	 */
	if (_tdx_hypercall(TDVMCALL_MAP_GPA, start, end - start, 0, 0))
		return false;

	/* private->shared conversion  requires only MapGPA call */
	if (!enc)
		return true;

	/*
	 * For shared->private conversion, accept the page using
	 * TDX_ACCEPT_PAGE TDX module call.
	 */
	while (start < end) {
		unsigned long len = end - start;
		unsigned long accept_size;

		/*
		 * Try larger accepts first. It gives chance to VMM to keep
		 * 1G/2M Secure EPT entries where possible and speeds up
		 * process by cutting number of hypercalls (if successful).
		 */
		accept_size = try_accept_one(start, len, PG_LEVEL_1G);
		if (!accept_size)
			accept_size = try_accept_one(start, len, PG_LEVEL_2M);
		if (!accept_size)
			accept_size = try_accept_one(start, len, PG_LEVEL_4K);
		
		if (!accept_size)
			return false;
		start += accept_size;
	}

	return true;
}

void tdx_get_ve_info(struct ve_info *ve)
{
	struct tdx_module_output out;

	/*
	 * Called during #VE handling to retrieve the #VE info from the
	 * TDX module.
	 *
	 * This has to be called early in #VE handling.  A "nested" #VE which
	 * occurs before this will raise a #DF and is not recoverable.
	 *
	 * The call retrieves the #VE info from the TDX module, which also
	 * clears the "#VE valid" flag. This must be done before anything else
	 * because any #VE that occurs while the valid flag is set will lead to
	 * #DF.
	 *
	 * Note, the TDX module treats virtual NMIs as inhibited if the #VE
	 * valid flag is set. It means that NMI=>#VE will not result in a #DF.
	 */
	tdx_module_call(TDX_GET_VEINFO, 0, 0, 0, 0, &out);

	/* Transfer the output parameters */
	ve->exit_reason = out.rcx;
	ve->exit_qual   = out.rdx;
	ve->gla         = out.r8;
	ve->gpa         = out.r9;
	ve->instr_len   = out.r10 & 0xffffffffU;
	ve->instr_info  = out.r10 >> 32;
}

void tdx_do_cpuid(unsigned long *rax, unsigned long *rbx, unsigned long *rcx, unsigned long *rdx)
{
	struct tdx_hypercall_args args = {
		.r10 = TDX_HYPERCALL_STANDARD,
		.r11 = EXIT_REASON_CPUID,
		.r12 = *rax,
		.r13 = *rcx,
	};

	/*
	 * CPUID leaf 0x2 provides cache and TLB information.
	 *
	 * The leaf is obsolete. There are leafs that provides the same
	 * information in a structured form. See leaf 0x4 on cache info and
	 * leaf 0x18 on TLB info.
	 */
	if (*rax == 2) {
		/*
		 * Each byte in EAX/EBX/ECX/EDX is an informational descriptor.
		 *
		 * The least-significant byte in register EAX always returns
		 * 0x01. Software should ignore this value and not interpret
		 * it as an informational descriptor.
		 *
		 * Descriptors used here:
		 *
		 *  - 0xff: use CPUID leaf 0x4 to query cache parameters;
		 *
		 *  - 0xfe: use CPUID leaf 0x18 to query TLB and other address
		 *          translation parameters.
		 *
		 * XXX: provide prefetch information?
		 */
		*rax = 0xf1ff01;
		*rbx = *rcx = *rdx = 0;
		return;
	}

	/*
	 * Only allow VMM to control range reserved for hypervisor
	 * communication.
	 *
	 * Return all-zeros for any CPUID outside the range. It matches CPU
	 * behaviour for non-supported leaf.
	 */
	// if (*rax < 0x40000000 || *rax > 0x4FFFFFFF) {
	// 	*rax = *rbx = *rcx = *rdx = 0;
	// 	return;
	// }

	/*
	 * Emulate the CPUID instruction via a hypercall. More info about
	 * ABI can be found in TDX Guest-Host-Communication Interface
	 * (GHCI), section titled "VP.VMCALL<Instruction.CPUID>".
	 */
	BUG_ON(__tdx_hypercall(&args, TDX_HCALL_HAS_OUTPUT));

	/*
	 * As per TDX GHCI CPUID ABI, r12-r15 registers contain contents of
	 * EAX, EBX, ECX, EDX registers after the CPUID instruction execution.
	 * So copy the register contents back to pt_regs.
	 */
	*rax = args.r12;
	*rbx = args.r13;
	*rcx = args.r14;
	*rdx = args.r15;
}

void tdx_handle_ve(struct arch_exec_context *ec)
{
	struct ve_info ve;

	tdx_get_ve_info(&ve);
	if (ve.exit_reason != EXIT_REASON_CPUID) {
		printk("EXIT_REASON=%llu, GPA=0x%llx\n", ve.exit_reason, ve.gpa);
	}
	BUG_ON(ve.exit_reason != EXIT_REASON_CPUID);

	tdx_do_cpuid(&ec->reg[RAX], &ec->reg[RBX], &ec->reg[RCX], &ec->reg[RDX]);

	ec->reg[RIP] += ve.instr_len;
}
