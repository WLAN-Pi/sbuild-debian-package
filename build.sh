#!/bin/bash

set -e

distro="${INPUTS_DISTRO:-bullseye}"
arch="${INPUTS_ARCH:-arm64}"
schroot_name="${distro}-${arch}-sbuild"
run_lintian="${INPUTS_RUN_LINTIAN:-true}"

if [ "${run_lintian}" == "true" ]; then
    run_lintian="--run-lintian"
else
    run_lintian="--no-run-lintian"
fi

export DEBIAN_FRONTEND=noninteractive

echo "Install dependencies"
sudo apt-get update -yqq
sudo apt-get install -yqq --no-install-recommends \
            devscripts \
            build-essential \
            sbuild \
            schroot \
            debootstrap

    echo 'BUILD.SH CI'
    sudo apt-get install -yqq --no-install-recommends qemu-user-static \
            binfmt-support

log_info() {
    echo "INFO: $1"
}

log_error() {
    echo "ERROR: $1" >&2
    local log_file="/srv/chroot/${schroot_name}/debootstrap/debootstrap.log"
    if [ -f "$log_file" ]; then
        echo "=== Debootstrap Log Contents ==="
        cat "$log_file"
        echo "=== End Debootstrap Log ==="
    fi
}

orig_errexit=$(set -o | grep errexit | cut -f2)

set +e
log_info "Checking for existing schroot: ${schroot_name}"
schroot_exists=$(sudo schroot -l | grep -o "chroot:${schroot_name}")
log_info "schroot check result: ${schroot_exists}"

schroot_target="/srv/chroot/${schroot_name}"
if [ "${schroot_exists}" != "chroot:${schroot_name}" ]; then
    log_info "Creating schroot at ${schroot_target}"
    sudo sbuild-createchroot --arch=${arch} ${distro} \
        "${schroot_target}" http://deb.debian.org/debian
    
    create_status=$?
    if [ $create_status -ne 0 ]; then
        log_error "sbuild-createchroot failed with status ${create_status}"
        exit $create_status
    fi
fi

if [ "$orig_errexit" = "on" ]; then
    set -e
else
    set +e
fi

# There is an issue on Ubuntu 20.04 and qemu 4.2 when entering fakeroot
# References:
# https://github.com/M-Reimer/repo-make/blob/master/repo-make-ci.sh#L252-L274
# https://github.com/osrf/multiarch-docker-image-generation/issues/36
# Start workaround
echo 'BUILD.SH CI: qemu-arm-static build --- implementing semtimedop workaround'
cat <<EOF > "/tmp/wrap_semop.c"
#include <unistd.h>
#include <asm/unistd.h>
#include <sys/syscall.h>
#include <linux/sem.h>
/* glibc 2.31 wraps semop() as a call to semtimedop() with the timespec set to NULL
 * qemu 3.1 doesn't support semtimedop(), so this wrapper syscalls the real semop()
 */
int semop(int semid, struct sembuf *sops, unsigned nsops)
{
  return syscall(__NR_semop, semid, sops, nsops);
}
EOF

cat <<EOF > "/tmp/pre-build.sh"
#!/bin/bash
gcc -fPIC -shared -Q -o /opt/libpreload-semop.so /tmp/wrap_semop.c
chmod 777 /opt/libpreload-semop.so
echo '/opt/libpreload-semop.so' >> /etc/ld.so.preload
EOF

sudo cp "/tmp/wrap_semop.c" "${schroot_target}/tmp/wrap_semop.c"
sudo cp "/tmp/pre-build.sh" "${schroot_target}/tmp/pre-build.sh"
# End workaround

# More workaround for qemu >5.2
sudo mkdir -p "${schroot_target}"/usr/libexec/qemu-binfmt

echo "Generate .dsc file"
res=$(dpkg-source -b ./)

echo "Get .dsc file name"
dsc_file=$(echo "$res" | grep .dsc | grep -o '[^ ]*$')

echo "Build inside schroot"
sudo sbuild --arch=${arch} -c ${schroot_name} ${run_lintian} \
    --chroot-setup-commands="chmod +x /tmp/pre-build.sh; /tmp/pre-build.sh" \
    -d ${distro} ../${dsc_file} --verbose

echo "Generated files:"
DEB_PACKAGE=$(find ./ -name "*.deb" | grep -v "dbgsym")
echo "Package: ${DEB_PACKAGE}"

# Set output
# https://github.blog/changelog/2022-10-11-github-actions-deprecating-save-state-and-set-output-commands/
# echo "::set-output name=deb-package::${DEB_PACKAGE}"
echo "deb-package=${DEB_PACKAGE}" >> $GITHUB_OUTPUT
