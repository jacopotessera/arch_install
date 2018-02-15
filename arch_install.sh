#!/bin/bash -e

. CONFIG

GET_ETH(){
	ip link | grep "^[0-9]: e" | cut -d":" -f2 | sed 's_[[:space:]]__g'
}

GET_WIFI(){
	ip link | grep "^[0-9]: w" | cut -d":" -f2 | sed 's_[[:space:]]__g'
}

GET_BATTERY(){
	if acpi 2>&1 | grep -q "^Battery"; then
		echo battery
	else
		echo power_supply
	fi
}

INSTALL_PACSERVE(){
	echo "[xyne-any]
SigLevel = Required
#Server = https://xyne.archlinux.ca/repos/xyne
Server = https://xyne.archlinux.ca/bin/repo.php?file=

[xyne-x86_64]
SigLevel = Required
#Server = https://xyne.archlinux.ca/repos/xyne
Server = https://xyne.archlinux.ca/bin/repo.php?file=" >> /etc/pacman.conf

	pacman -Sy --noconfirm pacserve

	sed -i '/^Include/i \
Include = /etc/pacman.d/pacserve' /etc/pacman.conf
	systemctl start pacserve
}

ETH_CONNECTION(){
	local eth=$(GET_ETH)
	echo "Description=Network Connection
Interface=${eth}
Connection=ethernet
IP=dhcp" > /etc/netctl/eth-connection
}

WIFI_CONNECTION(){
	local wifi=$(GET_WIFI)
	local DESCRIPTION=$(echo "${1}" | cut -d":" -f1)
	local ESSID=$(echo "${1}" | cut -d":" -f2)
	local PASSWORD=$(echo "${1}" | cut -d":" -f3)
	echo "Description='${DESCRIPTION}'
Interface=${wifi}
Connection=wireless
Security=wpa
ESSID=${ESSID}
IP=dhcp
Key=${PASSWORD}" > /etc/netctl/${wifi}-${ESSID}
}

WIFI_CONNECTIONS(){
	let local n=$(echo "${1}" | grep -o ";" | wc -l)+1
	for i in $(seq 1 ${n}); do
		local wifi_config=$(echo "${1}" | cut -d";" -f${i})
		WIFI_CONNECTION "${wifi_config}"
	done
}

INSTALL_DDCLIENT(){
	local HOSTNAME=$(echo "${1}" | cut -d":" -f1)
	local USERNAME=$(echo "${1}" | cut -d":" -f2)
	local PASSWORD=$(echo "${1}" | cut -d":" -f3)
	pacman -S --noconfirm ddclient
	echo "
daemon=300
pid=/var/run/ddclient.pid
ssl=yes
protocol=noip
use=web, web=checkip.dyndns.com/, web-skip='IP Address'
server=dynupdate.no-ip.com
login=${USERNAME}
password=${PASSWORD}
${HOSTNAME}" > /etc/ddclient/ddclient.conf
	systemctl enable ddclient
}

BIOS(){
	local disk=${1}
	local p=
	if [[ "${disk}" =~ nvme* ]]; then
		local p=p
	fi
	parted /dev/${disk} mklabel msdos
	parted /dev/${disk} mktable msdos
	parted /dev/${disk} mkpart primary ext4 1M 100%
	parted /dev/${disk} set 1 boot on
	mkfs.ext4 /dev/${disk}${p}1

	mount /dev/${disk}${p}1 /mnt
}

UEFI(){
	local disk=${1}
	local p=
	if [[ "${disk}" =~ nvme* ]]; then
		local p=p
	fi
	parted /dev/${disk} mklabel gpt
	parted /dev/${disk} mktable gpt
	parted /dev/${disk} mkpart primary fat32 1M 512M
	parted /dev/${disk} mkpart primary ext4 512M 100%
	parted /dev/${disk} set 1 boot on
	mkfs.fat -s1 -F32 /dev/${disk}${p}1
	mkfs.ext4 /dev/${disk}${p}2

	mount /dev/${disk}${p}2 /mnt
	mkdir /mnt/boot
	mount /dev/${disk}${p}1 /mnt/boot
}

