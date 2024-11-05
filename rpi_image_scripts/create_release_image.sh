#!/bin/sh

set -e

SOURCE_IMAGE="${1}"
DESTINATION_IMAGE="${2}"

if test -z "${SOURCE_IMAGE}"
then
  echo SOURCE_IMAGE is not set
  exit 1
fi

if test -z "${DESTINATION_IMAGE}"
then
  echo DESTINATION_IMAGE is not set
  exit 1
fi

DESTINATION_IMAGE_WO_XZ="${DESTINATION_IMAGE%%.xz}"

cd RPI_IMAGE_MAKER/

echo "Creating release image: from ${SOURCE_IMAGE} to ${DESTINATION_IMAGE}"

LOOPDEV=/dev/loop1
RESIZETOSIZE=3961MB
APPENDSIZEMB=1200

./unpack.sh "${SOURCE_IMAGE}" "${DESTINATION_IMAGE_WO_XZ}"

dd if=/dev/zero bs=1M count=${APPENDSIZEMB} >> "${DESTINATION_IMAGE_WO_XZ}"

unshare -m -i ./mount_and_run_scripts.sh \
   `realpath -m ./raspbian64` \
   "${LOOPDEV}" \
   "${DESTINATION_IMAGE_WO_XZ}" \
   "${RESIZETOSIZE}" \
   COPY install.sh \
   COPY WinRtkBaseConfigure.exe \
   COPY WinRtkBaseUtils.exe \
   RUN \
      target_scripts/update_upgrade.sh \
      target_scripts/place_configure_util.sh \
      target_scripts/rtkbase_install.sh

echo Compressing resulting image...

xz -z "${DESTINATION_IMAGE_WO_XZ}"
echo "Resulting image: ${DESTINATION_IMAGE}"
