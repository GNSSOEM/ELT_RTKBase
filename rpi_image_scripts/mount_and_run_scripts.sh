#!/bin/sh

set -e

DIR="${1}"
LOOPDEV="${2}"
IMAGEFILE="${3}"
RESIZETOSIZE="${4}"

shift 4
# Remaining arguments are files and shell scripts to run inside chroot

#DIR=/mnt/space/TMP/RPI/raspbian64
#LOOPDEV=/dev/loop4
#IMAGEFILE=2023-10-10-raspios-bookworm-arm64-lite-estimo-lv5-006.img
#RESIZETOSIZE=0 - do not resize
#RESIZETOSIZE=3561MB

export DIR
export LOOPDEV
export IMAGEFILE

echo "Setting up loop device..."
losetup -P "${LOOPDEV}" "${IMAGEFILE}"

if test "${RESIZETOSIZE}" != "0"
then
  echo "Resizing root fs..."
  parted "${LOOPDEV}" resizepart 2 "${RESIZETOSIZE}"
  resize2fs "${LOOPDEV}p2"
fi

mkdir -p "${DIR}"

mkdir -p ./tmp
chmod 1777 ./tmp

echo "Mounting FS into dir..."
mount "${LOOPDEV}p2" "${DIR}"
mount "${LOOPDEV}p1" "${DIR}/boot/firmware"
mount -t proc /proc "${DIR}/proc/"
mount --rbind --make-rslave /sys "${DIR}/sys/"
mount --rbind --make-rslave /dev "${DIR}/dev/"
mount --rbind --make-rslave ./tmp "${DIR}/tmp/"

MODE=run
for i in "$@"
do
  if test "$i" = "RUN"
  then
    MODE=RUN
  elif test "$i" = "COPY"
  then
    MODE=COPY
  else
    if test "$MODE" = "RUN"
    then
      echo "Running script \"${i}\"..."
      cp -a "${i}" "${DIR}/tmp/"
      TARGETNAME="`basename ${i}`"
      LANG=C unshare --uts chroot "${DIR}" "/tmp/${TARGETNAME}"
    else
      echo "Copying \"${i}\" to FS/tmp/"
      cp -aR "${i}" "${DIR}/tmp/"
    fi
  fi
done

# Clear the machine ID to make it regenerated after start and not duplicate
LANG=C unshare --uts chroot "${DIR}" rm -f /etc/machine-id
LANG=C unshare --uts chroot "${DIR}" touch /etc/machine-id
LANG=C unshare --uts chroot "${DIR}" chown root:root /etc/machine-id
LANG=C unshare --uts chroot "${DIR}" chmod 444 /etc/machine-id

# Fill the free space with zeroes, just to make compressed image smaller
dd if=/dev/zero bs=1M of="${DIR}/zeroes.bin" >/dev/null 2>&1 || true
rm -f "${DIR}/zeroes.bin"

echo "Unmounting dir and releasing loop device"
umount -R "${DIR}"
losetup -d "${LOOPDEV}"
