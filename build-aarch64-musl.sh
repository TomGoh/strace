#!/bin/bash
set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}strace aarch64-musl Build Script${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Step 1: Check for aarch64-linux-musl-gcc
echo -e "${YELLOW}[1/6] Checking for aarch64-linux-musl-gcc...${NC}"
if ! command -v aarch64-linux-musl-gcc &> /dev/null; then
    echo -e "${RED}ERROR: aarch64-linux-musl-gcc not found!${NC}"
    echo -e "${RED}Please install the aarch64-linux-musl cross-compiler toolchain.${NC}"
    echo ""
    echo "You can download it from:"
    echo "  https://musl.cc/"
    echo ""
    echo "Or install via:"
    echo "  wget https://musl.cc/aarch64-linux-musl-cross.tgz"
    echo "  tar xf aarch64-linux-musl-cross.tgz"
    echo "  export PATH=\"\$PWD/aarch64-linux-musl-cross/bin:\$PATH\""
    exit 1
fi

MUSL_GCC_PATH=$(which aarch64-linux-musl-gcc)
echo -e "${GREEN}✓ Found: $MUSL_GCC_PATH${NC}"
aarch64-linux-musl-gcc --version | head -n1
echo ""

# Step 2: Install required packages
echo -e "${YELLOW}[2/6] Installing required build packages...${NC}"
REQUIRED_PKGS="autoconf automake libtool make gcc gawk"

# Detect package manager
if command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt-get"
    INSTALL_CMD="sudo apt-get update && sudo apt-get install -y"
elif command -v yum &> /dev/null; then
    PKG_MANAGER="yum"
    INSTALL_CMD="sudo yum install -y"
elif command -v dnf &> /dev/null; then
    PKG_MANAGER="dnf"
    INSTALL_CMD="sudo dnf install -y"
elif command -v pacman &> /dev/null; then
    PKG_MANAGER="pacman"
    INSTALL_CMD="sudo pacman -S --noconfirm"
else
    echo -e "${YELLOW}Warning: Could not detect package manager${NC}"
    echo "Please manually install: $REQUIRED_PKGS"
    read -p "Press Enter to continue if packages are already installed..."
fi

if [ -n "$PKG_MANAGER" ]; then
    echo "Detected package manager: $PKG_MANAGER"
    echo "Installing: $REQUIRED_PKGS"

    # Check which packages are missing
    MISSING_PKGS=""
    for pkg in $REQUIRED_PKGS; do
        if ! command -v $pkg &> /dev/null && ! dpkg -l | grep -q "^ii  $pkg" 2>/dev/null; then
            MISSING_PKGS="$MISSING_PKGS $pkg"
        fi
    done

    if [ -n "$MISSING_PKGS" ]; then
        echo "Missing packages:$MISSING_PKGS"
        eval "$INSTALL_CMD $MISSING_PKGS"
    else
        echo -e "${GREEN}✓ All required packages already installed${NC}"
    fi
fi
echo ""

# Step 3: Apply musl compatibility fix
echo -e "${YELLOW}[3/6] Applying musl compatibility fix to src/ptrace.h...${NC}"
PTRACE_H="src/ptrace.h"

if [ ! -f "$PTRACE_H" ]; then
    echo -e "${RED}ERROR: $PTRACE_H not found!${NC}"
    echo "Make sure you're running this script from the strace source directory."
    exit 1
fi

# Check if fix is already applied
if grep -q "Workaround for musl + linux headers conflict on aarch64" "$PTRACE_H"; then
    echo -e "${GREEN}✓ Fix already applied${NC}"
else
    echo "Applying patch..."
    # Create a backup
    cp "$PTRACE_H" "${PTRACE_H}.backup"

    # Apply the fix using sed
    sed -i '/^# include <linux\/ptrace.h>$/i \
/* Workaround for musl + linux headers conflict on aarch64 */\
# if defined(__aarch64__)\
#  define sigcontext __kernel_sigcontext\
#  define _aarch64_ctx __kernel_aarch64_ctx\
#  define fpsimd_context __kernel_fpsimd_context\
#  define esr_context __kernel_esr_context\
#  define extra_context __kernel_extra_context\
#  define sve_context __kernel_sve_context\
# endif\
' "$PTRACE_H"

    sed -i '/^# include <linux\/ptrace.h>$/a \
\
# if defined(__aarch64__)\
#  undef sigcontext\
#  undef _aarch64_ctx\
#  undef fpsimd_context\
#  undef esr_context\
#  undef extra_context\
#  undef sve_context\
# endif' "$PTRACE_H"

    echo -e "${GREEN}✓ Fix applied successfully${NC}"
    echo "  Backup saved to: ${PTRACE_H}.backup"
fi
echo ""

# Step 4: Bootstrap (generate configure script)
echo -e "${YELLOW}[4/6] Generating configure script...${NC}"
if [ ! -f "configure" ]; then
    echo "Running ./bootstrap..."
    ./bootstrap
    echo -e "${GREEN}✓ Configure script generated${NC}"
else
    echo -e "${GREEN}✓ Configure script already exists${NC}"
fi
echo ""

# Step 5: Configure the build
echo -e "${YELLOW}[5/6] Configuring build for aarch64-linux-musl (static binary)...${NC}"
./configure \
    --host=aarch64-linux-musl \
    CC=aarch64-linux-musl-gcc \
    --enable-mpers=no \
    LDFLAGS="-static"

echo -e "${GREEN}✓ Configuration complete${NC}"
echo ""

# Step 6: Compile
echo -e "${YELLOW}[6/6] Compiling strace...${NC}"
NPROC=$(nproc 2>/dev/null || echo 4)
echo "Using $NPROC parallel jobs"
make -j$NPROC

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Build Successful!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Show binary information
BINARY_PATH="$(pwd)/src/strace"
if [ -f "$BINARY_PATH" ]; then
    echo -e "${BLUE}Binary Location:${NC}"
    echo "  $BINARY_PATH"
    echo ""

    echo -e "${BLUE}Binary Information:${NC}"
    ls -lh "$BINARY_PATH"
    echo ""
    file "$BINARY_PATH"
    echo ""

    # Test the binary
    echo -e "${BLUE}Version Check:${NC}"
    "$BINARY_PATH" --version 2>&1 | head -n3
    echo ""

    # Calculate size
    SIZE_KB=$(du -k "$BINARY_PATH" | cut -f1)
    SIZE_MB=$(echo "scale=2; $SIZE_KB / 1024" | bc)

    echo -e "${BLUE}Binary Type:${NC}"
    echo "  Statically linked - no external dependencies required!"
    echo "  Perfect for custom OS deployments"
    echo ""

    echo -e "${BLUE}Binary Size:${NC}"
    echo "  ${SIZE_MB} MB (with debug symbols)"
    echo ""
    echo -e "${YELLOW}Tip: To reduce size for deployment, run:${NC}"
    echo "  aarch64-linux-musl-strip $BINARY_PATH"
    echo "  (This can reduce size by ~70%)"
    echo ""

    echo -e "${BLUE}Installation:${NC}"
    echo "  This static binary works on any aarch64 Linux system!"
    echo ""
    echo "  Copy to your custom OS:"
    echo "    scp $BINARY_PATH user@target:/usr/bin/strace"
    echo ""
    echo "  Or install locally:"
    echo "    sudo cp $BINARY_PATH /usr/local/bin/strace"
    echo ""

    echo -e "${BLUE}Quick Test:${NC}"
    echo "  $BINARY_PATH ls -la"
    echo ""
else
    echo -e "${RED}ERROR: Binary not found at expected location!${NC}"
    exit 1
fi

echo -e "${GREEN}Done!${NC}"
