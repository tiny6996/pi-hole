#!/usr/bin/env bash
# shellcheck disable=SC1090

# Pi-hole: A black hole for Internet advertisements
# (c) 2017-2018 Pi-hole, LLC (https://pi-hole.net)
# Network-wide ad blocking via your own hardware.
#
# Installs and Updates Pi-hole
#
# This file is copyright under the latest version of the EUPL.
# Please see LICENSE file for your rights under this license.

# pi-hole.net/donate
#
# Install with this command (from your Linux machine):
#
# curl -sSL https://install.pi-hole.net | bash

# -e option instructs bash to immediately exit if any command [1] has a non-zero exit status
# We do not want users to end up with a partially working install, so we exit the script
# instead of continuing the installation with something broken
set -e

# Append common folders to the PATH to ensure that all basic commands are available.
# When using "su" an incomplete PATH could be passed: https://github.com/pi-hole/pi-hole/issues/3209
export PATH+=':/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

######## VARIABLES #########
# For better maintainability, we store as much information that can change in variables
# This allows us to make a change in one place that can propagate to all instances of the variable
# These variables should all be GLOBAL variables, written in CAPS
# Local variables will be in lowercase and will exist only within functions
# It's still a work in progress, so you may see some variance in this guideline until it is complete

# List of supported DNS servers
DNS_SERVERS=$(cat << EOM
Google (ECS);8.8.8.8;8.8.4.4;2001:4860:4860:0:0:0:0:8888;2001:4860:4860:0:0:0:0:8844
OpenDNS (ECS, DNSSEC);208.67.222.222;208.67.220.220;2620:119:35::35;2620:119:53::53
Level3;4.2.2.1;4.2.2.2;;
Comodo;8.26.56.26;8.20.247.20;;
DNS.WATCH;84.200.69.80;84.200.70.40;2001:1608:10:25:0:0:1c04:b12f;2001:1608:10:25:0:0:9249:d69b
Quad9 (filtered, DNSSEC);9.9.9.9;149.112.112.112;2620:fe::fe;2620:fe::9
Quad9 (unfiltered, no DNSSEC);9.9.9.10;149.112.112.10;2620:fe::10;2620:fe::fe:10
Quad9 (filtered + ECS);9.9.9.11;149.112.112.11;2620:fe::11;2620:fe::fe:11
Cloudflare;1.1.1.1;1.0.0.1;2606:4700:4700::1111;2606:4700:4700::1001
EOM
)

# Location for final installation log storage
installLogLoc=/etc/pihole/install.log
# This is an important file as it contains information specific to the machine it's being installed on
setupVars=/etc/pihole/setupVars.conf
# Pi-hole uses lighttpd as a Web server, and this is the config file for it
# shellcheck disable=SC2034
lighttpdConfig=/etc/lighttpd/lighttpd.conf
# This is a file used for the colorized output
coltable=/opt/pihole/COL_TABLE

# Root of the web server
webroot="/var/www/html"


# We clone (or update) two git repositories during the install. This helps to make sure that we always have the latest versions of the relevant files.
# AdminLTE is used to set up the Web admin interface.
# Pi-hole contains various setup scripts and files which are critical to the installation.
# Search for "PI_HOLE_LOCAL_REPO" in this file to see all such scripts.
# Two notable scripts are gravity.sh (used to generate the HOSTS file) and advanced/Scripts/webpage.sh (used to install the Web admin interface)
webInterfaceGitUrl="https://github.com/pi-hole/AdminLTE.git"
webInterfaceDir="${webroot}/admin"
piholeGitUrl="https://github.com/pi-hole/pi-hole.git"
PI_HOLE_LOCAL_REPO="/etc/.pihole"
# List of pihole scripts, stored in an array
PI_HOLE_FILES=(chronometer list piholeDebug piholeLogFlush setupLCD update version gravity uninstall webpage)
# This directory is where the Pi-hole scripts will be installed
PI_HOLE_INSTALL_DIR="/opt/pihole"
PI_HOLE_CONFIG_DIR="/etc/pihole"
PI_HOLE_BIN_DIR="/usr/local/bin"
PI_HOLE_BLOCKPAGE_DIR="${webroot}/pihole"
if [ -z "$useUpdateVars" ]; then
  useUpdateVars=false
fi

adlistFile="/etc/pihole/adlists.list"
# Pi-hole needs an IP address; to begin, these variables are empty since we don't know what the IP is until this script can run
IPV4_ADDRESS=${IPV4_ADDRESS}
IPV6_ADDRESS=${IPV6_ADDRESS}
# Give settings their default values. These may be changed by prompts later in the script.
QUERY_LOGGING=true
INSTALL_WEB_INTERFACE=true
PRIVACY_LEVEL=0
CACHE_SIZE=10000

if [ -z "${USER}" ]; then
  USER="$(id -un)"
fi

# whiptail dialog dimensions: 20 rows and 70 chars width assures to fit on small screens and is known to hold all content.
r=20
c=70

######## Undocumented Flags. Shhh ########
# These are undocumented flags; some of which we can use when repairing an installation
# The runUnattended flag is one example of this
reconfigure=false
runUnattended=false
INSTALL_WEB_SERVER=true
# Check arguments for the undocumented flags
for var in "$@"; do
    case "$var" in
        "--reconfigure" ) reconfigure=true;;
        "--unattended" ) runUnattended=true;;
        "--disable-install-webserver" ) INSTALL_WEB_SERVER=false;;
    esac
done

# If the color table file exists,
if [[ -f "${coltable}" ]]; then
    # source it
    source "${coltable}"
# Otherwise,
else
    # Set these values so the installer can still run in color
    COL_NC='\e[0m' # No Color
    COL_LIGHT_GREEN='\e[1;32m'
    COL_LIGHT_RED='\e[1;31m'
    TICK="[${COL_LIGHT_GREEN}✓${COL_NC}]"
    CROSS="[${COL_LIGHT_RED}✗${COL_NC}]"
    INFO="[i]"
    # shellcheck disable=SC2034
    DONE="${COL_LIGHT_GREEN} done!${COL_NC}"
    OVER="\\r\\033[K"
fi

# A simple function that just echoes out our logo in ASCII format
# This lets users know that it is a Pi-hole, LLC product
show_ascii_berry() {
  echo -e "
        ${COL_LIGHT_GREEN}.;;,.
        .ccccc:,.
         :cccclll:.      ..,,
          :ccccclll.   ;ooodc
           'ccll:;ll .oooodc
             .;cll.;;looo:.
                 ${COL_LIGHT_RED}.. ','.
                .',,,,,,'.
              .',,,,,,,,,,.
            .',,,,,,,,,,,,....
          ....''',,,,,,,'.......
        .........  ....  .........
        ..........      ..........
        ..........      ..........
        .........  ....  .........
          ........,,,,,,,'......
            ....',,,,,,,,,,,,.
               .',,,,,,,,,'.
                .',,,,,,'.
                  ..'''.${COL_NC}
"
}

is_command() {
    # Checks to see if the given command (passed as a string argument) exists on the system.
    # The function returns 0 (success) if the command exists, and 1 if it doesn't.
    local check_command="$1"

    command -v "${check_command}" >/dev/null 2>&1
}

os_check() {
    if [ "$PIHOLE_SKIP_OS_CHECK" != true ]; then
        # This function gets a list of supported OS versions from a TXT record at versions.pi-hole.net
        # and determines whether or not the script is running on one of those systems
        local remote_os_domain valid_os valid_version valid_response detected_os detected_version display_warning cmdResult digReturnCode response
        remote_os_domain=${OS_CHECK_DOMAIN_NAME:-"versions.pi-hole.net"}

        detected_os=$(grep "\bID\b" /etc/os-release | cut -d '=' -f2 | tr -d '"')
        detected_version=$(grep VERSION_ID /etc/os-release | cut -d '=' -f2 | tr -d '"')

        cmdResult="$(dig +short -t txt "${remote_os_domain}" @ns1.pi-hole.net 2>&1; echo $?)"
        # Gets the return code of the previous command (last line)
        digReturnCode="${cmdResult##*$'\n'}"

        if [ ! "${digReturnCode}" == "0" ]; then
            valid_response=false
        else
            # Dig returned 0 (success), so get the actual response, and loop through it to determine if the detected variables above are valid
            response="${cmdResult%%$'\n'*}"
            # If the value of ${response} is a single 0, then this is the return code, not an actual response.
            if [ "${response}" == 0 ]; then
                valid_response=false
            fi

            IFS=" " read -r -a supportedOS < <(echo "${response}" | tr -d '"')
            for distro_and_versions in "${supportedOS[@]}"
            do
                distro_part="${distro_and_versions%%=*}"
                versions_part="${distro_and_versions##*=}"

                # If the distro part is a (case-insensistive) substring of the computer OS
                if [[ "${detected_os^^}" =~ ${distro_part^^} ]]; then
                    valid_os=true
                    IFS="," read -r -a supportedVer <<<"${versions_part}"
                    for version in "${supportedVer[@]}"
                    do
                        if [[ "${detected_version}" =~ $version ]]; then
                            valid_version=true
                            break
                        fi
                    done
                    break
                fi
            done
        fi

        if [ "$valid_os" = true ] && [ "$valid_version" = true ] && [ ! "$valid_response" = false ]; then
            display_warning=false
        fi

        if [ "$display_warning" != false ]; then
            if [ "$valid_response" = false ]; then

                if [ "${digReturnCode}" -eq 0 ]; then
                    errStr="dig succeeded, but response was blank. Please contact support"
                else
                    errStr="dig failed with return code ${digReturnCode}"
                fi
                printf "  %b %bRetrieval of supported OS list failed. %s. %b\\n" "${CROSS}" "${COL_LIGHT_RED}" "${errStr}" "${COL_NC}"
                printf "      %bUnable to determine if the detected OS (%s %s) is supported%b\\n" "${COL_LIGHT_RED}" "${detected_os^}" "${detected_version}" "${COL_NC}"
                printf "      Possible causes for this include:\\n"
                printf "        - Firewall blocking certain DNS lookups from Pi-hole device\\n"
                printf "        - ns1.pi-hole.net being blocked (required to obtain TXT record from versions.pi-hole.net containing supported operating systems)\\n"
                printf "        - Other internet connectivity issues\\n"
            else
                printf "  %b %bUnsupported OS detected: %s %s%b\\n" "${CROSS}" "${COL_LIGHT_RED}" "${detected_os^}" "${detected_version}" "${COL_NC}"
                printf "      If you are seeing this message and you do have a supported OS, please contact support.\\n"
            fi
            printf "\\n"
            printf "      %bhttps://docs.pi-hole.net/main/prerequesites/#supported-operating-systems%b\\n" "${COL_LIGHT_GREEN}" "${COL_NC}"
            printf "\\n"
            printf "      If you wish to attempt to continue anyway, you can try one of the following commands to skip this check:\\n"
            printf "\\n"
            printf "      e.g: If you are seeing this message on a fresh install, you can run:\\n"
            printf "             %bcurl -sSL https://install.pi-hole.net | PIHOLE_SKIP_OS_CHECK=true sudo -E bash%b\\n" "${COL_LIGHT_GREEN}" "${COL_NC}"
            printf "\\n"
            printf "           If you are seeing this message after having run pihole -up:\\n"
            printf "             %bPIHOLE_SKIP_OS_CHECK=true sudo -E pihole -r%b\\n" "${COL_LIGHT_GREEN}" "${COL_NC}"
            printf "           (In this case, your previous run of pihole -up will have already updated the local repository)\\n"
            printf "\\n"
            printf "      It is possible that the installation will still fail at this stage due to an unsupported configuration.\\n"
            printf "      If that is the case, you can feel free to ask the community on Discourse with the %bCommunity Help%b category:\\n" "${COL_LIGHT_RED}" "${COL_NC}"
            printf "      %bhttps://discourse.pi-hole.net/c/bugs-problems-issues/community-help/%b\\n" "${COL_LIGHT_GREEN}" "${COL_NC}"
            printf "\\n"
            exit 1

        else
            printf "  %b %bSupported OS detected%b\\n" "${TICK}" "${COL_LIGHT_GREEN}" "${COL_NC}"
        fi
    else
        printf "  %b %bPIHOLE_SKIP_OS_CHECK env variable set to true - installer will continue%b\\n" "${INFO}" "${COL_LIGHT_GREEN}" "${COL_NC}"
    fi
}

# Compatibility
package_manager_detect() {
# If apt-get is installed, then we know it's part of the Debian family
if is_command apt-get ; then
    # Set some global variables here
    # We don't set them earlier since the family might be Red Hat, so these values would be different
    PKG_MANAGER="apt-get"
    # A variable to store the command used to update the package cache
    UPDATE_PKG_CACHE="${PKG_MANAGER} update"
    # The command we will use to actually install packages
    PKG_INSTALL=("${PKG_MANAGER}" -qq --no-install-recommends install)
    # grep -c will return 1 if there are no matches. This is an acceptable condition, so we OR TRUE to prevent set -e exiting the script.
    PKG_COUNT="${PKG_MANAGER} -s -o Debug::NoLocking=true upgrade | grep -c ^Inst || true"
    # Update package cache. This is required already here to assure apt-cache calls have package lists available.
    update_package_cache || exit 1
    # Debian 7 doesn't have iproute2 so check if it's available first
    if apt-cache show iproute2 > /dev/null 2>&1; then
        iproute_pkg="iproute2"
    # Otherwise, check if iproute is available
    elif apt-cache show iproute > /dev/null 2>&1; then
        iproute_pkg="iproute"
    # Else print error and exit
    else
        printf "  %b Aborting installation: iproute2 and iproute packages were not found in APT repository.\\n" "${CROSS}"
        exit 1
    fi
    # Check for and determine version number (major and minor) of current php install
    if is_command php ; then
        printf "  %b Existing PHP installation detected : PHP version %s\\n" "${INFO}" "$(php <<< "<?php echo PHP_VERSION ?>")"
        printf -v phpInsMajor "%d" "$(php <<< "<?php echo PHP_MAJOR_VERSION ?>")"
        printf -v phpInsMinor "%d" "$(php <<< "<?php echo PHP_MINOR_VERSION ?>")"
        # Is installed php version 7.0 or greater
        if [ "${phpInsMajor}" -ge 7 ]; then
            phpInsNewer=true
        fi
    fi
    # Several other packages depend on the version of PHP. If PHP is not installed, or an insufficient version,
    # those packages should fall back to the default (latest?)
    if [[ "$phpInsNewer" != true ]]; then
        # Prefer the php metapackage if it's there
        if apt-cache show php > /dev/null 2>&1; then
            phpVer="php"
        # Else fall back on the php5 package if it's there
        elif apt-cache show php5 > /dev/null 2>&1; then
            phpVer="php5"
        # Else print error and exit
        else
            printf "  %b Aborting installation: No PHP packages were found in APT repository.\\n" "${CROSS}"
            exit 1
        fi
    else
        # Else, PHP is already installed at a version beyond v7.0, so the additional packages
        # should match version with the current PHP version.
        phpVer="php$phpInsMajor.$phpInsMinor"
    fi
    # We also need the correct version for `php-sqlite` (which differs across distros)
    if apt-cache show "${phpVer}-sqlite3" > /dev/null 2>&1; then
        phpSqlite="sqlite3"
    elif apt-cache show "${phpVer}-sqlite" > /dev/null 2>&1; then
        phpSqlite="sqlite"
    else
        printf "  %b Aborting installation: No SQLite PHP module was found in APT repository.\\n" "${CROSS}"
        exit 1
    fi
    # Packages required to perfom the os_check (stored as an array)
    OS_CHECK_DEPS=(grep dnsutils)
    # Packages required to run this install script (stored as an array)
    INSTALLER_DEPS=(git "${iproute_pkg}" whiptail ca-certificates)
    # Packages required to run Pi-hole (stored as an array)
    PIHOLE_DEPS=(cron curl iputils-ping lsof netcat psmisc sudo unzip idn2 sqlite3 libcap2-bin dns-root-data libcap2)
    # Packages required for the Web admin interface (stored as an array)
    # It's useful to separate this from Pi-hole, since the two repos are also setup separately
    PIHOLE_WEB_DEPS=(lighttpd "${phpVer}-common" "${phpVer}-cgi" "${phpVer}-${phpSqlite}" "${phpVer}-xml" "${phpVer}-intl")
    # Prior to PHP8.0, JSON functionality is provided as dedicated module, required by Pi-hole AdminLTE: https://www.php.net/manual/json.installation.php
    if [[ "${phpInsNewer}" != true || "${phpInsMajor}" -lt 8 ]]; then
        PIHOLE_WEB_DEPS+=("${phpVer}-json")
    fi
    # The Web server user,
    LIGHTTPD_USER="www-data"
    # group,
    LIGHTTPD_GROUP="www-data"
    # and config file
    LIGHTTPD_CFG="lighttpd.conf.debian"

    # This function waits for dpkg to unlock, which signals that the previous apt-get command has finished.
    test_dpkg_lock() {
        i=0
        # fuser is a program to show which processes use the named files, sockets, or filesystems
        # So while the lock is held,
        while fuser /var/lib/dpkg/lock >/dev/null 2>&1
        do
            # we wait half a second,
            sleep 0.5
            # increase the iterator,
            ((i=i+1))
        done
        # and then report success once dpkg is unlocked.
        return 0
    }

# If apt-get is not found, check for rpm to see if it's a Red Hat family OS
elif is_command rpm ; then
    # Then check if dnf or yum is the package manager
    if is_command dnf ; then
        PKG_MANAGER="dnf"
    else
        PKG_MANAGER="yum"
    fi

    # These variable names match the ones in the Debian family. See above for an explanation of what they are for.
    PKG_INSTALL=("${PKG_MANAGER}" install -y)
    PKG_COUNT="${PKG_MANAGER} check-update | egrep '(.i686|.x86|.noarch|.arm|.src)' | wc -l"
    OS_CHECK_DEPS=(grep bind-utils)
    INSTALLER_DEPS=(git iproute newt procps-ng which chkconfig ca-certificates)
    PIHOLE_DEPS=(cronie curl findutils nmap-ncat sudo unzip libidn2 psmisc sqlite libcap lsof)
    PIHOLE_WEB_DEPS=(lighttpd lighttpd-fastcgi php-common php-cli php-pdo php-xml php-json php-intl)
    LIGHTTPD_USER="lighttpd"
    LIGHTTPD_GROUP="lighttpd"
    LIGHTTPD_CFG="lighttpd.conf.fedora"

# If neither apt-get or yum/dnf package managers were found
else
    # it's not an OS we can support,
    printf "  %b OS distribution not supported\\n" "${CROSS}"
    # so exit the installer
    exit
fi
}

