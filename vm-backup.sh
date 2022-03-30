#!/bin/bash

###################################################
#                                                 #
#  See syntax() below for background information  #
#                                                 #
###################################################

VERSION_STRING="2022.03.30-21.15"

###################################################
#                                                 #
#             Configuration variables             #
#                                                 #
###################################################

# If specified, the file is loaded and evaluated, allowing 
# to override the defaults. Can be specified with -c command
# line argument
CONFIG_FILE=

# local temp folder with a lot of space
# CHANGE THIS. /tmp is just a lazy default !
WORKDIR="/tmp/vm-backup-workdir"

# if _not_ to remote WORKDIR on script's completion
# 1 for 'yes', 0 for 'no'
WORKDIR_KEEP=0

# Backup host
REM_HOST="10.0.0.123"

# Base backup path on the remote end
REM_ROOT="/vmfs/volumes/backups"

# Number of older backup copies to keep
# 0 - to keep just the most recent copy
BACKUP_ROTATIONS=2

#-- Shutdown guestOS prior to running backups and power them back on afterwards
#-- This feature assumes VMware Tools are installed, else they will not power down and loop forever
#-- 2 for 'hard', 1 for 'soft' 0 for 'no'
#-- POWER_DOWN_VM='no'

#-- if the above flag "ENABLE_HARD_POWER_OFF "is set to 1, then will look at this flag which is the # of iterations
#-- the script will wait before executing a hard power off, this will be a multiple of 60seconds
#-- (e.g) = 3, which means this will wait up to 180seconds (3min) before it just powers off the VM
#-- POWER_DOWN_HARD_THRESHOLD=3

#-- Number of iterations the script will wait before giving up on powering down the VM and ignoring it for backup
#-- this will be a multiple of 60 (e.g) = 5, which means this will wait up to 300secs (5min) before it gives up
#-- POWER_DOWN_TIMEOUT=5

#-- Comma separated list of VM startup/shutdown ordering
#-- VM_SHUTDOWN_ORDER=
#-- VM_STARTUP_ORDER=

# Make VM snapshot even if it's powered off
# 1 for 'yes', 0 for 'no'
VM_SNAPSHOT_ALWAYS=1

# Include VMs memory when taking snapshot
# 1 for 'yes', 0 for 'no'
VM_SNAPSHOT_MEMORY=1

# Quiesce VM when taking snapshot (requires VMware Tools to be installed)
# 1 for 'yes', 0 for 'no'
VM_SNAPSHOT_QUIESCE=1

# default 15min timeout
VM_SNAPSHOT_TIMEOUT=15

# Format output of VMDK backup
#   zeroedthick                  - turns out this is faster than 'thin'
#   2gbsparse
#   thin
#   eagerzeroedthick
VMDK_CLONE_FORMAT='zeroedthick'

# If to email the log
# 1 for 'yes', 0 for 'no'
EMAIL_LOG=1

# Own hostname, defaults to $(hostname -s) if not set
EMAIL_SELFHOST=

# Email SMTP server
EMAIL_SERVER=10.1.2.3

# Email SMTP server port
EMAIL_SERVER_PORT=25

# Email SMTP username
EMAIL_USER_NAME=

# Email SMTP password
EMAIL_USER_PASS=

# Email FROM
EMAIL_FROM="esxi-vm-backup@${EMAIL_SELFHOST}"

# Comma separated list of receiving email addresses
EMAIL_TO=

# Comma separated list of additional receiving email addresses if status is not "OK"
EMAIL_ERRORS_TO=

# Email Delay Interval from NC (netcat) - default 1
EMAIL_RETRY_PAUSE=1

###################################################
#                                                 #
#             Internal state variables            #
#                                                 #
###################################################

RUN_TIMESTAMP="$(date +%Y.%m.%d-%H.%M.%S)"

#

LOG_FILE=
LOG_FILE_CRLF=
LOG_VERBOSE=0

#

VIM_CMD=
VMKFSTOOLS=
NC_BIN=
SSH='ssh'
TAR='tar'

ESX_VERSION=
ESX_RELEASE=

ESX4_OR_NEWER=0
ESX5_OR_NEWER=0

NEW_VIMCMD_SNAPSHOT=
ADAPTERTYPE_DEPRECATED=

VMSVC_GETALLVMS=

#

JUST_LIST_VMS=0

VM_LIST=''
BACKUP_ALL=0

VM_ID=
VM_VOLUME=
VM_PATH=
VMX_FILE=
VM_NVRAM_FILE=
VM_VMDKS=
VM_VMDKS_SIZE=
VM_VMDKS_INDEP=
VM_POWER=
VM_SNAPSHOT=
VM_POWERED_DOWN=

VM_BACKUP_PATH=
VM_ERROR=

VM_OK=0
VM_FAILED=0

EXIT_CODE=123

# Code uses nested "for ( .. in .. )" loops, each using
# its own separator list and we also launch external
# commands from these loops. To keep things tidy, here
# is a little helper api to save and restore current 
# IFS value pre- and post-loop respectively.

IFS_DEFAULT="$IFS"
IFS_STACK_POS=0

ifs_push() {
    case $IFS_STACK_POS in
    0) IFS_STACK_0="$IFS"; IFS_STACK_POS=1 ;;
    1) IFS_STACK_1="$IFS"; IFS_STACK_POS=2 ;;
    2) IFS_STACK_2="$IFS"; IFS_STACK_POS=3 ;;
    3) IFS_STACK_3="$IFS"; IFS_STACK_POS=4 ;;
    4) IFS_STACK_4="$IFS"; IFS_STACK_POS=5 ;;
    *) echo 'ifs_push overflow'; exit 1234 ;;
    esac

    if [[ "$1" == "" ]] ; then IFS="$IFS_DEFAULT"; else IFS="$1"; fi
}

ifs_pop() {
    case $IFS_STACK_POS in
    0) echo 'ifs_pop underflow'; exit 1234 ;;
    1) IFS="$IFS_STACK_0"; IFS_STACK_POS=0 ;;
    2) IFS="$IFS_STACK_1"; IFS_STACK_POS=1 ;;
    3) IFS="$IFS_STACK_2"; IFS_STACK_POS=2 ;;
    4) IFS="$IFS_STACK_3"; IFS_STACK_POS=3 ;;
    5) IFS="$IFS_STACK_4"; IFS_STACK_POS=4 ;;
    *) echo 'ifs_pop anomaly'; exit 1234
    esac
}

###################################################
#                                                 #
#                     Basics                      #
#                                                 #
###################################################

syntax() {

    echo "Syntax: $(basename $0) [-c config] [-m vm-name] [-a] [-l] [-v]"
    echo
    echo "   -c     File with overrides for config options"
    echo "   -m     Backup VM with specified name (can be repeated)"
    echo "   -a     Backup all VMs on this host (overrides -m)"
    echo "   -l     List all VMs on this host (overrides -m and -a)"
    echo "   -v     Verbose logging"
    echo
    echo "Based on ghettoVCB by William Lam, https://github.com/lamw/ghettoVCB"
    echo "Reworked by Alexander Pankratov, https://github.com/apankrat/esxi-vm-backup"
    echo
    exit 1
}

