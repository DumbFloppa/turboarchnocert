#!/usr/bin/env bash


cat << EOF
  ______           __          ___              __  
 /_  __/_  _______/ /_  ____  /   |  __________/ /_ 
  / / / / / / ___/ __ \/ __ \/ /| | / ___/ ___/ __ \\
 / / / /_/ / /  / /_/ / /_/ / ___ |/ /  / /__/ / / /
/_/  \__,_/_/  /_.___/\____/_/  |_/_/   \___/_/ /_/ 

TurboArch Release Candidate 4 ( https://evgvs.com/ )

Copyright (C) 2024 Evgeny Vasilievich LINUX PIMP

EOF

if [ "$EUID" -ne 0 ]; then 
  echo "Run as root!"
  exit 1
fi


if [ ! -f config.default ]; then

  UID_MIN=$(grep '^UID_MIN' /etc/login.defs | sed 's/[^0-9]//g')
  UID_MAX=$(grep '^UID_MAX' /etc/login.defs | sed 's/[^0-9]//g')

  read -p "Do you want to copy user configuration from current system? [Y/n] " -r yn
  if [[ $yn == [Nn]* ]]; then 
    echo "Root password will be ' ', i. e. space"
    SET_SPACE_PASSWORD=1
  else
    touch wheel_users
    echo "Found user: root"
    getent passwd root  > passwd_delta
    getent shadow root  > shadow_delta
    getent group root   > group_delta
    getent gshadow root > gshadow_delta

    normaluid=1000

    for d in $(getent passwd | awk -F: "(\$3 >= $UID_MIN && \$3 <= $UID_MAX) {printf \"%s\n\",\$1}") ; do

      IFS=':' read -r -a arr <<< "$(getent group "$d")"
      echo "${arr[0]}:${arr[1]}:$normaluid:${arr[3]}" >> group_delta

      IFS=':' read -r -a arr <<< "$(getent passwd "$d")"
      echo "${arr[0]}:${arr[1]}:$normaluid:$normaluid:${arr[4]}:${arr[5]}:${arr[6]}" >> passwd_delta

      if id -G -n "$d" | grep -qw 'sudo\|wheel'; then
        printf "Found user (sudo/wheel): %s", "$d"
        echo "$d" >> wheel_users
      else
        printf "Found user: %s", "$d"
      fi

      if [[ "${arr[2]}" != "$normaluid" ]]; then
        printf " (uid %s -> %s)" "${arr[2]}" "$normaluid"
      else
        printf " (uid %s)" "${arr[2]}"
      fi

      printf "\n"

      ((normaluid+=1))

      # getent shadow есть только в glibc
      getent gshadow &> /dev/null
      if [[ "$?" == "1" ]]; then
        grep "^$d:" /etc/gshadow >> gshadow_delta
        grep "^$d:" /etc/shadow >> shadow_delta
      else
        getent gshadow "$d" >> gshadow_delta
        getent shadow "$d"  >> shadow_delta
      fi

    done
    SET_SPACE_PASSWORD=0
  fi

  NETWORKMANAGER=1
  read -p "Do you want to install GNOME? [Y/n] " -r yn
  if [[ $yn == [Nn]* ]]; then 
    GNOME=0
    read -p "Do you want to use NetworkManager? [Y/n] " -r yn
    if [[ $yn == [Nn]* ]]; then 
      NETWORKMANAGER=0
    fi
  else
    GNOME=1
    NETWORKMANAGER=1
  fi

  read -p "Set hostname for new system: [archlinux] " -r NEWHOSTNAME
  if [ -z "$NEWHOSTNAME" ]; then
    NEWHOSTNAME=archlinux
  fi

  LOCALTIME=$(cat /etc/timezone 2> /dev/null)
  if [ -z "$LOCALTIME" ]; then
    # закостылено потому что в некоторых особенно парашных дистрах в timedatectl за каким-то хуем нет операции show
    LOCALTIME="$(timedatectl | grep 'Time zone' | sed 's/.*Time zone: //;s/ .*//')"
    LOCALTIME="${LOCALTIME#*=}"
  fi
  if [ -z "$LOCALTIME" ]; then
    LOCALTIME="$(readlink -f /etc/localtime 2> /dev/null | sed 's/.*\/zoneinfo\///' )"
  fi
  if [ "$LOCALTIME" == "/etc/localtime" ]; then
    LOCALTIME="Europe/Moscow"
  fi
  if [ -z "$LOCALTIME" ]; then
    LOCALTIME="Europe/Moscow"
  fi
  read -p "Set timezone for new system in \"region/city\" format: [$LOCALTIME] " -r INPUTLOCALTIME
  if [ -n "$INPUTLOCALTIME" ]; then
    LOCALTIME=$INPUTLOCALTIME
  fi

  SRAKUT=0
  if [[ $(dmsetup ls) != "No devices found" ]] && command -v dmsetup &> /dev/null; then 
    echo -e "\e[1m\e[40m\e[93mWARNING: CRAZY DISK CONFIGURATION FOUND (LUKS/LVM)\e[0m"
    echo -e "\e[1m\e[40m\e[93mNOTE THAT INITRAMFS WILL BE GENERATED BY DRACUT\e[0m"
    SRAKUT=1
  else
    read -p "Do you want to use dracut instead of mkinitcpio to generate initramfs? Answer 'y' only if you have some unusual disk configuration with LUKS or LVM. [y/N] " -r yn
    if [[ $yn == [Yy]* ]]; then 
      SRAKUT=1
    fi
  fi

  REFLECTOR=1
  read -p "Do you want to use reflector to select fastest mirrors? Otherwise, mirrors from 'mirrorlist.default' will be used. [Y/n] " -r yn
  if [[ $yn == [Nn]* ]]; then 
    REFLECTOR=0
  fi

  echo "GNOME=$GNOME" > config
  {
    echo "SET_SPACE_PASSWORD=$SET_SPACE_PASSWORD" 
    echo "SRAKUT=$SRAKUT"
    echo "NETWORKMANAGER=$NETWORKMANAGER"
    echo "LOCALTIME=$LOCALTIME"
    echo "NEWHOSTNAME=$NEWHOSTNAME"
    echo "REFLECTOR=$REFLECTOR"
    echo "FORCE_REBOOT_AFTER_INSTALLATION=0"
  } >> config
else
  echo "Using values from config.default"
  cp config.default config
fi


set -e

if [ -d '/archlinux-bootstrap' ]; then
  echo 'Found /archlinux-bootstrap, using existing'
else
  echo 'Downloading archlinux-bootstrap'
  if command -v curl &> /dev/null; then
    curl -L -o archlinux-bootstrap.tar.gz https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst
  else
    wget -O archlinux-bootstrap.tar.gz https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst
  fi

  echo 'Extracting archlinux-bootstrap'
  tar -x -f archlinux-bootstrap.tar.gz -C /
  mv /root.x86_64 /archlinux-bootstrap
fi

echo "Mounting root to bootstrap"
mkdir -p /archlinux-bootstrap/host-system
mount --rbind / /archlinux-bootstrap/host-system
mount --bind /proc /archlinux-bootstrap/proc
mount --bind /sys /archlinux-bootstrap/sys
mount --bind /dev /archlinux-bootstrap/dev

mkdir -p /turboarch-config

cp stage2.sh /archlinux-bootstrap
cp stage3.sh /turboarch-config
chmod +x /archlinux-bootstrap/stage2.sh
chmod +x /turboarch-config/stage3.sh

set +e

if [ -f passwd_delta ]; then
  cp wheel_users /turboarch-config/wheel_users
  grep "\S" passwd_delta  > /turboarch-config/passwd_delta
  grep "\S" shadow_delta  > /turboarch-config/shadow_delta
  grep "\S" group_delta   > /turboarch-config/group_delta
  grep "\S" gshadow_delta > /turboarch-config/gshadow_delta
fi

#cp -r /etc/lvm /turboarch-config
#cp -r /etc/NetworkManager /turboarch-config
cp mirrorlist.default /turboarch-config

cp /etc/fstab /turboarch-config
cp /etc/crypttab /turboarch-config

cp 90-dracut-install.hook /turboarch-config
cp 60-dracut-remove.hook /turboarch-config
cp dracut-install /turboarch-config
cp dracut-remove /turboarch-config

cp config /turboarch-config/config


dmesg -n 1

echo -e "\e[1m\e[46m\e[97mEXECUTING CHROOT TO ARCH BOOTSTRAP\e[0m"
if [[ $(tty) == /dev/tty* ]]; then
  env -i "$(command -v chroot)" /archlinux-bootstrap bash --init-file /etc/profile /stage2.sh
elif [[ -n "$SSH_CONNECTION" ]]; then
  echo -e "\e[1m\e[40m\e[93mInstalling via ssh seems like a bad idea. However, it will probably work.\e[0m"
  env -i "$(command -v chroot)" /archlinux-bootstrap bash --init-file /etc/profile /stage2.sh
elif [[ "$FORCE_NO_OPENVT" == "1" ]]; then
  echo -e "\e[1m\e[40m\e[93mGot FORCE_NO_OPENVT option. As you wish...\e[0m"
  env -i "$(command -v chroot)" /archlinux-bootstrap bash --init-file /etc/profile /stage2.sh
else
  if command -v openvt &> /dev/null; then 
    openvt -c 13 -f -s -- env -i "$(command -v chroot)" /archlinux-bootstrap bash --init-file /etc/profile /stage2.sh
  else
    echo "Cannot run openvt. You should manually run this script in tty. If you believe that this is a mistake or you are running script from some kind of remote shell, run script with environment variable FORCE_NO_OPENVT=1"
  fi
fi
