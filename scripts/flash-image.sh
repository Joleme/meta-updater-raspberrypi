#!/bin/bash

ask() {
    # http://djm.me/ask
    local prompt default REPLY

    while true; do

        if [ "${2:-}" = "Y" ]; then
            prompt="Y/n"
            default=Y
        elif [ "${2:-}" = "N" ]; then
            prompt="y/N"
            default=N
        else
            prompt="y/n"
            default=
        fi

        # Ask the question (not using "read -p" as it uses stderr not stdout)
        echo -n "$1 [$prompt] "

        # Read the answer (use /dev/tty in case stdin is redirected from somewhere else)
        read -r REPLY </dev/tty

        # Default?
        if [ -z "$REPLY" ]; then
            REPLY=$default
        fi

        # Check if the reply is valid
        case "$REPLY" in
            Y*|y*) return 0 ;;
            N*|n*) return 1 ;;
        esac

    done
}

if [[ $EUID -ne 0 ]]; then
  echo ""
  echo "  This script must be run as root" 1>&2
  echo ""
  exit 1
fi

if [ -z "$1" ]; then
  echo ""
  echo "   Flash a built image with a HERE OTA Connect device config file baked in."
  echo ""
  echo "   Usage: ./flash-configured-image.sh device [imagefile [force]]"
  echo ""
  echo ""
  echo "    device     : The device name to flash. Must be a removable device."
  echo "      Example: sdb"
  echo ""
  echo "    imagefile  : An image file generated by bitbake (optional)."
  echo "      Default: ./tmp/deploy/images/raspberrypi3/core-image-minimal-raspberrypi3.wic"
  echo ""
  echo "    force      : 1 to skip the check if device is removeable."
  echo "      Default: 0"
  echo ""
  echo "   The following utilities are prerequisites:"
  echo ""
  echo "    dd"
  echo "    parted"
  echo "    e2fsck"
  echo "    fdisk"
  echo "    resize2fs"
  echo ""
  exit 1
fi

set -euo pipefail

DEVICE_TO_FLASH=$1
IMAGE_TO_FLASH="${2-./tmp/deploy/images/raspberrypi3/core-image-minimal-raspberrypi3.wic}"
FORCE_WRITE=${3-0}
DEVICE_IS_REMOVABLE=$(cat "/sys/block/$DEVICE_TO_FLASH/removable")

if [[ $FORCE_WRITE != "1" && $DEVICE_IS_REMOVABLE != "1" ]]; then
  echo ""
  echo "  For safety, this script will only flash removable block devices."
  echo ""
  echo "  This check is implemented by reading /sys/block/$DEVICE_TO_FLASH/removable."
  echo ""
  exit 1
fi

echo " "
echo "   Writing image file: $IMAGE_TO_FLASH "
echo "   to device         : $DEVICE_TO_FLASH "
echo " "
if ask "Do you want to continue?" N; then
    echo " "
else
    exit 1
fi

if [ ! -f "$IMAGE_TO_FLASH" ]; then
  echo " "
  echo "  Error: $IMAGE_TO_FLASH doesn't exist"
  echo ""
  exit 1
fi

echo "Unmounting all partitions on $DEVICE_TO_FLASH"
umount "/dev/$DEVICE_TO_FLASH"* || true
sleep 2

echo "Writing image to $DEVICE_TO_FLASH..."
dd if="$IMAGE_TO_FLASH" of="/dev/$DEVICE_TO_FLASH" bs=32M && sync
sleep 2

# It turns out there are card readers that give their partitions funny names, like
# "/dev/mmcblk0" will be the device, but the partitions are called "/dev/mmcblk0p1"
# for example. Better to just get the name of the partition after we flash it.
SECOND_PARTITION=$(fdisk -l "/dev/$DEVICE_TO_FLASH" | tail -n 1 | awk '{print $1}')

# Check if there is a problem with the boot partition, and fix it if there is.
# parted can identify the problem but apparently can't fix it without user
# interaction.
MISMATCH=$(fdisk -l /dev/mmcblk0 2>&1 >/dev/null | grep "GPT PMBR size mismatch")
if [ -n "$MISMATCH" ]; then
  echo "Fixing GPT PMBR size mismatch."
  sgdisk -e "/dev/$DEVICE_TO_FLASH"
fi

echo "Resizing rootfs partition to fill all of $DEVICE_TO_FLASH..."
parted -s "/dev/$DEVICE_TO_FLASH" resizepart 2 '100%'
sleep 2
e2fsck -f "$SECOND_PARTITION" || true
sleep 2

echo "Resizing filesystem on $SECOND_PARTITION to match partition size..."
resize2fs -p "$SECOND_PARTITION"
sleep 2

echo "Done!"

