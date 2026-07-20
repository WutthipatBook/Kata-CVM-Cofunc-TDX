#!/usr/bin/env bash
set -euo pipefail

ACTION=check
LOG_PATH=""
PIN_MAX_FREQ=0
ISOLATED_CPUS=""
HOUSEKEEPING_CPUS=""
DRY_RUN=0
GRUB_FILE=${GRUB_FILE:-/etc/default/grub}

usage() {
	cat <<'EOF'
Usage:
  scripts/cofunc_tdx_host_perf_mode.sh [check|ensure] [options]
  scripts/cofunc_tdx_host_perf_mode.sh install-isolation [options]

Checks or prepares host CPU and core-isolation settings for CoFunc TDX
performance runs.

Actions:
  check                 Report state and exit nonzero if performance mode is not set
  ensure                Set governor/EPP to performance when needed, then report state
  install-isolation     Add GRUB boot args for core isolation and run update-grub
  active-isolated-cpus  Print the isolated CPU list from the current boot args

Options:
  --log PATH            Tee report to PATH
  --pin-max-freq        Also set scaling_min_freq to scaling_max_freq
  --isolated-cpus LIST  Isolated CPU list for install-isolation
  --housekeeping-cpus LIST
                         Housekeeping/IRQ CPU list for install-isolation
  --dry-run             Show the GRUB change without writing it
  -h, --help            Show this help

Notes:
  - install-isolation edits /etc/default/grub by default and requires a reboot.
  - Use the runner's --core-isolated option after reboot. isolcpus alone does
    not pin the measured QEMU/runtime onto those CPUs.
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

if (($#)) && [[ $1 != --* ]]; then
	ACTION=$1
	shift
fi

while (($#)); do
	case "$1" in
		--log)
			LOG_PATH=${2:?missing value for --log}
			shift 2
			;;
		--pin-max-freq)
			PIN_MAX_FREQ=1
			shift
			;;
		--isolated-cpus)
			ISOLATED_CPUS=${2:?missing value for --isolated-cpus}
			shift 2
			;;
		--housekeeping-cpus)
			HOUSEKEEPING_CPUS=${2:?missing value for --housekeeping-cpus}
			shift 2
			;;
		--dry-run)
			DRY_RUN=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown option: $1"
			;;
	esac
done

case "$ACTION" in
	check|ensure|set|install-isolation|active-isolated-cpus)
		;;
	*)
		die "unknown action: $ACTION"
		;;
esac

if [[ -n $LOG_PATH ]]; then
	mkdir -p "$(dirname "$LOG_PATH")"
	exec > >(tee "$LOG_PATH") 2>&1
fi

CPUFREQ_DIRS=()
for dir in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do
	[[ -d $dir ]] && CPUFREQ_DIRS+=("$dir")
done

write_sysfs() {
	local path=$1
	local value=$2

	if [[ -w $path ]]; then
		printf '%s\n' "$value" >"$path"
	else
		printf '%s\n' "$value" | sudo tee "$path" >/dev/null
	fi
}

ensure_sudo() {
	if [[ $EUID -eq 0 ]]; then
		return
	fi
	if [[ -t 0 ]]; then
		sudo -v || die "sudo is required to set host performance mode"
	else
		sudo -n true 2>/dev/null || die "sudo credentials are not cached; run 'sudo -v' first or execute this script with sudo"
	fi
}

file_supports_value() {
	local path=$1
	local value=$2

	[[ -r $path ]] || return 1
	grep -qw -- "$value" "$path"
}

all_governors_performance() {
	local dir path value seen=0

	for dir in "${CPUFREQ_DIRS[@]}"; do
		path="$dir/scaling_governor"
		[[ -r $path ]] || continue
		seen=1
		value=$(<"$path")
		[[ $value == performance ]] || return 1
	done
	[[ $seen == 1 ]]
}

