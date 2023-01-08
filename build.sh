#!/usr/bin/env bash
# Copyright (C) 2022 fadlyas07 <mhmmdfdlyas@gmail.com>

# Set a directory
DIR="$(pwd ...)"

# Setup about github-release
curl -Lo "$DIR/gh-release" https://github.com/fadlyas07/scripts/raw/master/github/github-release
[[ -f "$DIR/gh-release" ]] && chmod +x "$DIR/gh-release"

# clone push repo
git clone -j64 --single-branch "https://$GH_TOKEN@github.com/greenforce-project/clang-llvm" -b main --depth=1

# clone LLVM repo
git clone -j64 --single-branch "https://github.com/llvm/llvm-project" -b main --depth=1

# Simplify clang version
path="llvm-project/clang/lib/Basic/Version.cpp"
sed -i 's/return CLANG_REPOSITORY_STRING;/return "";/g' $path
sed -i 's/return CLANG_REPOSITORY;/return "";/g' $path
sed -i 's/return LLVM_REPOSITORY;/return "";/g' $path
sed -i 's/return CLANG_REVISION;/return "";/g' $path
sed -i 's/return LLVM_REVISION;/return "";/g' $path

if [[ ! -f "$(pwd)/gh-release" ]]; then
    echo "gh-release is missing!" && exit
fi

log="$DIR/temporary"
mkdir -p "$log"

# Build LLVM
JobsTotal="$(($(nproc --all)*4))"
./build-llvm.py \
    --clang-vendor "greenforce" \
    --defines "LLVM_PARALLEL_COMPILE_JOBS=$JobsTotal LLVM_PARALLEL_LINK_JOBS=$JobsTotal CMAKE_C_FLAGS='-g0 -O3' CMAKE_CXX_FLAGS='-g0 -O3' CMAKE_C_FLAGS='-march=native -mtune=native' CMAKE_CXX_FLAGS='-march=native -mtune=native'" \
    --pgo "kernel-defconfig-slim" \
    --projects "clang;lld;polly" \
    --no-update \
    --targets "ARM;AArch64" 2>&1 | tee "$log/build.log" && status=success || status=failed

# Build binutils
./build-binutils.py \
    --targets arm aarch64 \
    --march native

# Remove unused products
rm -fr install/include install/lib/libclang-cpp.so.16git
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
    patchelf --set-rpath "$DIR/install/lib" "$bin"
done

# Release Info
rel_date="$(date '+%Y%m%d')" # ISO 8601 format
rel_time="$(date +'%H%M')" # HoursMinute
rel_friendly_date="$(date '+%B %-d, %Y')" # "Month day, year" format

pushd $(pwd)/llvm-project
commit_msg=$(git log --pretty="format:%s" | head -n1)
short_llvm_commit="$(git rev-parse --short HEAD)"

popd
llvm_commit_url="https://github.com/llvm/llvm-project/commit/$short_llvm_commit"

binutils_version="$(ls | grep "^binutils-" | sed "s/binutils-//g")"
clang_version="$(install/bin/clang --version | head -n1 | cut -d' ' -f4)"
rel_msg="Automated build of LLVM + Clang $clang_version as of commit [$short_llvm_commit]($llvm_commit_url) and binutils $binutils_version"

# Push to GitHub
# Update Git repository
export files="clang-$clang_version-$rel_date-$rel_time.tar.gz"
git config --global user.name "greenforce-auto-build"
git config --global user.email "greenforce-auto-build@users.noreply.github.com"

pushd $(pwd)/clang-llvm
rm -rf * .git
cp -r ../install/* .
[[ ! -e README.md ]] && wget https://github.com/greenforce-project/clang-llvm/raw/main/README.md
CommitMessage=$(echo "
Clang version: $clang_version
Binutils version: $binutils_version
LLVM repo commit: $commit_msg
Link: $llvm_commit_url

Releases: https://github.com/greenforce-project/clang-llvm/releases/download/${rel_date}/${files}

")
git init
git remote add origin https://github.com/greenforce-project/clang-llvm
git checkout -b main
git remote set-url origin https://${GH_TOKEN}@github.com/greenforce-project/clang-llvm
git add -f .
git commit -m "greenforce: Bump to $(date '+%Y%m%d') build" -m "${CommitMessage}" --signoff
git push -fu origin main
popd

tar -czf "$files" $(pwd)/clang-llvm/*
[[ -e "$(pwd)/$files" ]] && path_files="$(pwd)/$files"
echo "${rel_msg}." > body

if [[ $status == success ]]; then
    push_tag() {
        ./gh-release release \
            --security-token "$GH_TOKEN" \
            --user "greenforce-project" \
            --repo "clang-llvm" \
            --tag "$rel_date" \
            --name "$rel_friendly_date" \
            --description "$(cat body)" || echo "Tag already exists"
    }
    push_log() {
        ./gh-release upload \
            --security-token "$GH_TOKEN" \
            --user "greenforce-project" \
            --repo "clang-llvm" \
            --tag "$rel_date" \
            --name "build.log" \
            --file "$log/build.log" || echo "Failed to push"
    }
  if [[ -n "$path_files" ]]; then
    push_tar() {
        ./gh-release upload \
            --security-token "$GH_TOKEN" \
            --user "greenforce-project" \
            --repo "clang-llvm" \
            --tag "$rel_date" \
            --name "$files" \
            --file "$path_files" || echo "Failed to push files"
    }
  fi
    if [[ $(push_tag) == "Tag already exists" ]]; then
        if ! [[ -f "$(pwd)/gh-release" ]]; then
            echo "gh-release file not found, pls check it!" && exit
        else
            chmod +x $(pwd)/gh-release
            sleep 10
            push_tag || echo "Failed again, Tag is already exists!"
        fi
    fi
    if [[ $(push_log) == "Failed to push" ]]; then
        if ! [[ -f "$(pwd)/gh-release" ]]; then
            echo "gh-release file not found, pls check it!" && exit
        else
            chmod +x $(pwd)/gh-release
            sleep 10
            push_log || echo "Failed again, Build.log cannot push into github release!"
        fi
    fi
    if [[ $(push_tar) == "Failed to push files" ]]; then
        if ! [[ -f "$(pwd)/gh-release" ]]; then
            echo "gh-release file not found, pls check it!" && exit
        else
            chmod +x $(pwd)/gh-release
            sleep 10
            push_tar || echo "Failed again, $files cannot push into github releases."
        fi
    fi
fi
