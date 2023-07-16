#!/usr/bin/env bash
# ---- Clang Build Script ----
# Copyright (C) 2023 fadlyas07 <mhmmdfdlyas@gmail.com>

# Function to show an informational message
msg() {
    echo -e "\e[1;32m$*\e[0m"
}

err() {
    echo -e "\e[1;41m$*\e[0m"
}

ScriptDir=$(pwd)
DistroName=$(source /etc/os-release && echo ${PRETTY_NAME})
ReleaseDate="$(date '+%Y%m%d')" # ISO 8601 format
ReleaseTime="$(date +'%H%M')" # HoursMinute
ReleaseFriendlyDate="$(date '+%B %-d, %Y')" # "Month day, year" format

curl -Lo "${ScriptDir}/GitHubRelease" https://github.com/fadlyas07/scripts/raw/master/github/github-release
if [[ -f "${ScriptDir}/GitHubRelease" ]]; then
    chmod +x "${ScriptDir}/GitHubRelease"
else
    err "ERROR: GitHubRelease file is missing!" && exit 1
fi

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

# Compile glibc.c for glibc version
gcc glibc.c -o glibc
export GlibcVersion="$(./glibc)"

# Clone LLVM project repository
git clone --single-branch https://github.com/llvm/llvm-project -b main --depth=1

# Create push repo
mkdir -p "${ScriptDir}/clang-llvm"

# Build LLVM
tg_post_msg "Greenforce clang compilation started at $(date)!"
BuildStart=$(date +"%s")
JobsTotal="$(($(nproc --all)*4))"
./build-llvm.py \
    --clang-vendor "greenforce" \
    --defines LLVM_PARALLEL_COMPILE_JOBS=$JobsTotal LLVM_PARALLEL_LINK_JOBS=$JobsTotal CMAKE_C_FLAGS='-g0 -O3' CMAKE_CXX_FLAGS='-g0 -O3' \
    --pgo "kernel-defconfig-slim" \
    --projects "clang;lld;polly" \
    --no-update \
    --targets "ARM;AArch64" 2>&1 | tee build.log

# Check if the final clang binary exists or not.
[ ! -f install/bin/clang-1* ] && {
    status=failed
    err "Building LLVM failed! Kindly check errors!!"
    tg_post_build "build.log" "$CHATID" "Error Log"
    exit 1
}
tg_post_build "build.log" "$CHATID" "Success Log"

# Build binutils
tg_post_msg "Building binutils..!"
./build-binutils.py \
    --targets arm aarch64

BuildEnd=$(date +"%s")
BuildDiff=$((BuildEnd - BuildStart))
BuildDiffMsg="$(($BuildDiff / 60)) minutes, $(($BuildDiff % 60)) seconds"
tg_post_msg "Build Complete in ${BuildDiffMsg}"

# Remove unused products
rm -fr install/include install/lib/libclang-cpp.so.17git
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
mkdir -p "${ScriptDir}/build-info"
echo "$(install/bin/clang --version | head -n1)" > "${ScriptDir}/build-info/clang"
echo "$(install/bin/ld.lld --version | head -n1)" > "${ScriptDir}/build-info/ld"
LLVMCommitURL="https://github.com/llvm/llvm-project/commit/${ShortLLVMCommit}"
BinutilsVersion="$(ls | grep "^binutils-" | sed "s/binutils-//g")"
ClangVersion="$(install/bin/clang --version | head -n1 | cut -d' ' -f4)"
ReleaseFileName="clang-${ClangVersion}-${ReleaseDate}-${ReleaseTime}.tar.gz"
GitHubLinkReleases="https://github.com/greenforce-project/clang-llvm/releases/download/${ReleaseDate}/${ReleaseFileName}"
READMEmsg="This toolchain is built on ${DistroName}, which uses ${GlibcVersion}. Compatibility with older distributions cannot be guaranteed. Other libc implementations (such as musl) are not supported."
echo "Automated build of LLVM + Clang ${ClangVersion} as of commit [${ShortLLVMCommit}](${LLVMCommitURL}) and binutils ${BinutilsVersion}." > "${ScriptDir}/build-info/body"