select_rpm_php(){
# If the host OS is Fedora,
if grep -qiE 'fedora|fedberry' /etc/redhat-release; then
    # all required packages should be available by default with the latest fedora release
    : # continue
# or if host OS is CentOS,
elif grep -qiE 'centos|scientific|alma' /etc/redhat-release; then
    # Pi-Hole currently supports CentOS 7+ with PHP7+
    SUPPORTED_CENTOS_VERSION=7
    SUPPORTED_CENTOS_PHP_VERSION=7
    # Check current CentOS major release version
    CURRENT_CENTOS_VERSION=$(grep -oP '(?<= )[0-9]+(?=\.?)' /etc/redhat-release)
    # Check if CentOS version is supported
    if [[ $CURRENT_CENTOS_VERSION -lt $SUPPORTED_CENTOS_VERSION ]]; then
        printf "  %b CentOS %s is not supported.\\n" "${CROSS}" "${CURRENT_CENTOS_VERSION}"
        printf "      Please update to CentOS release %s or later.\\n" "${SUPPORTED_CENTOS_VERSION}"
        # exit the installer
        exit
    fi
    # php-json is not required on CentOS 7 as it is already compiled into php
    # verifiy via `php -m | grep json`
    if [[ $CURRENT_CENTOS_VERSION -eq 7 ]]; then
        # create a temporary array as arrays are not designed for use as mutable data structures
        CENTOS7_PIHOLE_WEB_DEPS=()
        for i in "${!PIHOLE_WEB_DEPS[@]}"; do
            if [[ ${PIHOLE_WEB_DEPS[i]} != "php-json" ]]; then
                CENTOS7_PIHOLE_WEB_DEPS+=( "${PIHOLE_WEB_DEPS[i]}" )
            fi
        done
        # re-assign the clean dependency array back to PIHOLE_WEB_DEPS
        PIHOLE_WEB_DEPS=("${CENTOS7_PIHOLE_WEB_DEPS[@]}")
        unset CENTOS7_PIHOLE_WEB_DEPS
    fi
    # CentOS requires the EPEL repository to gain access to Fedora packages
    EPEL_PKG="epel-release"
    rpm -q ${EPEL_PKG} &> /dev/null || rc=$?
    if [[ $rc -ne 0 ]]; then
        printf "  %b Enabling EPEL package repository (https://fedoraproject.org/wiki/EPEL)\\n" "${INFO}"
        "${PKG_INSTALL[@]}" ${EPEL_PKG} &> /dev/null
        printf "  %b Installed %s\\n" "${TICK}" "${EPEL_PKG}"
    fi

    # The default php on CentOS 7.x is 5.4 which is EOL
    # Check if the version of PHP available via installed repositories is >= to PHP 7
    AVAILABLE_PHP_VERSION=$("${PKG_MANAGER}" info php | grep -i version | grep -o '[0-9]\+' | head -1)
    if [[ $AVAILABLE_PHP_VERSION -ge $SUPPORTED_CENTOS_PHP_VERSION ]]; then
        # Since PHP 7 is available by default, install via default PHP package names
        : # do nothing as PHP is current
    else
        REMI_PKG="remi-release"
        REMI_REPO="remi-php72"
        rpm -q ${REMI_PKG} &> /dev/null || rc=$?
    if [[ $rc -ne 0 ]]; then
        # The PHP version available via default repositories is older than version 7
        if ! whiptail --defaultno --title "PHP 7 Update (recommended)" --yesno "PHP 7.x is recommended for both security and language features.\\nWould you like to install PHP7 via Remi's RPM repository?\\n\\nSee: https://rpms.remirepo.net for more information" "${r}" "${c}"; then
            # User decided to NOT update PHP from REMI, attempt to install the default available PHP version
            printf "  %b User opt-out of PHP 7 upgrade on CentOS. Deprecated PHP may be in use.\\n" "${INFO}"
            : # continue with unsupported php version
        else
            printf "  %b Enabling Remi's RPM repository (https://rpms.remirepo.net)\\n" "${INFO}"
            "${PKG_INSTALL[@]}" "https://rpms.remirepo.net/enterprise/${REMI_PKG}-$(rpm -E '%{rhel}').rpm" &> /dev/null
            # enable the PHP 7 repository via yum-config-manager (provided by yum-utils)
            "${PKG_INSTALL[@]}" "yum-utils" &> /dev/null
            yum-config-manager --enable ${REMI_REPO} &> /dev/null
            printf "  %b Remi's RPM repository has been enabled for PHP7\\n" "${TICK}"
            # trigger an install/update of PHP to ensure previous version of PHP is updated from REMI
            if "${PKG_INSTALL[@]}" "php-cli" &> /dev/null; then
                printf "  %b PHP7 installed/updated via Remi's RPM repository\\n" "${TICK}"
            else
                printf "  %b There was a problem updating to PHP7 via Remi's RPM repository\\n" "${CROSS}"
                exit 1
            fi
        fi
    fi    # Warn user of unsupported version of Fedora or CentOS
    if ! whiptail --defaultno --title "Unsupported RPM based distribution" --yesno "Would you like to continue installation on an unsupported RPM based distribution?\\n\\nPlease ensure the following packages have been installed manually:\\n\\n- lighttpd\\n- lighttpd-fastcgi\\n- PHP version 7+" "${r}" "${c}"; then
        printf "  %b Aborting installation due to unsupported RPM based distribution\\n" "${CROSS}"
        exit
    else
        printf "  %b Continuing installation with unsupported RPM based distribution\\n" "${INFO}"
    fi
fi
fi
}

# A function for checking if a directory is a git repository
is_repo() {
    # Use a named, local variable instead of the vague $1, which is the first argument passed to this function
    # These local variables should always be lowercase
    local directory="${1}"
    # A variable to store the return code
    local rc
    # If the first argument passed to this function is a directory,
    if [[ -d "${directory}" ]]; then
        # move into the directory
        pushd "${directory}" &> /dev/null || return 1
        # Use git to check if the directory is a repo
        # git -C is not used here to support git versions older than 1.8.4
        git status --short &> /dev/null || rc=$?
    # If the command was not successful,
    else
        # Set a non-zero return code if directory does not exist
        rc=1
    fi
    # Move back into the directory the user started in
    popd &> /dev/null || return 1
    # Return the code; if one is not set, return 0
    return "${rc:-0}"
}

# A function to clone a repo
make_repo() {
    # Set named variables for better readability
    local directory="${1}"
    local remoteRepo="${2}"

    # The message to display when this function is running
    str="Clone ${remoteRepo} into ${directory}"
    # Display the message and use the color table to preface the message with an "info" indicator
    printf "  %b %s..." "${INFO}" "${str}"
    # If the directory exists,
    if [[ -d "${directory}" ]]; then
        # Return with a 1 to exit the installer. We don't want to overwrite what could already be here in case it is not ours
        str="Unable to clone ${remoteRepo} into ${directory} : Directory already exists"
        printf "%b  %b%s\\n" "${OVER}" "${CROSS}" "${str}"
        return 1
    fi
    # Clone the repo and return the return code from this command
    git clone -q --depth 20 "${remoteRepo}" "${directory}" &> /dev/null || return $?
    # Move into the directory that was passed as an argument
    pushd "${directory}" &> /dev/null || return 1
    # Check current branch. If it is master, then reset to the latest available tag.
    # In case extra commits have been added after tagging/release (i.e in case of metadata updates/README.MD tweaks)
    curBranch=$(git rev-parse --abbrev-ref HEAD)
    if [[ "${curBranch}" == "master" ]]; then
        # If we're calling make_repo() then it should always be master, we may not need to check.
        git reset --hard "$(git describe --abbrev=0 --tags)" || return $?
    fi
    # Show a colored message showing it's status
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    # Data in the repositories is public anyway so we can make it readable by everyone (+r to keep executable permission if already set by git)
    chmod -R a+rX "${directory}"
    # Move back into the original directory
    popd &> /dev/null || return 1
    return 0
}

# We need to make sure the repos are up-to-date so we can effectively install Clean out the directory if it exists for git to clone into
update_repo() {
    # Use named, local variables
    # As you can see, these are the same variable names used in the last function,
    # but since they are local, their scope does not go beyond this function
    # This helps prevent the wrong value from being assigned if you were to set the variable as a GLOBAL one
    local directory="${1}"
    local curBranch

    # A variable to store the message we want to display;
    # Again, it's useful to store these in variables in case we need to reuse or change the message;
    # we only need to make one change here
    local str="Update repo in ${1}"
    # Move into the directory that was passed as an argument
    pushd "${directory}" &> /dev/null || return 1
    # Let the user know what's happening
    printf "  %b %s..." "${INFO}" "${str}"
    # Stash any local commits as they conflict with our working code
    git stash --all --quiet &> /dev/null || true # Okay for stash failure
    git clean --quiet --force -d || true # Okay for already clean directory
    # Pull the latest commits
    git pull --quiet &> /dev/null || return $?
    # Check current branch. If it is master, then reset to the latest available tag.
    # In case extra commits have been added after tagging/release (i.e in case of metadata updates/README.MD tweaks)
    curBranch=$(git rev-parse --abbrev-ref HEAD)
    if [[ "${curBranch}" == "master" ]]; then
         git reset --hard "$(git describe --abbrev=0 --tags)" || return $?
    fi
    # Show a completion message
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    # Data in the repositories is public anyway so we can make it readable by everyone (+r to keep executable permission if already set by git)
    chmod -R a+rX "${directory}"
    # Move back into the original directory
    popd &> /dev/null || return 1
    return 0
}