logger() {

    LOG_TYPE=$1
    MSG="$2"

    if [[ ${LOG_TYPE} == 'debug' ]] && [[ ${LOG_VERBOSE} -ne 1 ]] ; then
        return
    fi

    LEVEL=$(printf "%-5s" ${LOG_TYPE})
    PID=$(printf "%5s" $$)
    FULL="$(date +%F" "%H:%M:%S) | ${PID} | ${LEVEL} | ${MSG}"

    echo -e "${FULL}"

    if [ -f "${LOG_FILE}" ] ; then
        echo -e "${FULL}" >> "${LOG_FILE}"
    fi

    if [ -f "${LOG_FILE_CRLF}" ] ; then
        echo -en "${FULL}\r\n" >> "${LOG_FILE_CRLF}"
    fi
}

calc_elapsed() {

    NOW=$(date +%s)
    SEC=$(echo $((NOW - $1)))

    SS=$(printf "%02d" $((SEC % 60)))
    MM=$(printf "%02d" $((SEC / 60 % 60)))
    HH=$(printf "%02d" $((SEC / 3600)))
    ELAPSED="$HH:$MM:$SS"
}

###################################################
#                                                 #
#                  Startup code                   #
#                                                 #
###################################################

check_if_root() {

    if [[ $(env | grep -e "^USER=" | awk -F = '{print $2}') != "root" ]] ; then
        logger "error" "This script needs to be executed by \"root\""
        exit 1
    fi
}

load_config() {

    if [[ -z "${CONFIG_FILE}" ]] ; then
        return
    fi

    if [[ ! -f "${CONFIG_FILE}" ]] ; then
        logger "error" "Specified config file not found - ${CONFIG_FILE}"
        exit 1
    fi

    logger "debug" "Loading ${CONFIG_FILE} ..."
    source "${CONFIG_FILE}"
}

parse_args() {

    while getopts ":c:m:avlw:" ARG; do
        case $ARG in
        c)
            if [ -z "${OPTARG}" ] ; then
                logger "error" "-$ARG parameter is missing"
                exit 1
            fi

            if [ ! -f "${OPTARG}" ] ; then
                logger "error" "specified config file '${OPTARG}' not found"
                exit 1
            fi

            CONFIG_FILE="${OPTARG}"
            load_config
            ;;
        m)
            if [ -z "${OPTARG}" ] ; then
                logger "error" "-$ARG parameter is missing"
                exit 1
            fi

            VM_LIST=$(printf "${VM_LIST}\n${OPTARG}")

            logger "debug" "vm_list <- [${OPTARG}]"
            ;;

        a)  BACKUP_ALL=1
            logger "debug" "backup_all -> 1"
            ;;

        v)  LOG_VERBOSE=1
            logger "debug" "log_verbose -> 1"
            ;;

        l)  JUST_LIST_VMS=1
            logger "debug" "just_list_vms -> 1"
            ;;

        *)
            logger "error" "unrecognized argument -${ARG}"
            exit 1
            ;;
        esac
    done
    OPTIND=1
}

check_bool_flag() {

    if [[ "$1" != '0' ]] && [[ "$1" != '1' ]] ; then
        logger "error" "$2 setting is neither 0 nor 1"
        exit 1
    fi
}

check_config() {

    if [[ "${WORKDIR}" == '' ]] ; then
        logger "error" "WORKDIR is not specified -- can't proceed"
        exit 1
    fi

    if [[ "${REM_HOST}" == '' ]] || [[ "${REM_ROOT}" == '' ]] ; then
        logger "error" "REM_HOST, REM_ROOT not specified -- can't proceed"
        exit 1
    fi

    if [[ "${VM_LIST}" == '' ]] && [[ ${BACKUP_ALL} -ne 1 ]] && [[ ${JUST_LIST_VMS} -ne 1 ]] ; then
        logger "error" "No VM specified (-m) and no (-a) argument -- can't proceed"
        exit 1
    fi

    check_bool_flag  "${WORKDIR_KEEP}"         "WORKDIR_KEEP"
    check_bool_flag  "${VM_SNAPSHOT_ALWAYS}"   "VM_SNAPSHOT_ALWAYS"
    check_bool_flag  "${VM_SNAPSHOT_MEMORY}"   "VM_SNAPSHOT_MEMORY"
    check_bool_flag  "${VM_SNAPSHOT_QUIESCE}"  "VM_SNAPSHOT_QUIESCE"
    check_bool_flag  "${EMAIL_LOG}"            "EMAIL_LOG"
}

init_workdir() {

    if [[ "${WORKDIR}" == "/" ]] ; then
        logger "error" "workdir can be the root"
        exit 1
    fi

    WORKDIR_BASE=$(dirname "${WORKDIR}");

    if ! mkdir -p "${WORKDIR_BASE}"; then
        logger "error" "${WORKDIR_BASE} can't be created"
        exit 1
    fi

    if ! mkdir "${WORKDIR}" 2>/dev/null; then
        logger "error" "${WORKDIR} can't be created (already exists ?)"
        exit 1
    fi

    echo $$ > "${WORKDIR}/pid"

    trap 'clean_up ; exit 2' 1 2 3 13 15 # on non-clean exits
}

init_logger() {

    LOG_FILE="/tmp/vm-backup-${RUN_TIMESTAMP}.log"
    LOG_FILE_CRLF="${WORKDIR}/vm-backup-${RUN_TIMESTAMP}-crlf.log"

    touch "${LOG_FILE}"
    touch "${LOG_FILE_CRLF}"

    if ! touch ${LOG_FILE} 2>/dev/null ; then
        logger "error" "Failed to touch ${FOO} - file logging is switched off"
        LOG_FILE=
    fi

    logger "info" "=== New run ${RUN_TIMESTAMP} ==="

    logger "info" "logfile: ${LOG_FILE}"
    logger "info" "workdir: ${WORKDIR}"

    if [[ ${WORKDIR_KEEP} -eq 1 ]] ; then
        logger "info" "${WORKDIR} will ** not ** removed on exit"
    fi
}

