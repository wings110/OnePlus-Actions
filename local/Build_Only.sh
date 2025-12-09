#!/bin/bash
#export all_proxy=socks5://192.168.x.x:x/
set -e

# --- Build Configuration ---
clear
echo "================================================="
echo "     OnePlus Kernel Build Configuration          "
echo "================================================="
echo "Press Enter to accept the default value in [brackets]."
echo ""

# Function to prompt user for input with a default value
ask() {
    local prompt default reply
    prompt="$1"
    default="$2"
    
    read -p "$prompt [$default]: " reply
    echo "${reply:-$default}"
}

# --- Interactive Inputs ---
CPU=$(ask "Enter CPU branch (e.g., sm8650, sm8550, sm8475)" "sm8650")
FEIL=$(ask "Enter phone model (e.g., oneplus_12, oneplus_11)" "oneplus_12")
ANDROID_VERSION=$(ask "Enter kernel Android version (android14, android13, android12)" "android14")
KERNEL_VERSION=$(ask "Enter kernel version (6.1, 5.15, 5.10)" "6.1")
lz4kd=$(ask "Enable lz4kd? (6.1 uses lz4 + zstd if Off) (On/Off)" "Off")
bbr=$(ask "Enable BBR congestion control algorithm? (On/Off)" "Off")
bbg=$(ask "Enable Baseband-Guard? (On/Off)" "On")
proxy=$(ask "Add proxy performance optimization? (if MTK CPU must be Off!)  (On/Off)" "On")

# --- Display Configuration Summary ---
clear
echo ""
echo "================================================="
echo "         Configuration Summary"
echo "================================================="
echo "Phone Model            : $FEIL"
echo "CPU                    : $CPU"
echo "Android Version        : $ANDROID_VERSION"
echo "Kernel Version         : $KERNEL_VERSION"
echo "lz4kd Enabled          : $lz4kd"
echo "BBR Enabled            : $bbr"
echo "Baseband-Guard Enabled : $bbg"
echo "Proxy Opts Enabled     : $proxy"
echo "================================================="
read -p "Press Enter to begin the build process..."
clear

# --- Environment Setup ---
echo "📦 Preparing the files..."
WORKSPACE=$PWD/build_workspace
sudo rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE"
cd "$WORKSPACE"

# Install dependencies BEFORE trying to use them.
echo "📦 Installing build dependencies (requires sudo)..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
  python3 git curl ccache libelf-dev \
  build-essential flex bison libssl-dev \
  libncurses-dev liblz4-tool zlib1g-dev \
  libxml2-utils rsync unzip python3-pip gawk
clear
echo "✅ All dependencies installed successfully."

# Set up and improve ccache
# Generous size for local builds
echo "⚙️ Setting up ccache..."
export CCACHE_DIR="$HOME/.ccache_${FEIL}_Kernel"
export CCACHE_COMPILERCHECK="%compiler% -dumpmachine; %compiler% -dumpversion"
export CCACHE_NOHASHDIR="true"
export CCACHE_HARDLINK="true"
export CCACHE_MAXSIZE="20G"
export PATH="/usr/lib/ccache:$PATH"
mkdir -p "$CCACHE_DIR"
echo "✅ ccache directory set to: $CCACHE_DIR"
ccache -M "$CCACHE_MAXSIZE"
ccache -z
# Clear statistics for a clean run summary

# Configure Git for repo tool
echo "🔐 Configuring Git user info..."
git config --global user.name "Local Builder"
git config --global user.email "builder@localhost"
echo "✅ Git configured."

# --- Source Code and Tooling ---

# Install Google Repo Tool if not present
if ! command -v repo &> /dev/null; then
    echo "📥 Installing Google Repo tool..."
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo > ~/repo
    chmod a+x ~/repo
    sudo mv ~/repo /usr/local/bin/repo
    echo "✅ Repo tool installed."
else
    echo "ℹ️ Repo tool already installed."
fi

