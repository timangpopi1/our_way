#!/usr/bin/env bash
# ---- Clang Build Script ----
# Copyright (C) 2023 fadlyas07 <mhmmdfdlyas@gmail.com>

export PATH=/usr/bin/core_perl:$PATH

# Function to show an informational message
msg() {
    echo -e "\e[1;32m$*\e[0m"
}

err() {
    echo -e "\e[1;41m$*\e[0m"
}

# Inlined function to post a message
export BOT_MSG_URL="https://api.telegram.org/bot$TOKEN"
tg_post_msg() {
	curl -s -X POST "$BOT_MSG_URL/sendMessage" -d chat_id="$CHATID" \
	-d "disable_web_page_preview=true" \
	-d "parse_mode=html" \
	-d text="$1"
}

tg_post_build() {
	curl --progress-bar -F document=@"$1" "$BOT_MSG_URL/sendDocument" \
	-F chat_id="$2"  \
	-F "disable_web_page_preview=true" \
	-F "parse_mode=html" \
	-F caption="$3"
}

# Setup env variable
ScriptDir=$(pwd)
DistroName=$(source /etc/os-release && echo ${PRETTY_NAME})

# Compile glibc.c for glibc version
gcc glibc.c -o glibc
export GlibcVersion="$(./glibc)"

# Clone LLVM project repository
git clone --single-branch https://github.com/llvm/llvm-project -b main --depth=1

# Clone/Create push repo
BuildBranchDate="$(date '+%Y%m%d')"
OriginURL="https://fadlyas07:${GL_TOKEN}@gitlab.com/fadlyas07/clang-llvm"
if ! git clone -j64 --single-branch -b ${BuildBranchDate} ${OriginURL} --depth=1; then
    mkdir -p "${ScriptDir}/clang-llvm" && pushd "${ScriptDir}/clang-llvm";
    git init && git remote add origin "${OriginURL}" && git checkout -b "${BuildBranchDate}";
    popd
fi

# Simplify clang version
LlvmPathVer="${ScriptDir}/llvm-project/clang/lib/Basic/Version.cpp"
sed -i 's/return CLANG_REPOSITORY_STRING;/return "";/g' ${LlvmPathVer}
sed -i 's/return CLANG_REPOSITORY;/return "";/g' ${LlvmPathVer}
sed -i 's/return LLVM_REPOSITORY;/return "";/g' ${LlvmPathVer}
sed -i 's/return CLANG_REVISION;/return "";/g' ${LlvmPathVer}
sed -i 's/return LLVM_REVISION;/return "";/g' ${LlvmPathVer}

# Build LLVM
tg_post_msg "greenforce clang compilation started at $(date)!"
BuildStart=$(date +"%s")
JobsTotal="$(($(nproc --all)*4))"
./build-llvm.py \
    --clang-vendor "greenforce" \
    --defines LLVM_PARALLEL_COMPILE_JOBS=$JobsTotal LLVM_PARALLEL_LINK_JOBS=$JobsTotal CMAKE_C_FLAGS='-g0 -O3' CMAKE_CXX_FLAGS='-g0 -O3' CMAKE_C_FLAGS='-march=native -mtune=native' CMAKE_CXX_FLAGS='-march=native -mtune=native' \
    --pgo "kernel-defconfig-slim" \
    --projects "clang;lld;polly" \
    --targets "ARM;AArch64;X86" \
    --no-update 2>&1 | tee build.log

# Check if the final clang binary exists or not.
[ ! -f ${ScriptDir}/install/bin/clang-1* ] && {
    status=failed
    err "Building LLVM failed! Kindly check errors!!"
    tg_post_build "${ScriptDir}/build.log" "$CHATID" "LLVM error Log"
    exit 1
}
tg_post_build "${ScriptDir}/build.log" "$CHATID" "LLVM success Log"
# Build binutils
tg_post_msg "Building binutils..!"
./build-binutils.py \
    --targets arm aarch64 x86_64

BuildEnd=$(date +"%s")
BuildDiff=$((BuildEnd - BuildStart))
BuildDiffMsg="$(($BuildDiff / 60)) minutes, $(($BuildDiff % 60)) seconds"
tg_post_msg "Build Complete in ${BuildDiffMsg}"

# Remove unused products
rm -fr install/include install/lib/libclang-cpp.so.18git
rm -f install/lib/*.a install/lib/*.la

# Strip remaining products
for f in $(find install -type f -exec file {} \; | grep 'not stripped' | awk '{print $1}'); do
    strip -s "${f: : -1}"
done

# Set executable rpaths so setting LD_LIBRARY_PATH isn't necessary
for bin in $(find install -mindepth 2 -maxdepth 3 -type f -exec file {} \; | grep 'ELF .* interpreter' | awk '{print $1}'); do
    # Remove last character from file output (':')
    bin="${bin: : -1}"

    echo "$bin"
    patchelf --set-rpath "${ScriptDir}/install/lib" "${bin}"
done

# Set Git Config
git config --global user.name "greenforce-auto-build"
git config --global user.email "greenforce-auto-build@users.noreply.github.com"

# Set environment for github push & release
pushd "${ScriptDir}/llvm-project"
CommitMessage=$(git log --pretty="format:%s" | head -n1)
ShortLLVMCommit="$(git rev-parse --short HEAD)"
popd
echo "$(install/bin/clang --version | head -n1)" > "${ScriptDir}/full_clang_version"
LLVMCommitURL="https://github.com/llvm/llvm-project/commit/${ShortLLVMCommit}"
ClangVersion="$(install/bin/clang --version | head -n1 | cut -d' ' -f4)"
BinutilsVersion="$(ls | grep "^binutils-" | sed "s/binutils-//g")"
READMEmsg="This toolchain is built on ${DistroName}, which uses ${GlibcVersion}. Compatibility with older distributions cannot be guaranteed. Other libc implementations (such as musl) are not supported."

# Push to GitHub Repository
pushd "${ScriptDir}/clang-llvm"
cp -r ../install/* .
[[ ! -e README.md ]] && wget https://github.com/greenforce-project/clang-llvm/raw/763e83ec123f3d9be6b05956327c7a84808a63fa/README.md
sed -i "s/AboutHostCompability/${READMEmsg}/g" ${ScriptDir}/clang-llvm/README.md
CommitMessage=$(echo "
Clang version: $(cat ${ScriptDir}/full_clang_version)
Binutils version: ${BinutilsVersion}
LLVM repo commit: ${CommitMessage}
Link: ${LLVMCommitURL}

")
git add -f .
git commit -m "greenforce: Bump to $(date '+%Y%m%d') build" -m "${CommitMessage}" --signoff
git push -fu origin ${BuildBranchDate}
popd

tg_post_msg "<b>Greenforce clang compilation finished!</b>
<b>Clang version: </b><code>$(cat ${ScriptDir}/full_clang_version)</code>
<b>LLVM commit: </b><code>${LLVMCommitURL}</code>
<b>Binutils version: </b><code>${BinutilsVersion}</code>
<b>Build took</b> <code>${BuildDiffMsg}</code>"