INSTALL_GRUB(){
	local disk=${1}
	local bios=${2}
	if [ "${bios}" == "BIOS" ]; then
		pacman -S --noconfirm grub
		grub-install /dev/${disk}
	elif [ "${bios}" == "UEFI" ]; then
		pacman -S --noconfirm grub efibootmgr
		grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=grub
	fi
	sed -i 's/GRUB_TIMEOUT=5/GRUB_TIMEOUT=0/' /etc/default/grub
	grub-mkconfig -o /boot/grub/grub.cfg
}

CREATE_USER(){
	local user=${1}
	local autologin=${2}
	useradd -m -p $(perl -e 'print crypt($ARGV[0], "password")' ${user}) ${user}
	echo "${user} ALL=(ALL:ALL) ALL" | (sudo EDITOR="tee -a" visudo)
	if [ "${autologin}" == "autologin" ]; then
		cp /usr/lib/systemd/system/getty@.service /usr/lib/systemd/system/getty@.service.back
		local auto=$(echo 's_ExecStart=-/sbin/agetty -o \x27-p -- \\\\u\x27 --noclear %I $TERM_ExecStart=-/sbin/agetty -a USERNAME --noclear %I $TERM_' | sed "s/USERNAME/${user}/")
		sed -i "${auto}" /usr/lib/systemd/system/getty@.service
		sed -i 's_Type=idle_Type=simple_' /usr/lib/systemd/system/getty@.service
		systemctl enable getty@tty1.service
	fi
}

AUR_INSTALL(){
	local package=${1}
	local user=${2}
	wget https://aur.archlinux.org/cgit/aur.git/snapshot/${package}.tar.gz -o /dev/null
	tar -xf ${package}.tar.gz
	cd ${package}
	makepkg -fs --noconfirm
	echo ${user} | sudo -S pacman --noconfirm -U ${package}*.pkg.tar.xz
	cd ..
	rm -f ${package}.tar.gz
	rm -rf ${package}
}

INSTALL_YAOURT(){
	AUR_INSTALL package-query ${1}
	AUR_INSTALL yaourt ${1}
}

