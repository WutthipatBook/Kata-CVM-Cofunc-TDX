# Copyright (c) 2023 Institute of Parallel And Distributed Systems (IPADS), Shanghai Jiao Tong University (SJTU)
# Licensed under the Mulan PSL v2.
# You can use this software according to the terms and conditions of the Mulan PSL v2.
# You may obtain a copy of Mulan PSL v2 at:
#     http://license.coscl.org.cn/MulanPSL2
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND, EITHER EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT, MERCHANTABILITY OR FIT FOR A PARTICULAR
# PURPOSE.
# See the Mulan PSL v2 for more details.

# Add bootloader source files
chcore_target_sources_out_objects(${kernel_target} PRIVATE init_objects
                                  init/header.S init/gdt.c)
set(init_objects ${init_objects} PARENT_SCOPE)

# Make ISO image
add_custom_target(
    chcore.iso ALL
    COMMAND [ -f chcore.iso ] && rm -f chcore.iso || true
    COMMAND [ -d iso ] && rm -rf iso || true
    COMMAND cp -r ${CMAKE_CURRENT_SOURCE_DIR}/iso .
    COMMAND cp $<TARGET_FILE:${kernel_target}> iso/boot
    COMMAND grub-mkrescue -o chcore.iso iso
    COMMAND test -f chcore.iso
    DEPENDS ${kernel_target})
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/chcore.iso
        DESTINATION ${CMAKE_INSTALL_PREFIX})

# Note: `$basedir` is a shell variable in `emulate.tpl.sh`.
# Paths are intentionally overridable because this artifact is migrated between
# local and server hosts.
set(COFUNC_TDX_QEMU
    "\${COFUNC_TDX_QEMU:-/mnt/new_disk/cofunc_tdx_artifact/install/qemu-tdx-2022-09-01-cofunc/bin/qemu-system-x86_64}"
)
set(COFUNC_TDX_OVMF
    "\${COFUNC_TDX_OVMF:-/mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd}"
)
set(COFUNC_TDX_QEMU_BIOS_DIR "\${COFUNC_TDX_QEMU_BIOS_DIR:-/usr/share/qemu}")
set(COFUNC_TDX_SMP "\${COFUNC_TDX_SMP:-32}")
set(COFUNC_TDX_QEMU_BASE_OPTIONS
    "-L ${COFUNC_TDX_QEMU_BIOS_DIR} -accel kvm -cpu host -object tdx-guest,id=tdx0 -machine q35,confidential-guest-support=tdx0,kernel-irqchip=split,smm=off -bios ${COFUNC_TDX_OVMF} -m 4G -smp ${COFUNC_TDX_SMP} -nodefaults -nographic -display none -serial mon:stdio -no-reboot -boot c -drive file=\$basedir/chcore.iso,if=none,id=bootdisk,format=raw,readonly=on -device virtio-blk-pci,drive=bootdisk,bootindex=1"
)

if (CHCORE_KERNEL_ENABLE_QEMU_VIRTIO_NET)
    chcore_generate_emulate_sh(
        "${COFUNC_TDX_QEMU}"
        "${COFUNC_TDX_QEMU_BASE_OPTIONS} -nic user,model=virtio-net-pci,hostfwd=tcp::1234-:9000,hostfwd=tcp::4096-:4096"
    )
else()
    chcore_generate_emulate_sh(
        "${COFUNC_TDX_QEMU}"
        "${COFUNC_TDX_QEMU_BASE_OPTIONS}"
    )
endif()