init_api() {

    if [[ -f /usr/bin/vmware-vim-cmd ]] ; then
        VIM_CMD=/usr/bin/vmware-vim-cmd
        VMKFSTOOLS=/usr/sbin/vmkfstools
    elif [[ -f /bin/vim-cmd ]] ; then
        VIM_CMD=/bin/vim-cmd
        VMKFSTOOLS=/sbin/vmkfstools
    else
        logger "error" "Unable to locate ** vim-cmd **"
        exit 1
    fi

    if ${VMKFSTOOLS} 2>&1 -h | grep -F -e '--adaptertype' | grep -qF 'deprecated' || ! ${VMKFSTOOLS} 2>&1 -h | grep -F -e '--adaptertype'; then
        ADAPTERTYPE_DEPRECATED=1
    fi

    ESX_VERSION=$(vmware -v | awk '{print $3}')
    ESX_RELEASE=$(uname -r)

    ESX4_OR_NEWER=0
    ESX5_OR_NEWER=0

    case "${ESX_VERSION}" in
        7.0.0|7.0.1|7.0.2|7.0.3) ESX_VER_MAJOR=7; ESX4_OR_NEWER=1; ESX5_OR_NEWER=1 ;;
        6.0.0|6.5.0|6.7.0)       ESX_VER_MAJOR=6; ESX4_OR_NEWER=1; ESX5_OR_NEWER=1 ;;
        5.0.0|5.1.0|5.5.0)       ESX_VER_MAJOR=5; ESX4_OR_NEWER=1; ESX5_OR_NEWER=1 ;;
        4.0.0|4.1.0)             ESX_VER_MAJOR=4; ESX4_OR_NEWER=1; ;;
        3.5.0|3i)                ESX_VER_MAJOR=3; ;;
        *)                       logger "error" "Unsupported ESX/i version"; exit 1;
    esac

    NEW_VIMCMD_SNAPSHOT="no"
    ${VIM_CMD} vmsvc/snapshot.remove 2>&1 | grep -q "snapshotId"
    [[ $? -eq 0 ]] && NEW_VIMCMD_SNAPSHOT="yes"

#   # Enable multiextent VMkernel module if disk format is 2gbsparse (disabled by default in 5.1)
#
#   if [[ "${VMDK_CLONE_FORMAT}" == "2gbsparse" ]] && [[ ! -z "${ESX5_OR_NEWER}" ]] ; then
#       esxcli system module list | grep multiextent > /dev/null 2>&1
#       if [ $? -eq 1 ] ; then
#           logger "info" "multiextent VMkernel module is not loaded & is required for 2gbsparse, enabling ..."
#           esxcli system module load -m multiextent
#       fi
#   fi

    VMSVC_GETALLVMS="${WORKDIR}/vmsvc-getallvms"
    logger "debug" "${VIM_CMD} vmsvc/getallvms ..."
    ${VIM_CMD} vmsvc/getallvms | fgrep 'vmx-' > ${VMSVC_GETALLVMS}

    if [[ $? -ne 0 ]] ; then
        logger "error" "Failed to get the list of all VMs - can't proceed"
        exit 1
    fi
}

init_vm_list() {

    if [[ ${BACKUP_ALL} -eq 1 ]] || [[ ${JUST_LIST_VMS} -eq 1 ]] ; then
        VM_LIST=$( cat "${VMSVC_GETALLVMS}" | cut -c 4- | cut -d '[' -f 1 | sed 's/^ \+//g' | sed 's/ \+$//g' )
    fi
}

require_email_var() {

    if [[ -z "$1" ]] ; then
        logger "error" "Email alerts enabled but $2 is not set"
        exit 1
    fi
}

init_email() {

    if [[ ${EMAIL_LOG} -ne 1 ]] ; then
        return
    fi

    # sanity checks

    if [[ "$EMAIL_SELFHOST" == "" ]] ; then
        EMAIL_SELFHOST="$(hostname -s)"
    fi

    require_email_var  "${EMAIL_SELFHOST}"     "EMAIL_SELFHOST"
    require_email_var  "${EMAIL_SERVER}"       "EMAIL_SERVER"
    require_email_var  "${EMAIL_SERVER_PORT}"  "EMAIL_SERVER_PORT"
    require_email_var  "${EMAIL_FROM}"         "EMAIL_FROM"
    require_email_var  "${EMAIL_TO}"           "EMAIL_TO"

    # find nc

    if [[ -f /usr/bin/nc ]] || [[ -f /bin/nc ]] ; then
        if [[ -f /usr/bin/nc ]] ; then
            NC_BIN=/usr/bin/nc
        elif [[ -f /bin/nc ]] ; then
            NC_BIN=/bin/nc
        fi
    else
        logger "error" "Failed to find 'nc' - can't send emails"
        exit 1
    fi

    # check firewall

    if [[ ${ESX5_OR_NEWER} -eq 1 ]] ; then
        /sbin/esxcli network firewall ruleset rule list | awk -F'[ ]{2,}' '{print $5}' | grep "^${EMAIL_SERVER_PORT}$" > /dev/null 2>&1
        if [[ $? -ne 0 ]] ; then
            logger "error" "No firewall rule for email traffic on port ${EMAIL_SERVER_PORT} - can't send emails\n"
            exit 1
        fi
    fi
}

log_var() {

    KEY=$1
    VAL=$2
    if [[ "$VAL" == "" ]] ; then VAL='-'; fi
    WHAT=$(printf "  %-24s  %s" "$KEY" "$VAL")
    logger "debug" "$WHAT"
}

log_vm_list() {

    logger "debug" "vm_list"

    if [[ "${VM_LIST}" == '' ]] ; then
        logger "debug" "  <none> !"
        return
    fi

    if [[ ${BACKUP_ALL} -eq 1 ]] ; then
        logger "debug" "  <all>"
    fi

    if [[ "${VM_LIST}" != '' ]] ; then
        ifs_push $'\n'
        for VM_NAME in ${VM_LIST}; do
           logger "debug" "  * ${VM_NAME}";
        done
        ifs_pop
    fi
}

dump_setup() {

    if [[ ${LOG_VERBOSE} -ne 1 ]] ; then
        return
    fi

    logger  "debug" "--- Setup ---"

    log_var "config_file"             "${CONFIG_FILE}"
    log_var "workdir"                 "${WORKDIR}"
    log_var "workdir_keep"            "${WORKDIR_KEEP}"
    log_var "run_timestamp"           "${RUN_TIMESTAMP}"

    logger  "debug" "logging"
    log_var "log_file"                "${LOG_FILE}"
    log_var "verbose"                 "${LOG_VERBOSE}"

    logger  "debug" "esx"
    log_var "version"                 "${ESX_VERSION}"
    log_var "release"                 "${ESX_RELEASE}"

    log_vm_list

    logger  "debug" "target"
    log_var "rem_host"                "${REM_HOST}"
    log_var "rem_root"                "${REM_ROOT}"
    log_var "backup_rotations"        "${BACKUP_ROTATIONS}"

    logger  "debug" "power down"
    log_var "power_down_vms"          "${POWER_DOWN_VM}"
    log_var "power_down_hard_thresh"  "${POWER_DOWN_HARD_THRESHOLD}"
    log_var "power_down_timeout"      "${POWER_DOWN_TIMEOUT} min"

    logger  "debug" "snapshot"
    log_var "snapshot_always"         "${VM_SNAPSHOT_ALWAYS}"
    log_var "snapshot_memory"         "${VM_SNAPSHOT_MEMORY}"
    log_var "snapshot_quiesce"        "${VM_SNAPSHOT_QUIESCE}"
    log_var "snapshot_timeout"        "${VM_SNAPSHOT_TIMEOUT} min"

    logger  "debug" "cloning"
    log_var "vmdk_backup_format"      "${VMDK_CLONE_FORMAT}"

    logger  "debug" "email"
    log_var "enabled"                 "${EMAIL_LOG}"
    log_var "server"                  "${EMAIL_SERVER}"
    log_var "server port"             "${EMAIL_SERVER_PORT}"
    log_var "username"                "${EMAIL_USER_NAME}"
    log_var "password"                "${EMAIL_USER_PASS}"
    log_var "from"                    "${EMAIL_FROM}"
    log_var "to"                      "${EMAIL_TO}"
    log_var "to (errors)"             "${EMAIL_ERRORS_TO}"
    log_var "retry_pause"             "${EMAIL_RETRY_PAUSE}"

    logger  "debug" "internals"
    log_var "vim_cmd"                 "${VIM_CMD}"
    log_var "vmkfstools"              "${VMKFSTOOLS}"
    log_var "nc"                      "${NC_BIN}"
    log_var "new_vimcmd_snapshot"     "${NEW_VIMCMD_SNAPSHOT}"
    log_var "adaptertype_depricated"  "${ADAPTERTYPE_DEPRECATED}"

    logger  "debug" "--- End of the setup ---"
}

