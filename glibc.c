#include <gnu/libc-version.h>
#include <stdio.h>
#include <unistd.h>

int main() {
    char version[30] = {0};
    confstr(_CS_GNU_LIBC_VERSION, version, 30);
    puts(version);

    return 0;
}
