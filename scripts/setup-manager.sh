#!/usr/bin/env bash

TMP_FOLDER=$(mktemp -d)
CONFIG_FILE='Therris.conf'
CONFIG_FOLDER='"$HOME"/.Therris'
BACKUP_FOLDER="$HOME/TherrisBackups"
COIN_DAEMON='therrisd'
COIN_PATH='/usr/bin/'
COIN_REPO='https://github.com/therriscoin/therriscoin.git'
#COIN_TGZ='http://github.com/therriscoin/therriscoin/releases/XXX.zip'
#COIN_ZIP=$(echo $COIN_TGZ | awk -F'/' '{print $NF}')
COIN_NAME='Therris'
COIN_PORT=44144
RPC_PORT=44155
NODEIP=$(curl -s4 icanhazip.com)

BLUE="\033[0;34m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"
PURPLE="\033[0;35m"
RED='\033[0;31m'
GREEN="\033[0;32m"
NC='\033[0m'
MAG='\e[1;35m'

purgeOldInstallation() {
    echo -e "${GREEN}Searching for and backing up any wallet and config files, and removing old $COIN_NAME files${NC}"
    #kill wallet daemon
    systemctl stop $COIN_NAME.service > /dev/null 2>&1
    sudo killall $COIN_DAEMON > /dev/null 2>&1
    today="$( date +"%Y%m%d" )"
    #Create a backups folder inside users home directory
    test -d ~/TherrisBackups && echo "Backups folder exists, skipping directory creation..." || mkdir ~/TherrisBackups
    iteration=0
    while test -d "$BACKUP_FOLDER/$today$suffix"; do
        (( ++iteration ))
        suffix="$( printf -- '-%02d' "$iteration" )"
    done
    foldername="$today$suffix"
    echo "Placing Backup Files into $BACKUP_FOLDER/$foldername"
    mkdir $BACKUP_FOLDER/$foldername
    mv $CONFIG_FOLDER/masternode.conf $BACKUP_FOLDER/$foldername
    mv $CONFIG_FOLDER/Therris.conf $BACKUP_FOLDER/$foldername
    mv $CONFIG_FOLDER/wallet.dat $BACKUP_FOLDER/$foldername
    #remove old ufw port allow
    sudo ufw delete allow $COIN_PORT/tcp > /dev/null 2>&1
    #remove old files
    sudo rm -rf $CONFIG_FOLDER > /dev/null 2>&1
    sudo rm -rf /usr/bin/$COIN_DAEMON > /dev/null 2>&1
    sudo rm -rf /tmp/*
    systemctl disable $COIN_NAME.service
    sudo rm -rf /etc/systemd/system/$COIN_NAME.service
    systemctl daemon-reload
    echo -e "${GREEN}* Done Backing Up and Uninstalling...${NONE}";
}

function configure_systemd() {
  cat << EOF > /etc/systemd/system/$COIN_NAME.service
[Unit]
Description=$COIN_NAME service
After=network.target
[Service]
User=$(id -un)
Group=$(id -gn)
Type=forking
#PIDFile=$CONFIG_FOLDER/$COIN_NAME.pid
ExecStart=$COIN_PATH$COIN_DAEMON -daemon -conf=$CONFIG_FOLDER/$CONFIG_FILE -datadir=$CONFIG_FOLDER
ExecStop=-$COIN_PATH$COIN_DAEMON -conf=$CONFIG_FOLDER/$CONFIG_FILE -datadir=$CONFIG_FOLDER stop
Restart=always
PrivateTmp=true
TimeoutStopSec=60s
TimeoutStartSec=10s
StartLimitInterval=120s
StartLimitBurst=5
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  sleep 3
  systemctl start $COIN_NAME.service
  systemctl enable $COIN_NAME.service >/dev/null 2>&1
  if [[ -z "$(ps axo cmd:100 | egrep $COIN_DAEMON)" ]]; then
    echo -e "${RED}$COIN_NAME is not running${NC}, please investigate. You should start by running the following commands as root:"
    echo -e "${GREEN}systemctl start $COIN_NAME.service"
    echo -e "systemctl status $COIN_NAME.service"
    echo -e "less /var/log/syslog${NC}"
    exit 1
  fi
}

function create_config() {
  mkdir $CONFIG_FOLDER >/dev/null 2>&1
  RPCUSER=$(tr -cd '[:alnum:]' < /dev/urandom | fold -w10 | head -n1)
  RPCPASSWORD=$(tr -cd '[:alnum:]' < /dev/urandom | fold -w22 | head -n1)
  cat << EOF > $CONFIG_FOLDER/$CONFIG_FILE
rpcuser=$RPCUSER
rpcpassword=$RPCPASSWORD
rpcport=$RPC_PORT
rpcallowip=127.0.0.1
listen=1
server=1
daemon=1
port=$COIN_PORT
EOF
}

function update_config() {
  echo -e "${BLUE}================================================================================================================================"
  echo -e "${GREEN}Important: To complete the Masternode setup, you must set up your controller wallet"
  echo -e "${BLUE}================================================================================================================================${NC}"
  echo -e "${PURPLE}Please follow this guide to setup the controller wallet, then return here to input your the genkey output: https://github.com/therriscoin/therriscoin/wiki/Setup-Manager---Masternode-Asisstant-Setup-Script-Guide${NC}"
  echo -e "${BLUE}================================================================================================================================${NC}"
  read -p "${PURPLE}Please enter the ${NC}${GREEN}genkey${NC}:" COINKEY
  systemctl stop therris
  sed -i 's/daemon=1/daemon=0/' $CONFIG_FOLDER/$CONFIG_FILE
  grep -Fxq "masternode=1" $CONFIG_FOLDER/$CONFIG_FILE
  if [ $? -eq 0 ]; then
    echo "Found previous masternode configuration. Will backup file then create configuration changes"
    backup_node_data
    rm $CONFIG_FOLDER/$CONFIG_FILE
    create_config
  fi
  cat << EOF >> $CONFIG_FOLDER/$CONFIG_FILE
logintimestamps=1
maxconnections=75
#bind=$NODEIP
masternode=1
externalip=$NODEIP:$COIN_PORT
masternodeprivkey=$COINKEY
masternodeaddr=$NODEIP:$COIN_PORT
#Addnodes
#addnode=123.456.78.9:44144
EOF
systemctl start therris
}

function enable_firewall() {
  echo -e "Installing and setting up firewall to allow ingress on port ${GREEN}$COIN_PORT${NC}"
  ufw allow $COIN_PORT/tcp comment "$COIN_NAME MN port" >/dev/null
  ufw allow ssh comment "SSH" >/dev/null 2>&1
  ufw limit ssh/tcp >/dev/null 2>&1
  ufw default allow outgoing >/dev/null 2>&1
  echo "y" | ufw enable >/dev/null 2>&1
}

function get_ip() {
  declare -a NODE_IPS
  for ips in $(netstat -i | awk '!/Kernel|Iface|lo/ {print $1," "}')
  do
    NODE_IPS+=($(curl --interface $ips --connect-timeout 2 -s4 icanhazip.com))
  done
  if [ ${#NODE_IPS[@]} -gt 1 ]
    then
      echo -e "${GREEN}More than one IP. Please type 0 to use the first IP, 1 for the second and so on...${NC}"
      INDEX=0
      for ip in "${NODE_IPS[@]}"
      do
        echo ${INDEX} $ip
        let INDEX=${INDEX}+1
      done
      read -e choose_ip
      NODEIP=${NODE_IPS[$choose_ip]}
  else
    NODEIP=${NODE_IPS[0]}
  fi
}

function compile_error() {
    if [ "$?" -gt "0" ];
     then
      echo -e "${RED}Failed to compile $COIN_NAME. Please investigate.${NC}"
      exit 1
    fi
}

function checks() {
    if [[ $(lsb_release -d) != *16.04* ]]; then
      echo -e "${RED}You are not running Ubuntu 16.04. Please ensure you are running Ubuntu 16.04.${NC}"
      exit 1
    fi
    if [[ $EUID -ne 0 ]]; then
       echo -e "${RED}$0 must be run as root.${NC}"
       exit 1
    fi
}

function prepare_system() {
    if [ -f ./install-dependencies.sh ]; then
        echo "Install-dependencies script is already available. Will not download."
        chmod +x ./install-dependencies.sh
        ./install-dependencies.sh
    else
        echo "Downloading latest install-dependencies script."
        wget https://raw.githubusercontent.com/therriscoin/therriscoin/master/scripts/install-dependencies.sh
        chmod +x install-dependencies.sh
        ./install-dependencies.sh
    fi
    if [ "$?" -gt "0" ];
      then
        echo -e "${RED}Not all required packages were installed properly. Try to install them manually by running the following commands:${NC}\n"
        echo "apt-get -y update && apt-get -y install build-essential libssl-dev libdb++-dev libboost-all-dev libcrypto++-dev \
    libqrencode-dev libminiupnpc-dev libgmp-dev libgmp3-dev autoconf autogen  qt5-default qt5-qmake qtbase5-dev-tools \
    qttools5-dev-tools build-essential libboost-dev libboost-system-dev libboost-filesystem-dev libgtk2.0-dev libtool \
    libboost-program-options-dev libboost-thread-dev autopoint bison flex gperf libtool ruby scons unzip libtool-bin \
    automake git p7zip-full intltool"
     exit 1
    fi
}

function important_information() {
    echo
    echo -e "${BLUE}================================================================================================================================${NC}"
    echo -e "${GREEN}Configuration file is:${NC}${RED}$CONFIG_FOLDER/$CONFIG_FILE${NC}"
    echo -e "${GREEN}Start:${NC}${RED}systemctl start $COIN_NAME.service${NC}"
    echo -e "${GREEN}Stop:${NC}${RED}systemctl stop $COIN_NAME.service${NC}"
    echo -e "${GREEN}VPS_IP:${NC}${GREEN}$NODEIP:$COIN_PORT${NC}"
    echo -e "${BLUE}================================================================================================================================"
    echo -e "${CYAN}Follow twitter to stay updated.  https://twitter.com/TherrisCoin${NC}"
    echo -e "${BLUE}================================================================================================================================${NC}"
    echo -e "${CYAN}Ensure Node is fully SYNCED with BLOCKCHAIN before starting your Node :).${NC}"
    echo -e "${BLUE}================================================================================================================================${NC}"
    echo -e "${GREEN}Usage Commands.${NC}"
    echo -e "${GREEN}therrisd masternode status${NC}"
    echo -e "${GREEN}therrisd getinfo${NC}"
    echo -e "${BLUE}================================================================================================================================${NC}"
    echo -e "${NC}"
}

function setup_node() {
  get_ip
  update_config
  systemctl restart therris
}

function install_therris() {
    echo "You chose to install the Therris Node"
    echo "Checking for Therris installation"
    if [ -e /usr/bin/therrisd ] || [ -e /usr/local/bin/therrisd ]; then
        purgeOldInstallation
    else
        echo "No installation found. Proceeding with install..."
    fi
    checks
    prepare_system
    echo "Would you like to download and compile from source? y/n: "
    read compilefromsource
    if [ "$compilefromsource" = "y" ] || [ "$compilefromsource" = "Y" ] ; then
        if [ -e ../Therris.pro ]; then
            echo "Compiling Source Code"
            chmod +x build-unix.sh
            ./build-unix.sh
            mv ../bin/therrisd /usr/bin
        else
            echo "Cloning github repository.."
            git clone https://github.com/therriscoin/therriscoin
            chmod +x ./therriscoin/scripts
            ./therriscoin/scripts/build-unix.sh
            mv ./therriscoin/bin/therrisd /usr/bin
            if [ -e "$HOME"/therris-swap ]; then
                echo "Removing temporary swap file"
                swapoff "$HOME"/therris-swap
                rm "$HOME"/therris-swap
            fi
        fi
    else
        echo "Download Executable Binary For Install"
        mkdir ./tmp
        cd tmp
        wget https://github.com/$(wget https://github.com/therriscoin/therriscoin/releases/latest -O - | egrep '/.*/.*/.*tar.gz' -o)
        tar -xvf *.tar.gz
        mv ./therrisd /usr/bin
        cd ..
        rm -r ./tmp
    fi
    create_config
    enable_firewall
    configure_systemd
    important_information
}