###################################################
#                                                 #
#                   Backup code                   #
#                                                 #
###################################################

mk_log_proxies() {

    if [[ ${LOG_VERBOSE} -eq 1 ]] ; then

        STDOUT_PROXY="/tmp/vm-backup-stdout-pipe.$$"
        rm -f "${STDOUT_PROXY}"
        mkfifo "${STDOUT_PROXY}"
        tee -a "${LOG_FILE}" < "${STDOUT_PROXY}" &
    else
        STDOUT_PROXY='/dev/null'
    fi

    STDERR_PROXY="/tmp/vm-backup-stderr-pipe.$$"
    rm -f "${STDERR_PROXY}"
    mkfifo "${STDERR_PROXY}"
    tee -a "${LOG_FILE}" < "${STDERR_PROXY}" >&2 &

    trap 'rm_log_proxies' 0
}

rm_log_proxies() {

    if [[ -f "${STDOUT_PROXY}" ]] && [[ "${STDOUT_PROXY}" != '/dev/null' ]] ; then
        rm "${STDOUT_PROXY}"
    fi

    if [[ -f "${STDERR_PROXY}" ]] ; then
        rm "${STDERR_PROXY}"
    fi
}

#

get_vm_id_by_name() {

    VM_ID=$( cat "${VMSVC_GETALLVMS}" | fgrep "${VM_NAME}" | cut -d ' ' -f 1 )
}

get_vmx_by_name() {

    VM_VOLUME=$( cat "${VMSVC_GETALLVMS}" | fgrep "${VM_NAME}" | cut -d '[' -f 2 | cut -d ']' -f 1 )
    _VMX_CONF=$( cat "${VMSVC_GETALLVMS}" | fgrep "${VM_NAME}" | cut -d ']' -f 2 | sed 's/^ \+//g' | sed -e 's/   .*$//' )

    VMX_FILE="/vmfs/volumes/${VM_VOLUME}/${_VMX_CONF}"
    VM_PATH=$(dirname "${VMX_FILE}")
}

vm_get_power_state() {

    VM_POWER=$( ${VIM_CMD} vmsvc/power.getstate ${VM_ID} | tail -1 )

    if [[ "${VM_POWER}" == '' ]] ; then
        logger "error" "vmsvc/power.getstate failed"
        VM_ERROR='vmsvc_power_getstate'
    fi
}

#

vm_power_off() {

#-- VM_POWERED_DOWN=0
#--
#-- START_ITERATION=0
#-- logger "info" "Powering off initiated for ${VM_NAME}, backup will not begin until VM is off..."
#--
#-- ${VIM_CMD} vmsvc/power.shutdown ${VM_ID} > /dev/null 2>&1
#-- while ${VIM_CMD} vmsvc/power.getstate ${VM_ID} | grep -i "Powered on" > /dev/null 2>&1; do
#--     #enable hard power off code
#--     if [[ "${POWER_DOWN_VM}" -eq 2 ]] ; then
#--         if [[ ${START_ITERATION} -ge ${POWER_DOWN_HARD_THRESHOLD} ]] ; then
#--             logger "info" "Hard power off occured for ${VM_NAME}, waited for $((POWER_DOWN_HARD_THRESHOLD*60)) seconds"
#--             ${VIM_CMD} vmsvc/power.off ${VM_ID} > /dev/null 2>&1
#--             #this is needed for ESXi, even the hard power off did not take affect right away
#--             sleep 60
#--             break
#--         fi
#--     fi
#--
#--     logger "info" "VM is still on - Iteration: ${START_ITERATION} - sleeping for 60secs (Duration: $((START_ITERATION*60)) seconds)"
#--     sleep 60
#--
#--     #logic to not backup this VM if unable to shutdown
#--     #after certain timeout period
#--     if [[ ${START_ITERATION} -ge ${POWER_DOWN_TIMEOUT} ]] ; then
#--         logger "info" "Unable to power off ${VM_NAME}, waited for $((POWER_DOWN_TIMEOUT*60)) seconds! Ignoring ${VM_NAME} for backup!"
#--         POWER_OFF_EC=1
#--         break
#--     fi
#--     START_ITERATION=$((START_ITERATION + 1))
#-- done
#-- if [[ ${POWER_OFF_EC} -eq 0 ]] ; then
#--     logger "info" "VM is powerdOff"
#-- fi
    echo '<vm_power_off>'
}

vm_power_on() {

#-- POWER_ON_EC=0
#--
#-- START_ITERATION=0
#-- logger "info" "Powering on initiated for ${VM_NAME}"
#--
#-- ${VIM_CMD} vmsvc/power.on ${VM_ID} > /dev/null 2>&1
#-- while ${VIM_CMD} vmsvc/get.guest ${VM_ID} | grep -i "toolsNotRunning" > /dev/null 2>&1; do
#--     logger "info" "VM is still not booted - Iteration: ${START_ITERATION} - sleeping for 60secs (Duration: $((START_ITERATION*60)) seconds)"
#--     sleep 60
#--
#--     #logic to not backup this VM if unable to shutdown
#--     #after certain timeout period
#--     if [[ ${START_ITERATION} -ge ${POWER_DOWN_TIMEOUT} ]] ; then
#--         logger "info" "Unable to detect started tools on ${VM_NAME}, waited for $((POWER_DOWN_TIMEOUT*60)) seconds!"
#--         POWER_ON_EC=1
#--         break
#--     fi
#--     START_ITERATION=$((START_ITERATION + 1))
#-- done
#-- if [[ ${POWER_ON_EC} -eq 0 ]] ; then
#--     logger "info" "VM is powerdOn"
#-- fi
    echo '<vm_power_on>'
}

###  vmdks  ###

get_vmdk_size() {

    VMDK_SECTORS=
    VMDK_SIZE=

    if [ -f "${VMDK_FILE}" ] ; then
        VMDK_SECTORS=$(cat "${VMDK_FILE}" 2> /dev/null | grep "VMFS" | grep ".vmdk" | awk '{ print $2 }')
        VMDK_SIZE=$(echo "${VMDK_SECTORS}" | awk '{printf "%.0f\n",$1*512/1024/1024/1024}')
    fi
}

