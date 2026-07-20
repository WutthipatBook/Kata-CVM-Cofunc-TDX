#!/usr/bin/env bash
set -euo pipefail

BUNDLE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ACTION=""
ROOT=${COFUNC_TDX_ROOT:-}
JOBS=${JOBS:-$(nproc)}
RESET_EXISTING=0
SKIP_QEMU_BLOBS=0

ARTIFACT_REPO=${ARTIFACT_REPO:-https://github.com/shijc-sjtu/cofunc-artifact.git}
ARTIFACT_BASE=7c41d63a1e40c9bddc7d0ba70c5b11c09fc80b90
ARTIFACT_BRANCH=cofunc-tdx-artifact

KERNEL_REPO=${KERNEL_REPO:-https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/resolute}
KERNEL_BASE=91baa15c711afa2e06f9c824297aea1319bd5842
KERNEL_BRANCH=cofunc-tdx-host-kernel

QEMU_REPO=${QEMU_REPO:-https://git.launchpad.net/ubuntu/+source/qemu}
QEMU_BASE=96cda2bbb2f530d08f6bda1f0dc186a0e0ce9674
QEMU_BRANCH=cofunc-tdx-qemu
QEMU_UPSTREAM_TAG=v10.2.1

usage() {
	cat <<'EOF'
Usage:
  ./setup_cofunc_tdx_e2e.sh ACTION --root /large/workdir [options]

Actions:
  prepare-sources       Clone original repos, checkout base commits, apply patches
  build-kernel          Build the patched host kernel bzImage/modules
  install-kernel        Install the built kernel into /boot and update GRUB
  install-kvm-modules   Install rebuilt kvm/kvm_intel modules for current kernel
  build-qemu            Build and install patched QEMU under ROOT/install
  build-artifact        Build CoFunc CVM OS, helper images, and runtime helpers
  install-isolation     Add isolcpus/nohz_full/rcu_nocbs/irqaffinity GRUB args
  check-host            Print host TDX, KVM, performance, and isolation state
  run-face-smoke        Run fn_py_face_detection through TDX fork mode
  run-fig11             Run the Fig. 11 TDX fork subset plus comparison reports
  all                   prepare-sources + build-kernel + build-qemu + build-artifact

Options:
  --root PATH           Required large workspace root, e.g. /mnt/nvme_500g/asdf
  --jobs N              Parallel build jobs; default: nproc
  --reset-existing      Reset existing git checkouts to the base commits first
  --skip-qemu-blobs     Do not fetch upstream QEMU edk2 pc-bios blobs
  -h, --help            Show this help

Environment overrides:
  ARTIFACT_REPO, KERNEL_REPO, QEMU_REPO can override clone URLs.

Notes:
  - install-kernel and install-isolation intentionally require explicit actions.
  - After install-kernel or install-isolation, reboot before running workloads.
  - Existing non-empty checkouts are not reset unless --reset-existing is set.
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

log() {
	printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

while (($#)); do
	case "$1" in
		--root)
			ROOT=${2:?missing value for --root}
			shift 2
			;;
		--jobs)
			JOBS=${2:?missing value for --jobs}
			shift 2
			;;
		--reset-existing)
			RESET_EXISTING=1
			shift
			;;
		--skip-qemu-blobs)
			SKIP_QEMU_BLOBS=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		-*)
			die "unknown option: $1"
			;;
		*)
			[[ -z $ACTION ]] || die "multiple actions specified: $ACTION and $1"
			ACTION=$1
			shift
			;;
	esac
done

ACTION=${ACTION:-prepare-sources}
[[ $JOBS =~ ^[0-9]+$ && $JOBS -gt 0 ]] || die "invalid --jobs value: $JOBS"

