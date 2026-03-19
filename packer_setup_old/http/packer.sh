mount -o remount,size=1G /run/archiso/cowspace;
mkdir -p /tmp/.ansible/tmp
chmod 1777 /tmp /tmp/.ansible /tmp/.ansible/tmp
if [ ! -e /usr/bin/python ] && [ ! -e /usr/bin/python3 ]; then
	pacman -Sy --noconfirm python
fi
if [ ! -e /usr/lib/ssh/sftp-server ]; then
	pacman -Sy --noconfirm openssh
fi
if [ ! -e /usr/lib/sftp-server ] && [ -e /usr/lib/ssh/sftp-server ]; then
	ln -s /usr/lib/ssh/sftp-server /usr/lib/sftp-server
fi
passwd <<PASSWD
root
root
PASSWD;