#!/bin/sh

# Запуск:
# sudo ./create_release_image.sh 1.7.6 2>&1 | tee log_release_1.7.6.txt
#
# scp 2023-10-10-raspios-bookworm-arm64-lite-eltehs-rtkbase-1.7.6.img.gz \
#     log_release_1.7.6.txt \
#     contabo3:/var/www/estimo-gnss.com/html/tmp/

set -e

VERSION="${1}"
if test -z "${VERSION}"
then
  VERSION=1.9.7d
fi

LOOPDEV=/dev/loop1
RESIZETOSIZE=3961MB
APPENDSIZEMB=1200

SOURCE_IMAGE=2025-05-13-raspios-bookworm-arm64-lite.img.xz
DESTINATION_IMAGE="2025-05-13-raspios-bookworm-arm64-lite-eltehs-rtkbase-${VERSION}.img.xz"

if test -z "${SOURCE_IMAGE}"
then
  echo "SOURCE_IMAGE is not set"
  exit 1
fi

if test -z "${DESTINATION_IMAGE}"
then
  echo "DESTINATION_IMAGE is not set"
  exit 1
fi

DESTINATION_IMAGE_WO_XZ="${DESTINATION_IMAGE%%.xz}"

echo "Creating release image: from ${SOURCE_IMAGE} to ${DESTINATION_IMAGE}"

./unpack.sh "${SOURCE_IMAGE}" "${DESTINATION_IMAGE_WO_XZ}"

dd if=/dev/zero bs=1M count=${APPENDSIZEMB} >> "${DESTINATION_IMAGE_WO_XZ}"

echo "raspberrypi" > hostname.txt

unshare -m -i ./mount_and_run_scripts.sh \
   `realpath -m ./raspbian64` \
   "${LOOPDEV}" \
   "${DESTINATION_IMAGE_WO_XZ}" \
   "${RESIZETOSIZE}" \
   COPY hostname.txt \
   COPY install.sh \
   COPY WinRtkBaseConfigure.exe \
   COPY WinRtkBaseUtils.exe \
   COPY find_rtkbase.exe \
   COPY ELT_RTKBase_v1.9.6_EN.pdf \
   RUN \
      target_scripts/set_hostname.sh \
      target_scripts/update_upgrade.sh \
      target_scripts/place_configure_util.sh \
      target_scripts/rtkbase_install.sh

echo Compressing resulting image...

xz -z "${DESTINATION_IMAGE_WO_XZ}"
echo "Resulting image: ${DESTINATION_IMAGE}"