vm_get_vmdks() {

    logger "info" "Listing vmdks ..."
    VMDK_LIST=$(grep -iE '(^scsi|^ide|^sata|^nvme)' "${VMX_FILE}" | grep -i fileName | awk -F . '{print $1}')

    VM_VMDKS=
    VM_VMDKS_SIZE=0
    VM_VMDKS_COUNT=0
    VM_VMDKS_INDEP=

    ifs_push $'\n'
    for VMDK_DEV_ID in ${VMDK_LIST}; do

        # e.g "ide1:0" or "scsi0:0"

        # get vmdk file
        VMDK_FILE=$(grep -i "^${VMDK_DEV_ID}.fileName" "${VMX_FILE}" | awk -F "\"" '{ print $2 }')

        if [[ "${VMDK_FILE}" == '' ]] ; then
            logger "error" "  ${VMDK_DEV_ID} -- skipped, no fileName"
            continue
        fi

        if [[ "${VMDK_FILE}" == 'emptyBackingString' ]] ; then
            logger "debug" "  ${VMDK_DEV_ID} -- skipped, fileName is emptyBackingString"
            continue
        fi

        # absolutize vmdk path
        echo "${VMDK_FILE}" | grep "\/vmfs\/volumes" > /dev/null 2>&1
        if [[ $? -ne 0 ]] ; then
            VMDK_FILE="${VM_PATH}/${VMDK_FILE}"
        fi

        # get size
        get_vmdk_size

        if [[ "${VMDK_SECTORS}" == '' ]] ; then
            logger "error" "  ${VMDK_DEV_ID} -- skipped, no size information"
            continue
        fi

        # check if present
        grep -i "^${VMDK_DEV_ID}.present" "${VMX_FILE}" | grep -i "true" > /dev/null 2>&1
        if [[ $? -ne 0 ]] ; then
            logger "info" "  ${VMDK_DEV_ID} -- skipped, not present, ${VMX_FILE}"
            continue
        fi

        # check if a physical RDM
        grep "vmfsPassthroughRawDeviceMap" "${VMX_FILE}" > /dev/null 2>&1
        if [[ $? -eq 0 ]] ; then
            logger "info" "  ${VMDK_DEV_ID} -- skipped, physical RDM, ${VMX_FILE}"
            continue
        fi

        # check if independent
        grep -i "^${VMDK_DEV_ID}.mode" "${VMX_FILE}" | grep -i "independent" > /dev/null 2>&1
        if [[ $? -eq 0 ]] ; then

            # independent - these disks are not affected by snapshots, hence they can not be backed up

            VM_VMDKS_INDEP="${VMDK_FILE}###${VMDK_SIZE}:${VM_VMDKS_INDEP}"

            logger "error" "  ${VMDK_DEV_ID} -- skipped, independent disk, ${DISK_SIZE} GB, ${VMDK_FILE}"
            continue
        fi

        # check if it's a scsi-disk
        grep -i "^${VMDK_DEV_ID}.deviceType" "${VMX_FILE}" | grep -i "scsi-hardDisk" > /dev/null 2>&1
        if [[ $? -eq 1 ]] ; then

            # not scsi

            # if the deviceType is NULL for IDE which it is, thanks for the inconsistency VMware
            # we'll do one more level of verification by checking to see if an ext. of .vmdk exists
            # since we can not rely on the deviceType showing "ide-hardDisk"
            grep -i "^${VMDK_DEV_ID}.fileName" "${VMX_FILE}" | grep -i ".vmdk" > /dev/null 2>&1
            if [[ $? -eq 1 ]] ; then

                logger "error" "  ${VMDK_DEV_ID} -- skipped, non-scsi disk without .vmdk, ${DISK_SIZE} GB, ${VMDK_FILE}"
                continue
            fi
        fi

        # all good

        VM_VMDKS="${VMDK_FILE}###${VMDK_SIZE}:${VM_VMDKS}"
        VM_VMDKS_SIZE=$((VM_VMDKS_SIZE+VMDK_SIZE))
        VM_VMDKS_COUNT=$((VM_VMDKS_COUNT+1))

        logger "info" "  ${VMDK_DEV_ID} -- included, ${VMDK_SIZE} GB, ${VMDK_FILE}"

    done
    ifs_pop

    logger "info" "  Total: ${VM_VMDKS_COUNT} vmdk(s), ${VM_VMDKS_SIZE} GB"
}

vm_create_snapshot() {

    VM_SNAPSHOT=
    VM_SNAPSHOT_NAME="vm-backup-snapshot-$(date +%F)"

    logger "info" "Creating snapshot - '${VM_SNAPSHOT_NAME}' ..."

    logger "debug" "  ${VIM_CMD} vmsvc/snapshot.create ${VM_ID} \"${VM_SNAPSHOT_NAME}\" \"\" \"${VM_SNAPSHOT_MEMORY}\" \"${VM_SNAPSHOT_QUIESCE}\""

    mk_log_proxies; ifs_push

    ${VIM_CMD} vmsvc/snapshot.create ${VM_ID} "${VM_SNAPSHOT_NAME}" "" "${VM_SNAPSHOT_MEMORY}" "${VM_SNAPSHOT_QUIESCE}" 1>"${STDOUT_PROXY}" 2>"${STDERR_PROXY}"
    RC=$?

    ifs_pop; rm_log_proxies

    if [[ $RC -ne 0 ]] ; then
        logger "error" "  vim-cmd failed with $RC"
        VM_ERROR='vm_snapshot'
        return
    fi

    logger "debug" "  RC $?, waiting for completion ..."

    CYCLE=0
    CYCLE_MAX=$((VM_SNAPSHOT_TIMEOUT * 12))
    while [[ $(${VIM_CMD} vmsvc/snapshot.get ${VM_ID} | wc -l) -eq 1 ]] ; do

        if [[ ${CYCLE} -ge ${CYCLE_MAX} ]] ; then
            logger "error" "  Timed out"
            VM_ERROR='vmsvc_snapshot_create'
            return
        fi

        CYCLE=$((CYCLE + 1))
        logger "debug" "  Waiting ... ${CYCLE} / ${CYCLE_MAX}"
        sleep 5
    done

    VM_SNAPSHOT='ok'
}

vm_delete_snapshot() {

    if [[ "${VM_SNAPSHOT}" != 'ok' ]] ; then
        return
    fi

    logger "info" "Removing snapshot - '${VM_SNAPSHOT_NAME}' ..."

    if [[ "${NEW_VIMCMD_SNAPSHOT}" == "yes" ]] ; then
        SNAPSHOT_ID=$( ${VIM_CMD} vmsvc/snapshot.get ${VM_ID} | grep -E '(Snapshot Name|Snapshot Id)' | grep -A1 ${VM_SNAPSHOT_NAME} | grep "Snapshot Id" | awk -F ":" '{print $2}' | sed -e 's/^[[:blank:]]*//;s/[[:blank:]]*$//' )
    else
        SNAPSHOT_ID=
    fi

    VM_SNAPSHOT=

    logger "debug" "  ${VIM_CMD} vmsvc/snapshot.remove ${VM_ID} ${SNAPSHOT_ID}"

    mk_log_proxies; ifs_push

    ${VIM_CMD} vmsvc/snapshot.remove ${VM_ID} ${SNAPSHOT_ID} 1>"${STDOUT_PROXY}" 2>"${STDERR_PROXY}"
    RC=$?

    ifs_pop; rm_log_proxies

    if [[ $RC -ne 0 ]] ; then
        logger "error" "  vim-cmd failed with $RC"
        VM_ERROR='vmsvc_snapshot_remove'
        return
    fi

    logger "debug" "  RC $?, waiting for completion ..."
    while ls "${VM_PATH}" | grep -q "\-delta\.vmdk"; do
        sleep 5
    done
}

