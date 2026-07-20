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

#include <common/asm.h>
#include <seg.h>
#include <memlayout.h>
#include <arch/drivers/multiboot2.h>

/* Linux 0xffffffff80000000 */
#define KCODE      0xFFFFFFFFC0000000
#define PADDR(x)   ((x) - KCODE)
#define KSTACKSIZE (4*0x1000)

/* linker.ld provides: edata and end */

/* MultiBoot2 header */
.align 8
.text
EXPORT(multiboot_header)
        .long MULTIBOOT2_HEADER_MAGIC			# multiboo2 magic number
        .long MULTIBOOT_ARCHITECTURE_I386		# architecture: 32-bit (protected) mode of i386
        .long multiboot_header_end - multiboot_header	# header_length
        .long (multiboot_header - MULTIBOOT2_HEADER_MAGIC - MULTIBOOT_ARCHITECTURE_I386 - multiboot_header_end) # checksum
address_tag_start:
.align 8
        .short MULTIBOOT_HEADER_TAG_ADDRESS
        .short MULTIBOOT_HEADER_TAG_OPTIONAL
        .long address_tag_end - address_tag_start
        /* header_addr */
        .long   PADDR(multiboot_header)
        /* load_addr */
        .long   PADDR(multiboot_header)
        /* load_end_addr */
        .long   PADDR(edata)
        /* bss_end_addr */
        .long   PADDR(end)
address_tag_end:
efi_boot_services_tag_start:
.align 8
        .short MULTIBOOT_HEADER_TAG_EFI_BS
        .short MULTIBOOT_HEADER_TAG_OPTIONAL
        .long efi_boot_services_tag_end - efi_boot_services_tag_start
efi_boot_services_tag_end:
efi_amd64_entry_address_tag_start:
.align 8
        .short MULTIBOOT_HEADER_TAG_ENTRY_ADDRESS_EFI64
        .short MULTIBOOT_HEADER_TAG_OPTIONAL
        .long efi_amd64_entry_address_tag_end - efi_amd64_entry_address_tag_start
        .long PADDR(_start)
efi_amd64_entry_address_tag_end:
framebuffer_tag_start:
.align 8
        .short MULTIBOOT_HEADER_TAG_FRAMEBUFFER
        .short MULTIBOOT_HEADER_TAG_OPTIONAL
        .long framebuffer_tag_end - framebuffer_tag_start
        .long 640
        .long 480
        .long 32
framebuffer_tag_end:
.align 8
        .short MULTIBOOT_TAG_TYPE_END
        .short 0
        .long 8
multiboot_header_end:

/* Entry point: running in 64-bit mode */
.code64
EXPORT(_start)
	movl %eax, %edi /* multiboot_magic */
	movl %ebx, %esi /* multiboot_info_ptr */

	wbinvd
	/* set init stack */
	movl $PADDR(stack+KSTACKSIZE), %esp

	/* zero bss */
	movl %edi, %edx
	/*
	 * rep stosb
	 * For ecx repetitions, stores the contents of eax into where edi points to,
	 * incrementing or decrementing edi (depending on the direction flag) by 4 bytes each time.
	 * Normally, this is used for a memset-type operation.  */
	movl $PADDR(edata), %edi
	movl $PADDR(end), %ecx
	subl $PADDR(edata), %ecx
	movl $0, %eax
	cld
	rep stosb
	movl %edx, %edi

        mov $PADDR(CHCORE_PGD), %rax
	mov %rax, %cr3

        mov $PADDR(_start64), %rax
        movq $KCODE, %r11
	addq %r11, %rax
        jmp *%rax

.code64
_start64:
	/* load VA stack */
	movabsq $(stack+KSTACKSIZE), %rsp
	movq $0, %rbp
	call main
	/* Un-reachable */
	jmp .

/* SMP boot entry */
.code64
EXPORT(_mp_start)
        mov $PADDR(CHCORE_PGD), %rax
	mov %rax, %cr3

        mov $PADDR(_mp_start64), %rax
        movq $KCODE, %r11
	addq %r11, %rax
        jmp *%rax

.code64
_mp_start64:
	movq cur_cpu_stack, %rsp
	movq $0, %rbp
	movl cur_cpu_id, %edi
	call secondary_start
	/* Un-reachable */
	jmp .

/* initial stack */
.comm stack, KSTACKSIZE

/* Page table attribute bits */
#define PRESENT  (1 << 0)
#define WRITABLE (1 << 1)
#define HUGE_1G  (1 << 7)
#define GLOBAL   (1 << 8)
#define NX	 (1ULL << 63)

/* CHCORE page table: one PGD page */
.align 4096
.global CHCORE_PGD
CHCORE_PGD:
	.quad PADDR(PUD_0)    + PRESENT + WRITABLE
	.space 4096 - 3*8
	.quad PADDR(PUD_DM)   + PRESENT + WRITABLE
	.quad PADDR(PUD_CODE) + PRESENT + WRITABLE

/* CHCORE page table: three PUD pages */
.align 4096
.global CHCORE_PUD_Boot_Mapping
CHCORE_PUD_Boot_Mapping:
PUD_0:
	/*
	 * Bindly mapping 0~4G with rwx here.
	 * We will adjust the kernel page table mapping after detecting
	 * the useable physical memory. See 'refill_kernel_page_table'.
	 */
	.quad (0 << 30) + PRESENT + WRITABLE + HUGE_1G + GLOBAL
	.quad (1 << 30) + PRESENT + WRITABLE + HUGE_1G + GLOBAL
	.quad (2 << 30) + PRESENT + WRITABLE + HUGE_1G + GLOBAL
	.quad (3 << 30) + PRESENT + WRITABLE + HUGE_1G + GLOBAL
	.space 4096 - 4*8

.align 4096
/* PUD_Direct_Mapping */
.global CHCORE_PUD_Direct_Mapping
CHCORE_PUD_Direct_Mapping:
PUD_DM:
	/* Bindly mapping 0~4G with rw */
	.quad (0 << 30) + PRESENT + WRITABLE + HUGE_1G + GLOBAL + NX
	.quad (1 << 30) + PRESENT + WRITABLE + HUGE_1G + GLOBAL + NX
	.quad (2 << 30) + PRESENT + WRITABLE + HUGE_1G + GLOBAL + NX
	.quad (3 << 30) + PRESENT + WRITABLE + HUGE_1G + GLOBAL + NX
	.space 4096 - 4*8

.align 4096
PUD_CODE:
	.space 4096 - 8
	/* Simply mapping 0~1G with rwx */
	.quad (0 << 30) + PRESENT + WRITABLE + HUGE_1G + GLOBAL