# A function that combines the previous git functions to update or clone a repo
getGitFiles() {
    # Setup named variables for the git repos
    # We need the directory
    local directory="${1}"
    # as well as the repo URL
    local remoteRepo="${2}"
    # A local variable containing the message to be displayed
    local str="Check for existing repository in ${1}"
    # Show the message
    printf "  %b %s..." "${INFO}" "${str}"
    # Check if the directory is a repository
    if is_repo "${directory}"; then
        # Show that we're checking it
        printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
        # Update the repo, returning an error message on failure
        update_repo "${directory}" || { printf "\\n  %b: Could not update local repository. Contact support.%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
    # If it's not a .git repo,
    else
        # Show an error
        printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
        # Attempt to make the repository, showing an error on failure
        make_repo "${directory}" "${remoteRepo}" || { printf "\\n  %bError: Could not update local repository. Contact support.%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
    fi
    echo ""
    # Success via one of the two branches, as the commands would exit if they failed.
    return 0
}

# Reset a repo to get rid of any local changed
resetRepo() {
    # Use named variables for arguments
    local directory="${1}"
    # Move into the directory
    pushd "${directory}" &> /dev/null || return 1
    # Store the message in a variable
    str="Resetting repository within ${1}..."
    # Show the message
    printf "  %b %s..." "${INFO}" "${str}"
    # Use git to remove the local changes
    git reset --hard &> /dev/null || return $?
    # Data in the repositories is public anyway so we can make it readable by everyone (+r to keep executable permission if already set by git)
    chmod -R a+rX "${directory}"
    # And show the status
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    # Return to where we came from
    popd &> /dev/null || return 1
    # Function succeeded, as "git reset" would have triggered a return earlier if it failed
    return 0
}

find_IPv4_information() {
    # Detects IPv4 address used for communication to WAN addresses.
    # Accepts no arguments, returns no values.

    # Named, local variables
    local route
    local IPv4bare

    # Find IP used to route to outside world by checking the the route to Google's public DNS server
    route=$(ip route get 8.8.8.8)

    # Get just the interface IPv4 address
    # shellcheck disable=SC2059,SC2086
    # disabled as we intentionally want to split on whitespace and have printf populate
    # the variable with just the first field.
    printf -v IPv4bare "$(printf ${route#*src })"
    # Get the default gateway IPv4 address (the way to reach the Internet)
    # shellcheck disable=SC2059,SC2086
    printf -v IPv4gw "$(printf ${route#*via })"

    if ! valid_ip "${IPv4bare}" ; then
        IPv4bare="127.0.0.1"
    fi

    # Append the CIDR notation to the IP address, if valid_ip fails this should return 127.0.0.1/8
    IPV4_ADDRESS=$(ip -oneline -family inet address show | grep "${IPv4bare}/" |  awk '{print $4}' | awk 'END {print}')
}

# Get available interfaces that are UP
get_available_interfaces() {
    # There may be more than one so it's all stored in a variable
    availableInterfaces=$(ip --oneline link show up | grep -v "lo" | awk '{print $2}' | cut -d':' -f1 | cut -d'@' -f1)
}

# A function for displaying the dialogs the user sees when first running the installer
welcomeDialogs() {
    # Display the welcome dialog using an appropriately sized window via the calculation conducted earlier in the script
    whiptail --msgbox --backtitle "Welcome" --title "Pi-hole automated installer" "\\n\\nThis installer will transform your device into a network-wide ad blocker!" "${r}" "${c}"

    # Request that users donate if they enjoy the software since we all work on it in our free time
    whiptail --msgbox --backtitle "Plea" --title "Free and open source" "\\n\\nThe Pi-hole is free, but powered by your donations:  https://pi-hole.net/donate/" "${r}" "${c}"

    # Explain the need for a static address
    if whiptail --defaultno --backtitle "Initiating network interface" --title "Static IP Needed" --yesno "\\n\\nThe Pi-hole is a SERVER so it needs a STATIC IP ADDRESS to function properly.

IMPORTANT: If you have not already done so, you must ensure that this device has a static IP. Either through DHCP reservation, or by manually assigning one. Depending on your operating system, there are many ways to achieve this.

Choose yes to indicate that you have understood this message, and wish to continue" "${r}" "${c}"; then
#Nothing to do, continue
  echo
else
  printf "  %b Installer exited at static IP message.\\n" "${INFO}"
  exit 1
fi
}

# A function that lets the user pick an interface to use with Pi-hole
chooseInterface() {
    # Turn the available interfaces into an array so it can be used with a whiptail dialog
    local interfacesArray=()
    # Number of available interfaces
    local interfaceCount
    # Whiptail variable storage
    local chooseInterfaceCmd
    # Temporary Whiptail options storage
    local chooseInterfaceOptions
    # Loop sentinel variable
    local firstLoop=1

    # Find out how many interfaces are available to choose from
    interfaceCount=$(wc -l <<< "${availableInterfaces}")

    # If there is one interface,
    if [[ "${interfaceCount}" -eq 1 ]]; then
        # Set it as the interface to use since there is no other option
        PIHOLE_INTERFACE="${availableInterfaces}"
    # Otherwise,
    else
        # While reading through the available interfaces
        while read -r line; do
            # Use a variable to set the option as OFF to begin with
            mode="OFF"
            # If it's the first loop,
            if [[ "${firstLoop}" -eq 1 ]]; then
                # set this as the interface to use (ON)
                firstLoop=0
                mode="ON"
            fi
            # Put all these interfaces into an array
            interfacesArray+=("${line}" "available" "${mode}")
        # Feed the available interfaces into this while loop
        done <<< "${availableInterfaces}"
        # The whiptail command that will be run, stored in a variable
        chooseInterfaceCmd=(whiptail --separate-output --radiolist "Choose An Interface (press space to toggle selection)" "${r}" "${c}" "${interfaceCount}")
        # Now run the command using the interfaces saved into the array
        chooseInterfaceOptions=$("${chooseInterfaceCmd[@]}" "${interfacesArray[@]}" 2>&1 >/dev/tty) || \
        # If the user chooses Cancel, exit
        { printf "  %bCancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
        # For each interface
        for desiredInterface in ${chooseInterfaceOptions}; do
            # Set the one the user selected as the interface to use
            PIHOLE_INTERFACE=${desiredInterface}
            # and show this information to the user
            printf "  %b Using interface: %s\\n" "${INFO}" "${PIHOLE_INTERFACE}"
        done
    fi
}

# This lets us prefer ULA addresses over GUA
# This caused problems for some users when their ISP changed their IPv6 addresses
# See https://github.com/pi-hole/pi-hole/issues/1473#issuecomment-301745953
testIPv6() {
    # first will contain fda2 (ULA)
    printf -v first "%s" "${1%%:*}"
    # value1 will contain 253 which is the decimal value corresponding to 0xFD
    value1=$(( (0x$first)/256 ))
    # value2 will contain 162 which is the decimal value corresponding to 0xA2
    value2=$(( (0x$first)%256 ))
    # the ULA test is testing for fc00::/7 according to RFC 4193
    if (( (value1&254)==252 )); then
        # echoing result to calling function as return value
        echo "ULA"
    fi
    # the GUA test is testing for 2000::/3 according to RFC 4291
    if (( (value1&112)==32 )); then
        # echoing result to calling function as return value
        echo "GUA"
    fi
    # the LL test is testing for fe80::/10 according to RFC 4193
    if (( (value1)==254 )) && (( (value2&192)==128 )); then
        # echoing result to calling function as return value
        echo "Link-local"
    fi
}

# A dialog for showing the user about IPv6 blocking
useIPv6dialog() {
    # Determine the IPv6 address used for blocking
    IPV6_ADDRESSES=($(ip -6 address | grep 'scope global' | awk '{print $2}'))

    # For each address in the array above, determine the type of IPv6 address it is
    for i in "${IPV6_ADDRESSES[@]}"; do
        # Check if it's ULA, GUA, or LL by using the function created earlier
        result=$(testIPv6 "$i")
        # If it's a ULA address, use it and store it as a global variable
        [[ "${result}" == "ULA" ]] && ULA_ADDRESS="${i%/*}"
        # If it's a GUA address, use it and store it as a global variable
        [[ "${result}" == "GUA" ]] && GUA_ADDRESS="${i%/*}"
        # Else if it's a Link-local address, we cannot use it, so just continue
    done

    # Determine which address to be used: Prefer ULA over GUA or don't use any if none found
    # If the ULA_ADDRESS contains a value,
    if [[ ! -z "${ULA_ADDRESS}" ]]; then
        # set the IPv6 address to the ULA address
        IPV6_ADDRESS="${ULA_ADDRESS}"
        # Show this info to the user
        printf "  %b Found IPv6 ULA address, using it for blocking IPv6 ads\\n" "${INFO}"
    # Otherwise, if the GUA_ADDRESS has a value,
    elif [[ ! -z "${GUA_ADDRESS}" ]]; then
        # Let the user know
        printf "  %b Found IPv6 GUA address, using it for blocking IPv6 ads\\n" "${INFO}"
        # And assign it to the global variable
        IPV6_ADDRESS="${GUA_ADDRESS}"
    # If none of those work,
    else
        # explain that IPv6 blocking will not be used
        printf "  %b Unable to find IPv6 ULA/GUA address, IPv6 adblocking will not be enabled\\n" "${INFO}"
        # So set the variable to be empty
        IPV6_ADDRESS=""
    fi

    # If the IPV6_ADDRESS contains a value
    if [[ ! -z "${IPV6_ADDRESS}" ]]; then
        # Display that IPv6 is supported and will be used
        whiptail --msgbox --backtitle "IPv6..." --title "IPv6 Supported" "$IPV6_ADDRESS will be used to block ads." "${r}" "${c}"
    fi
}

# A function to check if we should use IPv4 and/or IPv6 for blocking ads
use4andor6() {
    # Named local variables
    local useIPv4
    local useIPv6
    # Let user choose IPv4 and/or IPv6 via a checklist
    cmd=(whiptail --separate-output --checklist "Select Protocols (press space to toggle selection)" "${r}" "${c}" 2)
    # In an array, show the options available:
    # IPv4 (on by default)
    options=(IPv4 "Block ads over IPv4" on
    # or IPv6 (on by default if available)
    IPv6 "Block ads over IPv6" on)
    # In a variable, show the choices available; exit if Cancel is selected
    choices=$("${cmd[@]}" "${options[@]}" 2>&1 >/dev/tty) || { printf "  %bCancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
    # For each choice available,
    for choice in ${choices}
    do
        # Set the values to true
        case ${choice} in
        IPv4  )   useIPv4=true;;
        IPv6  )   useIPv6=true;;
        esac
    done
    # If IPv4 is to be used,
    if [[ "${useIPv4}" ]]; then
        # Run our function to get the information we need
        find_IPv4_information
        if [[ -f "/etc/dhcpcd.conf" ]]; then
            # configure networking via dhcpcd
            getStaticIPv4Settings
            setDHCPCD
        fi
    fi
    # If IPv6 is to be used,
    if [[ "${useIPv6}" ]]; then
        # Run our function to get this information
        useIPv6dialog
    fi
    # Echo the information to the user
    printf "  %b IPv4 address: %s\\n" "${INFO}" "${IPV4_ADDRESS}"
    printf "  %b IPv6 address: %s\\n" "${INFO}" "${IPV6_ADDRESS}"
    # If neither protocol is selected,
    if [[ ! "${useIPv4}" ]] && [[ ! "${useIPv6}" ]]; then
        # Show an error in red
        printf "  %bError: Neither IPv4 or IPv6 selected%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"
        # and exit with an error
        exit 1
    fi
}

getStaticIPv4Settings() {
    # Local, named variables
    local ipSettingsCorrect
    # Ask if the user wants to use DHCP settings as their static IP
    # This is useful for users that are using DHCP reservations; then we can just use the information gathered via our functions
    if whiptail --backtitle "Calibrating network interface" --title "Static IP Address" --yesno "Do you want to use your current network settings as a static address?
          IP address:    ${IPV4_ADDRESS}
          Gateway:       ${IPv4gw}" "${r}" "${c}"; then
        # If they choose yes, let the user know that the IP address will not be available via DHCP and may cause a conflict.
        whiptail --msgbox --backtitle "IP information" --title "FYI: IP Conflict" "It is possible your router could still try to assign this IP to a device, which would cause a conflict.  But in most cases the router is smart enough to not do that.
If you are worried, either manually set the address, or modify the DHCP reservation pool so it does not include the IP you want.
It is also possible to use a DHCP reservation, but if you are going to do that, you might as well set a static address." "${r}" "${c}"
    # Nothing else to do since the variables are already set above
    else
    # Otherwise, we need to ask the user to input their desired settings.
    # Start by getting the IPv4 address (pre-filling it with info gathered from DHCP)
    # Start a loop to let the user enter their information with the chance to go back and edit it if necessary
    until [[ "${ipSettingsCorrect}" = True ]]; do

        # Ask for the IPv4 address
        IPV4_ADDRESS=$(whiptail --backtitle "Calibrating network interface" --title "IPv4 address" --inputbox "Enter your desired IPv4 address" "${r}" "${c}" "${IPV4_ADDRESS}" 3>&1 1>&2 2>&3) || \
        # Canceling IPv4 settings window
        { ipSettingsCorrect=False; echo -e "  ${COL_LIGHT_RED}Cancel was selected, exiting installer${COL_NC}"; exit 1; }
        printf "  %b Your static IPv4 address: %s\\n" "${INFO}" "${IPV4_ADDRESS}"

        # Ask for the gateway
        IPv4gw=$(whiptail --backtitle "Calibrating network interface" --title "IPv4 gateway (router)" --inputbox "Enter your desired IPv4 default gateway" "${r}" "${c}" "${IPv4gw}" 3>&1 1>&2 2>&3) || \
        # Canceling gateway settings window
        { ipSettingsCorrect=False; echo -e "  ${COL_LIGHT_RED}Cancel was selected, exiting installer${COL_NC}"; exit 1; }
        printf "  %b Your static IPv4 gateway: %s\\n" "${INFO}" "${IPv4gw}"

        # Give the user a chance to review their settings before moving on
        if whiptail --backtitle "Calibrating network interface" --title "Static IP Address" --yesno "Are these settings correct?
            IP address: ${IPV4_ADDRESS}
            Gateway:    ${IPv4gw}" "${r}" "${c}"; then
                # After that's done, the loop ends and we move on
                ipSettingsCorrect=True
        else
            # If the settings are wrong, the loop continues
            ipSettingsCorrect=False
        fi
    done
    # End the if statement for DHCP vs. static
    fi
}

# Configure networking via dhcpcd
setDHCPCD() {
    # Check if the IP is already in the file
    if grep -q "${IPV4_ADDRESS}" /etc/dhcpcd.conf; then
        printf "  %b Static IP already configured\\n" "${INFO}"
    # If it's not,
    else
        # we can append these lines to dhcpcd.conf to enable a static IP
        echo "interface ${PIHOLE_INTERFACE}
        static ip_address=${IPV4_ADDRESS}
        static routers=${IPv4gw}
        static domain_name_servers=${PIHOLE_DNS_1} ${PIHOLE_DNS_2}" | tee -a /etc/dhcpcd.conf >/dev/null
        # Then use the ip command to immediately set the new address
        ip addr replace dev "${PIHOLE_INTERFACE}" "${IPV4_ADDRESS}"
        # Also give a warning that the user may need to reboot their system
        printf "  %b Set IP address to %s\\n" "${TICK}" "${IPV4_ADDRESS%/*}"
        printf "  %b You may need to restart after the install is complete\\n" "${INFO}"
    fi
}

# Check an IP address to see if it is a valid one
valid_ip() {
    # Local, named variables
    local ip=${1}
    local stat=1

    # Regex matching one IPv4 component, i.e. an integer from 0 to 255.
    # See https://tools.ietf.org/html/rfc1340
    local ipv4elem="(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]?|0)";
    # Regex matching an optional port (starting with '#') range of 1-65536
    local portelem="(#(6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}|[1-9][0-9]{0,3}|0))?";
    # Build a full IPv4 regex from the above subexpressions
    local regex="^${ipv4elem}\.${ipv4elem}\.${ipv4elem}\.${ipv4elem}${portelem}$"

    # Evaluate the regex, and return the result
    [[ $ip =~ ${regex} ]]

    stat=$?
    return "${stat}"
}

valid_ip6() {
    local ip=${1}
    local stat=1

    # Regex matching one IPv6 element, i.e. a hex value from 0000 to FFFF
    local ipv6elem="[0-9a-fA-F]{1,4}"
    # Regex matching an IPv6 CIDR, i.e. 1 to 128
    local v6cidr="(\\/([1-9]|[1-9][0-9]|1[0-1][0-9]|12[0-8])){0,1}"
    # Regex matching an optional port (starting with '#') range of 1-65536
    local portelem="(#(6553[0-5]|655[0-2][0-9]|65[0-4][0-9]{2}|6[0-4][0-9]{3}|[1-5][0-9]{4}|[1-9][0-9]{0,3}|0))?";
    # Build a full IPv6 regex from the above subexpressions
    local regex="^(((${ipv6elem}))*((:${ipv6elem}))*::((${ipv6elem}))*((:${ipv6elem}))*|((${ipv6elem}))((:${ipv6elem})){7})${v6cidr}${portelem}$"

    # Evaluate the regex, and return the result
    [[ ${ip} =~ ${regex} ]]

    stat=$?
    return "${stat}"
}

# A function to choose the upstream DNS provider(s)
setDNS() {
    # Local, named variables
    local DNSSettingsCorrect

    # In an array, list the available upstream providers
    DNSChooseOptions=()
    local DNSServerCount=0
    # Save the old Internal Field Separator in a variable,
    OIFS=$IFS
    # and set the new one to newline
    IFS=$'\n'
    # Put the DNS Servers into an array
    for DNSServer in ${DNS_SERVERS}
    do
        DNSName="$(cut -d';' -f1 <<< "${DNSServer}")"
        DNSChooseOptions[DNSServerCount]="${DNSName}"
        (( DNSServerCount=DNSServerCount+1 ))
        DNSChooseOptions[DNSServerCount]=""
        (( DNSServerCount=DNSServerCount+1 ))
    done
    DNSChooseOptions[DNSServerCount]="Custom"
    (( DNSServerCount=DNSServerCount+1 ))
    DNSChooseOptions[DNSServerCount]=""
    # Restore the IFS to what it was
    IFS=${OIFS}
    # In a whiptail dialog, show the options
    DNSchoices=$(whiptail --separate-output --menu "Select Upstream DNS Provider. To use your own, select Custom." "${r}" "${c}" 7 \
    "${DNSChooseOptions[@]}" 2>&1 >/dev/tty) || \
    # Exit if the user selects "Cancel"
    { printf "  %bCancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }

    # Depending on the user's choice, set the GLOBAL variables to the IP of the respective provider
    if [[ "${DNSchoices}" == "Custom" ]]
    then
        # Loop until we have a valid DNS setting
        until [[ "${DNSSettingsCorrect}" = True ]]; do
            # Signal value, to be used if the user inputs an invalid IP address
            strInvalid="Invalid"
            if [[ ! "${PIHOLE_DNS_1}" ]]; then
                if [[ ! "${PIHOLE_DNS_2}" ]]; then
                    # If the first and second upstream servers do not exist, do not prepopulate an IP address
                    prePopulate=""
                else
                    # Otherwise, prepopulate the whiptail dialogue with the appropriate DNS value(s)
                    prePopulate=", ${PIHOLE_DNS_2}"
                fi
            elif  [[ "${PIHOLE_DNS_1}" ]] && [[ ! "${PIHOLE_DNS_2}" ]]; then
                prePopulate="${PIHOLE_DNS_1}"
            elif [[ "${PIHOLE_DNS_1}" ]] && [[ "${PIHOLE_DNS_2}" ]]; then
                prePopulate="${PIHOLE_DNS_1}, ${PIHOLE_DNS_2}"
            fi

            # Prompt the user to enter custom upstream servers
            piholeDNS=$(whiptail --backtitle "Specify Upstream DNS Provider(s)"  --inputbox "Enter your desired upstream DNS provider(s), separated by a comma.\\n\\nFor example '8.8.8.8, 8.8.4.4'" "${r}" "${c}" "${prePopulate}" 3>&1 1>&2 2>&3) || \
            { printf "  %bCancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }
            # Clean user input and replace whitespace with comma.
            piholeDNS=$(sed 's/[, \t]\+/,/g' <<< "${piholeDNS}")

            # Separate the user input into the two DNS values (separated by a comma)
            printf -v PIHOLE_DNS_1 "%s" "${piholeDNS%%,*}"
            printf -v PIHOLE_DNS_2 "%s" "${piholeDNS##*,}"

            # If the first DNS value is invalid or empty, this if statement will be true and we will set PIHOLE_DNS_1="Invalid"
            if ! valid_ip "${PIHOLE_DNS_1}" || [[ ! "${PIHOLE_DNS_1}" ]]; then
                PIHOLE_DNS_1=${strInvalid}
            fi
            # If the second DNS value is invalid or empty, this if statement will be true and we will set PIHOLE_DNS_2="Invalid"
            if ! valid_ip "${PIHOLE_DNS_2}" && [[ "${PIHOLE_DNS_2}" ]]; then
                PIHOLE_DNS_2=${strInvalid}
            fi
            # If either of the DNS servers are invalid,
            if [[ "${PIHOLE_DNS_1}" == "${strInvalid}" ]] || [[ "${PIHOLE_DNS_2}" == "${strInvalid}" ]]; then
                # explain this to the user,
                whiptail --msgbox --backtitle "Invalid IP" --title "Invalid IP" "One or both entered IP addresses were invalid. Please try again.\\n\\n    DNS Server 1:   $PIHOLE_DNS_1\\n    DNS Server 2:   ${PIHOLE_DNS_2}" ${r} ${c}
                # set the variables back to nothing,
                if [[ "${PIHOLE_DNS_1}" == "${strInvalid}" ]]; then
                    PIHOLE_DNS_1=""
                fi
                if [[ "${PIHOLE_DNS_2}" == "${strInvalid}" ]]; then
                    PIHOLE_DNS_2=""
                fi
                # and continue the loop.
                DNSSettingsCorrect=False
            else
                # Otherwise, show the DNS setting to the user, and break the loop if they confirm them.
                if (whiptail --backtitle "Specify Upstream DNS Provider(s)" --title "Upstream DNS Provider(s)" --yesno "Are these settings correct?\\n    DNS Server 1:   $PIHOLE_DNS_1\\n    DNS Server 2:   ${PIHOLE_DNS_2}" "${r}" "${c}"); then
                    DNSSettingsCorrect=True
                else
                    DNSSettingsCorrect=False
                fi
            fi
        done
    else
        # Save the old Internal Field Separator in a variable,
        OIFS=$IFS
        # and set the new one to newline
        IFS=$'\n'
        for DNSServer in ${DNS_SERVERS}
        do
            DNSName="$(cut -d';' -f1 <<< "${DNSServer}")"
            if [[ "${DNSchoices}" == "${DNSName}" ]]
            then
                PIHOLE_DNS_1="$(cut -d';' -f2 <<< "${DNSServer}")"
                PIHOLE_DNS_2="$(cut -d';' -f3 <<< "${DNSServer}")"
                break
            fi
        done
        # Restore the IFS to what it was
        IFS=${OIFS}
    fi

    # Display final selection
    local DNSIP=${PIHOLE_DNS_1}
    [[ -z ${PIHOLE_DNS_2} ]] || DNSIP+=", ${PIHOLE_DNS_2}"
    printf "  %b Using upstream DNS: %s (%s)\\n" "${INFO}" "${DNSchoices}" "${DNSIP}"
}

# Allow the user to enable/disable logging
setLogging() {
    # Local, named variables
    local LogToggleCommand
    local LogChooseOptions
    local LogChoices

    # Ask if the user wants to log queries
    LogToggleCommand=(whiptail --separate-output --radiolist "Do you want to log queries?" "${r}" "${c}" 6)
    # The default selection is on
    LogChooseOptions=("On (Recommended)" "" on
        Off "" off)
    # Get the user's choice
    LogChoices=$("${LogToggleCommand[@]}" "${LogChooseOptions[@]}" 2>&1 >/dev/tty) || (printf "  %bCancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}" && exit 1)
    case ${LogChoices} in
        # If it's on,
        "On (Recommended)")
            printf "  %b Logging On.\\n" "${INFO}"
            # set the GLOBAL variable setting to true
            QUERY_LOGGING=true
            ;;
        # Otherwise, it's off,
        Off)
            printf "  %b Logging Off.\\n" "${INFO}"
            # set the GLOBAL variable setting to false
            QUERY_LOGGING=false
            ;;
    esac
}

# Allow the user to set their FTL privacy level
setPrivacyLevel() {
    local LevelCommand
    local LevelOptions

    LevelCommand=(whiptail --separate-output --radiolist "Select a privacy mode for FTL. https://docs.pi-hole.net/ftldns/privacylevels/" "${r}" "${c}" 6)

    # The default selection is level 0
    LevelOptions=(
        "0" "Show everything" on
        "1" "Hide domains" off
        "2" "Hide domains and clients" off
        "3" "Anonymous mode" off
    )

    # Get the user's choice
    PRIVACY_LEVEL=$("${LevelCommand[@]}" "${LevelOptions[@]}" 2>&1 >/dev/tty) || (echo -e "  ${COL_LIGHT_RED}Cancel was selected, exiting installer${COL_NC}" && exit 1)

    printf "  %b Privacy level %d" "${INFO}" "${PRIVACY_LEVEL}"
}

# Function to ask the user if they want to install the dashboard
setAdminFlag() {
    # Local, named variables
    local WebToggleCommand
    local WebChooseOptions
    local WebChoices

    # Similar to the logging function, ask what the user wants
    WebToggleCommand=(whiptail --separate-output --radiolist "Do you wish to install the web admin interface?" "${r}" "${c}" 6)
    # with the default being enabled
    WebChooseOptions=("On (Recommended)" "" on
        Off "" off)
    WebChoices=$("${WebToggleCommand[@]}" "${WebChooseOptions[@]}" 2>&1 >/dev/tty) || (printf "  %bCancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}" && exit 1)
    # Depending on their choice
    case ${WebChoices} in
        "On (Recommended)")
            printf "  %b Web Interface On\\n" "${INFO}"
            # Set it to true
            INSTALL_WEB_INTERFACE=true
            ;;
        Off)
            printf "  %b Web Interface Off\\n" "${INFO}"
            # or false
            INSTALL_WEB_INTERFACE=false
            # Deselect the web server as well, since it is obsolete then
            INSTALL_WEB_SERVER=false
            ;;
    esac

    # If the user wants to install the Web admin interface (i.e. it has not been deselected above)
    if [[ "${INSTALL_WEB_SERVER}" == true ]]; then
        # Get list of required PHP modules, excluding base package (common) and handler (cgi)
        local i php_modules
        for i in "${PIHOLE_WEB_DEPS[@]}"; do [[ $i == 'php'* && $i != *'-common' && $i != *'-cgi' ]] && php_modules+=" ${i#*-}"; done
        WebToggleCommand=(whiptail --separate-output --radiolist "Do you wish to install the web server (lighttpd) and required PHP modules?\\n\\nNB: If you disable this, and, do not have an existing web server and required PHP modules (${php_modules# }) installed, the web interface will not function. Additionally the web server user needs to be member of the \"pihole\" group for full functionality." "${r}" "${c}" 6)
        # Enable as default and recommended option
        WebChooseOptions=("On (Recommended)" "" on
            Off "" off)
        WebChoices=$("${WebToggleCommand[@]}" "${WebChooseOptions[@]}" 2>&1 >/dev/tty) || (printf "  %bCancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}" && exit 1)
        # Depending on their choice
        case ${WebChoices} in
            "On (Recommended)")
                printf "  %b Web Server On\\n" "${INFO}"
                # set it to true, as clearly seen below.
                INSTALL_WEB_SERVER=true
                ;;
            Off)
                printf "  %b Web Server Off\\n" "${INFO}"
                # or false
                INSTALL_WEB_SERVER=false
                ;;
        esac
    fi
}

