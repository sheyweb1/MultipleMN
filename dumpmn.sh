#!/bin/bash

# TODO:
# - dupmn reinstall <profile_name> <instance_number>
# - avoid that people can create a profile named dupmn.conf, for gods sake...
# - dupmn ipadd <ip> # will require hard restart
# - dupmn ipdel <ip> # not main one
# - dupmn ipinstall <profile_name> <ip> # repeated ip => just change rpcport + listen=0
# - dupmn iplist


readonly RED='\e[1;31m'
readonly GREEN='\e[1;32m'
readonly YELLOW='\e[1;33m'
readonly BLUE='\e[1;34m'
readonly MAGENTA='\e[1;35m'
readonly CYAN='\e[1;36m'
readonly UNDERLINE='\e[1;4m'
readonly NC='\e[0m'


coin_name=""
coin_path=""
coin_daemon=""
coin_cli=""
coin_folder=""
coin_config=""
rpc_port=""
dup_count=""


function get_conf() {
	# <$1 = conf_file>
	local str_map="";
	for line in `sed '/^$/d' $1`; do
		str_map+="[${line%=*}]=${line#*=} "
	done
	echo -e "( $str_map )"
}

function port_check() {
	# <$1 = port_number>
	if [ ! $(lsof -Pi :$1 -sTCP:LISTEN -t) ]; then
		echo -e 1
	fi
}

function find_port() {
	# <$1 = initial_check>
	for (( i=$1; i<=49151; i++ )); do
		if [ $(port_check $i) ]; then
			echo -e "$i"
			return
		fi
	done
	for (( i=1024; i<$1; i++ )); do
		if [ $(port_check $i) ]; then
			echo -e "$i"
			return
		fi
	done
}

function is_number() {
	# <$1 = number>
	if [[ $1 =~ ^[0-9]+$ ]]; then 
		echo -e "1"
	fi
}

