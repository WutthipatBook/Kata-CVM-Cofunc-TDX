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

/*
   MIT License

   Copyright (c) 2020 sandwichdoge

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in all
   copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
   SOFTWARE.
*/

/* Reference: https://github.com/sandwichdoge/catchOS/blob/master/kernel/drivers/acpi/madt.c */

#include <common/util.h>
#include <arch/drivers/acpi.h>
#include <arch/mmu.h>

#include "madt.h"

static struct madt_info_t madt_info = {
	0,
	.irq_override = {[0 ... 23] = -1},	// init irq_override as -1
};

static struct madt_mp_wakeup_mailbox *mp_wakeup_mailbox;

/*
 * From wiki.osdev.org/MADT:
 *
 * ACPI MADT (Multiple APIC Description Table).
 *   ACPI (Advanced Configuration and Power Interface).
 *   APIC (Advanced Programmable Interrupt Controller).
 *
 * MADT decribes all of the interrupt controllers in the system.
 * MADT starts with the standard ACPI table header and the signature is "APIC".
 * MADT contains a sequence of varibale length entries which enumerate the
 * interrupt devices on the machine.
 */

void parse_madt(struct madt_t *madt)
{
	u8 src;
	u32 madt_len, mapped;
	struct madt_entry_header *entry;
	struct madt_entry_processor_local_apic *local_apic;
	struct madt_entry_io_apic *io_apic;
	struct madt_interrupt_source_override *source_override;
	struct madt_entry_mp_wakeup *mp_wakeup;

	BUG_ON(!madt);

	madt_info.local_apic_addr = (void *)(u64)madt->local_apic_addr;
	entry = (struct madt_entry_header *)madt->entries;
	madt_len = madt->h.length;

	while ((char *)entry + entry->entry_len <= (char *)madt + madt_len) {
		if (entry->entry_len == 0)
			break;

		switch (entry->entry_type) {
		case MADT_ENTRY_TYPE_LOCAL_APIC: {
			local_apic = (struct madt_entry_processor_local_apic *)entry;
			kinfo("[MADT INFO] [Local APIC] ProcessorID [%u], APIC ID[%u], flags[%u]\n",
			       local_apic->acpi_processor_id,
			       local_apic->apic_id,
			       local_apic->flags);
			madt_info.processor_ids[madt_info.processor_count] =
				local_apic->acpi_processor_id;
			madt_info.local_apic_ids[madt_info.processor_count] =
				local_apic->apic_id;
			madt_info.processor_count++;
			break;
		}

		case MADT_ENTRY_TYPE_IO_APIC: {
			io_apic = (struct madt_entry_io_apic *)entry;
			madt_info.io_apic_addrs[madt_info.io_apic_count] =
				io_apic->io_apic_addr;
			madt_info.io_apic_ids[madt_info.io_apic_count] =
				io_apic->io_apic_id;
			madt_info.io_apic_gsi_base[madt_info.io_apic_count] =
				io_apic->global_system_interrupt_base;
			madt_info.io_apic_count++;
			break;
		}

		case MADT_ENTRY_TYPE_SOURCE_OVERRIDE: {
			source_override = (struct madt_interrupt_source_override *)entry;
			src = source_override->irq_source;
			mapped = source_override->global_system_interrupt;
			if (src != mapped)
				madt_info.irq_override[src] = mapped;
			break;
		}

		case MADT_ENTRY_TYPE_MP_WAKEUP: {
			mp_wakeup = (struct madt_entry_mp_wakeup *)entry;
			mp_wakeup_mailbox = (void *)phys_to_virt(mp_wakeup->mailbox_addr);
		}

		default:
			break;
		}
		entry = (struct madt_entry_header *)((char *)entry
						    + entry->entry_len);
	}
}

u8 get_cpu_apic_id(int cpu_id)
{
	BUG_ON(cpu_id < 0 || cpu_id >= madt_info.processor_count);
	return madt_info.local_apic_ids[cpu_id];
}

void madt_wakeup_cpu(int apic_id, u64 wakeup_vector)
{
	mp_wakeup_mailbox->apic_id = apic_id;
	mp_wakeup_mailbox->wakeup_vector = wakeup_vector;
	mp_wakeup_mailbox->command = 1;

	while (mp_wakeup_mailbox->command);
}