# Push to GitHub Repository
pushd "${ScriptDir}/clang-llvm"
rm -rf * .git
cp -r ../install/* .
[[ ! -e README.md ]] && wget https://github.com/greenforce-project/clang-llvm/raw/763e83ec123f3d9be6b05956327c7a84808a63fa/README.md
sed -i "s/AboutHostCompability/${READMEmsg}/g" ${ScriptDir}/clang-llvm/README.md
CommitMessage=$(echo "
Clang version: $(cat ${ScriptDir}/build-info/clang),
$(cat ${ScriptDir}/build-info/ld)
Binutils version: ${BinutilsVersion}
LLVM repo commit: ${CommitMessage}
Link: ${LLVMCommitURL}

")
git init
git remote add origin https://github.com/greenforce-project/clang-llvm
git checkout -b main
git remote set-url origin https://${GH_TOKEN}@github.com/greenforce-project/clang-llvm
rm -rf gitignore .gitignore
git add -f .
git commit -m "greenforce: Bump to $(date '+%Y%m%d') build" -m "${CommitMessage}" --signoff
git push -fu origin main
popd

# Set Git Config (2)
git config --global user.name "fadlyas07"
git config --global user.email "mhmmdfdlyas@gmail.com"

pushd "${ScriptDir}/clang-llvm"
if [[ -e "${ScriptDir}/clang-llvm/gitignore" ]]; then
    rm -rf "${ScriptDir}/clang-llvm/gitignore"
    git add . && git commit -am "git: Remove gitignore"
    git push -f origin main
else
    msg "WARN: ${ScriptDir}/clang-llvm/gitignore not detected!"
fi
popd

# Push to github releases
tar -czvf "${ReleaseFileName}" ${ScriptDir}/clang-llvm/*
[[ -e "${ScriptDir}/${ReleaseFileName}" ]] && ReleasePathFile="${ScriptDir}/${ReleaseFileName}"
if [[ $status != failed ]]; then
    push_tag() {
        ./GitHubRelease release \
            --security-token "${GH_TOKEN}" \
            --user "greenforce-project" \
            --repo "clang-llvm" \
            --tag "${ReleaseDate}" \
            --name "${ReleaseFriendlyDate}" \
            --description "$(cat ${ScriptDir}/build-info/body)" || echo "WARN: GitHub Tag already exists!"
    }
    push_tar() {
        ./GitHubRelease upload \
            --security-token "${GH_TOKEN}" \
            --user "greenforce-project" \
            --repo "clang-llvm" \
            --tag "${ReleaseDate}" \
            --name "${ReleaseFileName}" \
            --file "${ReleasePathFile}" || echo "ERROR: Failed to push files!"
    }
    if [[ $(push_tag) == "WARN: GitHub Tag already exists!" ]]; then
        if ! [[ -f "${ScriptDir}/GitHubRelease" ]]; then
            err "ERROR: GitHubRelease file is not found, pls check it!" && exit
        else
            chmod +x ${ScriptDir}/GitHubRelease
            sleep 2
            push_tag || err "ERROR: Failed again, Tag is already exists!"
        fi
    fi
    if [[ $(push_tar) == "ERROR: Failed to push files!" ]]; then
        if ! [[ -f "${ScriptDir}/GitHubRelease" ]]; then
            err "ERROR: GitHubRelease file is not found, pls check it!" && exit
        else
            chmod +x ${ScriptDir}/GitHubRelease
            sleep 2
            push_tar || err "ERROR: Failed again, can't push ${ReleaseFileName} to github releases."
        fi
    fi
fi

tg_post_msg "<b>Greenforce clang compilation finished!</b>
<b>Clang version: </b><code>$(cat ${ScriptDir}/build-info/clang)</code>
<b>LLVM commit: </b><code>${LLVMCommitURL}</code>
<b>Binutils version: </b><code>${BinutilsVersion}</code>
<b>GitHub release: </b><code>${GitHubLinkReleases}</code>
<b>Build took</b> <code>${BuildDiffMsg}</code>"