# A function to display a list of example blocklists for users to select
chooseBlocklists() {
    # Back up any existing adlist file, on the off chance that it exists. Useful in case of a reconfigure.
    if [[ -f "${adlistFile}" ]]; then
        mv "${adlistFile}" "${adlistFile}.old"
    fi
    # Let user select (or not) blocklists via a checklist
    cmd=(whiptail --separate-output --checklist "Pi-hole relies on third party lists in order to block ads.\\n\\nYou can use the suggestion below, and/or add your own after installation\\n\\nTo deselect the suggested list, use spacebar" "${r}" "${c}" 5)
    # In an array, show the options available (all off by default):
    options=(StevenBlack "StevenBlack's Unified Hosts List" on)

    # In a variable, show the choices available; exit if Cancel is selected
    choices=$("${cmd[@]}" "${options[@]}" 2>&1 >/dev/tty) || { printf "  %bCancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; rm "${adlistFile}" ;exit 1; }
    # Add all selected choices to the lists file
    for choice in ${choices}
    do
        appendToListsFile "${choice}"
    done
    # Create an empty adList file with appropriate permissions.
    touch "${adlistFile}"
    chmod 644 "${adlistFile}"
}

# Accept a string parameter, it must be one of the default lists
# This function saves duplication between chooseBlocklists and installDefaultBlocklists
appendToListsFile() {
    case $1 in
        StevenBlack  )  echo "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" >> "${adlistFile}";;
    esac
}

# Used only in unattended setup
# If there is already the adListFile, we keep it, else we create it using all default lists
installDefaultBlocklists() {
    # In unattended setup, could be useful to use userdefined blocklist.
    # If this file exists, we avoid overriding it.
    if [[ -f "${adlistFile}" ]]; then
        return;
    fi
    appendToListsFile StevenBlack
}

# Check if /etc/dnsmasq.conf is from pi-hole.  If so replace with an original and install new in .d directory
version_check_dnsmasq() {
    # Local, named variables
    local dnsmasq_conf="/etc/dnsmasq.conf"
    local dnsmasq_conf_orig="/etc/dnsmasq.conf.orig"
    local dnsmasq_pihole_id_string="addn-hosts=/etc/pihole/gravity.list"
    local dnsmasq_pihole_id_string2="# Dnsmasq config for Pi-hole's FTLDNS"
    local dnsmasq_original_config="${PI_HOLE_LOCAL_REPO}/advanced/dnsmasq.conf.original"
    local dnsmasq_pihole_01_source="${PI_HOLE_LOCAL_REPO}/advanced/01-pihole.conf"
    local dnsmasq_pihole_01_target="/etc/dnsmasq.d/01-pihole.conf"
    local dnsmasq_rfc6761_06_source="${PI_HOLE_LOCAL_REPO}/advanced/06-rfc6761.conf"
    local dnsmasq_rfc6761_06_target="/etc/dnsmasq.d/06-rfc6761.conf"

    # If the dnsmasq config file exists
    if [[ -f "${dnsmasq_conf}" ]]; then
        printf "  %b Existing dnsmasq.conf found..." "${INFO}"
        # If a specific string is found within this file, we presume it's from older versions on Pi-hole,
        if grep -q "${dnsmasq_pihole_id_string}" "${dnsmasq_conf}" ||
           grep -q "${dnsmasq_pihole_id_string2}" "${dnsmasq_conf}"; then
            printf " it is from a previous Pi-hole install.\\n"
            printf "  %b Backing up dnsmasq.conf to dnsmasq.conf.orig..." "${INFO}"
            # so backup the original file,
            mv -f "${dnsmasq_conf}" "${dnsmasq_conf_orig}"
            printf "%b  %b Backing up dnsmasq.conf to dnsmasq.conf.orig...\\n" "${OVER}"  "${TICK}"
            printf "  %b Restoring default dnsmasq.conf..." "${INFO}"
            # and replace it with the default
            install -D -m 644 -T "${dnsmasq_original_config}" "${dnsmasq_conf}"
            printf "%b  %b Restoring default dnsmasq.conf...\\n" "${OVER}"  "${TICK}"
        else
        # Otherwise, don't to anything
        printf " it is not a Pi-hole file, leaving alone!\\n"
        fi
    else
        # If a file cannot be found,
        printf "  %b No dnsmasq.conf found... restoring default dnsmasq.conf..." "${INFO}"
        # restore the default one
        install -D -m 644 -T "${dnsmasq_original_config}" "${dnsmasq_conf}"
        printf "%b  %b No dnsmasq.conf found... restoring default dnsmasq.conf...\\n" "${OVER}"  "${TICK}"
    fi

    printf "  %b Installing %s..." "${INFO}" "${dnsmasq_pihole_01_target}"
    # Check to see if dnsmasq directory exists (it may not due to being a fresh install and dnsmasq no longer being a dependency)
    if [[ ! -d "/etc/dnsmasq.d"  ]];then
        install -d -m 755 "/etc/dnsmasq.d"
    fi
    # Copy the new Pi-hole DNS config file into the dnsmasq.d directory
    install -D -m 644 -T "${dnsmasq_pihole_01_source}" "${dnsmasq_pihole_01_target}"
    printf "%b  %b Installed %s\n" "${OVER}"  "${TICK}" "${dnsmasq_pihole_01_target}"
    # Replace our placeholder values with the GLOBAL DNS variables that we populated earlier
    # First, swap in the interface to listen on,
    sed -i "s/@INT@/$PIHOLE_INTERFACE/" "${dnsmasq_pihole_01_target}"
    if [[ "${PIHOLE_DNS_1}" != "" ]]; then
        # then swap in the primary DNS server.
        sed -i "s/@DNS1@/$PIHOLE_DNS_1/" "${dnsmasq_pihole_01_target}"
    else
        # Otherwise, remove the line which sets DNS1.
        sed -i '/^server=@DNS1@/d' "${dnsmasq_pihole_01_target}"
    fi
    # Ditto if DNS2 is not empty
    if [[ "${PIHOLE_DNS_2}" != "" ]]; then
        sed -i "s/@DNS2@/$PIHOLE_DNS_2/" "${dnsmasq_pihole_01_target}"
    else
        sed -i '/^server=@DNS2@/d' "${dnsmasq_pihole_01_target}"
    fi

	# Set the cache size
	sed -i "s/@CACHE_SIZE@/$CACHE_SIZE/" "${dnsmasq_pihole_01_target}"

    sed -i 's/^#conf-dir=\/etc\/dnsmasq.d$/conf-dir=\/etc\/dnsmasq.d/' "${dnsmasq_conf}"

    # If the user does not want to enable logging,
    if [[ "${QUERY_LOGGING}" == false ]] ; then
        # disable it by commenting out the directive in the DNS config file
        sed -i 's/^log-queries/#log-queries/' "${dnsmasq_pihole_01_target}"
    else
        # Otherwise, enable it by uncommenting the directive in the DNS config file
        sed -i 's/^#log-queries/log-queries/' "${dnsmasq_pihole_01_target}"
    fi

    printf "  %b Installing %s..." "${INFO}" "${dnsmasq_rfc6761_06_source}"
    install -D -m 644 -T "${dnsmasq_rfc6761_06_source}" "${dnsmasq_rfc6761_06_target}"
    printf "%b  %b Installed %s\n" "${OVER}"  "${TICK}" "${dnsmasq_rfc6761_06_target}"
}

