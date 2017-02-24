gpart destroy -F ada0
gpart create -s gpt ada0
gpart add -b 34 -s 94 -t freebsd-boot ada0
gpart add -t freebsd-zfs -l disk0 ada0
gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 ada0

zpool create zroot /dev/gpt/disk0
zpool set bootfs=zroot zroot
zfs set mountpoint=/mnt zroot

zpool export zroot
zpool import -o cachefile=/var/tmp/zpool.cache zroot

zfs create zroot/usr
zfs create zroot/usr/home
zfs create zroot/var

zfs set atime=off zroot

zfs create -V 4G zroot/swap
zfs set org.freebsd:swap=on zroot/swap
zfs set checksum=off zroot/swap

cd /mnt ; ln -s usr/home home

cd /usr/freebsd-dist
export DESTDIR=/mnt
for file in base.txz lib32.txz kernel.txz src.txz;
do (cat $file | tar --unlink -xpJf - -C ${DESTDIR:-/}); done

cp /var/tmp/zpool.cache /mnt/boot/zfs/zpool.cache

echo 'zfs_enable="YES"' >> /mnt/etc/rc.conf
echo 'zfs_load="YES"' >> /mnt/boot/loader.conf
echo 'vfs.root.mountfrom="zfs:zroot"' >> /mnt/boot/loader.conf
touch /mnt/etc/fstab

zfs umount -af