require_root() {
	[[ -n $ROOT ]] || die "--root is required"
	ROOT=$(realpath -m "$ROOT")
	mkdir -p "$ROOT"

	ARTIFACT="$ROOT/cofunc-artifact"
	KERNEL_SRC="$ROOT/src/ubuntu-resolute-6.19.0-3.3"
	KERNEL_BUILD="$ROOT/build/kernel-ubuntu-6.19-tdx"
	QEMU_SRC="$ROOT/src/ubuntu-qemu-resolute"
	QEMU_BUILD="$ROOT/build/qemu-ubuntu-tdx"
	QEMU_INSTALL="$ROOT/install/qemu-ubuntu-tdx"
	PYTHON_DEPS="$ROOT/build/python-deps"
	RESULTS_DIR="$ROOT/results"
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

ensure_git_commit() {
	local repo=$1
	local commit=$2

	if ! git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null; then
		log "fetching missing commit $commit in $repo"
		git -C "$repo" fetch --all --tags
	fi
	git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null || \
		die "commit $commit is not available in $repo"
}

patch_subject() {
	local patch=$1
	sed -n -E 's/^Subject: (\[PATCH[^]]*\] )?//p' "$patch" | head -n 1
}

apply_patch_if_needed() {
	local repo=$1
	local patch=$2
	local subject

	subject=$(patch_subject "$patch")
	[[ -n $subject ]] || die "cannot read patch subject: $patch"
	if git -C "$repo" log --format=%s --max-count=300 | grep -Fxq "$subject"; then
		log "patch already applied in $(basename "$repo"): $subject"
		return
	fi
	log "applying patch to $(basename "$repo"): $subject"
	git -C "$repo" am --3way "$patch"
}

prepare_repo() {
	local name=$1
	local url=$2
	local path=$3
	local branch=$4
	local base=$5
	shift 5
	local patch
	local new_clone=0

	mkdir -p "$(dirname "$path")"
	if [[ ! -d $path/.git ]]; then
		log "cloning $name into $path"
		git clone "$url" "$path"
		new_clone=1
	else
		log "using existing $name checkout: $path"
	fi

	ensure_git_commit "$path" "$base"

	if [[ $new_clone == 1 || $RESET_EXISTING == 1 ]]; then
		log "resetting $name to $base"
		git -C "$path" checkout -B "$branch" "$base"
		git -C "$path" reset --hard "$base"
	else
		git -C "$path" diff --quiet || die "$path has uncommitted changes; use --reset-existing or a fresh --root"
		git -C "$path" diff --cached --quiet || die "$path has staged changes; use --reset-existing or a fresh --root"
		if git -C "$path" merge-base --is-ancestor "$base" HEAD; then
			git -C "$path" checkout -B "$branch" HEAD
		else
			die "$path is not based on expected commit $base; use --reset-existing or a fresh --root"
		fi
	fi

	for patch in "$@"; do
		apply_patch_if_needed "$path" "$patch"
	done
}

write_env_file() {
	cat >"$ROOT/cofunc-tdx-env.sh" <<EOF
export COFUNC_TDX_ROOT="$ROOT"
export ARTIFACT="$ARTIFACT"
export KERNEL_SRC="$KERNEL_SRC"
export KERNEL_BUILD="$KERNEL_BUILD"
export QEMU_SRC="$QEMU_SRC"
export QEMU_BUILD="$QEMU_BUILD"
export QEMU_INSTALL="$QEMU_INSTALL"
EOF
	log "wrote $ROOT/cofunc-tdx-env.sh"
}

prepare_sources() {
	require_root
	need_cmd git

	prepare_repo \
		"CoFunc artifact" \
		"$ARTIFACT_REPO" \
		"$ARTIFACT" \
		"$ARTIFACT_BRANCH" \
		"$ARTIFACT_BASE" \
		"$BUNDLE_DIR/patches/cofunc-artifact/0001-Enable-CoFunc-TDX-split-container-execution.patch" \
		"$BUNDLE_DIR/patches/cofunc-artifact/0001-Fix-CoFunc-workload-build-dependencies.patch"

	prepare_repo \
		"TDX host kernel" \
		"$KERNEL_REPO" \
		"$KERNEL_SRC" \
		"$KERNEL_BRANCH" \
		"$KERNEL_BASE" \
		"$BUNDLE_DIR/patches/host-kernel/0001-Add-KVM-support-for-CoFunc-split-containers.patch"

	prepare_repo \
		"QEMU" \
		"$QEMU_REPO" \
		"$QEMU_SRC" \
		"$QEMU_BRANCH" \
		"$QEMU_BASE" \
		"$BUNDLE_DIR/patches/qemu/0001-Wire-CoFunc-split-container-KVM-ioctls-into-QEMU.patch"

	write_env_file
}

download_file() {
	local url=$1
	local out=$2

	if command -v curl >/dev/null 2>&1; then
		curl -fL "$url" -o "$out"
	elif command -v wget >/dev/null 2>&1; then
		wget -O "$out" "$url"
	else
		die "curl or wget is required to download $url"
	fi
}

ensure_qemu_bios_blobs() {
	local blob
	local -a blobs=(
		edk2-aarch64-code.fd.bz2
		edk2-arm-code.fd.bz2
		edk2-arm-vars.fd.bz2
		edk2-i386-code.fd.bz2
		edk2-i386-secure-code.fd.bz2
		edk2-i386-vars.fd.bz2
		edk2-loongarch64-code.fd.bz2
		edk2-loongarch64-vars.fd.bz2
		edk2-riscv-code.fd.bz2
		edk2-riscv-vars.fd.bz2
		edk2-x86_64-code.fd.bz2
		edk2-x86_64-secure-code.fd.bz2
	)

	[[ $SKIP_QEMU_BLOBS == 0 ]] || return 0
	mkdir -p "$QEMU_SRC/pc-bios"
	for blob in "${blobs[@]}"; do
		[[ -f $QEMU_SRC/pc-bios/$blob ]] && continue
		log "downloading QEMU pc-bios/$blob from upstream $QEMU_UPSTREAM_TAG"
		download_file \
			"https://raw.githubusercontent.com/qemu/qemu/${QEMU_UPSTREAM_TAG}/pc-bios/${blob}" \
			"$QEMU_SRC/pc-bios/$blob"
	done
}

build_kernel() {
	require_root
	[[ -d $KERNEL_SRC/.git ]] || die "missing kernel source; run prepare-sources first"
	need_cmd make
	mkdir -p "$KERNEL_BUILD"
	cp "$BUNDLE_DIR/configs/host-kernel-6.19.0-rc6-cofunc-tdx.config" "$KERNEL_BUILD/.config"
	log "building host kernel in $KERNEL_BUILD"
	make -C "$KERNEL_SRC" O="$KERNEL_BUILD" olddefconfig
	make -C "$KERNEL_SRC" O="$KERNEL_BUILD" -j"$JOBS" bzImage modules
}

install_kernel() {
	require_root
	[[ -d $KERNEL_BUILD ]] || die "missing kernel build; run build-kernel first"
	need_cmd make
	local krel
	krel=$(make -s -C "$KERNEL_SRC" O="$KERNEL_BUILD" kernelrelease)
	[[ -n $krel ]] || die "could not determine kernelrelease"
	log "installing kernel $krel"
	sudo make -C "$KERNEL_SRC" O="$KERNEL_BUILD" modules_install
	sudo cp "$KERNEL_BUILD/arch/x86/boot/bzImage" "/boot/vmlinuz-$krel"
	sudo cp "$KERNEL_BUILD/System.map" "/boot/System.map-$krel"
	sudo cp "$KERNEL_BUILD/.config" "/boot/config-$krel"
	sudo depmod "$krel"
	sudo update-initramfs -c -k "$krel"
	sudo update-grub
	log "kernel installed; reboot into $krel before running TDX workloads"
}

install_kvm_modules() {
	require_root
	[[ -d $KERNEL_BUILD ]] || die "missing kernel build; run build-kernel first"
	sudo -E BUILD_DIR="$KERNEL_BUILD" "$BUNDLE_DIR/scripts/cofunc_install_rebuilt_kvm_modules.sh"
}

build_qemu() {
	require_root
	[[ -d $QEMU_SRC/.git ]] || die "missing QEMU source; run prepare-sources first"
	need_cmd python3
	need_cmd ninja
	ensure_qemu_bios_blobs
	mkdir -p "$QEMU_BUILD" "$QEMU_INSTALL" "$PYTHON_DEPS"
	python3 -m pip install --upgrade --target "$PYTHON_DEPS" tomli
	log "configuring QEMU in $QEMU_BUILD"
	(
		cd "$QEMU_BUILD"
		PYTHONPATH="$PYTHON_DEPS" "$QEMU_SRC/configure" \
			--target-list=x86_64-softmmu \
			--enable-kvm \
			--disable-docs \
			--disable-werror \
			--disable-install-blobs \
			--prefix="$QEMU_INSTALL"
		ninja -j"$JOBS" qemu-system-x86_64
		ninja install
	)
}

build_artifact() {
	require_root
	[[ -d $ARTIFACT/.git ]] || die "missing CoFunc artifact; run prepare-sources first"
	log "building CoFunc CVM OS"
	(
		cd "$ARTIFACT/cvm_os"
		./download_musl.sh
		./chbuild build
	)
	log "building CoFunc helper/runtime images"
	(cd "$ARTIFACT/testcases/tools/lean_container" && ./build.sh)
	(cd "$ARTIFACT/shadow_container" && COFUNC_PLAT=intel_tdx ./build.sh)
	(cd "$ARTIFACT/testcases/tools/js_binding" && ./build.sh)
	(cd "$ARTIFACT/testcases/tools/libc_builder" && ./build.sh)
	(cd "$ARTIFACT/testcases/environment" && ./build_all.sh)
}

install_isolation() {
	"$BUNDLE_DIR/scripts/cofunc_tdx_host_perf_mode.sh" install-isolation \
		--isolated-cpus "${ISOLATED_CPUS:-16-31}" \
		--housekeeping-cpus "${HOUSEKEEPING_CPUS:-0-15}"
	log "GRUB isolation args installed; reboot before running workloads"
}

check_host() {
	require_root
	"$BUNDLE_DIR/scripts/cofunc_tdx_host_perf_mode.sh" check || true
	printf 'kernel: %s\n' "$(uname -r)"
	printf 'kvm_intel.tdx: %s\n' "$(cat /sys/module/kvm_intel/parameters/tdx 2>/dev/null || printf missing)"
	printf 'kvm srcversion: %s\n' "$(cat /sys/module/kvm/srcversion 2>/dev/null || printf missing)"
	printf 'kvm_intel srcversion: %s\n' "$(cat /sys/module/kvm_intel/srcversion 2>/dev/null || printf missing)"
}

run_face_smoke() {
	require_root
	mkdir -p "$RESULTS_DIR"
	sudo -v
	"$BUNDLE_DIR/scripts/run_tdx_sc_fork_e2e.sh" \
		--artifact "$ARTIFACT" \
		--workloads fn_py_face_detection \
		--prepare-performance \
		--core-isolated \
		--quiet-workload-output \
		--out "$RESULTS_DIR/tdx_face_$(date -u +%Y%m%d_%H%M%S)"
}

run_fig11() {
	require_root
	mkdir -p "$RESULTS_DIR"
	sudo -v
	"$BUNDLE_DIR/scripts/run_tdx_fig11_pdf_compare.sh" \
		--artifact "$ARTIFACT" \
		--quiet-workload-output \
		--out "$RESULTS_DIR/tdx_fig11_$(date -u +%Y%m%d_%H%M%S)"
}

case "$ACTION" in
	prepare-sources)
		prepare_sources
		;;
	build-kernel)
		build_kernel
		;;
	install-kernel)
		install_kernel
		;;
	install-kvm-modules)
		install_kvm_modules
		;;
	build-qemu)
		build_qemu
		;;
	build-artifact)
		build_artifact
		;;
	install-isolation)
		install_isolation
		;;
	check-host)
		check_host
		;;
	run-face-smoke)
		run_face_smoke
		;;
	run-fig11)
		run_fig11
		;;
	all)
		prepare_sources
		build_kernel
		build_qemu
		build_artifact
		;;
	*)
		usage >&2
		die "unknown action: $ACTION"
		;;
esac
