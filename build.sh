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

PATH="$LLVM_BIN:$PATH"
echo "PATH: $PATH"

echo "testing llvm..."
clang --version
ld.lld --version

BUILD_TARGET=dm3q_kor_singlex
export MODEL=$(echo ${BUILD_TARGET} | cut -d'_' -f1)
export PROJECT_NAME=${MODEL}
export REGION=$(echo ${BUILD_TARGET} | cut -d'_' -f2)
export CARRIER=$(echo ${BUILD_TARGET} | cut -d'_' -f3)
export TARGET_BUILD_VARIANT=user

CHIPSET_NAME=kalama
export ANDROID_BUILD_TOP="$CWD"
export TARGET_PRODUCT=gki
export TARGET_BOARD_PLATFORM=gki

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
MAKE_ARGS="-j$(nproc --all)"
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

if [ "${LTO}" = "none" -o "${LTO}" = "thin" -o "${LTO}" = "full" ]; then
  echo "modifying LTO mode to '${LTO}'"

  if [ "${LTO}" = "none" ]; then
     "${CWD}/scripts/config" --file "${OUT_DIR}/.config" \
      -d LTO_CLANG \
      -e LTO_NONE \
      -d LTO_CLANG_THIN \
      -d LTO_CLANG_FULL \
      -d THINLTO \
      --set-val FRAME_WARN 0 || exit 1
  elif [ "${LTO}" = "thin" ]; then
    "${CWD}/scripts/config" --file "${OUT_DIR}/.config" \
      -e LTO_CLANG \
      -d LTO_NONE \
      -e LTO_CLANG_THIN \
      -d LTO_CLANG_FULL \
      -e THINLTO || exit 1
  elif [ "${LTO}" = "full" ]; then
    "${CWD}/scripts/config" --file "${OUT_DIR}/.config" \
      -e LTO_CLANG \
      -d LTO_NONE \
      -d LTO_CLANG_THIN \
      -e LTO_CLANG_FULL \
      -d THINLTO || exit 1
  fi
  (
    echo "olddefconfig..."
    cd "$OUT_DIR" || exit 1
    make O="${OUT_DIR}" ${TOOL_ARGS} "${MAKE_ARGS[@]}" olddefconfig
  ) || exit 1
elif [ -n "${LTO}" ]; then
  echo "LTO must be one of 'none', 'thin' or 'full'." >&2
  exit 1
fi

echo "building kernel..."
(
  export ARCH=arm64
  cd "$OUT_DIR" || exit 1
  make O="${OUT_DIR}" ${TOOL_ARGS} "${MAKE_ARGS[@]}" ${MAKE_GOALS}
) || exit 1