all_epp_performance() {
	local dir path choices value seen=0

	for dir in "${CPUFREQ_DIRS[@]}"; do
		path="$dir/energy_performance_preference"
		choices="$dir/energy_performance_available_preferences"
		[[ -r $path ]] || continue
		if [[ -r $choices ]] && ! file_supports_value "$choices" performance; then
			continue
		fi
		seen=1
		value=$(<"$path")
		[[ $value == performance ]] || return 1
	done

	# EPP is optional on some drivers; absence should not fail the run.
	[[ $seen == 0 || $seen == 1 ]]
}

performance_ready() {
	all_governors_performance && all_epp_performance
}

print_unique_file() {
	local file=$1
	local label=$2
	local dir path value
	local values=()

	for dir in "${CPUFREQ_DIRS[@]}"; do
		path="$dir/$file"
		[[ -r $path ]] || continue
		value=$(<"$path")
		values+=("$value")
	done

	if ((${#values[@]} == 0)); then
		printf '%s: unavailable\n' "$label"
		return
	fi

	printf '%s:\n' "$label"
	printf '%s\n' "${values[@]}" | sort | uniq -c | sed 's/^/  /'
}

cmdline_value() {
	local key=$1
	local token

	for token in $(cat /proc/cmdline); do
		case "$token" in
			"$key"=*)
				printf '%s\n' "${token#*=}"
				return
				;;
			"$key")
				printf '(set)\n'
				return
				;;
		esac
	done
	printf 'missing\n'
}

active_isolated_cpus() {
	local raw field joined
	local -a fields
	local cpus=()

	raw=$(cmdline_value isolcpus)
	[[ $raw != "missing" && $raw != "(set)" ]] || return 1
	IFS=',' read -r -a fields <<<"$raw"
	for field in "${fields[@]}"; do
		if [[ $field =~ ^[0-9]+(-[0-9]+)?$ ]]; then
			cpus+=("$field")
		fi
	done
	((${#cpus[@]})) || return 1
	joined=$(printf ',%s' "${cpus[@]}")
	printf '%s\n' "${joined#,}"
}

cmdline_key_present() {
	local key=$1
	local value

	value=$(cmdline_value "$key")
	[[ $value != "missing" ]]
}

core_isolation_ready() {
	active_isolated_cpus >/dev/null &&
		cmdline_key_present nohz_full &&
		cmdline_key_present rcu_nocbs &&
		cmdline_key_present irqaffinity
}

range_text() {
	local start=$1
	local end=$2

	if ((start == end)); then
		printf '%s' "$start"
	else
		printf '%s-%s' "$start" "$end"
	fi
}

print_isolation_guidance() {
	local total isolated_start isolated_end housekeeping_end isolated housekeeping

	total=$(nproc --all 2>/dev/null || nproc)
	if ((total < 4)); then
		return
	fi

	isolated_start=$((total / 2))
	isolated_end=$((total - 1))
	housekeeping_end=$((isolated_start - 1))
	isolated=$(range_text "$isolated_start" "$isolated_end")
	housekeeping=$(range_text 0 "$housekeeping_end")

	printf 'suggested_isolated_cpus=%s\n' "$isolated"
	printf 'suggested_housekeeping_cpus=%s\n' "$housekeeping"
	printf 'suggested_boot_args=isolcpus=domain,managed_irq,%s nohz_full=%s rcu_nocbs=%s irqaffinity=%s\n' \
		"$isolated" "$isolated" "$isolated" "$housekeeping"
	printf 'runner_affinity=--taskset-cpus %s\n' "$isolated"
}

default_isolated_cpus() {
	local total isolated_start isolated_end

	total=$(nproc --all 2>/dev/null || nproc)
	isolated_start=$((total / 2))
	isolated_end=$((total - 1))
	range_text "$isolated_start" "$isolated_end"
}

default_housekeeping_cpus() {
	local total housekeeping_end

	total=$(nproc --all 2>/dev/null || nproc)
	housekeeping_end=$(((total / 2) - 1))
	range_text 0 "$housekeeping_end"
}

validate_cpulist() {
	local value=$1

	[[ $value =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]
}

print_report() {
	local active

	printf 'timestamp_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'hostname=%s\n' "$(hostname)"
	printf 'kernel=%s\n' "$(uname -r)"
	printf 'logical_cpus=%s\n' "$(nproc --all 2>/dev/null || nproc)"
	printf 'cmdline=%s\n' "$(cat /proc/cmdline)"
	printf 'cpufreq_cpus=%s\n' "${#CPUFREQ_DIRS[@]}"
	print_unique_file scaling_driver scaling_driver
	print_unique_file scaling_governor scaling_governor
	print_unique_file energy_performance_preference energy_performance_preference
	print_unique_file scaling_min_freq scaling_min_freq
	print_unique_file scaling_cur_freq scaling_cur_freq
	print_unique_file scaling_max_freq scaling_max_freq
	if [[ -r /sys/devices/system/cpu/intel_pstate/status ]]; then
		printf 'intel_pstate_status=%s\n' "$(< /sys/devices/system/cpu/intel_pstate/status)"
	fi
	if [[ -r /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
		printf 'intel_pstate_no_turbo=%s\n' "$(< /sys/devices/system/cpu/intel_pstate/no_turbo)"
	fi
	if [[ -r /sys/devices/system/cpu/cpufreq/boost ]]; then
		printf 'cpufreq_boost=%s\n' "$(< /sys/devices/system/cpu/cpufreq/boost)"
	fi
	if [[ -r /proc/sys/kernel/numa_balancing ]]; then
		printf 'numa_balancing=%s\n' "$(< /proc/sys/kernel/numa_balancing)"
	fi
	printf 'isolcpus=%s\n' "$(cmdline_value isolcpus)"
	printf 'nohz_full=%s\n' "$(cmdline_value nohz_full)"
	printf 'rcu_nocbs=%s\n' "$(cmdline_value rcu_nocbs)"
	printf 'irqaffinity=%s\n' "$(cmdline_value irqaffinity)"
	if active=$(active_isolated_cpus 2>/dev/null); then
		printf 'active_isolated_cpus=%s\n' "$active"
	else
		printf 'active_isolated_cpus=missing\n'
	fi
	print_isolation_guidance
	if core_isolation_ready; then
		printf 'core_isolation_ready=yes\n'
	else
		printf 'core_isolation_ready=no\n'
	fi
	if performance_ready; then
		printf 'performance_ready=yes\n'
	else
		printf 'performance_ready=no\n'
	fi
}

install_boot_isolation() {
	local isolated housekeeping backup tmp

	isolated=${ISOLATED_CPUS:-$(default_isolated_cpus)}
	housekeeping=${HOUSEKEEPING_CPUS:-$(default_housekeeping_cpus)}
	validate_cpulist "$isolated" || die "invalid --isolated-cpus list: $isolated"
	validate_cpulist "$housekeeping" || die "invalid --housekeeping-cpus list: $housekeeping"
	[[ -f $GRUB_FILE ]] || die "missing GRUB config: $GRUB_FILE"

	tmp=$(mktemp)
	python3 - "$GRUB_FILE" "$isolated" "$housekeeping" >"$tmp" <<'PY'
import re
import sys

path, isolated, housekeeping = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as file:
    lines = file.readlines()

target = None
for index, line in enumerate(lines):
    if re.match(r"\s*GRUB_CMDLINE_LINUX\s*=", line) and not re.match(r"\s*#", line):
        target = index

if target is None:
    lines.append('GRUB_CMDLINE_LINUX=""\n')
    target = len(lines) - 1

line = lines[target].rstrip("\n")
match = re.match(r"(\s*GRUB_CMDLINE_LINUX\s*=\s*)(['\"])(.*)\2(\s*)$", line)
if match:
    prefix, quote, value, suffix = match.groups()
else:
    prefix = "GRUB_CMDLINE_LINUX="
    quote = '"'
    value = line.split("=", 1)[1].strip().strip("'\"") if "=" in line else ""
    suffix = ""

remove_keys = ("isolcpus", "nohz_full", "rcu_nocbs", "irqaffinity")
tokens = [token for token in value.split() if token.split("=", 1)[0] not in remove_keys]
tokens.extend([
    f"isolcpus=domain,managed_irq,{isolated}",
    f"nohz_full={isolated}",
    f"rcu_nocbs={isolated}",
    f"irqaffinity={housekeeping}",
])
lines[target] = f"{prefix}{quote}{' '.join(tokens)}{quote}{suffix}\n"
sys.stdout.write("".join(lines))
PY

	if [[ $DRY_RUN == 1 ]]; then
		printf 'dry_run=yes\n'
		diff -u "$GRUB_FILE" "$tmp" || true
		rm -f "$tmp"
		return
	fi

	ensure_sudo
	backup="${GRUB_FILE}.cofunc-backup-$(date -u +%Y%m%d_%H%M%S)"
	sudo cp -a "$GRUB_FILE" "$backup"
	sudo install -m 0644 "$tmp" "$GRUB_FILE"
	rm -f "$tmp"
	sudo update-grub
	printf 'updated_grub_file=%s\n' "$GRUB_FILE"
	printf 'backup=%s\n' "$backup"
	printf 'isolated_cpus=%s\n' "$isolated"
	printf 'housekeeping_cpus=%s\n' "$housekeeping"
	printf 'reboot_required=yes\n'
	printf 'after_reboot_runner_flag=--core-isolated\n'
}

set_performance_mode() {
	local dir path choices max_freq

	ensure_sudo

	for dir in "${CPUFREQ_DIRS[@]}"; do
		path="$dir/scaling_governor"
		choices="$dir/scaling_available_governors"
		[[ -w $path || -r $path ]] || continue
		if [[ -r $choices ]] && ! file_supports_value "$choices" performance; then
			printf 'warning: %s does not advertise performance governor\n' "$choices" >&2
			continue
		fi
		if [[ $(<"$path") != performance ]]; then
			write_sysfs "$path" performance
		fi
	done

	for dir in "${CPUFREQ_DIRS[@]}"; do
		path="$dir/energy_performance_preference"
		choices="$dir/energy_performance_available_preferences"
		[[ -r $path ]] || continue
		if [[ -r $choices ]] && ! file_supports_value "$choices" performance; then
			continue
		fi
		if [[ $(<"$path") != performance ]]; then
			write_sysfs "$path" performance
		fi
	done

	if [[ $PIN_MAX_FREQ == 1 ]]; then
		for dir in "${CPUFREQ_DIRS[@]}"; do
			[[ -r $dir/scaling_max_freq && -r $dir/scaling_min_freq ]] || continue
			max_freq=$(<"$dir/scaling_max_freq")
			write_sysfs "$dir/scaling_min_freq" "$max_freq"
		done
	fi
}

if [[ $ACTION == active-isolated-cpus ]]; then
	active_isolated_cpus
	exit 0
fi

if [[ $ACTION == install-isolation ]]; then
	install_boot_isolation
	exit 0
fi

if ((${#CPUFREQ_DIRS[@]} == 0)); then
	die "no cpufreq sysfs entries found under /sys/devices/system/cpu"
fi

if [[ $ACTION == ensure || $ACTION == set ]]; then
	printf '== before ==\n'
	print_report
	if ! performance_ready || [[ $PIN_MAX_FREQ == 1 ]]; then
		printf '== setting performance mode ==\n'
		set_performance_mode
	fi
	printf '== after ==\n'
	print_report
	performance_ready || die "host CPU performance mode is still not ready"
else
	print_report
	performance_ready || exit 1
fi
