#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob
trap "rm -rf temp/*tmp.* temp/*/*tmp.* temp/*-temporary-files; exit 130" INT

if [ "${1-}" = "clean" ]; then
	rm -rf temp build logs build.md
	exit 0
fi

source utils.sh

if [ "$OS" = Android ]; then
    if ! [ -d "$HOME/storage" ]; then
        pr "Requesting Termux storage permission..."
        pr "Please allow storage access in the popup"
      	sleep 5
      	termux-setup-storage
    fi
    OUTPUT_DIR="/sdcard/Download/rvx-output"
    mkdir -p "$OUTPUT_DIR"
else
    OUTPUT_DIR="$BUILD_DIR"
fi

install_pkg jq
if [ "$OS" = Android ]; then
    install_pkg java openjdk-17
else
    install_pkg java openjdk-21-jdk
fi
install_pkg zip

set_prebuilts

vtf() { if ! isoneof "${1}" "true" "false"; then abort "ERROR: '${1}' is not a valid option for '${2}': only true or false is allowed"; fi; }

# -- Main config --
toml_prep "${1:-config.toml}" || abort "could not find config file '${1:-config.toml}'\n\tUsage: $0 <config.toml>"
main_config_t=$(toml_get_table_main)
if ! PARALLEL_JOBS=$(toml_get "$main_config_t" parallel-jobs); then
	if [ "$OS" = Android ]; then PARALLEL_JOBS=1; else PARALLEL_JOBS=$(nproc); fi
fi
DEF_PATCHES_VER=$(toml_get "$main_config_t" patches-version) || DEF_PATCHES_VER="latest"
DEF_CLI_VER=$(toml_get "$main_config_t" cli-version) || DEF_CLI_VER="latest"
DEF_PATCHES_SRC=$(toml_get "$main_config_t" patches-source) || DEF_PATCHES_SRC="anddea/revanced-patches"
DEF_CLI_SRC=$(toml_get "$main_config_t" cli-source) || DEF_CLI_SRC="inotia00/revanced-cli"
DEF_RV_BRAND=$(toml_get "$main_config_t" rv-brand) || DEF_RV_BRAND="RVX"
DEF_DPI_LIST=$(toml_get "$main_config_t" dpi) || DEF_DPI_LIST="nodpi anydpi 120-640dpi"
mkdir -p "$TEMP_DIR" "$BUILD_DIR"

: >build.md