# Clean an existing installation to prepare for upgrade/reinstall
clean_existing() {
    # Local, named variables
    # ${1} Directory to clean
    local clean_directory="${1}"
    # Pop the first argument, and shift all addresses down by one (i.e. ${2} becomes ${1})
    shift
    # Then, we can access all arguments ($@) without including the directory to clean
    local old_files=( "$@" )

    # Remove each script in the old_files array
    for script in "${old_files[@]}"; do
        rm -f "${clean_directory}/${script}.sh"
    done
}

# Install the scripts from repository to their various locations
installScripts() {
    # Local, named variables
    local str="Installing scripts from ${PI_HOLE_LOCAL_REPO}"
    printf "  %b %s..." "${INFO}" "${str}"

    # Clear out script files from Pi-hole scripts directory.
    clean_existing "${PI_HOLE_INSTALL_DIR}" "${PI_HOLE_FILES[@]}"

    # Install files from local core repository
    if is_repo "${PI_HOLE_LOCAL_REPO}"; then
        # move into the directory
        cd "${PI_HOLE_LOCAL_REPO}"
        # Install the scripts by:
        #  -o setting the owner to the user
        #  -Dm755 create all leading components of destination except the last, then copy the source to the destination and setting the permissions to 755
        #
        # This first one is the directory
        install -o "${USER}" -Dm755 -d "${PI_HOLE_INSTALL_DIR}"
        # The rest are the scripts Pi-hole needs
        install -o "${USER}" -Dm755 -t "${PI_HOLE_INSTALL_DIR}" gravity.sh
        install -o "${USER}" -Dm755 -t "${PI_HOLE_INSTALL_DIR}" ./advanced/Scripts/*.sh
        install -o "${USER}" -Dm755 -t "${PI_HOLE_INSTALL_DIR}" ./automated\ install/uninstall.sh
        install -o "${USER}" -Dm755 -t "${PI_HOLE_INSTALL_DIR}" ./advanced/Scripts/COL_TABLE
        install -o "${USER}" -Dm755 -t "${PI_HOLE_BIN_DIR}" pihole
        install -Dm644 ./advanced/bash-completion/pihole /etc/bash_completion.d/pihole
        printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"

    else
        # Otherwise, show an error and exit
        printf "%b  %b %s\\n" "${OVER}"  "${CROSS}" "${str}"
        printf "\\t\\t%bError: Local repo %s not found, exiting installer%b\\n" "${COL_LIGHT_RED}" "${PI_HOLE_LOCAL_REPO}" "${COL_NC}"
        return 1
    fi
}

# Install the configs from PI_HOLE_LOCAL_REPO to their various locations
installConfigs() {
    printf "\\n  %b Installing configs from %s...\\n" "${INFO}" "${PI_HOLE_LOCAL_REPO}"
    # Make sure Pi-hole's config files are in place
    version_check_dnsmasq

    # Install list of DNS servers
    # Format: Name;Primary IPv4;Secondary IPv4;Primary IPv6;Secondary IPv6
    # Some values may be empty (for example: DNS servers without IPv6 support)
    echo "${DNS_SERVERS}" > "${PI_HOLE_CONFIG_DIR}/dns-servers.conf"
    chmod 644 "${PI_HOLE_CONFIG_DIR}/dns-servers.conf"

    # Install empty file if it does not exist
    if [[ ! -r "${PI_HOLE_CONFIG_DIR}/pihole-FTL.conf" ]]; then
        install -d -m 0755 ${PI_HOLE_CONFIG_DIR}
        if ! install -o pihole -m 664 /dev/null "${PI_HOLE_CONFIG_DIR}/pihole-FTL.conf" &>/dev/null; then
            printf "  %bError: Unable to initialize configuration file %s/pihole-FTL.conf\\n" "${COL_LIGHT_RED}" "${PI_HOLE_CONFIG_DIR}"
            return 1
        fi
    fi

    # Install empty custom.list file if it does not exist
    if [[ ! -r "${PI_HOLE_CONFIG_DIR}/custom.list" ]]; then
        if ! install -o root -m 644 /dev/null "${PI_HOLE_CONFIG_DIR}/custom.list" &>/dev/null; then
            printf "  %bError: Unable to initialize configuration file %s/custom.list\\n" "${COL_LIGHT_RED}" "${PI_HOLE_CONFIG_DIR}"
            return 1
        fi
    fi

    # If the user chose to install the dashboard,
    if [[ "${INSTALL_WEB_SERVER}" == true ]]; then
        # and if the Web server conf directory does not exist,
        if [[ ! -d "/etc/lighttpd" ]]; then
            # make it and set the owners
            install -d -m 755 -o "${USER}" -g root /etc/lighttpd
        # Otherwise, if the config file already exists
        elif [[ -f "/etc/lighttpd/lighttpd.conf" ]]; then
            # back up the original
            mv /etc/lighttpd/lighttpd.conf /etc/lighttpd/lighttpd.conf.orig
        fi
        # and copy in the config file Pi-hole needs
        install -D -m 644 -T ${PI_HOLE_LOCAL_REPO}/advanced/${LIGHTTPD_CFG} /etc/lighttpd/lighttpd.conf
        # Make sure the external.conf file exists, as lighttpd v1.4.50 crashes without it
        touch /etc/lighttpd/external.conf
        chmod 644 /etc/lighttpd/external.conf
        # If there is a custom block page in the html/pihole directory, replace 404 handler in lighttpd config
        if [[ -f "${PI_HOLE_BLOCKPAGE_DIR}/custom.php" ]]; then
            sed -i 's/^\(server\.error-handler-404\s*=\s*\).*$/\1"pihole\/custom\.php"/' /etc/lighttpd/lighttpd.conf
        fi
        # Make the directories if they do not exist and set the owners
        mkdir -p /run/lighttpd
        chown ${LIGHTTPD_USER}:${LIGHTTPD_GROUP} /run/lighttpd
        mkdir -p /var/cache/lighttpd/compress
        chown ${LIGHTTPD_USER}:${LIGHTTPD_GROUP} /var/cache/lighttpd/compress
        mkdir -p /var/cache/lighttpd/uploads
        chown ${LIGHTTPD_USER}:${LIGHTTPD_GROUP} /var/cache/lighttpd/uploads
    fi
}

install_manpage() {
    # Copy Pi-hole man pages and call mandb to update man page database
    # Default location for man files for /usr/local/bin is /usr/local/share/man
    # on lightweight systems may not be present, so check before copying.
    printf "  %b Testing man page installation" "${INFO}"
    if ! is_command mandb ; then
        # if mandb is not present, no manpage support
        printf "%b  %b man not installed\\n" "${OVER}" "${INFO}"
        return
    elif [[ ! -d "/usr/local/share/man" ]]; then
        # appropriate directory for Pi-hole's man page is not present
        printf "%b  %b man pages not installed\\n" "${OVER}" "${INFO}"
        return
    fi
    if [[ ! -d "/usr/local/share/man/man8" ]]; then
        # if not present, create man8 directory
        install -d -m 755 /usr/local/share/man/man8
    fi
    if [[ ! -d "/usr/local/share/man/man5" ]]; then
        # if not present, create man5 directory
        install -d -m 755 /usr/local/share/man/man5
    fi
    # Testing complete, copy the files & update the man db
    install -D -m 644 -T ${PI_HOLE_LOCAL_REPO}/manpages/pihole.8 /usr/local/share/man/man8/pihole.8
    install -D -m 644 -T ${PI_HOLE_LOCAL_REPO}/manpages/pihole-FTL.8 /usr/local/share/man/man8/pihole-FTL.8
    install -D -m 644 -T ${PI_HOLE_LOCAL_REPO}/manpages/pihole-FTL.conf.5 /usr/local/share/man/man5/pihole-FTL.conf.5
    if mandb -q &>/dev/null; then
        # Updated successfully
        printf "%b  %b man pages installed and database updated\\n" "${OVER}" "${TICK}"
        return
    else
        # Something is wrong with the system's man installation, clean up
        # our files, (leave everything how we found it).
        rm /usr/local/share/man/man8/pihole.8 /usr/local/share/man/man8/pihole-FTL.8 /usr/local/share/man/man5/pihole-FTL.conf.5
        printf "%b  %b man page db not updated, man pages not installed\\n" "${OVER}" "${CROSS}"
    fi
}

stop_service() {
    # Stop service passed in as argument.
    # Can softfail, as process may not be installed when this is called
    local str="Stopping ${1} service"
    printf "  %b %s..." "${INFO}" "${str}"
    if is_command systemctl ; then
        systemctl stop "${1}" &> /dev/null || true
    else
        service "${1}" stop &> /dev/null || true
    fi
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
}

# Start/Restart service passed in as argument
restart_service() {
    # Local, named variables
    local str="Restarting ${1} service"
    printf "  %b %s..." "${INFO}" "${str}"
    # If systemctl exists,
    if is_command systemctl ; then
        # use that to restart the service
        systemctl restart "${1}" &> /dev/null
    else
        # Otherwise, fall back to the service command
        service "${1}" restart &> /dev/null
    fi
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
}

# Enable service so that it will start with next reboot
enable_service() {
    # Local, named variables
    local str="Enabling ${1} service to start on reboot"
    printf "  %b %s..." "${INFO}" "${str}"
    # If systemctl exists,
    if is_command systemctl ; then
        # use that to enable the service
        systemctl enable "${1}" &> /dev/null
    else
        #  Otherwise, use update-rc.d to accomplish this
        update-rc.d "${1}" defaults &> /dev/null
    fi
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
}

# Disable service so that it will not with next reboot
disable_service() {
    # Local, named variables
    local str="Disabling ${1} service"
    printf "  %b %s..." "${INFO}" "${str}"
    # If systemctl exists,
    if is_command systemctl ; then
        # use that to disable the service
        systemctl disable "${1}" &> /dev/null
    else
        # Otherwise, use update-rc.d to accomplish this
        update-rc.d "${1}" disable &> /dev/null
    fi
    printf "%b  %b %s...\\n" "${OVER}" "${TICK}" "${str}"
}

check_service_active() {
    # If systemctl exists,
    if is_command systemctl ; then
        # use that to check the status of the service
        systemctl is-enabled "${1}" &> /dev/null
    else
        # Otherwise, fall back to service command
        service "${1}" status &> /dev/null
    fi
}

# Systemd-resolved's DNSStubListener and dnsmasq can't share port 53.
disable_resolved_stublistener() {
    printf "  %b Testing if systemd-resolved is enabled\\n" "${INFO}"
    # Check if Systemd-resolved's DNSStubListener is enabled and active on port 53
    if check_service_active "systemd-resolved"; then
        # Check if DNSStubListener is enabled
        printf "  %b  %b Testing if systemd-resolved DNSStub-Listener is active" "${OVER}" "${INFO}"
        if ( grep -E '#?DNSStubListener=yes' /etc/systemd/resolved.conf &> /dev/null ); then
            # Disable the DNSStubListener to unbind it from port 53
            # Note that this breaks dns functionality on host until dnsmasq/ftl are up and running
            printf "%b  %b Disabling systemd-resolved DNSStubListener" "${OVER}" "${TICK}"
            # Make a backup of the original /etc/systemd/resolved.conf
            # (This will need to be restored on uninstallation)
            sed -r -i.orig 's/#?DNSStubListener=yes/DNSStubListener=no/g' /etc/systemd/resolved.conf
            printf " and restarting systemd-resolved\\n"
            systemctl reload-or-restart systemd-resolved
        else
            printf "%b  %b Systemd-resolved does not need to be restarted\\n" "${OVER}" "${INFO}"
        fi
    else
        printf "%b  %b Systemd-resolved is not enabled\\n" "${OVER}" "${INFO}"
    fi
}

update_package_cache() {
    # Running apt-get update/upgrade with minimal output can cause some issues with
    # requiring user input (e.g password for phpmyadmin see #218)

    # Update package cache on apt based OSes. Do this every time since
    # it's quick and packages can be updated at any time.

    # Local, named variables
    local str="Update local cache of available packages"
    printf "  %b %s..." "${INFO}" "${str}"
    # Create a command from the package cache variable
    if eval "${UPDATE_PKG_CACHE}" &> /dev/null; then
        printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    else
        # Otherwise, show an error and exit
        printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
        printf "  %bError: Unable to update package cache. Please try \"%s\"%b" "${COL_LIGHT_RED}" "sudo ${UPDATE_PKG_CACHE}" "${COL_NC}"
        return 1
    fi
}

# Let user know if they have outdated packages on their system and
# advise them to run a package update at soonest possible.
notify_package_updates_available() {
    # Local, named variables
    local str="Checking ${PKG_MANAGER} for upgraded packages"
    printf "\\n  %b %s..." "${INFO}" "${str}"
    # Store the list of packages in a variable
    updatesToInstall=$(eval "${PKG_COUNT}")

    if [[ -d "/lib/modules/$(uname -r)" ]]; then
        if [[ "${updatesToInstall}" -eq 0 ]]; then
            printf "%b  %b %s... up to date!\\n\\n" "${OVER}" "${TICK}" "${str}"
        else
            printf "%b  %b %s... %s updates available\\n" "${OVER}" "${TICK}" "${str}" "${updatesToInstall}"
            printf "  %b %bIt is recommended to update your OS after installing the Pi-hole!%b\\n\\n" "${INFO}" "${COL_LIGHT_GREEN}" "${COL_NC}"
        fi
    else
        printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
        printf "      Kernel update detected. If the install fails, please reboot and try again\\n"
    fi
}

install_dependent_packages() {

    # Install packages passed in via argument array
    # No spinner - conflicts with set -e
    declare -a installArray

    # Debian based package install - debconf will download the entire package list
    # so we just create an array of packages not currently installed to cut down on the
    # amount of download traffic.
    # NOTE: We may be able to use this installArray in the future to create a list of package that were
    # installed by us, and remove only the installed packages, and not the entire list.
    if is_command apt-get ; then
        # For each package, check if it's already installed (and if so, don't add it to the installArray)
        for i in "$@"; do
            printf "  %b Checking for %s..." "${INFO}" "${i}"
            if dpkg-query -W -f='${Status}' "${i}" 2>/dev/null | grep "ok installed" &> /dev/null; then
                printf "%b  %b Checking for %s\\n" "${OVER}" "${TICK}" "${i}"
            else
                printf "%b  %b Checking for %s (will be installed)\\n" "${OVER}" "${INFO}" "${i}"
                installArray+=("${i}")
            fi
        done
        # If there's anything to install, install everything in the list.
        if [[ "${#installArray[@]}" -gt 0 ]]; then
            test_dpkg_lock
            printf "  %b Processing %s install(s) for: %s, please wait...\\n" "${INFO}" "${PKG_MANAGER}" "${installArray[*]}"
            printf '%*s\n' "$columns" '' | tr " " -;
            "${PKG_INSTALL[@]}" "${installArray[@]}"
            printf '%*s\n' "$columns" '' | tr " " -;
            return
        fi
        printf "\\n"
        return 0
    fi

    # Install Fedora/CentOS packages
    for i in "$@"; do
    # For each package, check if it's already installed (and if so, don't add it to the installArray)
        printf "  %b Checking for %s..." "${INFO}" "${i}"
        if "${PKG_MANAGER}" -q list installed "${i}" &> /dev/null; then
            printf "%b  %b Checking for %s\\n" "${OVER}" "${TICK}" "${i}"
        else
            printf "%b  %b Checking for %s (will be installed)\\n" "${OVER}" "${INFO}" "${i}"
            installArray+=("${i}")
        fi
    done
    # If there's anything to install, install everything in the list.
    if [[ "${#installArray[@]}" -gt 0 ]]; then
        printf "  %b Processing %s install(s) for: %s, please wait...\\n" "${INFO}" "${PKG_MANAGER}" "${installArray[*]}"
        printf '%*s\n' "$columns" '' | tr " " -;
        "${PKG_INSTALL[@]}" "${installArray[@]}"
        printf '%*s\n' "$columns" '' | tr " " -;
        return
    fi
    printf "\\n"
    return 0
}

# Install the Web interface dashboard
installPiholeWeb() {
    printf "\\n  %b Installing blocking page...\\n" "${INFO}"

    local str="Creating directory for blocking page, and copying files"
    printf "  %b %s..." "${INFO}" "${str}"
    # Install the directory,
    install -d -m 0755 ${PI_HOLE_BLOCKPAGE_DIR}
    # and the blockpage
    install -D -m 644 ${PI_HOLE_LOCAL_REPO}/advanced/{index,blockingpage}.* ${PI_HOLE_BLOCKPAGE_DIR}/

    # Remove superseded file
    if [[ -e "${PI_HOLE_BLOCKPAGE_DIR}/index.js" ]]; then
        rm "${PI_HOLE_BLOCKPAGE_DIR}/index.js"
    fi

    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"

    local str="Backing up index.lighttpd.html"
    printf "  %b %s..." "${INFO}" "${str}"
    # If the default index file exists,
    if [[ -f "${webroot}/index.lighttpd.html" ]]; then
        # back it up
        mv ${webroot}/index.lighttpd.html ${webroot}/index.lighttpd.orig
        printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
    else
        # Otherwise, don't do anything
        printf "%b  %b %s\\n" "${OVER}" "${INFO}" "${str}"
        printf "      No default index.lighttpd.html file found... not backing up\\n"
    fi

    # Install Sudoers file
    local str="Installing sudoer file"
    printf "\\n  %b %s..." "${INFO}" "${str}"
    # Make the .d directory if it doesn't exist,
    install -d -m 755 /etc/sudoers.d/
    # and copy in the pihole sudoers file
    install -m 0640 ${PI_HOLE_LOCAL_REPO}/advanced/Templates/pihole.sudo /etc/sudoers.d/pihole
    # Add lighttpd user (OS dependent) to sudoers file
    echo "${LIGHTTPD_USER} ALL=NOPASSWD: ${PI_HOLE_BIN_DIR}/pihole" >> /etc/sudoers.d/pihole

    # If the Web server user is lighttpd,
    if [[ "$LIGHTTPD_USER" == "lighttpd" ]]; then
        # Allow executing pihole via sudo with Fedora
        # Usually /usr/local/bin ${PI_HOLE_BIN_DIR} is not permitted as directory for sudoable programs
        echo "Defaults secure_path = /sbin:/bin:/usr/sbin:/usr/bin:${PI_HOLE_BIN_DIR}" >> /etc/sudoers.d/pihole
    fi
    # Set the strict permissions on the file
    chmod 0440 /etc/sudoers.d/pihole
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
}

# Installs a cron file
installCron() {
    # Install the cron job
    local str="Installing latest Cron script"
    printf "\\n  %b %s..." "${INFO}" "${str}"
    # Copy the cron file over from the local repo
    # File must not be world or group writeable and must be owned by root
    install -D -m 644 -T -o root -g root ${PI_HOLE_LOCAL_REPO}/advanced/Templates/pihole.cron /etc/cron.d/pihole
    # Randomize gravity update time
    sed -i "s/59 1 /$((1 + RANDOM % 58)) $((3 + RANDOM % 2))/" /etc/cron.d/pihole
    # Randomize update checker time
    sed -i "s/59 17/$((1 + RANDOM % 58)) $((12 + RANDOM % 8))/" /etc/cron.d/pihole
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
}

# Gravity is a very important script as it aggregates all of the domains into a single HOSTS formatted list,
# which is what Pi-hole needs to begin blocking ads
runGravity() {
    # Run gravity in the current shell
    { /opt/pihole/gravity.sh --force; }
}

# Check if the pihole user exists and create if it does not
create_pihole_user() {
    local str="Checking for user 'pihole'"
    printf "  %b %s..." "${INFO}" "${str}"
    # If the pihole user exists,
    if id -u pihole &> /dev/null; then
        # and if the pihole group exists,
        if getent group pihole > /dev/null 2>&1; then
            # succeed
            printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
        else
            local str="Checking for group 'pihole'"
            printf "  %b %s..." "${INFO}" "${str}"
            local str="Creating group 'pihole'"
            # if group can be created
            if groupadd pihole; then
                printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
                local str="Adding user 'pihole' to group 'pihole'"
                printf "  %b %s..." "${INFO}" "${str}"
                # if pihole user can be added to group pihole
                if usermod -g pihole pihole; then
                    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
                else
                    printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
                fi
            else
                printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
            fi
        fi
    else
        # If the pihole user doesn't exist,
        printf "%b  %b %s" "${OVER}" "${CROSS}" "${str}"
        local str="Creating user 'pihole'"
        printf "%b  %b %s..." "${OVER}" "${INFO}" "${str}"
        # create her with the useradd command,
        if getent group pihole > /dev/null 2>&1; then
            # then add her to the pihole group (as it already exists)
            if useradd -r --no-user-group -g pihole -s /usr/sbin/nologin pihole; then
                printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
            else
                printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
            fi
        else
            # add user pihole with default group settings
            if useradd -r -s /usr/sbin/nologin pihole; then
                printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
            else
                printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
            fi
        fi
    fi
}

# This function saves any changes to the setup variables into the setupvars.conf file for future runs
finalExports() {
    # If the Web interface is not set to be installed,
    if [[ "${INSTALL_WEB_INTERFACE}" == false ]]; then
        # and if there is not an IPv4 address,
        if [[ "${IPV4_ADDRESS}" ]]; then
            # there is no block page, so set IPv4 to 0.0.0.0 (all IP addresses)
            IPV4_ADDRESS="0.0.0.0"
        fi
        if [[ "${IPV6_ADDRESS}" ]]; then
            # and IPv6 to ::/0
            IPV6_ADDRESS="::/0"
        fi
    fi

    # If the setup variable file exists,
    if [[ -e "${setupVars}" ]]; then
        # update the variables in the file
        sed -i.update.bak '/PIHOLE_INTERFACE/d;/IPV4_ADDRESS/d;/IPV6_ADDRESS/d;/PIHOLE_DNS_1\b/d;/PIHOLE_DNS_2\b/d;/QUERY_LOGGING/d;/INSTALL_WEB_SERVER/d;/INSTALL_WEB_INTERFACE/d;/LIGHTTPD_ENABLED/d;/CACHE_SIZE/d;' "${setupVars}"
    fi
    # echo the information to the user
    {
    echo "PIHOLE_INTERFACE=${PIHOLE_INTERFACE}"
    echo "IPV4_ADDRESS=${IPV4_ADDRESS}"
    echo "IPV6_ADDRESS=${IPV6_ADDRESS}"
    echo "PIHOLE_DNS_1=${PIHOLE_DNS_1}"
    echo "PIHOLE_DNS_2=${PIHOLE_DNS_2}"
    echo "QUERY_LOGGING=${QUERY_LOGGING}"
    echo "INSTALL_WEB_SERVER=${INSTALL_WEB_SERVER}"
    echo "INSTALL_WEB_INTERFACE=${INSTALL_WEB_INTERFACE}"
    echo "LIGHTTPD_ENABLED=${LIGHTTPD_ENABLED}"
    echo "CACHE_SIZE=${CACHE_SIZE}"
    echo "DNS_FQDN_REQUIRED=true"
    echo "DNS_BOGUS_PRIV=true"
    }>> "${setupVars}"
    chmod 644 "${setupVars}"

    # Set the privacy level
    sed -i '/PRIVACYLEVEL/d' "${PI_HOLE_CONFIG_DIR}/pihole-FTL.conf"
    echo "PRIVACYLEVEL=${PRIVACY_LEVEL}" >> "${PI_HOLE_CONFIG_DIR}/pihole-FTL.conf"

    # Bring in the current settings and the functions to manipulate them
    source "${setupVars}"
    source "${PI_HOLE_LOCAL_REPO}/advanced/Scripts/webpage.sh"

    # Look for DNS server settings which would have to be reapplied
    ProcessDNSSettings

    # Look for DHCP server settings which would have to be reapplied
    ProcessDHCPSettings
}

# Install the logrotate script
installLogrotate() {
    local str="Installing latest logrotate script"
    local target=/etc/pihole/logrotate

    printf "\\n  %b %s..." "${INFO}" "${str}"
    if [[ -f ${target} ]]; then
        printf "\\n\\t%b Existing logrotate file found. No changes made.\\n" "${INFO}"
        # Return value isn't that important, using 2 to indicate that it's not a fatal error but
        # the function did not complete.
        return 2
    fi
    # Copy the file over from the local repo
    install -D -m 644 -T "${PI_HOLE_LOCAL_REPO}"/advanced/Templates/logrotate ${target}
    # Different operating systems have different user / group
    # settings for logrotate that makes it impossible to create
    # a static logrotate file that will work with e.g.
    # Rasbian and Ubuntu at the same time. Hence, we have to
    # customize the logrotate script here in order to reflect
    # the local properties of the /var/log directory
    logusergroup="$(stat -c '%U %G' /var/log)"
    # If there is a usergroup for log rotation,
    if [[ -n "${logusergroup}" ]]; then
        # replace the line in the logrotate script with that usergroup.
        sed -i "s/# su #/su ${logusergroup}/g;" ${target}
    fi
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
}

# At some point in the future this list can be pruned, for now we'll need it to ensure updates don't break.
# Refactoring of install script has changed the name of a couple of variables. Sort them out here.
accountForRefactor() {
    sed -i 's/piholeInterface/PIHOLE_INTERFACE/g' "${setupVars}"
    sed -i 's/IPv4_address/IPV4_ADDRESS/g' "${setupVars}"
    sed -i 's/IPv4addr/IPV4_ADDRESS/g' "${setupVars}"
    sed -i 's/IPv6_address/IPV6_ADDRESS/g' "${setupVars}"
    sed -i 's/piholeIPv6/IPV6_ADDRESS/g' "${setupVars}"
    sed -i 's/piholeDNS1/PIHOLE_DNS_1/g' "${setupVars}"
    sed -i 's/piholeDNS2/PIHOLE_DNS_2/g' "${setupVars}"
    sed -i 's/^INSTALL_WEB=/INSTALL_WEB_INTERFACE=/' "${setupVars}"
    # Add 'INSTALL_WEB_SERVER', if its not been applied already: https://github.com/pi-hole/pi-hole/pull/2115
    if ! grep -q '^INSTALL_WEB_SERVER=' ${setupVars}; then
        local webserver_installed=false
        if grep -q '^INSTALL_WEB_INTERFACE=true' ${setupVars}; then
            webserver_installed=true
        fi
        echo -e "INSTALL_WEB_SERVER=$webserver_installed" >> "${setupVars}"
    fi
}

# Install base files and web interface
installPihole() {
    # If the user wants to install the Web interface,
    if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then
        if [[ ! -d "${webroot}" ]]; then
            # make the Web directory if necessary
            install -d -m 0755 ${webroot}
        fi

        if [[ "${INSTALL_WEB_SERVER}" == true ]]; then
            # Set the owner and permissions
            chown ${LIGHTTPD_USER}:${LIGHTTPD_GROUP} ${webroot}
            chmod 0775 ${webroot}
            # Repair permissions if webroot is not world readable
            chmod a+rx /var/www
            chmod a+rx ${webroot}
            # Give lighttpd access to the pihole group so the web interface can
            # manage the gravity.db database
            usermod -a -G pihole ${LIGHTTPD_USER}
            # If the lighttpd command is executable,
            if is_command lighty-enable-mod ; then
                # enable fastcgi and fastcgi-php
                lighty-enable-mod fastcgi fastcgi-php > /dev/null || true
            else
                # Otherwise, show info about installing them
                printf "  %b Warning: 'lighty-enable-mod' utility not found\\n" "${INFO}"
                printf "      Please ensure fastcgi is enabled if you experience issues\\n"
            fi
        fi
    fi
    # For updates and unattended install.
    if [[ "${useUpdateVars}" == true ]]; then
        accountForRefactor
    fi
    # Install base files and web interface
    if ! installScripts; then
        printf "  %b Failure in dependent script copy function.\\n" "${CROSS}"
        exit 1
    fi
    # Install config files
    if ! installConfigs; then
        printf "  %b Failure in dependent config copy function.\\n" "${CROSS}"
        exit 1
    fi
    # If the user wants to install the dashboard,
    if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then
        # do so
        installPiholeWeb
    fi
    # Install the cron file
    installCron

    # Install the logrotate file
    installLogrotate || true

    # Check if dnsmasq is present. If so, disable it and back up any possible
    # config file
    disable_dnsmasq

    # install a man page entry for pihole
    install_manpage

    # Update setupvars.conf with any variables that may or may not have been changed during the install
    finalExports
}

# SELinux
checkSelinux() {
    local DEFAULT_SELINUX
    local CURRENT_SELINUX
    local SELINUX_ENFORCING=0
    # Check for SELinux configuration file and getenforce command
    if [[ -f /etc/selinux/config ]] && command -v getenforce &> /dev/null; then
        # Check the default SELinux mode
        DEFAULT_SELINUX=$(awk -F= '/^SELINUX=/ {print $2}' /etc/selinux/config)
        case "${DEFAULT_SELINUX,,}" in
            enforcing)
                printf "  %b %bDefault SELinux: %s%b\\n" "${CROSS}" "${COL_RED}" "${DEFAULT_SELINUX}" "${COL_NC}"
                SELINUX_ENFORCING=1
                ;;
            *)  # 'permissive' and 'disabled'
                printf "  %b %bDefault SELinux: %s%b\\n" "${TICK}" "${COL_GREEN}" "${DEFAULT_SELINUX}" "${COL_NC}"
                ;;
        esac
        # Check the current state of SELinux
        CURRENT_SELINUX=$(getenforce)
        case "${CURRENT_SELINUX,,}" in
            enforcing)
                printf "  %b %bCurrent SELinux: %s%b\\n" "${CROSS}" "${COL_RED}" "${CURRENT_SELINUX}" "${COL_NC}"
                SELINUX_ENFORCING=1
                ;;
            *)  # 'permissive' and 'disabled'
                printf "  %b %bCurrent SELinux: %s%b\\n" "${TICK}" "${COL_GREEN}" "${CURRENT_SELINUX}" "${COL_NC}"
                ;;
        esac
    else
        echo -e "  ${INFO} ${COL_GREEN}SELinux not detected${COL_NC}";
    fi
    # Exit the installer if any SELinux checks toggled the flag
    if [[ "${SELINUX_ENFORCING}" -eq 1 ]] && [[ -z "${PIHOLE_SELINUX}" ]]; then
        printf "  Pi-hole does not provide an SELinux policy as the required changes modify the security of your system.\\n"
        printf "  Please refer to https://wiki.centos.org/HowTos/SELinux if SELinux is required for your deployment.\\n"
        printf "      This check can be skipped by setting the environment variable %bPIHOLE_SELINUX%b to %btrue%b\\n" "${COL_LIGHT_RED}" "${COL_NC}" "${COL_LIGHT_RED}" "${COL_NC}"
        printf "      e.g: export PIHOLE_SELINUX=true\\n"
        printf "      By setting this variable to true you acknowledge there may be issues with Pi-hole during or after the install\\n"
        printf "\\n  %bSELinux Enforcing detected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}";
        exit 1;
    elif [[ "${SELINUX_ENFORCING}" -eq 1 ]] && [[ -n "${PIHOLE_SELINUX}" ]]; then
        printf "  %b %bSELinux Enforcing detected%b. PIHOLE_SELINUX env variable set - installer will continue\\n" "${INFO}" "${COL_LIGHT_RED}" "${COL_NC}"
    fi
}

# Installation complete message with instructions for the user
displayFinalMessage() {
    # If the number of arguments is > 0,
    if [[ "${#1}" -gt 0 ]] ; then
        # set the password to the first argument.
        pwstring="$1"
    elif [[ $(grep 'WEBPASSWORD' -c /etc/pihole/setupVars.conf) -gt 0 ]]; then
        # Else if the password exists from previous setup, we'll load it later
        pwstring="unchanged"
    else
        # Else, inform the user that there is no set password.
        pwstring="NOT SET"
    fi
    # If the user wants to install the dashboard,
    if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then
        # Store a message in a variable and display it
        additional="View the web interface at http://pi.hole/admin or http://${IPV4_ADDRESS%/*}/admin

Your Admin Webpage login password is ${pwstring}"
   fi

    # Final completion message to user
    whiptail --msgbox --backtitle "Make it so." --title "Installation Complete!" "Configure your devices to use the Pi-hole as their DNS server using:

IPv4:	${IPV4_ADDRESS%/*}
IPv6:	${IPV6_ADDRESS:-"Not Configured"}

If you have not done so already, the above IP should be set to static.

The install log is in /etc/pihole.

${additional}" "${r}" "${c}"
}

update_dialogs() {
    # If pihole -r "reconfigure" option was selected,
    if [[ "${reconfigure}" = true ]]; then
        # set some variables that will be used
        opt1a="Repair"
        opt1b="This will retain existing settings"
        strAdd="You will remain on the same version"
    else
        # Otherwise, set some variables with different values
        opt1a="Update"
        opt1b="This will retain existing settings."
        strAdd="You will be updated to the latest version."
    fi
    opt2a="Reconfigure"
    opt2b="Resets Pi-hole and allows re-selecting settings."

    # Display the information to the user
    UpdateCmd=$(whiptail --title "Existing Install Detected!" --menu "\\n\\nWe have detected an existing install.\\n\\nPlease choose from the following options: \\n($strAdd)" "${r}" "${c}" 2 \
    "${opt1a}"  "${opt1b}" \
    "${opt2a}"  "${opt2b}" 3>&2 2>&1 1>&3) || \
    { printf "  %bCancel was selected, exiting installer%b\\n" "${COL_LIGHT_RED}" "${COL_NC}"; exit 1; }

    # Set the variable based on if the user chooses
    case ${UpdateCmd} in
        # repair, or
        ${opt1a})
            printf "  %b %s option selected\\n" "${INFO}" "${opt1a}"
            useUpdateVars=true
            ;;
        # reconfigure,
        ${opt2a})
            printf "  %b %s option selected\\n" "${INFO}" "${opt2a}"
            useUpdateVars=false
            ;;
    esac
}

check_download_exists() {
    status=$(curl --head --silent "https://ftl.pi-hole.net/${1}" | head -n 1)
    if grep -q "404" <<< "$status"; then
        return 1
    else
        return 0
    fi
}

fully_fetch_repo() {
    # Add upstream branches to shallow clone
    local directory="${1}"

    cd "${directory}" || return 1
    if is_repo "${directory}"; then
        git remote set-branches origin '*' || return 1
        git fetch --quiet || return 1
    else
        return 1
    fi
    return 0
}

get_available_branches() {
    # Return available branches
    local directory
    directory="${1}"
    local output

    cd "${directory}" || return 1
    # Get reachable remote branches, but store STDERR as STDOUT variable
    output=$( { git ls-remote --heads --quiet | cut -d'/' -f3- -; } 2>&1 )
    # echo status for calling function to capture
    echo "$output"
    return
}

fetch_checkout_pull_branch() {
    # Check out specified branch
    local directory
    directory="${1}"
    local branch
    branch="${2}"

    # Set the reference for the requested branch, fetch, check it put and pull it
    cd "${directory}" || return 1
    git remote set-branches origin "${branch}" || return 1
    git stash --all --quiet &> /dev/null || true
    git clean --quiet --force -d || true
    git fetch --quiet || return 1
    checkout_pull_branch "${directory}" "${branch}" || return 1
}

checkout_pull_branch() {
    # Check out specified branch
    local directory
    directory="${1}"
    local branch
    branch="${2}"
    local oldbranch

    cd "${directory}" || return 1

    oldbranch="$(git symbolic-ref HEAD)"

    str="Switching to branch: '${branch}' from '${oldbranch}'"
    printf "  %b %s" "${INFO}" "$str"
    git checkout "${branch}" --quiet || return 1
    printf "%b  %b %s\\n" "${OVER}" "${TICK}" "$str"
    # Data in the repositories is public anyway so we can make it readable by everyone (+r to keep executable permission if already set by git)
    chmod -R a+rX "${directory}"

    git_pull=$(git pull || return 1)

    if [[ "$git_pull" == *"up-to-date"* ]]; then
        printf "  %b %s\\n" "${INFO}" "${git_pull}"
    else
        printf "%s\\n" "$git_pull"
    fi

    return 0
}

clone_or_update_repos() {
    # If the user wants to reconfigure,
    if [[ "${reconfigure}" == true ]]; then
        printf "  %b Performing reconfiguration, skipping download of local repos\\n" "${INFO}"
        # Reset the Core repo
        resetRepo ${PI_HOLE_LOCAL_REPO} || \
        { printf "  %bUnable to reset %s, exiting installer%b\\n" "${COL_LIGHT_RED}" "${PI_HOLE_LOCAL_REPO}" "${COL_NC}"; \
        exit 1; \
        }
        # If the Web interface was installed,
        if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then
            # reset it's repo
            resetRepo ${webInterfaceDir} || \
            { printf "  %bUnable to reset %s, exiting installer%b\\n" "${COL_LIGHT_RED}" "${webInterfaceDir}" "${COL_NC}"; \
            exit 1; \
            }
        fi
    # Otherwise, a repair is happening
    else
        # so get git files for Core
        getGitFiles ${PI_HOLE_LOCAL_REPO} ${piholeGitUrl} || \
        { printf "  %bUnable to clone %s into %s, unable to continue%b\\n" "${COL_LIGHT_RED}" "${piholeGitUrl}" "${PI_HOLE_LOCAL_REPO}" "${COL_NC}"; \
        exit 1; \
        }
        # If the Web interface was installed,
        if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then
            # get the Web git files
            getGitFiles ${webInterfaceDir} ${webInterfaceGitUrl} || \
            { printf "  %bUnable to clone %s into ${webInterfaceDir}, exiting installer%b\\n" "${COL_LIGHT_RED}" "${webInterfaceGitUrl}" "${COL_NC}"; \
            exit 1; \
            }
        fi
    fi
}

# Download FTL binary to random temp directory and install FTL binary
# Disable directive for SC2120 a value _can_ be passed to this function, but it is passed from an external script that sources this one
# shellcheck disable=SC2120
FTLinstall() {
    # Local, named variables
    local latesttag
    local str="Downloading and Installing FTL"
    printf "  %b %s..." "${INFO}" "${str}"

    # Move into the temp ftl directory
    pushd "$(mktemp -d)" > /dev/null || { printf "Unable to make temporary directory for FTL binary download\\n"; return 1; }

    # Always replace pihole-FTL.service
    install -T -m 0755 "${PI_HOLE_LOCAL_REPO}/advanced/Templates/pihole-FTL.service" "/etc/init.d/pihole-FTL"

    local ftlBranch
    local url

    if [[ -f "/etc/pihole/ftlbranch" ]];then
        ftlBranch=$(</etc/pihole/ftlbranch)
    else
        ftlBranch="master"
    fi

    local binary
    binary="${1}"

    # Determine which version of FTL to download
    if [[ "${ftlBranch}" == "master" ]];then
        url="https://github.com/pi-hole/ftl/releases/latest/download"
    else
        url="https://ftl.pi-hole.net/${ftlBranch}"
    fi

    if curl -sSL --fail "${url}/${binary}" -o "${binary}"; then
        # If the download worked, get sha1 of the binary we just downloaded for verification.
        curl -sSL --fail "${url}/${binary}.sha1" -o "${binary}.sha1"

        # If we downloaded binary file (as opposed to text),
        if sha1sum --status --quiet -c "${binary}".sha1; then
            printf "transferred... "

            # Before stopping FTL, we download the macvendor database
            curl -sSL "https://ftl.pi-hole.net/macvendor.db" -o "${PI_HOLE_CONFIG_DIR}/macvendor.db" || true

            # Stop pihole-FTL service if available
            stop_service pihole-FTL &> /dev/null

            # Install the new version with the correct permissions
            install -T -m 0755 "${binary}" /usr/bin/pihole-FTL

            # Move back into the original directory the user was in
            popd > /dev/null || { printf "Unable to return to original directory after FTL binary download.\\n"; return 1; }

            # Installed the FTL service
            printf "%b  %b %s\\n" "${OVER}" "${TICK}" "${str}"
            return 0
        else
            # Otherwise, the hash download failed, so print and exit.
            popd > /dev/null || { printf "Unable to return to original directory after FTL binary download.\\n"; return 1; }
            printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
            printf "  %bError: Download of %s/%s failed (checksum error)%b\\n" "${COL_LIGHT_RED}" "${url}" "${binary}" "${COL_NC}"
            return 1
        fi
    else
        # Otherwise, the download failed, so print and exit.
        popd > /dev/null || { printf "Unable to return to original directory after FTL binary download.\\n"; return 1; }
        printf "%b  %b %s\\n" "${OVER}" "${CROSS}" "${str}"
        # The URL could not be found
        printf "  %bError: URL %s/%s not found%b\\n" "${COL_LIGHT_RED}" "${url}" "${binary}" "${COL_NC}"
        return 1
    fi
}

disable_dnsmasq() {
    # dnsmasq can now be stopped and disabled if it exists
    if which dnsmasq &> /dev/null; then
        if check_service_active "dnsmasq";then
            printf "  %b FTL can now resolve DNS Queries without dnsmasq running separately\\n" "${INFO}"
            stop_service dnsmasq
            disable_service dnsmasq
        fi
    fi

    # Backup existing /etc/dnsmasq.conf if present and ensure that
    # /etc/dnsmasq.conf contains only "conf-dir=/etc/dnsmasq.d"
    local conffile="/etc/dnsmasq.conf"
    if [[ -f "${conffile}" ]]; then
        printf "  %b Backing up %s to %s.old\\n" "${INFO}" "${conffile}" "${conffile}"
        mv "${conffile}" "${conffile}.old"
    fi
    # Create /etc/dnsmasq.conf
    echo "conf-dir=/etc/dnsmasq.d" > "${conffile}"
    chmod 644 "${conffile}"
}

get_binary_name() {
    # This gives the machine architecture which may be different from the OS architecture...
    local machine
    machine=$(uname -m)

    local l_binary

    local str="Detecting processor"
    printf "  %b %s..." "${INFO}" "${str}"
    # If the machine is arm or aarch
    if [[ "${machine}" == "arm"* || "${machine}" == *"aarch"* ]]; then
        # ARM
        local rev
        rev=$(uname -m | sed "s/[^0-9]//g;")
        local lib
        lib=$(ldd /bin/ls | grep -E '^\s*/lib' | awk '{ print $1 }')
        if [[ "${lib}" == "/lib/ld-linux-aarch64.so.1" ]]; then
            printf "%b  %b Detected AArch64 (64 Bit ARM) processor\\n" "${OVER}" "${TICK}"
            # set the binary to be used
            l_binary="pihole-FTL-aarch64-linux-gnu"
        elif [[ "${lib}" == "/lib/ld-linux-armhf.so.3" ]]; then
            # Hard-float available: Use gnueabihf binaries
            # If ARMv8 or higher is found (e.g., BCM2837 as found in Raspberry Pi Model 3B)
            if [[ "${rev}" -gt 7 ]]; then
                printf "%b  %b Detected ARMv8 (or newer) processor\\n" "${OVER}" "${TICK}"
                # set the binary to be used
                l_binary="pihole-FTL-armv8-linux-gnueabihf"
            elif [[ "${rev}" -eq 7 ]]; then
                # Otherwise, if ARMv7 is found (e.g., BCM2836 as found in Raspberry Pi Model 2)
                printf "%b  %b Detected ARMv7 processor (with hard-float support)\\n" "${OVER}" "${TICK}"
                # set the binary to be used
                l_binary="pihole-FTL-armv7-linux-gnueabihf"
            else
                # Otherwise, use the ARMv6 binary (e.g., BCM2835 as found in Raspberry Pi Zero and Model 1)
                printf "%b  %b Detected ARMv6 processor (with hard-float support)\\n" "${OVER}" "${TICK}"
                # set the binary to be used
                l_binary="pihole-FTL-armv6-linux-gnueabihf"
            fi
        else
            # No hard-float support found: Use gnueabi binaries
            # Use the ARMv4-compliant binary only if we detected an ARMv4T core
            if [[ "${rev}" -eq 4 ]]; then
                printf "%b  %b Detected ARMv4 processor\\n" "${OVER}" "${TICK}"
                # set the binary to be used
                l_binary="pihole-FTL-armv4-linux-gnueabi"
            # Otherwise, use the ARMv5 binary. To date (end of 2020), all modern ARM processors
            # are backwards-compatible to the ARMv5
            else
                printf "%b  %b Detected ARMv5 (or newer) processor\\n" "${OVER}" "${TICK}"
                # set the binary to be used
                l_binary="pihole-FTL-armv5-linux-gnueabi"
            fi
        fi
    elif [[ "${machine}" == "x86_64" ]]; then
        # This gives the processor of packages dpkg installs (for example, "i386")
        local dpkgarch
        dpkgarch=$(dpkg --print-processor 2> /dev/null || dpkg --print-architecture 2> /dev/null)

        # Special case: This is a 32 bit OS, installed on a 64 bit machine
        # -> change machine processor to download the 32 bit executable
        # We only check this for Debian-based systems as this has been an issue
        # in the past (see https://github.com/pi-hole/pi-hole/pull/2004)
        if [[ "${dpkgarch}" == "i386" ]]; then
            printf "%b  %b Detected 32bit (i686) processor\\n" "${OVER}" "${TICK}"
            l_binary="pihole-FTL-linux-x86_32"
        else
            # 64bit
            printf "%b  %b Detected x86_64 processor\\n" "${OVER}" "${TICK}"
            # set the binary to be used
            l_binary="pihole-FTL-linux-x86_64"
        fi
    else
        # Something else - we try to use 32bit executable and warn the user
        if [[ ! "${machine}" == "i686" ]]; then
            printf "%b  %b %s...\\n" "${OVER}" "${CROSS}" "${str}"
            printf "  %b %bNot able to detect processor (unknown: %s), trying x86 (32bit) executable%b\\n" "${INFO}" "${COL_LIGHT_RED}" "${machine}" "${COL_NC}"
            printf "  %b Contact Pi-hole Support if you experience issues (e.g: FTL not running)\\n" "${INFO}"
        else
            printf "%b  %b Detected 32bit (i686) processor\\n" "${OVER}" "${TICK}"
        fi
        l_binary="pihole-FTL-linux-x86_32"
    fi

    # Returning a string value via echo
    echo ${l_binary}
}