function cmd_profadd() {
	# <$1 = profile_file> | <$2 = profile_name>

	local -A prof=$(get_conf $1)
	local CMD_ARRAY=(COIN_NAME COIN_PATH COIN_DAEMON COIN_CLI COIN_FOLDER COIN_CONFIG)

	for var in "${CMD_ARRAY[@]}"; do
		if [[ ! "${!prof[@]}" =~ "$var" ]]; then
			echo -e "${MAGENTA}$var${NC} doesn't exists in the supplied profile file"
			exit
		elif [[ -z "${prof[$var]}" ]]; then
			echo -e "${MAGENTA}$var${NC} doesn't contain a value in the supplied profile file"
			exit
		fi
	done

	if [ ! -d ".dupmn" ]; then
		mkdir ".dupmn"
	fi
	if [ ! -f ".dupmn/dupmn.conf" ]; then
		touch ".dupmn/dupmn.conf"
	fi
	if [ ! $(grep $2 .dupmn/dupmn.conf) ]; then
		echo -e "$2=0" >> ".dupmn/dupmn.conf"
	fi

	cp "$1" ".dupmn/$2"

	local fix_path=${prof[COIN_PATH]}
	local fix_folder=${prof[COIN_FOLDER]}

	if [[ ${fix_path:${#fix_path}-1:1} != "/" ]]; then
		sed -i "/^COIN_PATH=/s/=.*/=\"${fix_path//"/"/"\/"}\/\"/" .dupmn/$2
	fi
	if [[ ${fix_folder:${#fix_folder}-1:1} = "/" ]]; then
		fix_folder=${fix_folder::-1}
		sed -i "/^COIN_FOLDER=/s/=.*/=\"${fix_folder//"/"/"\/"}\"/" .dupmn/$2
	fi

	echo -e "${BLUE}$2${NC} profile successfully added, use ${GREEN}dupmn install $2${NC} to create a new instance of the masternode"
}

function cmd_profdel() {
	# <$1 = profile_name>

	if [ $dup_count -gt 0 ]; then
		cmd_uninstall $1 all
	fi
	sed -i "/$1\=/d" ".dupmn/dupmn.conf"

	rm -rf /usr/bin/$coin_daemon-0
	rm -rf /usr/bin/$coin_daemon-all
	rm -rf /usr/bin/$coin_cli-0
	rm -rf /usr/bin/$coin_cli-all
	rm -rf .dupmn/$1
}

function cmd_install() {
	# <$1 = profile_name>

	function configure_systemd() {
		# <$1 = prof_file> | <$2 = instance_number>

		echo -e "[Unit]\
		\nDescription=$coin_name-$2 service\
		\nAfter=network.target\
		\n\
		\n[Service]\
		\nUser=root\
		\nGroup=root\
		\nType=forking\
		\nExecStart=$coin_path$coin_daemon -daemon -conf=$coin_folder$2/$coin_config -datadir=$coin_folder$2\
		\nExecStop=$coin_path$coin_cli -conf=$coin_folder$2/$coin_config -datadir=$coin_folder$2 stop\
		\nRestart=always\
		\nPrivateTmp=true\
		\nTimeoutStopSec=60s\
		\nTimeoutStartSec=10s\
		\nStartLimitInterval=120s\
		\nStartLimitBurst=5\
		\n\
		\n[Install]\
		\nWantedBy=multi-user.target" > /etc/systemd/system/$coin_name-$2.service
		chmod +x /etc/systemd/system/$coin_name-$2.service

		systemctl daemon-reload
		sleep 3
		systemctl start $coin_name-$2.service
		systemctl enable $coin_name-$2.service > /dev/null 2>&1

		if [[ -z "$(ps axo cmd:100 | egrep $coin_name-$2)" ]]; then
			echo -e "1"
		fi
	}

	if [ ! -d "$coin_folder" ]; then
		echo -e "$coin_folder folder can't be found, $coin_name is not installed in the system or the given profile has a wrong parameter"
		exit
	elif [ ! "$(command -v $coin_daemon)" ]; then
		echo -e "$coin_daemon command can't be found, $coin_name is not installed in the system or the given profile has a wrong parameter"
		exit
	elif [ ! "$(command -v $coin_cli)" ]; then
		echo -e "$coin_cli command can't be found, $coin_name is not installed in the system or the given profile has a wrong parameter"
		exit
	fi

	dup_count=$(($dup_count+1))

	local new_key=$($coin_cli masternode genkey)
	local new_rpc=$(find_port $(($(grep -Po '(?<=RPC_PORT=).*' .dupmn/$1 || grep -Po '(?<=rpcport=).*' $coin_folder/$coin_config || echo -e "1023")+1)))
	local new_folder="$coin_folder$dup_count"

	if [[ ! $new_key =~ ^[a-zA-Z0-9]+$ ]]; then
		echo -e "Main masternode must be running to create a duplicate masternode, use ${GREEN}$coin_daemon -daemon${NC} to start the main masternode"
		exit
	fi

	mkdir $new_folder
	cp $coin_folder/$coin_config $new_folder

	grep -Poq '(?<=rpcport=).*'           $new_folder/$coin_config && sed -i "/^rpcport=/s/=.*/=$new_rpc/"           $new_folder/$coin_config || echo -e "rpcport=$new_rpc"           >> $new_folder/$coin_config
	grep -Poq '(?<=listen=).*'            $new_folder/$coin_config && sed -i "/^listen=/s/=.*/=0/"                   $new_folder/$coin_config || echo -e "listen=0"                   >> $new_folder/$coin_config
	grep -Poq '(?<=masternodeprivkey=).*' $new_folder/$coin_config && sed -i "/^masternodeprivkey=/s/=.*/=$new_key/" $new_folder/$coin_config || echo -e "masternodeprivkey=$new_key" >> $new_folder/$coin_config

	echo -e "#!/bin/bash\n$coin_cli \$@"    > /usr/bin/$coin_cli-0
	echo -e "#!/bin/bash\n$coin_daemon \$@" > /usr/bin/$coin_daemon-0
	echo -e "#!/bin/bash\n$coin_cli -datadir=$new_folder \$@"    > /usr/bin/$coin_cli-$dup_count
	echo -e "#!/bin/bash\n$coin_daemon -datadir=$new_folder \$@" > /usr/bin/$coin_daemon-$dup_count
	echo -e "#!/bin/bash\nfor (( i=0; i<=$dup_count; i++ )) do\n echo -e MN\$i:\n $coin_cli-\$i \$@\ndone"    > /usr/bin/$coin_cli-all
	echo -e "#!/bin/bash\nfor (( i=0; i<=$dup_count; i++ )) do\n echo -e MN\$i:\n $coin_daemon-\$i \$@\ndone" > /usr/bin/$coin_daemon-all
	chmod +x /usr/bin/$coin_cli-0
	chmod +x /usr/bin/$coin_daemon-0
	chmod +x /usr/bin/$coin_cli-$dup_count
	chmod +x /usr/bin/$coin_daemon-$dup_count
	chmod +x /usr/bin/$coin_cli-all
	chmod +x /usr/bin/$coin_daemon-all

	sed -i "/^$1=/s/=.*/=$dup_count/" .dupmn/dupmn.conf

	local sysmd_res=$(configure_systemd $1 $dup_count)

	echo -e "===================================================================================================\
			\n${BLUE}$coin_name${NC} duplicated masternode ${CYAN}number $dup_count${NC} should be now up and trying to sync with the blockchain.\
			\nThe duplicated masternode uses the same IP and port than the original one, but the private key is different and obviously it requires a different transaction (you cannot have 2 masternodes with the same transaction).\
			\nNew RPC port is ${MAGENTA}$new_rpc${NC} (other programs may not be able to use this port, but you can change it with ${MAGENTA}dupmn rpcchange $1 $dup_count PORT_NUMBER${NC})\
			\nStart:              ${RED}systemctl start   $1-$dup_count.service${NC}\
			\nStop:               ${RED}systemctl stop    $1-$dup_count.service${NC}\
			\nStart on reboot:    ${RED}systemctl enable  $1-$dup_count.service${NC}\
			\nNo start on reboot: ${RED}systemctl disable $1-$dup_count.service${NC}\
			\n(Currently configured to start on reboot)\
			\nDUPLICATED MASTERNODE PRIVATEKEY is: ${GREEN}$new_key${NC}\
			\nWait until the duplicated masternode is synced with the blockchain before trying to start it.\
			\nFor check masternode status just use: ${GREEN}$coin_cli-$dup_count masternode status${NC} (if says \"Hot Node\" => synced).\
			\nNOTE: ${GREEN}$coin_cli-0${NC} and ${GREEN}$coin_daemon-0${NC} are just a reference to the 'main masternode', not a duplicated one.\
			\nNOTE 2: You can use ${GREEN}$coin_cli-all [parameters]${NC} and ${GREEN}$coin_daemon-all [parameters]${NC} to apply the parameters on all masternodes. Example: ${GREEN}$coin_cli-all masternode status${NC}\
			\n==================================================================================================="

	if [[ $sysmd_res ]]; then 
		echo -e "\n${RED}IMPORTANT!!!${NC} \
				\nSeems like there might be a problem with the systemctl configuration, please investigate.\
				\nYou should start by running the following commands:\
				\n${GREEN}systemctl start  $coin_name-$2.service${NC}\
				\n${GREEN}systemctl status $coin_name-$2.service${NC}\
				\n${GREEN}less /var/log/syslog${NC}\
				\nThe most common causes of this might be that either you made something to a file that dupmn modifies or creates, or that you don't have enough free resources (usually memory).
				\nThere's also the chance that this could be a false positive error (so actually everything is ok), anyway please use the commands above to investigate."
	fi
}

function cmd_list() {
	local -A conf=$(get_conf .dupmn/dupmn.conf)
	if [ ${#conf[@]} -eq 0 ]; then 
		echo -e "(no profiles added)"
	else
		for var in "${!conf[@]}"; do
			echo -e "$var : ${conf[$var]}"
		done
	fi
}

function cmd_uninstall() {
	# <$1 = profile_name> | <$2 = instance_number/all>

	if [ $dup_count = 0 ]; then 
		echo -e "There aren't duplicated ${BLUE}$1${NC} masternodes to remove"
		exit
	fi

	if [ "$2" = "all" ]; then 
		for (( i=$dup_count; i>=1; i-- )); do
			echo -e "Uninstalling ${BLUE}$1${NC} instance ${CYAN}number $i${NC}"
			rm -rf /usr/bin/$coin_cli-$i
			rm -rf /usr/bin/$coin_daemon-$i
			systemctl stop $coin_name-$i.service > /dev/null
			systemctl disable $coin_name-$i.service > /dev/null 2>&1
			sleep 3
			rm -rf /etc/systemd/system/$coin_name-$i.service
			rm -rf $coin_folder$i
		done
		sed -i "/^$1=/s/=.*/=0/" ".dupmn/dupmn.conf"
		echo -e "#!/bin/bash\nfor (( i=0; i<=0; i++ )) do\n echo -e MN\$i:\n $coin_cli-\$i \$@\ndone" > /usr/bin/$coin_cli-all
		echo -e "#!/bin/bash\nfor (( i=0; i<=0; i++ )) do\n echo -e MN\$i:\n $coin_daemon-\$i \$@\ndone" > /usr/bin/$coin_daemon-all
		chmod +x /usr/bin/$coin_cli-all
		chmod +x /usr/bin/$coin_daemon-all
		systemctl daemon-reload
	else 
		echo -e "Uninstalling ${BLUE}$1${NC} instance ${CYAN}number $(($2))${NC}"
		rm -rf /usr/bin/$coin_cli-$(($dup_count))
		rm -rf /usr/bin/$coin_daemon-$(($dup_count))
		$coin_cli -datadir=$coin_folder$(($2)) stop > /dev/null
		sed -i "/^$1=/s/=.*/=$(($dup_count-1))/" ".dupmn/dupmn.conf"
		echo -e "#!/bin/bash\nfor (( i=0; i<=$(($dup_count-1)); i++ )) do\n echo -e MN\$i:\n $coin_cli-\$i \$@\ndone"    > /usr/bin/$coin_cli-all
		echo -e "#!/bin/bash\nfor (( i=0; i<=$(($dup_count-1)); i++ )) do\n echo -e MN\$i:\n $coin_daemon-\$i \$@\ndone" > /usr/bin/$coin_daemon-all
		chmod +x /usr/bin/$coin_cli-all
		chmod +x /usr/bin/$coin_daemon-all
		sleep 3
		rm -rf $coin_folder$2
			
		for (( i=$2; i<=$dup_count; i++ )); do
			systemctl stop $coin_name-$i.service 
		done
		for (( i=$2+1; i<=$dup_count; i++ )); do
			echo -e "setting ${CYAN}instance $i${NC} as ${CYAN}instance $(($i-1))${NC}..."
			mv $coin_folder$i $coin_folder$(($i-1))
			sleep 1
			systemctl start $coin_name-$(($i-1)).service 
		done

		systemctl disable $coin_name-$dup_count.service > /dev/null 2>&1
		sleep 3
		rm -rf /etc/systemd/system/$coin_name-$dup_count.service
		systemctl daemon-reload
	fi
}

function cmd_rpcchange() {
	# <$1 = profile_name> | <$2 = instance_number> | [$3 = port_number]

	if [[ ! $(is_number $2) ]]; then
		echo -e "${YELLOW}dupmn rpcchange <prof_name> <number> [port]${NC}, <number> must be a number"
		exit
	elif [[ $(($2)) -gt $dup_count ]]; then 
		echo -e "Instance ${CYAN}number $(($2))${NC} doesn't exists, there are only ${CYAN}$dup_count${NC} ${BLUE}$1${NC} instances"
		exit
	elif [[ $(($2)) = 0 ]]; then 
		echo -e "Instance ${CYAN}number 0${NC} is the main masternode, not a duplicated one, can't change this one"
		exit
	fi

	local new_port="$(grep -Po "rpcport=\K.*" $coin_folder$(($2))/$coin_config)";

	if [[ -z "$3" ]]; then
		echo -e "No port provided, the port will be changed for any other free port..."
		new_port=$(find_port $new_port)
	elif [[ ! $(is_number $3) ]]; then
		echo -e "${YELLOW}dupmn rpcchange <prof_name> <number> [port]${NC}, [port] must be a number"
		exit
	elif [[ $(($3)) -lt 1024 || $(($3)) -gt 49151 ]]; then 
		echo -e "${MAGENTA}$3${NC} is not a valid or a reserved port (must be between ${MAGENTA}1024${NC} and ${MAGENTA}49151${NC})"
		exit
	else 
		new_port=$(($3))
		if [[ ! $(port_check $(($new_port))) ]]; then
			echo -e "Port ${MAGENTA}$(($new_port))${NC} seems to be in use by another process"
			exit
		fi
	fi

	systemctl stop $coin_name-$(($2)).service > /dev/null
	sleep 3
	sed -i "/^rpcport=/s/=.*/=$(($new_port))/" $coin_folder$(($2))/$coin_config
	systemctl start $coin_name-$(($2)).service

	echo -e "${BLUE}$1${NC} instance ${CYAN}number $(($2))${NC} is now listening the rpc port ${MAGENTA}$(($new_port))${NC}"
}

function cmd_swapfile() {
	# <$1 = size_in_mbytes>

	if [[ ! $(is_number $1) ]]; then 
		echo -e "${YELLOW}<size_in_mbytes>${NC} must be a number"
		exit
	fi

	local avail_mb=$(df / --output=avail -m | grep [0-9])
	local total_mb=$(df / --output=size -m | grep [0-9])

	if [[ $(($1)) -ge $(($avail_mb)) ]]; then 
		echo -e "There's only $(($avail_mb)) MB available in the hard disk (NOTE: recommended to use a swapfile of NUMBER_OF_MASTERNODES * 150 MB)"
		exit
	fi

	echo -e "All duplicated instances will be temporary disabled until the swapfile command is finished to decrease the pressure on RAM..."

	local -A conf=$(get_conf .dupmn/dupmn.conf)
	for x in "${!conf[@]}"; do
		local -A prof=$(get_conf .dupmn/$x)
		for (( i=1; i<=${conf[$x]}; i++ )); do
			systemctl stop ${prof[COIN_NAME]}-$i.service 
			sleep 1
		done
	done

	if [[ -f /mnt/dupmn_swapfile ]]; then
		swapoff /mnt/dupmn_swapfile > /dev/null
	fi

	if [[ $(($1)) = 0 ]]; then 
		rm -rf /mnt/dupmn_swapfile 
		echo -e "Swapfile deleted"
	else
		dd if=/dev/zero of=/mnt/dupmn_swapfile bs=1024 count=$(($1 * 1024)) > /dev/null 2>&1
		chmod 600 /mnt/dupmn_swapfile > /dev/null 2>&1
		mkswap /mnt/dupmn_swapfile > /dev/null 2>&1
		swapon /mnt/dupmn_swapfile > /dev/null 2>&1
		/mnt/dupmn_swapfile swap swap defaults 0 0 > /dev/null 2>&1
		echo -e "Swapfile new size = ${GREEN}$(($1)) MB${NC}"
	fi

	echo -e "Reenabling instances... (you don't need to activate them again from your wallet and your position in the mn pool reward won't be lost)"
	for x in "${!conf[@]}"; do
		local -A prof=$(get_conf .dupmn/$x)
		for (( i=1; i<=${conf[$x]}; i++ )); do
			systemctl start ${prof[COIN_NAME]}-$i.service
			sleep 2
		done
	done

	echo -e "Use ${YELLOW}swapon -s${NC} to see the changes of your swapfile and ${YELLOW}free -m${NC} to see the total available memory"
}

function cmd_systemctlall() {
	# <$1 = profile_name> | <$2 = command>

	trap '' 2
	for (( i=1; i<=$dup_count; i++ )); do
		echo -e "${CYAN}systemctl $2 $coin_name-$i.service${NC}"
		systemctl $2 $coin_name-$i.service
	done
	trap 2
}

function cmd_help() {
	echo -e "Options:\n" \
			"  - ${YELLOW}dupmn profadd <prof_file> <prof_name>       ${NC}Adds a profile with the given name that will be used to create duplicates of the masternode\n" \
			"  - ${YELLOW}dupmn profdel <prof_name>                   ${NC}Deletes the given profile name, this will uninstall too any duplicated instance that uses this profile\n" \
			"  - ${YELLOW}dupmn install <prof_name>                   ${NC}Install a new instance based on the parameters of the given profile name\n" \
			"  - ${YELLOW}dupmn list                                  ${NC}Shows the amount of duplicated instances of every masternode\n" \
			"  - ${YELLOW}dupmn uninstall <prof_name> <number>        ${NC}Uninstall the specified instance of the given profile name, you can put \"all\" instead of a number to uninstall all the duplicated instances\n" \
			"  - ${YELLOW}dupmn rpcchange <prof_name> <number> [port] ${NC}Changes the RPC port used from the given number instance with the new one (or finds a new one by itself if no port is given)\n" \
			"  - ${YELLOW}dupmn swapfile <size_in_mbytes>             ${NC}Creates, changes or deletes (if parameter is 0) a swapfile of the given size in MB to increase the virtual memory\n" \
			"  - ${YELLOW}dupmn systemctlall <prof_name> <command>    ${NC}Applies the systemctl command to all the duplicated instances of the given profile name (but not the main instance)"
}

function main() {

	function load_profile() {
		# <$1 = profile_name>

		if [[ ! -f ".dupmn/$1" ]]; then
			echo -e "${BLUE}$1${NC} profile hasn't been added"
			exit
		fi

		local -A prof=$(get_conf .dupmn/$1)
		local -A conf=$(get_conf .dupmn/dupmn.conf)

		local CMD_ARRAY=(COIN_NAME COIN_PATH COIN_DAEMON COIN_CLI COIN_FOLDER COIN_CONFIG)
		for var in "${CMD_ARRAY[@]}"; do
			if [[ ! "${!prof[@]}" =~ "$var" || -z "${prof[$var]}" ]]; then
				echo -e "Seems like you modified something that was supposed to remain unmodified: ${MAGENTA}$var${NC} parameter should exists and have a assigned value in ${GREEN}.dupmn/$1${NC} file"
				echo -e "You can fix it by adding the ${BLUE}$1${NC} profile again"
				exit
			fi
		done
		if [[ ! "${!conf[@]}" =~ "$1" || -z "${conf[$1]}" || ! $(is_number "${conf[$1]}") ]]; then
			echo -e "Seems like you modified something that was supposed to remain unmodified: ${MAGENTA}$1${NC} parameter should exists and have a assigned number in ${GREEN}.dupmn/dupmn.conf${NC} file"
			echo -e "You can fix it by adding ${MAGENTA}$1=0${NC} to the .dupmn/dupmn.conf file (replace the number 0 for the number of nodes installed with dupmn using the ${BLUE}$1${NC} profile)"
			exit
		fi

		coin_name="${prof[COIN_NAME]}"
		coin_path="${prof[COIN_PATH]}"
		coin_daemon="${prof[COIN_DAEMON]}"
		coin_cli="${prof[COIN_CLI]}"
		coin_folder="${prof[COIN_FOLDER]}"
		coin_config="${prof[COIN_CONFIG]}"
		rpc_port="${prof[RPC_PORT]}"
		dup_count=$((${conf[$1]}))
	}

	function instance_valid() {
		# <$1 = profile_name> | <$2 = instance_number>

		local -A conf=$(get_conf .dupmn/dupmn.conf)
		local count=${conf[$1]}

		if [[ ! $(is_number $2) ]]; then
			echo -e "${RED}$2${NC} is not a number"
			exit
		elif [[ $(($2)) = 0 ]]; then
			echo -e "Instance ${CYAN}0${NC} is a reference to the main masternode, not a duplicated one, can't modify this one"
			exit
		elif [[ $(($2)) -gt $(($count)) ]]; then
			echo -e "Instance ${CYAN}$2${NC} doesn't exists, there are only ${CYAN}$(($count))${NC} instances of ${BLUE}$1${NC}"
			exit
		fi
	}

	if [[ -z "$1" ]]; then
		echo -e "No command inserted, use ${YELLOW}dupmn help${NC} to see all the available commands"
		exit
	fi

	case "$1" in
		"profadd")
			if [[ -z "$3" ]]; then
				echo -e "${YELLOW}dupmn profadd <prof_file> <coin_name>${NC} requires a profile file and a new profile name as parameters"
				exit
			fi
			cmd_profadd "$2" "$3"
			;;
		"profdel")
			if [[ -z "$2" ]]; then
				echo -e "${YELLOW}dupmn profadd <prof_name>${NC} requires a profile name as parameter"
				exit
			fi
			load_profile "$2"
			cmd_profdel "$2"
			;;
		"install")
			if [[ -z "$2" ]]; then
				echo -e "${YELLOW}dupmn install <coin_name>${NC} requires a profile name of an added profile as a parameter"
				exit
			fi
			load_profile "$2"
			cmd_install "$2"
			;;
		"list")
			cmd_list
			;;
		"uninstall")
			if [[ -z "$3" ]]; then
				echo -e "${YELLOW}dupmn uninstall <coin_name> <param>${NC} requires a profile name and a number (or all) as parameters"
				exit
			fi
			load_profile "$2"
			if [[ "$3" != "all" ]]; then
				instance_valid "$2" "$3"
			fi
			cmd_uninstall "$2" "$3"
			;;
		"rpcchange")
			if [[ -z "$3" ]]; then
				echo -e "${YELLOW}dupmn rpcchange <prof_name> <number> [port]${NC} requires a profile name, instance number and optionally a port number as parameters"
				exit
			fi
			load_profile "$2"
			instance_valid "$2" "$3"
			cmd_rpcchange "$2" "$3" "$4"
			;;
		"swapfile")
			if [[ -z "$2" ]]; then
				echo -e "${YELLOW}dupmn swapfile <size_in_mbytes>${NC} requires a number as parameter"
				exit
			fi
			cmd_swapfile "$2"
			;;
		"systemctlall")
			if [[ -z "$3" ]]; then
				echo -e "${YELLOW}dupmn systemctlall <prof_name> <command>${NC} requires a profile name and a command as parameters"
				exit
			fi
			load_profile "$2"
			cmd_systemctlall "$2" "$3"
			;;
		"help")
			cmd_help
			;;
		*)
			echo -e "Unrecognized parameter: ${RED}$1${NC}"
			echo -e "use ${YELLOW}dupmn help${NC} to see all the available commands"
			;;
	esac
}

main $@

