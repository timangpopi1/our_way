#!/usr/bin/env bash
# ---- Clang Build Script ----
# Copyright (C) 2023 fadlyas07 <mhmmdfdlyas@gmail.com>

ScriptDir=$(pwd)
DistroName=$(source /etc/os-release && echo ${PRETTY_NAME})
ReleaseDate="$(date '+%Y%m%d')" # ISO 8601 format
ReleaseTime="$(date +'%H%M')" # HoursMinute
ReleaseFriendlyDate="$(date '+%B %-d, %Y')" # "Month day, year" format

curl -Lo "${ScriptDir}/GitHubRelease" https://github.com/fadlyas07/scripts/raw/master/github/github-release
if [[ -f "${ScriptDir}/GitHubRelease" ]]; then
    chmod +x "${ScriptDir}/GitHubRelease"
else
    echo "ERROR: GitHubRelease file is missing!" && exit 1
fi

# Compile glibc.c for glibc version
gcc glibc.c -o glibc
export GlibcVersion="$(./glibc)"

# Clone LLVM project repository
git clone --single-branch https://github.com/llvm/llvm-project -b main --depth=1

# Create push repo
mkdir -p "${ScriptDir}/clang-llvm"

# Build LLVM
JobsTotal="$(($(nproc --all)*4))"
./build-llvm.py \
    --clang-vendor "greenforce" \
    --defines "LLVM_PARALLEL_COMPILE_JOBS=$JobsTotal LLVM_PARALLEL_LINK_JOBS=$JobsTotal CMAKE_C_FLAGS='-g0 -O3' CMAKE_CXX_FLAGS='-g0 -O3' CMAKE_C_FLAGS='-march=native -mtune=native' CMAKE_CXX_FLAGS='-march=native -mtune=native'" \
    --pgo "kernel-defconfig-slim" \
    --projects "clang;lld;polly" \
    --no-update \
    --targets "ARM;AArch64" && status=success || status=failed

# Build binutils
./build-binutils.py \
    --targets arm aarch64 \
    --march native

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
LLVMCommitURL="https://github.com/llvm/llvm-project/commit/${ShortLLVMCommit}"
BinutilsVersion="$(ls | grep "^binutils-" | sed "s/binutils-//g")"
ClangVersion="$(install/bin/clang --version | head -n1 | cut -d' ' -f4)"
ReleaseFileName="clang-${ClangVersion}-${ReleaseDate}-${ReleaseTime}.tar.gz"
READMEmsg="This toolchain is built on ${DistroName}, which uses ${GlibcVersion}. Compatibility with older distributions cannot be guaranteed. Other libc implementations (such as musl) are not supported."
echo "Automated build of LLVM + Clang ${ClangVersion} as of commit [${ShortLLVMCommit}](${LLVMCommitURL}) and binutils ${BinutilsVersion}." > body

# Push to GitHub Repository
pushd "${ScriptDir}/clang-llvm"
rm -rf * .git
cp -r ../install/* .
[[ ! -e README.md ]] && wget https://github.com/greenforce-project/clang-llvm/raw/2f11cf680896d7be7cbaefc82099fe92cfa92cd9/README.md
sed -i "s/YouCanChangeThis/${READMEmsg}/g" ${ScriptDir}/clang-llvm/README.md
CommitMessage=$(echo "
Clang version: ${ClangVersion}
Binutils version: ${BinutilsVersion}
LLVM repo commit: ${CommitMessage}
Link: ${LLVMCommitURL}
Releases: https://github.com/greenforce-project/clang-llvm/releases/download/${ReleaseDate}/${ReleaseFileName}

")
git init
git remote add origin https://github.com/greenforce-project/clang-llvm
git checkout -b main
git remote set-url origin https://${GH_TOKEN}@github.com/greenforce-project/clang-llvm
rm -rf gitignore .gitignore
git add -f .
git commit -m "greenforce: Bump to $(date '+%Y%m%d') build" -m "${CommitMessage}"
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
    echo "WARN: ${ScriptDir}/clang-llvm/gitignore not detected!"
fi
popd

# Push to github releases
tar -czf "${ReleaseFileName}" ${ScriptDir}/clang-llvm/*
[[ -e "${ScriptDir}/${ReleaseFileName}" ]] && ReleasePathFile="${ScriptDir}/${ReleaseFileName}"
if [[ $status == success ]]; then
    push_tag() {
        ./GitHubRelease release \
            --security-token "${GH_TOKEN}" \
            --user "greenforce-project" \
            --repo "clang-llvm" \
            --tag "${ReleaseDate}" \
            --name "${ReleaseFriendlyDate}" \
            --description "$(cat body)" || echo "WARN: GitHub Tag already exists!"
    }
    if [[ -n "${ReleasePathFile}" ]]; then
        push_tar() {
            ./GitHubRelease upload \
                --security-token "${GH_TOKEN}" \
                --user "greenforce-project" \
                --repo "clang-llvm" \
                --tag "${ReleaseDate}" \
                --name "${ReleaseFileName}" \
                --file "${ReleasePathFile}" || echo "ERROR: Failed to push files!"
        }
    fi
    if [[ $(push_tag) == "WARN: GitHub Tag already exists!" ]]; then
        if ! [[ -f "${ScriptDir}/GitHubRelease" ]]; then
            echo "ERROR: GitHubRelease file is not found, pls check it!" && exit
        else
            chmod +x ${ScriptDir}/GitHubRelease
            sleep 8
            push_tag || echo "ERROR: Failed again, Tag is already exists!"
        fi
    fi
    if [[ $(push_tar) == "ERROR: Failed to push files!" ]]; then
        if ! [[ -f "${ScriptDir}/GitHubRelease" ]]; then
            echo "ERROR: GitHubRelease file is not found, pls check it!" && exit
        else
            chmod +x ${ScriptDir}/GitHubRelease
            sleep 8
            push_tar || echo "ERROR: Failed again, can't push ${ReleaseFileName} to github releases."
        fi
    fi
fi
