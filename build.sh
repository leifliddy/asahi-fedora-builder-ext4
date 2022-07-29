#!/bin/bash


mkosi_rootfs='mkosi.rootfs'
image_dir='images'
image_mnt='mnt_image'
image_name='asahi-base'
current_directory=$(dirname $(readlink -f $0))

# this has to match the volume_id in installer_data.json
# "volume_id": "0x2abf9f91"
EFI_UUID=2ABF-9F91
ROOT_UUID=$(uuidgen)

if [ "$(whoami)" != 'root' ]; then
    echo "You must be root to run this script."
    exit 1
fi

mkdir -p $image_mnt $mkosi_rootfs $image_dir/$image_name


mkosi_create_rootfs() {
    mkosi clean
    rm -rf .mkosi-*
    wget https://leifliddy.com/asahi-linux/asahi-linux.repo -O mkosi.skeleton/etc/yum.repos.d/asahi-linux.repo
    mkosi
}


make_image() {
    # if  $image_mnt is mounted, then unmount it
    [[ -n "$(findmnt -n $image_mnt/boot)" ]] && umount $image_mnt/boot
    [[ -n "$(findmnt -n $image_mnt)" ]] && umount $image_mnt
    echo "## Making image $image_name"
    echo '### Cleaning up...'
    rm -f $mkosi_rootfs/var/cache/dnf/*
    echo '### Calculating image size...'
    size=$(du -B M -s $mkosi_rootfs | cut -dM -f1)
    echo "### Image size: $size MiB"
    size=$(($size + ($size / 8) + 64))
    echo "### Padded size: $size MiB"
    rm -rf $image_dir/$image_name/*
    truncate -s ${size}M $image_dir/$image_name/root.img
    echo '### Creating ext4 filesystem...'
    echo "mkfs.ext4 -O '^metadata_csum' -U $ROOT_UUID -L 'asahi-root' $image_dir/$image_name/root.img"
    mkfs.ext4 -O '^metadata_csum' -U $ROOT_UUID -L 'asahi-root' $image_dir/$image_name/root.img
    echo '### Loop mounting...'
    mount -o loop $image_dir/$image_name/root.img $image_mnt
    echo '### Copying files...'
    rsync -aHAX --exclude '/tmp/*' $mkosi_rootfs/ $image_mnt/
    echo '### Setting pre-defined uuid for efi vfat partition in /etc/fstab...'
    sed -i "s/EFI_UUID_PLACEHOLDER/$EFI_UUID/" $image_mnt/etc/fstab
    echo '### Setting random uuid for root ext4 partition in /etc/fstab...'
    sed -i "s/ROOT_UUID_PLACEHOLDER/$ROOT_UUID/" $image_mnt/etc/fstab
    echo '### Running systemd-machine-id-setup...'
    # needed to generate a (temp) machine-id so a BLS entry can be created below
    chroot $image_mnt systemd-machine-id-setup
    chroot $image_mnt echo "KERNEL_INSTALL_MACHINE_ID=$(cat /etc/machine-id)" > /etc/machine-info
    # run update-m1n1 to ensure the /boot/dtb/apple/*.dtb files are used
    echo '### Running update-m1n1...'
    arch-chroot $image_mnt /usr/sbin/update-m1n1
    echo '### Updating GRUB...'
    arch-chroot $image_mnt /usr/sbin/update-grub
    echo "### Creating BLS (/boot/loader/entries/) entry..."
    chroot $image_mnt /image.creation/create.bls.entry
    echo "### Enabling system services..."
    chroot $image_mnt systemctl enable iwd.service sshd.service systemd-networkd.service
    echo "### Disabling systemd-firstboot..."
    chroot $image_mnt rm -f /usr/lib/systemd/system/sysinit.target.wants/systemd-firstboot.service
    echo '### Creating EFI system partition tree...'
    mkdir -p $image_dir/$image_name/esp/
    rsync -aHAX $image_mnt/boot/efi/ $image_dir/$image_name/esp/
    rm -rf $image_mnt/boot/efi/*
    rm -f  $image_mnt/etc/machine-id
    rm -rf $image_mnt/image.creation
    echo '### Unmounting...'
    umount $image_mnt
    echo '### Compressing...'
    rm -f $image_dir/$image_name.zip
    cd $image_dir/$image_name/ && zip -r ../$image_name.zip *
    cd $current_directory
    echo '### Done'
}

mkosi_create_rootfs
make_image