if [ "$(echo "$TEMP_DIR"/*-rv/changelog.md)" ]; then
	: >"$TEMP_DIR"/*-rv/changelog.md || :
fi

declare -A cliriplib
idx=0
for table_name in $(toml_get_table_names); do
	if [ -z "$table_name" ]; then continue; fi
	t=$(toml_get_table "$table_name")
	enabled=$(toml_get "$t" enabled) || enabled=true
	vtf "$enabled" "enabled"
	if [ "$enabled" = false ]; then continue; fi
	if ((idx >= PARALLEL_JOBS)); then
		wait -n
		idx=$((idx - 1))
	fi

	declare -A app_args
	patches_src=$(toml_get "$t" patches-source) || patches_src=$DEF_PATCHES_SRC

	if [ "${BUILD_MODE:-}" = "dev" ]; then
        patches_ver="dev"
    else
        patches_ver=$(toml_get "$t" patches-version) || patches_ver=$DEF_PATCHES_VER
    fi
	
	cli_src=$(toml_get "$t" cli-source) || cli_src=$DEF_CLI_SRC
	cli_ver=$(toml_get "$t" cli-version) || cli_ver=$DEF_CLI_VER

	if ! RVP="$(get_rv_prebuilts "$cli_src" "$cli_ver" "$patches_src" "$patches_ver")"; then
		abort "could not download rv prebuilts"
	fi
	read -r rv_cli_jar rv_patches_jar <<<"$RVP"
	app_args[cli]=$rv_cli_jar
	app_args[ptjar]=$rv_patches_jar
	if [[ -v cliriplib[${app_args[cli]}] ]]; then app_args[riplib]=${cliriplib[${app_args[cli]}]}; else
		if [[ $(java -jar "${app_args[cli]}" patch 2>&1) == *rip-lib* ]]; then
			cliriplib[${app_args[cli]}]=true
			app_args[riplib]=true
		else
			cliriplib[${app_args[cli]}]=false
			app_args[riplib]=false
		fi
	fi
	if [ "${app_args[riplib]}" = "true" ] && [ "$(toml_get "$t" riplib)" = "false" ]; then app_args[riplib]=false; fi
	app_args[rv_brand]=$(toml_get "$t" rv-brand) || app_args[rv_brand]=$DEF_RV_BRAND

	app_args[excluded_patches]=$(toml_get "$t" excluded-patches) || app_args[excluded_patches]=""
	if [ -n "${app_args[excluded_patches]}" ] && [[ ${app_args[excluded_patches]} != *'"'* ]]; then abort "patch names inside excluded-patches must be quoted"; fi
	app_args[included_patches]=$(toml_get "$t" included-patches) || app_args[included_patches]=""
	if [ -n "${app_args[included_patches]}" ] && [[ ${app_args[included_patches]} != *'"'* ]]; then abort "patch names inside included-patches must be quoted"; fi
	app_args[exclusive_patches]=$(toml_get "$t" exclusive-patches) && vtf "${app_args[exclusive_patches]}" "exclusive-patches" || app_args[exclusive_patches]=false
	app_args[version]=$(toml_get "$t" version) || app_args[version]="auto"
	app_args[app_name]=$(toml_get "$t" app-name) || app_args[app_name]=$table_name
	app_args[patcher_args]=$(toml_get "$t" patcher-args) || app_args[patcher_args]=""
	app_args[table]=$table_name
	app_args[uptodown_dlurl]=$(toml_get "$t" uptodown-dlurl) && {
		app_args[uptodown_dlurl]=${app_args[uptodown_dlurl]%/}
		app_args[uptodown_dlurl]=${app_args[uptodown_dlurl]%download}
		app_args[uptodown_dlurl]=${app_args[uptodown_dlurl]%/}
		app_args[dl_from]=uptodown
	} || app_args[uptodown_dlurl]=""
	app_args[apkmirror_dlurl]=$(toml_get "$t" apkmirror-dlurl) && {
		app_args[apkmirror_dlurl]=${app_args[apkmirror_dlurl]%/}
		app_args[dl_from]=apkmirror
	} || app_args[apkmirror_dlurl]=""
	app_args[archive_dlurl]=$(toml_get "$t" archive-dlurl) && {
		app_args[archive_dlurl]=${app_args[archive_dlurl]%/}
		app_args[dl_from]=archive
	} || app_args[archive_dlurl]=""
	if [ -z "${app_args[dl_from]-}" ]; then abort "ERROR: no 'apkmirror_dlurl', 'uptodown_dlurl' or 'archive_dlurl' option was set for '$table_name'."; fi
	app_args[arch]=$(toml_get "$t" arch) || app_args[arch]="all"
	if [ "${app_args[arch]}" != "both" ] && [ "${app_args[arch]}" != "all" ] && [[ ${app_args[arch]} != "arm64-v8a"* ]] && [[ ${app_args[arch]} != "arm-v7a"* ]]; then
		abort "wrong arch '${app_args[arch]}' for '$table_name'"
	fi

	app_args[dpi]=$(toml_get "$t" dpi) || app_args[dpi]="$DEF_DPI_LIST"
	table_name_f=${table_name,,}
	table_name_f=${table_name_f// /-}

	if [ "${app_args[arch]}" = both ]; then
		app_args[table]="$table_name (arm64-v8a)"
		app_args[arch]="arm64-v8a"
		idx=$((idx + 1))
		build_rv "$(declare -p app_args)" &
		app_args[table]="$table_name (arm-v7a)"
		app_args[arch]="arm-v7a"
		if ((idx >= PARALLEL_JOBS)); then
			wait -n
			idx=$((idx - 1))
		fi
		idx=$((idx + 1))
		build_rv "$(declare -p app_args)" &
	else
		idx=$((idx + 1))
		build_rv "$(declare -p app_args)" &
	fi
done
wait
rm -rf temp/tmp.*
if [ -z "$(ls -A1 "${BUILD_DIR}")" ]; then abort "All builds failed."; fi

if [ "$OS" = Android ]; then
    pr "Moving outputs to /sdcard/Download/rvx-output"
    for apk in "${BUILD_DIR}"/*; do
        if [ -f "$apk" ]; then
            mv -f "$apk" "$OUTPUT_DIR/"
            pr "$(basename "$apk")"
        fi
    done
    am start -a android.intent.action.VIEW -d "file:///sdcard/Download/rvx-output" -t resource/folder >/dev/null 2>&1 || :
fi

log "\n- ▶️ » Install [MicroG-RE](https://github.com/MorpheApp/MicroG-RE/releases) for YouTube and YT Music APKs\n"
log "$(cat "$TEMP_DIR"/*-rv/changelog.md)"

SKIPPED=$(cat "$TEMP_DIR"/skipped 2>/dev/null || :)
if [ -n "$SKIPPED" ]; then
	log "\nSkipped:"
	log "$SKIPPED"
fi

pr "Done"