# Clone Kernel Source
echo "⬇️ Cloning kernel source code..."
# If the directory already exists from a previous failed run, remove it for a clean start
sudo rm -rf kernel_workspace
mkdir -p kernel_workspace && cd kernel_workspace

echo "🌐 Initializing repo for oneplus/${CPU} on model ${FEIL}..."
repo init -u https://github.com/Xiaomichael/kernel_manifest.git -b refs/heads/oneplus/${CPU} -m ${FEIL}.xml --depth=1

echo "🔄 Syncing repositories (using $(nproc --all) threads)..."
repo sync -c -j$(nproc --all) --no-tags --no-clone-bundle --force-sync

export adv=$ANDROID_VERSION
echo "kernel_name: -$adv-oki-xiaoxiaow"
echo "🔧 Cleaning up and modifying version strings..."
rm -f kernel_platform/common/android/abi_gki_protected_exports_* || echo "No protected exports to remove from common!"
rm -f kernel_platform/msm-kernel/android/abi_gki_protected_exports_* || echo "No protected exports to remove from msm-kernel!"

sed -i 's/ -dirty//g' kernel_platform/common/scripts/setlocalversion
sed -i 's/ -dirty//g' kernel_platform/msm-kernel/scripts/setlocalversion
sed -i 's/ -dirty//g' kernel_platform/external/dtc/scripts/setlocalversion
sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' kernel_platform/common/scripts/setlocalversion
sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' kernel_platform/msm-kernel/scripts/setlocalversion
sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' kernel_platform/external/dtc/scripts/setlocalversion
sed -i '$s|echo "\$res"|echo "-$adv-oki-xiaoxiaow"|' kernel_platform/common/scripts/setlocalversion
sed -i '$s|echo "\$res"|echo "-$adv-oki-xiaoxiaow"|' kernel_platform/msm-kernel/scripts/setlocalversion
sed -i '$s|echo "\$res"|echo "-$adv-oki-xiaoxiaow"|' kernel_platform/external/dtc/scripts/setlocalversion
echo "✅ Kernel source cloned and configured."

if [ "$bbg" = "On" ]; then
    set -e
    cd kernel_platform/common
    curl -sSL https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh -o setup.sh
    bash setup.sh
    cd ../..
fi

# --- Kernel Customization ---
# Set up Zram and other patches
echo "🔧 Setting up SUSFS and applying patches..."
git clone https://github.com/Xiaomichael/kernel_patches.git
git clone https://github.com/ShirkNeko/SukiSU_patch.git

cd kernel_platform
echo "📝 Copying patch files..."

if [ "$lz4kd" = "Off" ] && [ "$KERNEL_VERSION" = "6.1" ]; then
  echo "📦 Copying lz4+zstd patches..."
  cp ../kernel_patches/zram/001-lz4.patch ./common/
  cp ../kernel_patches/zram/lz4armv8.S ./common/lib
  cp ../kernel_patches/zram/002-zstd.patch ./common/
fi

