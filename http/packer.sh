mount -o remount,size=1G /run/archiso/cowspace;
pacman -Sy --noconfirm ansible;
passwd <<PASSWD
root
root
PASSWD;