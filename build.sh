if [ "$BASH_SOURCE" != "$0" ]; then
    echo "source not supported" >&2
	return 1 2> /dev/null || exit 1
fi

CWD="$(dirname -- "$0" 2> /dev/null)"
if [ $? -ne 0 -o -z "$CWD" ]; then
	echo "unable to retrieve cwd" >&2
	return 1 2> /dev/null || exit 1
fi

CWD="$(realpath "$CWD")"
echo "cwd: $CWD"

BUILDCONFIG="build.config.gki.aarch64"

LLVM_DIR="/usr/lib/llvm-14"
LLVM_BIN="$LLVM_DIR/bin"

TOOLS=(
  "clang"
  "ld.lld"
  "llvm-ar"
  "llvm-nm"
  "llvm-objcopy"
  "llvm-objdump"
  "llvm-readelf"
  "llvm-strip"
)

for tool in "${TOOLS[@]}"; do
  IS_MISSING=""
  if [ ! -x "$LLVM_BIN/$tool" ]; then
    echo "missing: $tool"
    IS_MISSING="1"
  fi
  if [ -n "$IS_MISSING" ]; then
    echo "some tools missing at: $LLVM_BIN"
    exit 1
  fi
done

export PATH="$LLVM_BIN:$PATH"
echo "PATH: $PATH"

BUILD_TARGET="dm3q_kor_singlex"
export MODEL="$(echo ${BUILD_TARGET} | cut -d'_' -f1)"
export PROJECT_NAME=${MODEL}
export REGION="$(echo ${BUILD_TARGET} | cut -d'_' -f2)"
export CARRIER="$(echo ${BUILD_TARGET} | cut -d'_' -f3)"
export TARGET_BUILD_VARIANT="user"

CHIPSET_NAME="kalama"
export ANDROID_BUILD_TOP="$CWD"
export TARGET_PRODUCT="gki"
export TARGET_BOARD_PLATFORM="gki"

export ANDROID_PRODUCT_OUT="${ANDROID_BUILD_TOP}/out/target/product/${MODEL}"
export OUT_DIR="${ANDROID_BUILD_TOP}/out/msm-${CHIPSET_NAME}-${CHIPSET_NAME}-${TARGET_PRODUCT}"

export LTO="${LTO:-none}"
# export TRIM_NONLISTED_KMI=$([ -z "$TRIM_NONLISTED_KMI" ] && [ "$LTO" = "none" ] && echo 0)
# export KMI_SYMBOL_LIST_STRICT_MODE=$([ -z "$KMI_SYMBOL_LIST_STRICT_MODE" ] && [ "$LTO" = "none" ] && echo 0)
RECOMPILE_KERNEL=${RECOMPILE_KERNEL:-1}

if [ "$RECOMPILE_KERNEL" = "1" ]; then
  SKIP_MRPROPER=1
fi

LLVM=1
TOOL_ARGS="LLVM=1"
MAKE_ARGS=("-j$(nproc --all)")
echo "MAKE_ARGS: $MAKE_ARGS"

KERNEL_DIR="."
ROOT_DIR="$CWD"

echo "running config..."
cd "$CWD" || exit 1
pushd "$CWD"
set -a
source "$CWD/$BUILDCONFIG" || exit 1
set +a
popd > "/dev/null"

echo "making mrproper..."
if [ "$SKIP_MRPROPER" = "1" ]; then
  echo "skipped"
else
  (
    cd ${CWD} || exit 1
    make ${TOOL_ARGS} O=${OUT_DIR} "${MAKE_ARGS[@]}" mrproper
  ) || exit 1
fi

echo "making defconfig..."
(
  if [ -z "$DEFCONFIG" ]; then
    echo "defconfig empty" >&2
    exit 1
  fi
  cd ${CWD} || exit 1
  make ${TOOL_ARGS} O=${OUT_DIR} "${MAKE_ARGS[@]}" "$DEFCONFIG"
) || exit 1

function check_defconfig() {
  echo "checking defconfig..."
  pushd "${OUT_DIR}"
  make "${TOOL_ARGS}" O="${OUT_DIR}" savedefconfig
  popd > /dev/null
}

if [ -n "${POST_DEFCONFIG_CMDS}" ]; then
  echo "running post defconfig cmds..."
  eval ${POST_DEFCONFIG_CMDS}
fi

if [ "$LTO" = "none" -o "$LTO" = "thin" -o "$LTO" = "full" ]; then
  echo "modifying LTO mode to '$LTO'"

  if [ "$LTO" = "none" ]; then
     "$CWD/scripts/config" --file "$OUT_DIR/.config" \
      -d LTO_CLANG \
      -e LTO_NONE \
      -d LTO_CLANG_THIN \
      -d LTO_CLANG_FULL \
      -d THINLTO \
      --set-val FRAME_WARN 0 || exit 1
  elif [ "$LTO" = "thin" ]; then
    "$CWD/scripts/config" --file "$OUT_DIR/.config" \
      -e LTO_CLANG \
      -d LTO_NONE \
      -e LTO_CLANG_THIN \
      -d LTO_CLANG_FULL \
      -e THINLTO || exit 1
  elif [ "$LTO" = "full" ]; then
    "$CWD/scripts/config" --file "$OUT_DIR/.config" \
      -e LTO_CLANG \
      -d LTO_NONE \
      -d LTO_CLANG_THIN \
      -e LTO_CLANG_FULL \
      -d THINLTO || exit 1
  fi
  (
    echo "olddefconfig..."
    cd "$OUT_DIR" &&
    make O="$OUT_DIR" $TOOL_ARGS "${MAKE_ARGS[@]}" olddefconfig
  ) || exit 1