FTLcheckUpdate() {
    #In the next section we check to see if FTL is already installed (in case of pihole -r).
    #If the installed version matches the latest version, then check the installed sha1sum of the binary vs the remote sha1sum. If they do not match, then download
    printf "  %b Checking for existing FTL binary...\\n" "${INFO}"

    local ftlLoc
    ftlLoc=$(which pihole-FTL 2>/dev/null)

    local ftlBranch

    if [[ -f "/etc/pihole/ftlbranch" ]];then
        ftlBranch=$(</etc/pihole/ftlbranch)
    else
        ftlBranch="master"
    fi

    local binary
    binary="${1}"

    local remoteSha1
    local localSha1

    # if dnsmasq exists and is running at this point, force reinstall of FTL Binary
    if which dnsmasq &> /dev/null; then
        if check_service_active "dnsmasq";then
            return 0
        fi
    fi

    if [[ ! "${ftlBranch}" == "master" ]]; then
        #Check whether or not the binary for this FTL branch actually exists. If not, then there is no update!
        local path
        path="${ftlBranch}/${binary}"
        # shellcheck disable=SC1090
        if ! check_download_exists "$path"; then
            printf "  %b Branch \"%s\" is not available.\\n" "${INFO}" "${ftlBranch}"
            printf "  %b Use %bpihole checkout ftl [branchname]%b to switch to a valid branch.\\n" "${INFO}" "${COL_LIGHT_GREEN}" "${COL_NC}"
            return 2
        fi

        if [[ ${ftlLoc} ]]; then
            # We already have a pihole-FTL binary downloaded.
            # Alt branches don't have a tagged version against them, so just confirm the checksum of the local vs remote to decide whether we download or not
            remoteSha1=$(curl -sSL --fail "https://ftl.pi-hole.net/${ftlBranch}/${binary}.sha1" | cut -d ' ' -f 1)
            localSha1=$(sha1sum "$(which pihole-FTL)" | cut -d ' ' -f 1)

            if [[ "${remoteSha1}" != "${localSha1}" ]]; then
                printf "  %b Checksums do not match, downloading from ftl.pi-hole.net.\\n" "${INFO}"
                return 0
            else
                printf "  %b Checksum of installed binary matches remote. No need to download!\\n" "${INFO}"
                return 1
            fi
        else
            return 0
        fi
    else
        if [[ ${ftlLoc} ]]; then
            local FTLversion
            FTLversion=$(/usr/bin/pihole-FTL tag)
            local FTLlatesttag

            if ! FTLlatesttag=$(curl -sI https://github.com/pi-hole/FTL/releases/latest | grep --color=never -i Location: | awk -F / '{print $NF}' | tr -d '[:cntrl:]'); then
                # There was an issue while retrieving the latest version
                printf "  %b Failed to retrieve latest FTL release metadata" "${CROSS}"
                return 3
            fi

            if [[ "${FTLversion}" != "${FTLlatesttag}" ]]; then
                return 0
            else
                printf "  %b Latest FTL Binary already installed (%s). Confirming Checksum...\\n" "${INFO}" "${FTLlatesttag}"

                remoteSha1=$(curl -sSL --fail "https://github.com/pi-hole/FTL/releases/download/${FTLversion%$'\r'}/${binary}.sha1" | cut -d ' ' -f 1)
                localSha1=$(sha1sum "$(which pihole-FTL)" | cut -d ' ' -f 1)

                if [[ "${remoteSha1}" != "${localSha1}" ]]; then
                    printf "  %b Corruption detected...\\n" "${INFO}"
                    return 0
                else
                    printf "  %b Checksum correct. No need to download!\\n" "${INFO}"
                    return 1
                fi
            fi
        else
            return 0
        fi
    fi
}

# Detect suitable FTL binary platform
FTLdetect() {
    printf "\\n  %b FTL Checks...\\n\\n" "${INFO}"

    printf "  %b" "${2}"

    if FTLcheckUpdate "${1}"; then
        FTLinstall "${1}" || return 1
    fi
}

make_temporary_log() {
    # Create a random temporary file for the log
    TEMPLOG=$(mktemp /tmp/pihole_temp.XXXXXX)
    # Open handle 3 for templog
    # https://stackoverflow.com/questions/18460186/writing-outputs-to-log-file-and-console
    exec 3>"$TEMPLOG"
    # Delete templog, but allow for addressing via file handle
    # This lets us write to the log without having a temporary file on the drive, which
    # is meant to be a security measure so there is not a lingering file on the drive during the install process
    rm "$TEMPLOG"
}

copy_to_install_log() {
    # Copy the contents of file descriptor 3 into the install log
    # Since we use color codes such as '\e[1;33m', they should be removed
    sed 's/\[[0-9;]\{1,5\}m//g' < /proc/$$/fd/3 > "${installLogLoc}"
    chmod 644 "${installLogLoc}"
}

main() {
    ######## FIRST CHECK ########
    # Must be root to install
    local str="Root user check"
    printf "\\n"

    # If the user's id is zero,
    if [[ "${EUID}" -eq 0 ]]; then
        # they are root and all is good
        printf "  %b %s\\n" "${TICK}" "${str}"
        # Show the Pi-hole logo so people know it's genuine since the logo and name are trademarked
        show_ascii_berry
        make_temporary_log
    else
        # Otherwise, they do not have enough privileges, so let the user know
        printf "  %b %s\\n" "${INFO}" "${str}"
        printf "  %b %bScript called with non-root privileges%b\\n" "${INFO}" "${COL_LIGHT_RED}" "${COL_NC}"
        printf "      The Pi-hole requires elevated privileges to install and run\\n"
        printf "      Please check the installer for any concerns regarding this requirement\\n"
        printf "      Make sure to download this script from a trusted source\\n\\n"
        printf "  %b Sudo utility check" "${INFO}"

        # If the sudo command exists, try rerunning as admin
        if is_command sudo ; then
            printf "%b  %b Sudo utility check\\n" "${OVER}"  "${TICK}"

            # when run via curl piping
            if [[ "$0" == "bash" ]]; then
                # Download the install script and run it with admin rights
                exec curl -sSL https://raw.githubusercontent.com/pi-hole/pi-hole/master/automated%20install/basic-install.sh | sudo bash "$@"
            else
                # when run via calling local bash script
                exec sudo bash "$0" "$@"
            fi

            exit $?
        else
            # Otherwise, tell the user they need to run the script as root, and bail
            printf "%b  %b Sudo utility check\\n" "${OVER}" "${CROSS}"
            printf "  %b Sudo is needed for the Web Interface to run pihole commands\\n\\n" "${INFO}"
            printf "  %b %bPlease re-run this installer as root${COL_NC}\\n" "${INFO}" "${COL_LIGHT_RED}"
            exit 1
        fi
    fi

    # Check for supported package managers so that we may install dependencies
    package_manager_detect

    # Notify user of package availability
    notify_package_updates_available

    # Install packages necessary to perform os_check
    printf "  %b Checking for / installing Required dependencies for OS Check...\\n" "${INFO}"
    install_dependent_packages "${OS_CHECK_DEPS[@]}"

    # Check that the installed OS is officially supported - display warning if not
    os_check

    # Install packages used by this installation script
    printf "  %b Checking for / installing Required dependencies for this install script...\\n" "${INFO}"
    install_dependent_packages "${INSTALLER_DEPS[@]}"

    #In case of RPM based distro, select the proper PHP version
    if [[ "$PKG_MANAGER" == "yum" || "$PKG_MANAGER" == "dnf" ]] ; then
      select_rpm_php
    fi

    # Check if SELinux is Enforcing
    checkSelinux

    # If the setup variable file exists,
    if [[ -f "${setupVars}" ]]; then
        # if it's running unattended,
        if [[ "${runUnattended}" == true ]]; then
            printf "  %b Performing unattended setup, no whiptail dialogs will be displayed\\n" "${INFO}"
            # Use the setup variables
            useUpdateVars=true
            # also disable debconf-apt-progress dialogs
            export DEBIAN_FRONTEND="noninteractive"
        else
            # If running attended, show the available options (repair/reconfigure)
            update_dialogs
        fi
    fi

    if [[ "${useUpdateVars}" == false ]]; then
        # Display welcome dialogs
        welcomeDialogs
        # Create directory for Pi-hole storage
        install -d -m 755 /etc/pihole/
        # Determine available interfaces
        get_available_interfaces
        # Find interfaces and let the user choose one
        chooseInterface
        # Decide what upstream DNS Servers to use
        setDNS
        # Give the user a choice of blocklists to include in their install. Or not.
        chooseBlocklists
        # Let the user decide if they want to block ads over IPv4 and/or IPv6
        use4andor6
        # Let the user decide if they want the web interface to be installed automatically
        setAdminFlag
        # Let the user decide if they want query logging enabled...
        setLogging
        # Let the user decide the FTL privacy level
        setPrivacyLevel
    else
        # Setup adlist file if not exists
        installDefaultBlocklists

        # Source ${setupVars} to use predefined user variables in the functions
        source "${setupVars}"

        # Get the privacy level if it exists (default is 0)
        if [[ -f "${PI_HOLE_CONFIG_DIR}/pihole-FTL.conf" ]]; then
            PRIVACY_LEVEL=$(sed -ne 's/PRIVACYLEVEL=\(.*\)/\1/p' "${PI_HOLE_CONFIG_DIR}/pihole-FTL.conf")

            # If no setting was found, default to 0
            PRIVACY_LEVEL="${PRIVACY_LEVEL:-0}"
        fi
    fi
    # Download or update the scripts by updating the appropriate git repos
    clone_or_update_repos

    # Install the Core dependencies
    local dep_install_list=("${PIHOLE_DEPS[@]}")
    if [[ "${INSTALL_WEB_SERVER}" == true ]]; then
        # And, if the setting says so, install the Web admin interface dependencies
        dep_install_list+=("${PIHOLE_WEB_DEPS[@]}")
    fi

    # Install packages used by the actual software
    printf "  %b Checking for / installing Required dependencies for Pi-hole software...\\n" "${INFO}"
    install_dependent_packages "${dep_install_list[@]}"
    unset dep_install_list

    # On some systems, lighttpd is not enabled on first install. We need to enable it here if the user
    # has chosen to install the web interface, else the LIGHTTPD_ENABLED check will fail
    if [[ "${INSTALL_WEB_SERVER}" == true ]]; then
        enable_service lighttpd
    fi
    # Determine if lighttpd is correctly enabled
    if check_service_active "lighttpd"; then
        LIGHTTPD_ENABLED=true
    else
        LIGHTTPD_ENABLED=false
    fi
    # Create the pihole user
    create_pihole_user

    # Check if FTL is installed - do this early on as FTL is a hard dependency for Pi-hole
    local funcOutput
    funcOutput=$(get_binary_name) #Store output of get_binary_name here
    local binary
    binary="pihole-FTL${funcOutput##*pihole-FTL}" #binary name will be the last line of the output of get_binary_name (it always begins with pihole-FTL)
    local theRest
    theRest="${funcOutput%pihole-FTL*}" # Print the rest of get_binary_name's output to display (cut out from first instance of "pihole-FTL")
    if ! FTLdetect "${binary}" "${theRest}"; then
        printf "  %b FTL Engine not installed\\n" "${CROSS}"
        exit 1
    fi

    # Install and log everything to a file
    installPihole | tee -a /proc/$$/fd/3

    # Copy the temp log file into final log location for storage
    copy_to_install_log

    if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then
        # Add password to web UI if there is none
        pw=""
        # If no password is set,
        if [[ $(grep 'WEBPASSWORD' -c /etc/pihole/setupVars.conf) == 0 ]] ; then
            # generate a random password
            pw=$(tr -dc _A-Z-a-z-0-9 < /dev/urandom | head -c 8)
            # shellcheck disable=SC1091
            . /opt/pihole/webpage.sh
            echo "WEBPASSWORD=$(HashPassword "${pw}")" >> "${setupVars}"
        fi
    fi

    # Check for and disable systemd-resolved-DNSStubListener before reloading resolved
    # DNSStubListener needs to remain in place for installer to download needed files,
    # so this change needs to be made after installation is complete,
    # but before starting or resarting the dnsmasq or ftl services
    disable_resolved_stublistener

    # If the Web server was installed,
    if [[ "${INSTALL_WEB_SERVER}" == true ]]; then
        if [[ "${LIGHTTPD_ENABLED}" == true ]]; then
            restart_service lighttpd
            enable_service lighttpd
        else
            printf "  %b Lighttpd is disabled, skipping service restart\\n" "${INFO}"
        fi
    fi

    printf "  %b Restarting services...\\n" "${INFO}"
    # Start services

    # Enable FTL
    # Ensure the service is enabled before trying to start it
    # Fixes a problem reported on Ubuntu 18.04 where trying to start
    # the service before enabling causes installer to exit
    enable_service pihole-FTL
    restart_service pihole-FTL

    # Download and compile the aggregated block list
    runGravity

    # Force an update of the updatechecker
    /opt/pihole/updatecheck.sh
    /opt/pihole/updatecheck.sh x remote

    if [[ "${useUpdateVars}" == false ]]; then
        displayFinalMessage "${pw}"
    fi

    # If the Web interface was installed,
    if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then
        # If there is a password,
        if (( ${#pw} > 0 )) ; then
            # display the password
            printf "  %b Web Interface password: %b%s%b\\n" "${INFO}" "${COL_LIGHT_GREEN}" "${pw}" "${COL_NC}"
            printf "  %b This can be changed using 'pihole -a -p'\\n\\n" "${INFO}"
        fi
    fi

    if [[ "${useUpdateVars}" == false ]]; then
        # If the Web interface was installed,
        if [[ "${INSTALL_WEB_INTERFACE}" == true ]]; then
            printf "  %b View the web interface at http://pi.hole/admin or http://%s/admin\\n\\n" "${INFO}" "${IPV4_ADDRESS%/*}"
        fi
        # Explain to the user how to use Pi-hole as their DNS server
        printf "  %b You may now configure your devices to use the Pi-hole as their DNS server\\n" "${INFO}"
        [[ -n "${IPV4_ADDRESS%/*}" ]] && printf "  %b Pi-hole DNS (IPv4): %s\\n" "${INFO}" "${IPV4_ADDRESS%/*}"
        [[ -n "${IPV6_ADDRESS}" ]] && printf "  %b Pi-hole DNS (IPv6): %s\\n" "${INFO}" "${IPV6_ADDRESS}"
        printf "  %b If you have not done so already, the above IP should be set to static.\\n" "${INFO}"
        INSTALL_TYPE="Installation"
    else
        INSTALL_TYPE="Update"
    fi

    # Display where the log file is
    printf "\\n  %b The install log is located at: %s\\n" "${INFO}" "${installLogLoc}"
    printf "%b%s Complete! %b\\n" "${COL_LIGHT_GREEN}" "${INSTALL_TYPE}" "${COL_NC}"

    if [[ "${INSTALL_TYPE}" == "Update" ]]; then
        printf "\\n"
        "${PI_HOLE_BIN_DIR}"/pihole version --current
    fi
}

if [[ "${PH_TEST}" != true ]] ; then
    main "$@"
fi