if [ "$lz4kd" = "On" ]; then
  echo "🚀 Copying lz4kd patches..."
  cp -r ../SukiSU_patch/other/zram/lz4k/include/linux/* ./common/include/linux
  cp -r ../SukiSU_patch/other/zram/lz4k/lib/* ./common/lib
  cp -r ../SukiSU_patch/other/zram/lz4k/crypto/* ./common/crypto
  cp -r ../SukiSU_patch/other/zram/lz4k_oplus ./common/lib/
fi

echo "🔧 Applying patches..."
cd ./common

if [ "$lz4kd" = "Off" ] && [ "$KERNEL_VERSION" = "6.1" ]; then
  echo "📦 Applying lz4+zstd patches..."
  git apply -p1 < 001-lz4.patch || true
  patch -p1 < 002-zstd.patch || true
fi

if [ "$lz4kd" = "On" ]; then
  echo "🚀 Applying lz4kd patches..."
  cp ../../SukiSU_patch/other/zram/zram_patch/${KERNEL_VERSION}/lz4kd.patch ./
  patch -p1 -F 3 < lz4kd.patch || true
  cp ../../SukiSU_patch/other/zram/zram_patch/${KERNEL_VERSION}/lz4k_oplus.patch ./
  patch -p1 -F 3 < lz4k_oplus.patch || true
fi
echo "✅ All patches applied."
cd ../..
# Back to $WORKSPACE/kernel_workspace

# Configure Kernel Options
echo "⚙️ Configuring kernel build options (defconfig)..."
DEFCONFIG_PATH="$WORKSPACE/kernel_workspace/kernel_platform/common/arch/arm64/configs/gki_defconfig"

if [ "$bbg" == "On" ]; then
  echo "📦 Enabling BBG..."
  cat <<EOT >> "$DEFCONFIG_PATH"
CONFIG_BBG=y
CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor,bpf,baseband_guard"
EOT
fi

if [ "$bbr" = "On" ]; then
  echo "🌐 Enabling BBR..."
  cat <<EOT >> "$DEFCONFIG_PATH"
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_NET_SCH_FQ=y
CONFIG_TCP_CONG_BIC=n
CONFIG_TCP_CONG_WESTWOOD=n
CONFIG_TCP_CONG_HTCP=n
EOT
fi

if [ "$lz4kd" = "On" ]; then
  echo "📦 Enabling lz4kd..."
  cat <<EOT >> "$DEFCONFIG_PATH"
CONFIG_CRYPTO_LZ4KD=y
CONFIG_CRYPTO_LZ4K_OPLUS=y
CONFIG_ZRAM_WRITEBACK=y
EOT
fi

if [ "$KERNEL_VERSION" = "6.1" ]; then echo "CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y" >> "$DEFCONFIG_PATH"; fi

if [ "$proxy" = "On" ]; then
  echo "📦 Adding proxy optimizations..."
  cat <<EOT >> "$DEFCONFIG_PATH"
CONFIG_BPF_STREAM_PARSER=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_IP_SET=y
CONFIG_IP_SET_MAX=65534
CONFIG_IP_SET_BITMAP_IP=y
CONFIG_IP_SET_BITMAP_IPMAC=y
CONFIG_IP_SET_BITMAP_PORT=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_IPMARK=y
CONFIG_IP_SET_HASH_IPPORT=y
CONFIG_IP_SET_HASH_IPPORTIP=y
CONFIG_IP_SET_HASH_IPPORTNET=y
CONFIG_IP_SET_HASH_IPMAC=y
CONFIG_IP_SET_HASH_MAC=y
CONFIG_IP_SET_HASH_NETPORTNET=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_IP_SET_HASH_NETNET=y
CONFIG_IP_SET_HASH_NETPORT=y
CONFIG_IP_SET_HASH_NETIFACE=y
CONFIG_IP_SET_LIST_SET=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
EOT
fi

if [ "$KERNEL_VERSION" = "5.10" ] || [ "$KERNEL_VERSION" = "5.15" ]; then
  echo "📦 Configuring LTO for Kernel 5.1x..."
  sed -i 's/^CONFIG_LTO=n/CONFIG_LTO=y/' "$DEFCONFIG_PATH"
  sed -i 's/^CONFIG_LTO_CLANG_FULL=y/CONFIG_LTO_CLANG_THIN=y/' "$DEFCONFIG_PATH"
  sed -i 's/^CONFIG_LTO_CLANG_NONE=y/CONFIG_LTO_CLANG_THIN=y/' "$DEFCONFIG_PATH"
  grep -q '^CONFIG_LTO_CLANG_THIN=y' "$DEFCONFIG_PATH" || echo 'CONFIG_LTO_CLANG_THIN=y' >> "$DEFCONFIG_PATH"
fi

echo "CONFIG_HEADERS_INSTALL=n" >> "$DEFCONFIG_PATH"

sed -i 's/check_defconfig//' "$WORKSPACE/kernel_workspace/kernel_platform/common/build.config.gki"
echo "✅ Kernel defconfig updated."
cd ../..
# Back to $WORKSPACE

# --- Build and Package ---

echo "🔨 Building the kernel..."
cd "$WORKSPACE/kernel_workspace/kernel_platform/common"

MAKE_CMD_COMMON="make -j$(nproc --all) LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=\"ccache clang\" RUSTC=../../prebuilts/rust/linux-x86/1.73.0b/bin/rustc PAHOLE=../../prebuilts/kernel-build-tools/linux-x86/bin/pahole LD=ld.lld HOSTLD=ld.lld O=out gki_defconfig all"

if [ "$KERNEL_VERSION" = "6.1" ]; then
    export KBUILD_BUILD_TIMESTAMP="Wed Aug 20 07:17:20 UTC 2025"
    export KBUILD_BUILD_VERSION=1
    export PATH="$WORKSPACE/kernel_workspace/kernel_platform/prebuilts/clang/host/linux-x86/clang-r487747c/bin:$PATH"
    eval "$MAKE_CMD_COMMON KCFLAGS+=-O2"
elif [ "$KERNEL_VERSION" = "5.15" ]; then
    export PATH="$WORKSPACE/kernel_workspace/kernel_platform/prebuilts/clang/host/linux-x86/clang-r450784e/bin:$PATH"
    eval "$MAKE_CMD_COMMON"
elif [ "$KERNEL_VERSION" = "5.10" ]; then
    export PATH="$WORKSPACE/kernel_workspace/kernel_platform/prebuilts-master/clang/host/linux-x86/clang-r416183b/bin:$PATH"
    eval "make -j$(nproc --all) LLVM_IAS=1 LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=\"ccache clang\" RUSTC=../../prebuilts/rust/linux-x86/1.73.0b/bin/rustc PAHOLE=../../prebuilts/kernel-build-tools/linux-x86/bin/pahole LD=ld.lld HOSTLD=ld.lld O=out gki_defconfig all"
else
    echo "❌ Unsupported Kernel Version: $KERNEL_VERSION" && exit 1
fi

echo "📊 Displaying ccache statistics:"
ccache -s
echo "✅ Kernel compilation finished."
cd "$WORKSPACE"

# Package Kernel with AnyKernel3
echo "📦 Packaging kernel with AnyKernel3..."
git clone https://github.com/Xiaomichael/AnyKernel3 --depth=1
rm -rf ./AnyKernel3/.git

IMAGE_PATH=$(find "$WORKSPACE/kernel_workspace/kernel_platform/common/out/" -name "Image" | head -n 1)
if [ -z "$IMAGE_PATH" ]; then echo "❌ FATAL: Kernel Image not found after build!" && exit 1; fi

echo "✅ Kernel Image found at: $IMAGE_PATH"
cp "$IMAGE_PATH" ./AnyKernel3/Image

# --- Finalize and Upload ---
if [ "$lz4kd" = "On" ]; then
  ARTIFACT_NAME="Anykernel3_${FEIL}_lz4kd}_Kernel_Only"
elif [ "$KERNEL_VERSION" = "6.1" ]; then
  ARTIFACT_NAME="Anykernel3_${FEIL}_lz4_zstd}_Kernel_Only"
else
  ARTIFACT_NAME="Anykernel3_${FEIL}_Kernel_Only"
fi
FINAL_ZIP_NAME="${ARTIFACT_NAME}.zip"

echo "📦 Creating final zip file: ${FINAL_ZIP_NAME}..."
cd AnyKernel3 && zip -q -r9 "../${FINAL_ZIP_NAME}" ./* && cd ..

# --- Build Summary ---
echo ""
echo "================================================="
echo "               Build Complete!"
echo "================================================="
echo "-> Flashable Zip: $WORKSPACE/${FINAL_ZIP_NAME}"

ZRAM_KO_PATH=$(find "$WORKSPACE/kernel_workspace/kernel_platform/common/out/" -name "zram.ko" | head -n 1)
if [ -n "$ZRAM_KO_PATH" ]; then
    cp "$ZRAM_KO_PATH" "$WORKSPACE/"
    echo "-> zram.ko module: $WORKSPACE/zram.ko"
fi

echo "================================================="
echo ""