function compile_linux_daemon() {
    echo "You chose to compile the Therris CLI Daemon/Wallet"
    checks
    prepare_system
    if [ ! -e ../Therris.pro ] ; then
        echo "Cloning Therris Coin github repository to this directory."
        git clone https://github.com/therriscoin/therriscoin
        ./therriscoin/scripts/build-unix.sh
        clear
        echo "Compile is complete, you can find the binary file in ./therriscoin/bin/"
    else
        echo "Compiling Source Code"
        ./build-unix.sh
        clear
        echo "Compile is complete, you can find the binary file in ../bin/"
    fi
}

function compile_linux_gui() {
    echo "You chose to compile the linux GUI wallet"
    checks
    prepare_system
    if [ ! -e ../Therris.pro ] ; then
        echo "Cloning Therris Coin Github Repository"
        git clone https://github.com/therriscoin/therriscoin
        ./therriscoin/scripts/build-unix.sh --with-gui
        clear
        echo "Compile is complete, you can find the binary file in ./therriscoin/bin/"
    else
        echo "Compiling Source Code"
        ./build-unix.sh --with-gui
        clear
        echo "Compile is complete, you can find the binary file in ../bin/"
    fi
}

function compile_windows_exe() {
    echo "You chose to compile windows executables"
    checks
    prepare_system
    if [ ! -e ../Therris.pro ] ; then
        echo "Cloning Therris Coin Github Repository"
        git clone https://github.com/therriscoin/therriscoin
        chmod +x ./therriscoin/scripts/*
        ./therriscoin/scripts/clean.sh
        ./therriscoin/scripts/configure-mxe.sh
        ./therriscoin/scripts/build-win-mxe.sh
    else
        echo "Compiling Source Code"
        chmod +x ./*
        ./clean.sh
        ./configure-mxe.sh
        ./build-win-mxe.sh
    fi
}

function setup_masternode() {
    echo "You chose to setup a masternode"
    if [ -e /usr/bin/therrisd ] || [ -e /usr/local/bin/therrisd ]; then
        read -p "There is already an installation of Therris Coin. Did you want to use the currently installed software, or install the latest software? Y/n:" yn
        case $yn in
            [Yy]* ) install_therris; setup_node; important_information;;
            [Nn]* ) backup_node_data; setup_node; important_information;;
            * ) echo "Sorry, did not understand your command, please enter Y/n";;
        esac
    else
        install_therris
        setup_node
        important_information
    fi
}

function install_dependencies_only() {
    echo "You chose to install Therris dependencies only"
    prepare_system
}

function backup_node_data() {
    echo "You chose to backup your wallet and settings files"
    today="$( date +"%Y%m%d" )"
    #Create a backups folder inside users home directory
    test -d ~/TherrisBackups && echo "Backups folder exists" || mkdir ~/TherrisBackups
    iteration=0
    while test -d "$BACKUP_FOLDER/$today$suffix"; do
        (( ++iteration ))
        suffix="$( printf -- '-%02d' "$iteration" )"
    done
    foldername="$today$suffix"
    echo "Placing Backup Files into $BACKUP_FOLDER/$foldername"
    mkdir $BACKUP_FOLDER/$foldername
    cp $CONFIG_FOLDER/masternode.conf $BACKUP_FOLDER/$foldername
    cp $CONFIG_FOLDER/Therris.conf $BACKUP_FOLDER/$foldername
    cp $CONFIG_FOLDER/wallet.dat $BACKUP_FOLDER/$foldername
}

function uninstall() {
    read -p "You chose to uninstall Therris, would you like to continue? y/n:" yn
    case $yn in
        [Yy]* ) purgeOldInstallation;;
        [Nn]* ) exit;;
        * ) echo "Please answer Y/n";;
    esac
}

function compile_only() {
    echo "What would you like to compile?"
    echo "[1] - Compile Linux GUI wallet"
    echo "[2] - Compile Linux CLI binary"
    echo "[3] - Compile Windows executables"
    read compilechoice
    case $compilechoice in
        "1") compile_linux_gui;;
        "2") compile_linux_daemon;;
        "3") compile_windows_exe;;
    esac
}

##### Main #####
clear

if [ $# > 0 ] ; then
    if [[ $1 = "--backup" ]] ; then
        backup_node_data
        exit 1
    fi
fi

echo "Welcome to the interactive setup manager. Please select an option:"
echo "========================================================="
echo "[1] - Install Therris node (will uninstall/upgrade existing installation)"
echo "[2] - Compile only (will compile linux daemon, linux GUI, or windows GUI - no install)"
echo "[3] - Prepare masternode (will install Therris Node if needed)"
echo "[4] - Install dependencies only"
echo "[5] - Backup Therris wallet and settings"
echo "[6] - Uninstall Therris"

read choice1

case $choice1 in
    "1") install_therris;;
    "2") compile_only;;
    "3") setup_masternode;;
    "4") install_dependencies_only;;
    "5") backup_node_data;;
    "6") uninstall;;
esac