###  cloning / copying  ###

#

vm_clone_vdmks() {

    VMDK_CLONE_ERROR=

    ifs_push ':'
    for VMDK_INFO in ${VM_VMDKS}; do

        VMDK=$(echo "${VMDK_INFO}" | awk -F "###" '{print $1}')

        logger "info" "Cloning ${VMDK} ..."

        # handle VMDK(s) stored in different datastore than the VM
#       echo ${VMDK} | grep "^/vmfs/volumes" > /dev/null 2>&1
#       if [[ $? -eq 0 ]] ; then
#           SOURCE_VMDK="${VMDK}"
#           DS_UUID="$(echo ${VMDK#/vmfs/volumes/*})"
#           DS_UUID="$(echo ${DS_UUID%/*/*})"
#           VMDK_DISK="$(echo ${VMDK##/*/})"
#           mkdir -p "${VM_BACKUP_DIR}/${DS_UUID}"
#           DESTINATION_VMDK="${VM_BACKUP_DIR}/${DS_UUID}/${VMDK_DISK}"
#       else
#           SOURCE_VMDK="${VMX_DIR}/${VMDK}"
#           DESTINATION_VMDK="${VM_BACKUP_DIR}/${VMDK}"
#       fi

        VMDK_SRC="${VMDK}"
        VMDK_DST="${VM_BACKUP_PATH}/${VMDK_SRC##*/}"

        ADAPTER_FORMAT=
        VMDK_FORMAT="?"

        if [[ "${VMDK_CLONE_FORMAT}" == "zeroedthick" ]] ; then
            if [[ ${ESX4_OR_NEWER} -eq 1 ]] ; then
                VMDK_FORMAT="-d zeroedthick"
            else
                VMDK_FORMAT=""
            fi
        elif [[ "${VMDK_CLONE_FORMAT}" == "2gbsparse" ]] ; then
            VMDK_FORMAT="-d 2gbsparse"
        elif [[ "${VMDK_CLONE_FORMAT}" == "thin" ]] ; then
            VMDK_FORMAT="-d thin"
        elif [[ "${VMDK_CLONE_FORMAT}" == "eagerzeroedthick" ]] ; then
            if [[ ${ESX4_OR_NEWER} -eq 1 ]] ; then
                VMDK_FORMAT="-d eagerzeroedthick"
            else
                VMDK_FORMAT=""
            fi
        fi

        if [[ "${VMDK_FORMAT}" == "?" ]] ; then
            logger "error" "  Don't have the format for the clone"
            VM_ERROR='select_vmdk_format'
            break
        fi

        # clone !

        [[ -z "${ADAPTERTYPE_DEPRECATED}" ]] && ADAPTER_FORMAT=$(grep -i "ddb.adapterType" "${VMDK_SRC}" | awk -F "=" '{ print $2 }' | sed -e 's/^[[:blank:]]*//;s/[[:blank:]]*$//;s/"//g')
        [[ -n "${ADAPTER_FORMAT}" ]] && ADAPTER_FORMAT="-a ${ADAPTER_FORMAT}"

        logger "debug" "  ${VMKFSTOOLS} -i \"${VMDK_SRC}\" ${ADAPTER_FORMAT} ${VMDK_FORMAT} \"${VMDK_DST}\""

        mk_log_proxies; ifs_push

        ${VMKFSTOOLS} -i "${VMDK_SRC}" ${ADAPTER_FORMAT} ${VMDK_FORMAT} "${VMDK_DST}" 1>"${STDOUT_PROXY}" 2>"${STDERR_PROXY}"
        RC=$?

        ifs_pop; rm_log_proxies

        if [[ $RC -ne 0 ]] ; then
            logger "error" "  vmkfstools failed with $RC"
            VM_ERROR='vmkfstools_i'
            break
        fi

    done
    ifs_pop
}

copy_to_remote() {

    REM_PATH="${REM_ROOT}/${VM_NAME}"
    REM_FILE="${REM_PATH}/${RUN_TIMESTAMP}"

    logger "info" "Creating [${REM_PATH}] on ${REM_HOST} ..."
    logger "debug" "  ${SSH} ${REM_HOST} mkdir -p \"${REM_PATH}\""

    ${SSH} ${REM_HOST} mkdir -p \"${REM_PATH}\"
    logger "info" "Copying ${VM_BACKUP_PATH} ..."
    logger "info" "  -> ${REM_HOST}:${REM_FILE}.tar"

    logger "debug" "  ${TAR} -C \"${VM_BACKUP_PATH}\" -cvf - . | ${SSH} ${REM_HOST} \"cat > \"${REM_FILE}.tar\"\""

    if [[ ${LOG_VERBOSE} -eq 1 ]] ; then
        ${TAR} -C "${VM_BACKUP_PATH}" -cvf - . | ${SSH} ${REM_HOST} "cat > \"${REM_FILE}.tar\" 2>>\"${LOG_FILE}\""
        RC=$?
    else
        ${TAR} -C "${VM_BACKUP_PATH}" -cf - . | ${SSH} ${REM_HOST} "cat > \"${REM_FILE}.tar\" 2>>\"${LOG_FILE}\""
        RC=$?
    fi

#   REM_PATH_ESCAPED=$( echo "$REM_PATH" | sed 's/ /\\ /g' )
#   logger "debug" "${SCP} -r \"$VM_BACKUP_PATH\" ${REM_HOST}:\"${REM_PATH_ESCAPED}.2\""
#   eval ${SCP} -r \"$VM_BACKUP_PATH\" ${REM_HOST}:\"${REM_PATH_ESCAPED}.2\"

#   0:34:32    time ${TAR} -C "${VM_BACKUP_PATH}" -cvf - . | ${SSH} ${REM_HOST} "gzip -9 > \"${REM_FILE}.tgz\""
#   0:35:00    time ${TAR} -C "${VM_BACKUP_PATH}" -cvf - . | ${SSH} -C ${REM_HOST} "gzip -9 > \"${REM_FILE}.tgz\""
#   1:17:20    time ${TAR} -C "${VM_BACKUP_PATH}" -cvzf - . | ${SSH} ${REM_HOST} "cat > \"${REM_FILE}.tgz\""
#   1:17:23    time ${TAR} -C "${VM_BACKUP_PATH}" -cvzf - . | ${SSH} -C ${REM_HOST} "cat > \"${REM_FILE}.tgz\""

    if [[ $RC -ne 0 ]] ; then
        logger "info" "  Copying failed with $RC\n"
        VM_ERROR='copy_to_remote'
    fi
}