elif [ -n "$LTO" ]; then
  echo "LTO must be one of 'none', 'thin' or 'full'." >&2
  exit 1
fi

if [ -n "${KMI_SYMBOL_LIST}" ]; then
  "$CWD/process_symbols" --out-dir="$OUT_DIR" --out-file=abi_symbollist \
    --report-file=abi_symbollist.report --in-dir="$CWD" \
    "${KMI_SYMBOL_LIST}" ${ADDITIONAL_KMI_SYMBOL_LISTS}
  pushd "$ROOT_DIR/$KERNEL_DIR"

  if [ "${TRIM_NONLISTED_KMI}" = "1" ]; then
    cat "${OUT_DIR}/abi_symbollist" | \
      "$CWD/flatten_symbol_list" > \
      "${OUT_DIR}/abi_symbollist.raw"

    "$CWD/scripts/config" --file ${OUT_DIR}/.config \
      -d UNUSED_SYMBOLS -e TRIM_UNUSED_KSYMS \
      --set-str UNUSED_KSYMS_WHITELIST "${OUT_DIR}/abi_symbollist.raw"
    (
      cd ${OUT_DIR} &&
      make O="${OUT_DIR}" ${TOOL_ARGS} "${MAKE_ARGS[@]}" olddefconfig
    ) || exit 1
    
    grep CONFIG_UNUSED_KSYMS_WHITELIST ${OUT_DIR}/.config > /dev/null || {
      echo "ERROR: Failed to apply TRIM_NONLISTED_KMI kernel configuration" >&2
      echo "Does your kernel support CONFIG_UNUSED_KSYMS_WHITELIST?" >&2
      exit 1
    }
  elif [ "${KMI_SYMBOL_LIST_STRICT_MODE}" = "1" ]; then
    echo "ERROR: KMI_SYMBOL_LIST_STRICT_MODE requires TRIM_NONLISTED_KMI=1" >&2
    exit 1
  fi

  popd # $ROOT_DIR/$KERNEL_DIR
elif [ "${TRIM_NONLISTED_KMI}" = "1" ]; then
  echo "ERROR: TRIM_NONLISTED_KMI requires a KMI_SYMBOL_LIST" >&2
  exit 1
elif [ "${KMI_SYMBOL_LIST_STRICT_MODE}" = "1" ]; then
  echo "ERROR: KMI_SYMBOL_LIST_STRICT_MODE requires a KMI_SYMBOL_LIST" >&2
  exit 1
fi

echo "building kernel..."
(
  cd "$OUT_DIR" &&
  make O="${OUT_DIR}" ${TOOL_ARGS} "${MAKE_ARGS[@]}" ${MAKE_GOALS}
) || exit 1

compare_to_symbol_list() {
  if [ "$#" -ne 2 ]; then
    echo "ERROR: illegal number of parameters" >&2
    echo "Usage: $(basename "$0") <path/to/Module.symvers> <path/to/symbol-list>" >&2
    return 1
  fi

  local ksymtab=$(mktemp)
  local symbollist=$(mktemp)

  # List of objects, typically vmlinux + GKI modules
  local objects="${KMI_STRICT_MODE_OBJECTS:-vmlinux}"
  objects=($objects)

  local ksym=""

  # Parse Module.symvers, and ignore non-exported and vendor-specific symbols
  cut -d$'\t' -f2- $1 | while read line; do
    ksym=($line) # 0=symbol name; 1=object name; 2=export type
    if [[ "${ksym[2]}" != "EXPORT_SYMBOL"* ]]; then
      continue
    elif [[ ! " ${objects[@]} " =~ " ${ksym[1]} " ]]; then
      continue
    fi
    echo "${ksym[0]}"
  done | sort -u > $ksymtab

  sort -u "$2" > $symbollist

  delta=$(diff -u $ksymtab $symbollist | grep -v ' ')
  rm $ksymtab $symbollist
  if [ -n "$delta" ]; then
    echo "ERROR: Differences between ksymtab and symbol list detected!" >&2
    echo "Symbols missing from ksymtab:" >&2
    echo "$delta" | sed -n -e 's/^+/ - /p' >&2
    echo "Symbols missing from symbol list:" >&2
    echo "$delta" | sed -n -e 's/^-/ - /p' >&2
    return 1
  fi
}

if [ "${KMI_SYMBOL_LIST_STRICT_MODE}" = "1" ]; then
  echo "comparing the KMI and the symbol lists:"

  gki_modules_list="$CWD/android/gki_system_dlkm_modules"
  (
    export KMI_STRICT_MODE_OBJECTS="vmlinux $(sed 's/\.ko$//' ${gki_modules_list} | tr '\n' ' ')"
    echo "KMI_STRICT_MODE_OBJECTS: $KMI_STRICT_MODE_OBJECTS"
    compare_to_symbol_list "${OUT_DIR}/Module.symvers" "${OUT_DIR}/abi_symbollist.raw"
  ) || exit 1
fi

