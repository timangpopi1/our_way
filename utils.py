#!/usr/bin/env python3
# Description: Common helper functions

import hashlib
import shutil
import sys
import subprocess


def create_gitignore(folder):
    """
    Create a gitignore that ignores all files in a folder. Some folders are not
    known until the script is run so they can't be added to the root .gitignore
    :param folder: Folder to create the gitignore in
    """
    with folder.joinpath(".gitignore").open("w") as gitignore:
        gitignore.write("*")


def current_binutils():
    """
    Simple getter for current stable binutils release
    :return: The current stable release of binutils
    """
    return "binutils-2.34"


def download_binutils(folder):
    """
    Downloads the latest stable version of binutils
    :param folder: Directory to download binutils to
    """
    binutils = current_binutils()
    binutils_folder = folder.joinpath(binutils)
    if not binutils_folder.is_dir():
        # Remove any previous copies of binutils
        for entity in folder.glob('binutils-*'):
            if entity.is_dir():
                shutil.rmtree(entity)
            else:
                entity.unlink()

        # Download the tarball
        binutils_tarball = folder.joinpath(binutils + ".tar.xz")
        curl_cmd = [
            "curl", "-LSs", "-o", binutils_tarball,
            "https://ftp.gnu.org/gnu/binutils/" + binutils_tarball.name
        ]
        subprocess.run(curl_cmd, check=True)

        # Extract the tarball then remove it
        subprocess.run(["tar", "-xJf", binutils_tarball.name],
                       check=True,
                       cwd=folder)
        create_gitignore(binutils_folder)
        binutils_tarball.unlink()


def verify_binutils_checksum(file_to_check):
    # Check the SHA512 checksum of the downloaded file with a known good one
    # The sha512.sum file from <sourceware.org> ships the SHA512 checksums
    # Link: https://sourceware.org/pub/binutils/releases/sha512.sum
    file_hash = hashlib.sha512()
    with file_to_check.open("rb") as file:
        while True:
            data = file.read(131072)
            if not data:
                break
            file_hash.update(data)
    good_hash = "f00b0e8803dc9bab1e2165bd568528135be734df3fabf8d0161828cd56028952"
    if file_hash.hexdigest() != good_hash:
        raise RuntimeError(
            "binutils: SHA512 checksum does not match known good one!")


def flush_std_err_out():
    sys.stderr.flush()
    sys.stdout.flush()


def print_header(string):
    """
    Prints a fancy header
    :param string: String to print inside the header
    """
    # Use bold cyan for the header so that the headers
    # are not intepreted as success (green) or failed (red)
    print("\033[01;36m")
    for _ in range(0, len(string) + 6):
        print("=", end="")
    print(f"\n== {string} ==")
    for _ in range(0, len(string) + 6):
        print("=", end="")
    # \033[0m resets the color back to the user's default
    print("\n\033[0m")
    flush_std_err_out()


def print_error(string):
    """
    Prints a error in bold red
    :param string: String to print
    """
    # Use bold red for error
    print(f"\033[01;31m{string}\n\033[0m", flush=True)


def print_warning(string):
    """
    Prints a error in bold yellow
    :param string: String to print
    """
    # Use bold yellow for error
    print(f"\033[01;33m{string}\n\033[0m", flush=True)