CREATE_HOME_SCRIPTS(){

	local user=${1}

	echo '#echo ${user} | sudo -S modprobe nct6775 force_id=0xd120
[[ -f ~/.bashrc ]] && . ~/.bashrc
if [[ -z $DISPLAY ]] && [[ $(tty) = /dev/tty1 ]]; then
    exec startx
fi' > .bash_profile

	mkdir -p .vnc
	echo ${user} | vncpasswd -f > .vnc/passwd
	echo "geometry=1920x1080
dpi=96
localhost" > .vnc/config

	echo "#!/bin/bash
unset SESSION_MANAGER
exec /home/${user}/.xinitrc" > .vnc/xstartup
chmod +x .vnc/xstartup

GIT_CONFIG(){
	echo "[user]
	name = ${GIT_USERNAME}
	email = ${GIT_EMAIL}" > .gitconfig
}

	if [ $(GET_BATTERY) == "battery" ]; then

		echo "xbindkeys &
lux -S 20% &
setxkbmap it &
xrandr --dpi 96 &
while true
do
    sh .xsetroot.sh
    sleep 1s
done &
exec dwm" > .xinitrc

		echo 'DATETIME=`date +"%Y-%m-%d %H:%M:%S"`
BATTERY=$(acpi -b | cut -d"," -f2)
xsetroot -name "> ${HOSTNAME} ${DATETIME} Battery:${BATTERY} <"' > .xsetroot.sh

		echo '"lux -s 10%"
	m:0x0 + c:232
	XF86MonBrightnessDown

"lux -a 10%"
	m:0x0 + c:233
	XF86MonBrightnessUp' > .xbindkeysrc

	else

		echo "xset led 3 &
setxkbmap it &
xrandr --dpi 96 &
while true
do
    sh .xsetroot.sh
    sleep 1s
done &
exec dwm" > .xinitrc
chmod +x .xinitrc

		echo 'DATETIME=`date +"%Y-%m-%d %H:%M:%S"`
xsetroot -name "> ${HOSTNAME} ${DATETIME} <"' > .xsetroot.sh
		echo 'DATETIME=`date +"%Y-%m-%d %H:%M:%S"`
T_CPU=$(sensors | grep CPUTIN | cut -d" " -f18)
nv=$(nvidia-smi -x -q)
T_GPU=$(echo  $nv | xmllint --xpath ''//gpu_temp'' - | sed ''s/<gpu_temp>//g'' | sed ''s/<\/gpu_temp>/ /g'')
xsetroot -name "CPU: ${T_CPU} GPU: ${T_GPU} > ${HOSTNAME} ${DATETIME} <"' > .xsetroot.sh

	fi
}

SET_GEDIT_PREFERENCES(){
	local gedit_preferences="org.gnome.gedit.preferences.editor wrap-mode 'none'
org.gnome.gedit.preferences.editor display-right-margin true
org.gnome.gedit.preferences.editor highlight-current-line true
org.gnome.gedit.preferences.editor scheme 'cobalt'
org.gnome.gedit.preferences.editor display-line-numbers true
org.gnome.gedit.preferences.editor bracket-matching true
org.gnome.gedit.preferences.editor right-margin-position 80
org.gnome.gedit.preferences.editor tabs-size 4
org.gnome.gedit.preferences.editor background-pattern 'grid'"

	while read -r line; do
		gsettings set ${line}
	done <<< "${gedit_preferences}"
}

HG_RC(){
	local user=${1}

	echo "[ui]
username = ${user}

[extension]
hgk =
progress =

[web]
cacerts = /etc/ssl/certs/ca-certificates.crt" > .hgrc
}

NOCHROOT(){
	WIFI_CONNECTIONS "${WIFI_CONFIG}"
	ETH_CONNECTION

	if [ "${CONNECTION}" == "wifi" ]; then
		netctl start $(GET_WIFI)-${ESSID}
	elif [ "{$CONNECTION}" == "eth" ]; then
		netctl start eth-connection
	fi

	if [ "${NFS}" == "nfs" ]; then
		mount ${NFS_PATH} /var/cache/pacman/pkg
	elif [ "${NFS}" == "pacserve" ]; then
		INSTALL_PACSERVE
	fi

	if [ "${BIOS}" == "BIOS" ]; then
		BIOS ${DISK}
	elif [ "${BIOS}" == "UEFI" ]; then
		UEFI ${DISK}
	fi

	pacman-key --init
	pacman-key --populate archlinux
	pacman-key --refresh-keys

	pacstrap /mnt base base-devel
	genfstab -p /mnt >> /mnt/etc/fstab
	
	cp -r /etc/netctl/* /mnt/etc/netctl/
	cp ${0} /mnt/${0}
	cp CONFIG /mnt/CONFIG
	arch-chroot /mnt /${0} chroot
}

CHROOT(){
	echo ${HOSTNAME} > /etc/hostname

	ln -sf /usr/share/zoneinfo/Europe/Rome /etc/localtime
	sed -i 's/#en_US/en_US/' /etc/locale.gen
	locale-gen
	echo "LANG=en_US.UTF-8" > /etc/locale.conf
	echo "KEYMAP=it" > /etc/vconsole.conf

	if [ "${NFS}" == "nfs" ]; then
		mount ${NFS_PATH} /var/cache/pacman/pkg
	elif [ "${NFS}" == "pacserve" ]; then
		INSTALL_PACSERVE
		systemctl enable pacserve
	fi

	pacman -S --noconfirm sudo wget
	echo "Defaults visiblepw" | (EDITOR="tee -a" visudo)
	CREATE_USER ${USERNAME} ${AUTOLOGIN}
	
	INSTALL_GRUB ${DISK} ${BIOS}
	
	pacman -S --noconfirm linux-headers wget acpi
	pacman -S --noconfirm dhcpcd dhclient wpa_supplicant wpa_actiond iproute

	pacman -S --noconfirm openssh sshpass x11vnc tigervnc
	systemctl enable sshd
	
	echo "#!/bin/bash
ssh -f -X -o ExitOnForwardFailure=yes -p 22 ${SSH_HOST} -L 10001:localhost:5901 sleep 10
vncviewer -passwd ~/.vnc/passwd -FullScreen localhost:10001" > /bin/vnc-1
	chmod +x /bin/vnc-1

	echo "#!/bin/bash
ssh -f -X -o ExitOnForwardFailure=yes -p 10022 ${SSH_HOST} -L 10002:localhost:5901 sleep 10
vncviewer -passwd ~/.vnc/passwd -FullScreen localhost:10002" > /bin/vnc-2
	chmod +x /bin/vnc-2

	if [ $(GET_BATTERY) == "power_supply" ] && [[ ! -z ${DDCLIENT_CONFIG} ]]; then
		INSTALL_DDCLIENT "${DDCLIENT_CONFIG}"
	fi

	pacman -S --noconfirm ntp
	ntpd -gq
	hwclock --systohc

	pacman -S --noconfirm xorg xorg-xinit xorg-xsetroot gnu-free-fonts dmenu terminator firefox xbindkeys wireless_tools
	pacman -S --noconfirm alsa-firmware alsa-utils
	pacman -S --noconfirm gedit thunar file-roller gvfs thunar-volman thunar-archive-plugin ntfs-3g
	pacman -S --noconfirm yajl libxft libx11 libxinerama libxft freetype2
	
	if [ "${CONNECTION}" == "wifi" ]; then
		netctl enable $(GET_WIFI)-${ESSID}
	elif [ "${CONNECTION}" == "eth" ]; then
		netctl enable eth-connection
	fi

	if [ "${VGA}" == "nvidia" ]; then
		pacman -S --noconfirm nvidia
	elif [ "${VGA}" == "amd" ]; then
		pacman -S --noconfirm xf86-video-amdgpu
	fi

	if [ "${DEVEL}" == "yes" ]; then
		pacman -S --noconfirm cuda cppunit eigen libmongoc mongodb mercurial git cmake boost boost-libs
		systemctl enable mongodb
		pacman -S --noconfirm python-pip tk
		pip install numpy matplotlib pymongo pandas
	fi

	su ${USERNAME} -c "/${0} user"
	mkinitcpio -p linux
	passwd
	exit
}

USER(){
	local user=$(whoami)
	pushd /home/${user}/
	
	CREATE_HOME_SCRIPTS ${user}
	gedit --version
	SET_GEDIT_PREFERENCES
	systemctl --user enable vncserver@:1

#	INSTALL_YAOURT $user
#	AUR_INSTALL nct677x-git ${user}
	AUR_INSTALL st ${user}
	AUR_INSTALL dwm ${user}
	echo ${user} | sudo -S mv /usr/bin/st /usr/bin/st.back
	echo ${user} | sudo -S ln -s /bin/terminator /bin/st

	if [ "${DEVEL}" == "yes" ]; then
		HG_RC ${user}
		mkdir hg
		pushd hg
		hg clone https://bitbucket.org/eigen/eigen/
		pushd eigen
		mkdir build_dir
		pushd build_dir
		cmake ../
		echo ${user} | sudo -S make install
		popd
		popd
		popd
		rm -rf hg
		AUR_INSTALL mongo-cxx-driver ${user}
		echo ${user} | sudo -S ln -s /usr/local/lib/libmongocxx.so._noabi /lib/libmongocxx.so._noabi
		echo ${user} | sudo -S ln -s /usr/local/lib/libbsoncxx.so._noabi /lib/libbsoncxx.so._noabi
	fi

	if [ $(GET_BATTERY) == "battery" ]; then
		AUR_INSTALL lux ${user}
		echo ${user} | sudo -S lux
	fi

	if [ "${SSH}" = "yes" ]; then
		mkdir -p /home/${user}/.ssh/
		ssh-keygen -t rsa -b 4096 -q -N "" -f /home/${user}/.ssh/id_rsa
		set +e
		sshpass -p ${user} ssh-copy-id -oStrictHostKeyChecking=no -p 22 ${SSH_HOST}
		sshpass -p ${user} ssh-copy-id -oStrictHostKeyChecking=no -p 10022 ${SSH_HOST}
		set -e
		#update /etc/ssh/ssh_config -> X forwarding + NoRoot + NoPassword
	fi

	popd
}

if [ ${#} -ge 1 ]; then
	if [ ${1} = "chroot" ]; then
		CHROOT
	elif [ ${1} = "user" ]; then
		USER
	elif [ ${1} = "gedit" ]; then
		SET_GEDIT_PREFERENCES
	elif [ ${1} = "pacserve" ]; then
		INSTALL_PACSERVE
	elif [ ${1} = "yaourt" ]; then
		INSTALL_YAOURT
	else
		NOCHROOT
	fi
else
	NOCHROOT
fi