remote_rotate() {

    RECENT=$(( BACKUP_ROTATIONS+1 ))
    REM_PATH_ESCAPED=$( echo "$REM_PATH" | sed 's/ /\\ /g' )

    logger "info" "Trimming backup set, keeping ${RECENT} most recent ..."

    ALL=$( ${SSH} ${REM_HOST} ls -t1 ${REM_PATH_ESCAPED}/*.tar )
    EXC=$( ${SSH} ${REM_HOST} ls -t1 ${REM_PATH_ESCAPED}/*.tar | head -n $RECENT )

    ifs_push $'\n'
    for TAR in ${ALL} ; do
        for PRECIOUS in ${EXC} ; do
            if [[ "${TAR}" == "${PRECIOUS}" ]] ; then
                logger "info" "  $(basename "$TAR") - kept"
                continue 2
            fi
        done

        logger "info" "  $(basename "$TAR") - removing ..."

        logger "debug" "  ${SSH} ${REM_HOST} rm \"${TAR}\""
        ${SSH} ${REM_HOST} rm \"${TAR}\"
    done
    ifs_pop

    return
}

###  vm_backup  ###

vm_backup_inner() {

    VM_ERROR=
    VM_ID=
    VM_VOLUME=
    VM_PATH=
    VMX_FILE=
    VM_NVRAM_FILE=
    VM_POWER=
    VM_VMDKS=
    VM_BACKUP_PATH=

    # name -> id
    get_vm_id_by_name
    if [[ "${VM_ID}" == '' ]] ; then
        logger "error" "Failed to determine VM's ID"
        VM_ERROR='get_vm_id_by_name'
        return
    fi

    # name -> path
    get_vmx_by_name
    if [[ "${VM_VOLUME}" == '' ]] || [[ "${VMX_FILE}" == '' ]] || [[ "${VM_PATH}" == '' ]] ; then
        logger "error" "Failed to determine VM location"
        VM_ERROR='get_vmx_by_name'
        return
    fi

    # nvram
    VM_NVRAM_FILE=$(grep "nvram" "${VMX_FILE}" | awk -F "\"" '{ print $2 }')

    logger "debug" "  vm.id       ${VM_ID}"
    logger "debug" "  vm.volume   ${VM_VOLUME}"
    logger "debug" "  vm.path     ${VM_PATH}"
    logger "debug" "  vm.vmx      ${VMX_FILE}"
    logger "debug" "  vm.nvram    ${VM_NVRAM_FILE}"

    # see if it's up
    vm_get_power_state

    [[ "${VM_ERROR}" != "" ]] && return

    logger "debug" "  vm.power    ${VM_POWER}"

    # check for snapshots
    if ls "${VM_PATH}" | grep -q "\-delta\.vmdk" > /dev/null 2>&1; then
        logger "error" "VM has a snapshot - can't proceed"
        VM_ERROR='check_for_snapshots'
        return
    fi

    # get vmdk list
    vm_get_vmdks # $VMX_FILE

    # create backup directory
    VM_BACKUP_PATH="${WORKDIR}/${VM_NAME}/${RUN_TIMESTAMP}"

    logger "info" "Creating directory - [${VM_BACKUP_PATH}] ..."
    if ! mkdir -p "${VM_BACKUP_PATH}"; then
        logger "error" "Failed"
        VM_ERROR='mkdir_vm_backup_path'
        return
    fi

    # power down the vm if specified
#   if [[ "${VM_POWER}" != "Powered off" ]] && [[ ${POWER_DOWN_VM} -ne 0 ]] ; then
#       vm_power_off
#       [[ "${VM_ERROR}" != "" ]] && return
#   fi

    # snapshot the vm if it's up
    if [[ "${VM_POWER}" != "Powered off" ]] || [[ ${VM_SNAPSHOT_ALWAYS} -eq 1 ]] ; then

        vm_create_snapshot

        [[ "${VM_ERROR}" != "" ]] && return
    fi

    # copy peanuts
    logger "info" "Copying vmx file ..."
    if ! cp "${VMX_FILE}" "${VM_BACKUP_PATH}"; then
        logger "error" "Failed"
        VM_ERROR='cp_vmx_file'
        return
    fi

    if [[ -f "${VM_NVRAM_FILE}" ]] ; then
        logger "info" "Copying nvram file ..."

        if ! cp "${VM_PATH}/${VM_NVRAM_FILE}" "${VM_BACKUP_PATH}"; then
            logger "error" "Failed"
            VM_ERROR='cp_nvram_file'
            return
        fi
    fi

    # clone disks
    vm_clone_vdmks
    [[ "${VM_ERROR}" != "" ]] && return

    #
    copy_to_remote
    [[ "${VM_ERROR}" != "" ]] && return

    #
    remote_rotate
    [[ "${VM_ERROR}" != "" ]] && return
}

vm_backup() {

    STARTED_VM_BACKUP=$(date +%s)

    logger "info" "--- Backing up [${VM_NAME}] ---"

    vm_backup_inner

    # remove local backup files unless keeping the workdir
    if [[ -d "${VM_BACKUP_PATH}" ]] && [[ "${WORKDIR_KEEP}" -ne 1 ]] ; then
        logger "debug" "Removing ${VM_BACKUP_PATH} ..."
        rm -rf "${VM_BACKUP_PATH}"
    fi

    # remove snapshot
    vm_delete_snapshot

    # power back up
#   if [[ ${VM_POWERED_DOWN} -eq 1 ]] ; then
#       vm_power_on
#       [[ "${VM_ERROR}" != "" ]] && return
#   fi

    calc_elapsed $STARTED_VM_BACKUP

    RESULT='Completed OK'
    [[ "$VM_ERROR" != "" ]] && RESULT='FAILED'

    logger "info" "--- End of backup of [${VM_NAME}] -- ${RESULT} in ${ELAPSED} ----"
}

backup_vms(){

    ifs_push $'\n'
    for VM_NAME in ${VM_LIST}; do

        vm_backup

        if [[ "${VM_ERROR}" == "" ]] ; then
            VM_OK=$((VM_OK+1))
        else
            VM_FAILED=$((VM_FAILED+1))
        fi
    done
    ifs_pop

    logger "info" "All backups are completed"
    logger "info" "  ${VM_OK} OK"
    logger "info" "  ${VM_FAILED} failed"

    if [[ $VM_FAILED != 0 ]] ; then
        EXIT_CODE=100
    else
        EXIT_CODE=0
    fi
}

###################################################
#                                                 #
#                   Email alerts                  #
#                                                 #
###################################################

prep_email_transcript() {

    EMAIL_ADDRESS=$1

    if [[ $VM_OK != 0 ]] && [[ $VM_FAILED == 0 ]] ; then
        EXEC_SUMMARY='backed up OK'
    elif [[ $VM_OK != 0 ]] && [[ $VM_FAILED != 0 ]] ; then
        EXEC_SUMMARY='some backups FAILED'
    elif [[ $VM_OK == 0 ]] && [[ $VM_FAILED != 0 ]] ; then
        EXEC_SUMMARY='all backups FAILED'
    else
        EXEC_SUMMARY='empty run, no VMs specified'
    fi

    EMAIL_TRANSCRIPT="${WORKDIR}/vm-backup-email-transcript-$$"

    echo -ne "HELO ${EMAIL_SELFHOST}\r\n" > "${EMAIL_TRANSCRIPT}"
    if [[ "${EMAIL_USER_NAME}" != "" ]] ; then
        echo -ne "EHLO ${EMAIL_SELFHOST}\r\n" >> "${EMAIL_TRANSCRIPT}"
        echo -ne "AUTH LOGIN\r\n" >> "${EMAIL_TRANSCRIPT}"
        echo -ne "$(echo -n "${EMAIL_USER_NAME}" | openssl base64 2>&1 | tail -1)\r\n" >> "${EMAIL_TRANSCRIPT}"
        echo -ne "$(echo -n "${EMAIL_USER_PASS}" | openssl base64 2>&1 | tail -1)\r\n" >> "${EMAIL_TRANSCRIPT}"
    fi

    echo -ne "MAIL FROM: <${EMAIL_FROM}>\r\n" >> "${EMAIL_TRANSCRIPT}"
    echo -ne "RCPT TO: <${EMAIL_ADDRESS}>\r\n" >> "${EMAIL_TRANSCRIPT}"
    echo -ne "DATA\r\n" >> "${EMAIL_TRANSCRIPT}"
    echo -ne "From: ${EMAIL_FROM}\r\n" >> "${EMAIL_TRANSCRIPT}"
    echo -ne "To: ${EMAIL_ADDRESS}\r\n" >> "${EMAIL_TRANSCRIPT}"
    echo -ne "Subject: vm-backup on ${EMAIL_SELFHOST} - ${EXEC_SUMMARY}\r\n" >> "${EMAIL_TRANSCRIPT}"
    echo -ne "Date: $( date +"%a, %d %b %Y %T %z" )\r\n" >> "${EMAIL_TRANSCRIPT}"
    echo -ne "Message-Id: <$( date -u +%Y%m%d%H%M%S ).$( dd if=/dev/urandom bs=6 count=1 2>/dev/null | hexdump -e '/1 "%02X"' )@${EMAIL_SELFHOST}>\r\n" >> "${EMAIL_TRANSCRIPT}"
    echo -ne "XMailer: vm-backup ${VERSION_STRING}\r\n" >> "${EMAIL_TRANSCRIPT}"
    echo -en "\r\n" >> "${EMAIL_TRANSCRIPT}"

    # append log
    cat "${LOG_FILE_CRLF}" >> "${EMAIL_TRANSCRIPT}"

    # close
    echo -en ".\r\n" >> "${EMAIL_TRANSCRIPT}"
    echo -en "QUIT\r\n" >> "${EMAIL_TRANSCRIPT}"
}

send_pause() {

    c=0;
    while read L; do
        [ $c -lt 4 ] && sleep ${EMAIL_RETRY_PAUSE}
        c=$((c+1))
        echo $L
    done
}

send_email_to() {

    logger "debug" "  to [$1] ..."

    prep_email_transcript $1
    cat "${EMAIL_TRANSCRIPT}" | send_pause | "${NC_BIN}" "${EMAIL_SERVER}" "${EMAIL_SERVER_PORT}" > /dev/null 2>&1
    #"${NC_BIN}" -i "${EMAIL_RETRY_PAUSE}" "${EMAIL_SERVER}" "${EMAIL_SERVER_PORT}" < "${EMAIL_LOG_CONTENT}" > /dev/null 2>&1
    if [[ $? -eq 1 ]] ; then
        logger "error" "  failed"
    fi
}

send_emails() {

    if [[ ${EMAIL_LOG} -ne 1 ]] ; then
        return
    fi

    logger "info" "Sending email..."
    logger "debug" "  via ${EMAIL_SERVER}:${EMAIL_SERVER_PORT}"

#-- #close email message
#-- if [[ "${EMAIL_LOG}" -eq 1 ]] || [[ "${EMAIL_ALERT}" -eq 1 ]] ; then
#--     SMTP=1
#--     #validate firewall has email port open for ESXi 5
#--     if [[ "${ESX_VER_MAJOR}" == "5" ]] || [[ "${ESX_VER_MAJOR}" == "6" ]] || [[ "${ESX_VER_MAJOR}" == "7" ]] ; then
#--         /sbin/esxcli network firewall ruleset rule list | awk -F'[ ]{2,}' '{print $5}' | grep "^${EMAIL_SERVER_PORT}$" > /dev/null 2>&1
#--         if [[ $? -eq 1 ]] ; then
#--             logger "info" "ERROR: Please enable firewall rule for email traffic on port ${EMAIL_SERVER_PORT}\n"
#--             logger "info" "Please refer to ghettoVCB documentation for ESXi 5 firewall configuration\n"
#--             SMTP=0
#--         fi
#--     fi
#-- fi

    if [ "${EMAIL_ERRORS_TO}" != "" ] && [[ ${VM_FAILED} != 0 ]] ; then
        if [ "${EMAIL_TO}" == "" ] ; then
            EMAIL_TO="${EMAIL_ERRORS_TO}"
        else
            EMAIL_TO="${EMAIL_TO},${EMAIL_ERRORS_TO}"
        fi
    fi

    ifs_push ','
    for i in ${EMAIL_TO}; do send_email_to ${i}; done
    ifs_pop
}

remove_workdir() {

    if [[ ${WORKDIR_KEEP} -ne 1 ]] ; then
        logger "debug" "Removing workdir..."
        rm -rf "${WORKDIR}"
    else
        logger "debug" "Workdir retained - ${WORKDIR}"
    fi
}

clean_up() {

    logger "debug" "--- Cleaning up ---"

    vm_delete_snapshot

    remove_workdir
}

###################################################
#                                                 #
#                   not backup                    #
#                                                 #
###################################################

just_list_vms() {

    if [[ ${JUST_LIST_VMS} -ne 1 ]] ; then
        return
    fi

    if [[ "${VM_LIST}" == "" ]] ; then
        logger "info" "** No VMs found **"
    else
        logger "info" "------+----------------------------------------"
        logger "info" "  ID  |  VM name"
        logger "info" "------+----------------------------------------"

        ifs_push $'\n'
        for VM_NAME in ${VM_LIST}; do
           get_vm_id_by_name
           logger "info" "$(printf "%4s" ${VM_ID})  |  ${VM_NAME}"
        done
        ifs_pop

        logger "info" "------+----------------------------------------"
    fi

    clean_up

    logger "info" "=== End of the run ===\n"

    exit 0
}

###################################################
#                                                 #
#                      main()                     #
#                                                 #
###################################################

STARTED_MAIN=$(date +%s)

if [ $# -lt 1 ] ; then syntax; fi # have args

check_if_root

load_config

parse_args "$@"

check_config

init_workdir

init_logger

init_api

init_vm_list  # if backing up all of them

just_list_vms # delay not

init_email

dump_setup

backup_vms

send_emails

clean_up

calc_elapsed $STARTED_MAIN

logger "info" "=== End of the run, elapsed ${ELAPSED}, exit code ${EXIT_CODE} ===\n"

exit $EXIT_CODE
