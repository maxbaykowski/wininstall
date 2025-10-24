#!/bin/bash
#This script allows a Linux only installation of Windows, using tools like wimlib and disk
#formatting utilities.
#QEMU is used to start a small Windows PE environment which uses
#You need the folowing utilities in order to run this script:
#awk to parse command line output
#dosfstools for handling of FAT partitions. A FAT32 EFI System Partition is required on GPT
#formatted disks.
#mkisofs (required to generate a Windows PE image to cary out steps Linux can't do)
#ntfs-3g for handling of NTFS partitions
#qemu-system-x86_64 to run the generated Windows PE image
#sfdisk for the automated partitioning of disks
#wimlib for manipulation and extraction of WIM files
#xmlstarlet for parsing XML data in WIM images
#Hardware virtualization will greatly speed up the process of running the Windows PE in QEMU
set -o pipefail
#Define functions
function align_down {
	#Check if the disk is a block device
	is_blk "$2"
	local alignment=$(alignment_value "$2")
	#Print the alignment
	echo "$((($1 / $alignment) * $alignment))"
}
function align_up {
	#Check if the disk is a block device
	is_blk "$2"
	local alignment="$(alignment_value "$2")"
	#Print the alignment
	echo "$(((($1 + ($alignment - 1)) / $alignment) * $alignment))"
}
function alignment_value {
	#Check if the disk is a block device
	is_blk "$1"
	#Get the logical sector size of the disk
	local sectorsize="$(cat /sys/block/$(basename "$1")/queue/hw_sector_size)"
	#Now we multiply 1024*1024 for an alignment of 1 MiB, and devide that by our sector size
	echo "$((1024 * 1024 / $sectorsize))"
}
function autodetect_windows_version {
	#We use a little trick to get the major Windows version in the ISO
	local majorversion="$(xmlstarlet sel -t -m '/WIM/IMAGE' -v 'NAME' -n "$tempdir/wiminfo.xml" | awk '{print $2}' | uniq)"
	if [ "$majorversion" ] && [ "$(echo "$majorversion" | wc -l)" = 1 ]; then
		echo "$majorversion"
	else
		return 1
	fi
}
function check_reqs {
	if [ -z "$1" ]; then
		#No array was specified
		return 0
	fi
	#Otherwise we begin going through the items of the array
	for i in "${@}"; do
		if ! type "$i" 1>/dev/null 2>/dev/null; then
			#A requirement is missing
			echo "Missing requirement: $i" 1>&2
			#Next we set a local boolian variable if requirements are missing
			local missingreqs=1
		fi
	done
	if [ "$missingreqs" = "1" ]; then
		#Return 1 if requirements are missing
		return 1
	fi
}
function cleanup {
	if [ -z "$tempdir" ]; then
		return
	fi
	umount -q $tempdir/{iso,log,wim,windows,winre}
	if [ "$logloop" ]; then
		losetup -d "$logloop"
	fi
	rm -rf "$tempdir"
}
function contains_wim {
	#Ensure that the ISO file contains an install.wim file
	if [ -f "$tempdir/iso/sources/install.wim" ]; then
		export wimpath="$tempdir/iso/sources/install.wim"
		#ISO contains an install.wim
		return 0
	elif [ -f "$tempdir/iso/sources/install2.wim" ]; then
		export wimpath="$tempdir/iso/sources/install2.wim"
		#ISO contains an install2.wim
		return 0
	else
		#Couldn't find install.wim, so return 1
		return 1
	fi
}
function copy_winre {
	#First we detect if rsync is installed. It will show progress
	is_blk "$winrepart"
	#First mount the WIM image and the selected index
	if type rsync 1>/dev/null 2>/dev/null; then
		local cpcommand="rsync --human-readable --progress"
	else
		local cpcommand="cp"
	fi
	wimmount "$wimpath" "$image" "$tempdir/wim"
	#Next we mount the recovery partition
	mount "$winrepart" "$tempdir/winre"
	#Make a few nested directories
	mkdir -p "$tempdir/winre/Recovery/WindowsRE"
	#Now we copy the recovery image into the WindowsRE directory
	$cpcommand "$winre" "$tempdir/winre/Recovery/WindowsRE/"
	wimunmount "$tempdir/wim"
	umount "$tempdir/winre"
}
function create_menu {
	#$1 is assumed to be the path of the text file containing menu options
	#Check if $1 is defined
	if [ -z "$1" ]; then
		echo "Error: no text file defined" 1>&2
		return 1
	#Check if the text file really exists
	elif [ ! -f "$1" ]; then
		echo "Error: $1: No such file or directory" 1>&2
		return 1
	fi
	#Check if temp directory exists
	if [ -z "$tempdir" ]; then
		local tempdir=$(mktemp -d)
	fi
	#Get the number of lines in the file
	#each line will be presented as an option to the user
	local end=$(cat "$1" | wc -l)
	#Define menu title
	if [ "$2" ]; then
		echo "$2" >$tempdir/menulist
	else
		echo "Please select an option" >$tempdir/menulist
	fi
	#parse options
	for i in $(seq 1 $end); do
		echo "$i $(sed -n "${i}p" "$1")" >>$tempdir/menulist
	done
	#Display menu options to the user
	cat $tempdir/menulist 1>&2
	#Determine how to take user input
	#A menu with more than 10 options will require the user to press enter after typing in the
	#number corisponding to the option
	if [ "$end" -lt 10 ]; then
		echo "enter a number" 1>&2
	else
		echo "Enter a number, then press enter" 1>&2
	fi
	#Take input from user
	while true; do
		if [ "$end" -lt 10 ]; then
			read -sn 1 char #For menus with less than 10 options
		else
			read -e char #For menus that have more than 10 options
		fi
		#Check if input is a valid option
		for i in $(seq 1 $end); do
			if [ "$char" = "$i" ]; then
				#Export option and menu item name to shell
				export option=$char
				export itemname=$(sed -n "${option}p" "$1")
				return
			fi
		done
		#Now we're back to the main loop
		#If the loop has come this far then the user input doesn't match any of the menu options
		#We throw an error and the loop restarts
		if [ $end -ge 10 ]; then
			echo "Error: invalid option. Try again." 1>&2
		fi
		#A menu with less than 10 options will display nothing as the script ignores invalid single digits
	done
}
function detect_fw {
	#Determine if we are on UEFI or old BIOS by checking if /sys/firmware/efi exists
	if [ -e /sys/firmware/efi ]; then
		#We're on UEFI
		echo "uefi"
	else
		#We're on BIOS
		echo "bios"
	fi
}
function detect_mct {
	#I don't like the Media Creation Tool.
	#That's why I won't support it in this script!
	#Check if ISO contains an install.esd file
	if [ -f "$tempdir/iso/sources/install.esd" ]; then
		#ISO contains an install.esd file
		return 0
	else
		#ISO does not contain an install.esd file
		return 1
	fi
}
function detect_winre {
	#First mount the WIM image and the selected index
	wimmount "$wimpath" "$image" "$tempdir/wim" || return 2
	#A return value of 2 means failed
	#Next we search for the recovery image in the System32 directory
	#This is a pain because Linux file names are case sensitive and Windows isn't
	if [ -f "$tempdir/wim/Windows/System32/Recovery/Winre.wim" ] || [ -f "$tempdir/wim/Windows/System32/Recovery/winRE.wim" ]; then
		echo "$tempdir/wim/Windows/System32/Recovery/"*.wim
		wimunmount "$tempdir/wim"
		return 0
	else
		wimunmount "$tempdir/wim"
		return 1
	fi
}
function disk_select {
	local i=""
	#Print disks to a file
	lsblk -bde7 -lnoNAME,SIZE -p | numfmt --field=2 --to=si >"$tempdir/disks"
	#Echo the refresh option
	echo "Refresh" >>"$tempdir/disks"
	while [ -z "$i" ]; do
		#Here comes the fun part
		clear
		create_menu "$tempdir/disks" "Please Select the Disk where Windows should be installed"
		local i="$(echo "$itemname" | awk '{print $1}')"
		if [ "$itemname" = "Refresh" ]; then
			unset i
			#Print disks to file, overwriting the original
			lsblk -bde7 -lnoNAME,SIZE -p | numfmt --field=2 --to=si >"$tempdir/disks"
			#Echo the refresh option
			echo "Refresh" >>"$tempdir/disks"
			continue
		elif [ "$(lsblk -bdlnoSIZE "$i")" -lt "$minsize" ]; then
			#The disk is too small
			echo "Error: Disk must be at least $$print_in_human_readable_format) in size" 1>&2
			unset i
			continue
		fi
	done
	#All checks have completed, so we Print the disk to stdout
	export disk="$i"
}
function extract_xml {
	wiminfo --extract-xml "$tempdir/wiminfo.xml" "$1"
}
function file_is_iso {
	#Ensure the ISO file selected ends with .iso and not some random ass file extension
	if [[ "$1" == *.iso ]] || [[ "$1" == *.ISO ]]; then
		#File extensionends with .iso
		return 0
	else
		#The file isn't an iso so we return a value of 1
		return 1
	fi
}
function format_boot {
	is_blk "$bootpart"
	mkfs.ntfs -f "$bootpart"
}
function format_efi {
	is_blk "$efipart"
	#Check if the ESP already contains a FAT32 filesystem
	if [ "$(lsblk -nloFSVER)" = "FAT32" ] && [ "$(yes_no "Your EFI System Partition already contains a FAT32 filesystem. Format anyway?")" = "n" ]; then
		#We return a value of 0 if both statements are true
		return 0
	fi
	mkfs.vfat -F32 "$efipart"
}
function format_main {
	is_blk "$datapart"
	mkfs.ntfs -f "$datapart"
}
function format_partitions_bios {
	#The script needs to exit if any of these commands fail
	set -e
	format_boot
	if [ "$datapart" ]; then
		format_main
	fi
	if [ "$winrepart" ]; then
		format_winre
	fi
}
function format_partitions_uefi {
	#The script needs to exit if any of these commands fail
	set -e
	format_efi
	format_main
	if [ "$winrepart" ]; then
		format_winre
	fi
}
function format_winre {
	is_blk "$winrepart"
	mkfs.ntfs -f "$winrepart"
}
function generate_diskpart_script_bios {
	cat <<EOF
select disk 0
select partition $bootnum
assign letter=S
EOF
	if [ "$datapart" ] && [ "$datanum" ]; then
		#Assign the letter W to the Windows partition
		cat <<EOF
select partition $datanum
assign letter=W
EOF
	fi
	if [ "$winrepart" ] && [ "$winrenum" ]; then
		#Assign the letter R to the Windows partition
		cat <<EOF
select partition $winrenum
assign letter=R
EOF
	fi
}
function generate_diskpart_script_uefi {
	cat <<EOF
select disk 0
select partition $efinum
assign letter=S
select partition $datanum
assign letter=W
EOF
	if [ "$winrepart" ] && [ "$winrenum" ]; then
		#Assign the letter R to the recovery partition
		cat <<EOF
select partition $winrenum
assign letter=R
EOF
	fi
}
function generate_install_script_bios {
	#This is the function that will set up BCD entries as well as register WindowsRE (if present)
	if [ "$bootnum" ] && [ -z "$datanum" ]; then
		#We set the Windows drive letter as S to avoid code complexity
		local windowsletter=S
	else
		local windowsletter=W
	fi
	cat <<EOF
@echo off
diskpart /s X:\mountparts
bcdboot $windowsletter:\Windows /s S:
bootsect /nt60 S: /mbr
EOF
	if [ "$winrepart" ] && [ "$winrenum" ]; then
		#Register Windows Recovery
		cat <<EOF
$windowsletter:\Windows\System32\Reagentc /Setreimage /Path R:\Recovery\WindowsRE /Target $windowsletter:\Windows
$windowsletter:\Windows\System32\Reagentc /Setosimage /Path R:\Recovery\WindowsRE /index 1 /Target $windowsletter:\Windows
$windowsletter:\Windows\System32\Reagentc /Enable /Target $windowsletter:\Windows
EOF
	fi
}
function generate_install_script_uefi {
	#This is the function that will set up BCD entries as well as register WindowsRE (if present)
	cat <<EOF
@echo off
diskpart /s X:\mountparts
bcdboot W:\Windows /s S: /f UEFI
EOF
	if [ "$winrepart" ] && [ "$winrenum" ]; then
		#Register Windows Recovery
		cat <<EOF
W:\Windows\System32\Reagentc /Setreimage /Path R:\Recovery\WindowsRE /Target W:\Windows
W:\Windows\System32\Reagentc /Setosimage /Path R:\Recovery\WindowsRE /index 1 /Target W:\Windows
EOF
	fi
}
function generate_install_scripts {
	#Make scripts directory
	mkdir -p "$tempdir/scripts"
	generate_logmount_script >"$tempdir/scripts/logmount"
	#Now for the log script itself
	generate_log_script >"$tempdir/scripts/logoutput.bat"
	#Next we generate the actual install scripts
	generate_diskpart_script_$fw >"$tempdir/scripts/mountparts"
	generate_install_script_$fw >"$tempdir/scripts/install.bat"
}
function generate_log_script {
	cat <<EOF
@echo off
setlocal
diskpart /s X:\logmount > NUL 2>&1
cmd /v:off /c "call X:\install.bat" >> L:\log.txt 2>&1
timeout /t 2 > NUL
wpeutil shutdown
EOF
}
function generate_logmount_script {
	cat <<EOF
select disk 1
select partition 1
assign letter=L
EOF
}
function generate_sfdisk_script_bios {
	is_blk "$1"
	local total="$(total_sectors "$1")"
	#We get the last usable sector by subtracting 1
	local last="$(($total - 1))"
	#Now we align that value to the nearest one MiB boundary
	local alignedend="$(align_down "$last" "$1")"
	local used="$(alignment_value "$1")"
	#Print the script header
	cat <<EOF
label: dos
device: $1
unit: sectors
EOF
	if is_removable $1; then
		local datastart=$used
		#Now we calculate the size of the data partition by subtracting the aligned start of the disk from the aligned end
		local datasize="$(align_down $(($alignedend - $datastart)) "$1")"
		cat <<EOF
start=$datastart, size=$datasize, type=7, bootable
EOF
		#We stop here, as we only need 1 partition for removable media
		return
	fi
	#If the disk is not removable
	#We calculate the geometry of the disk partitions, even before we generate the sfdisk script
	local used="$(alignment_value "$1")"
	#This is the start of our system partition
	local systemstart=$used
	#The size of our system partition is 200 MB
	local systemsize="$(align_down $(size_to_sectors 200000000 "$1") "$1")"
	#We add that to the used space
	local used=$(($used + $systemsize))
	#This is also the data partition start
	local datastart=$used
	#Before we can calculate the data partition size, we must calculate the recovery partition start and size
	local winresize="$(align_down $(size_to_sectors 650000000 "$1") "$1")"
	#Now we use this data to calculate the start of the recovery partition
	local winrestart="$(align_up $(($alignedend - $winresize)) "$1")"
	#Now we subtract the data partition start from the start of the recovery partition to get the data partition's size
	local datasize="$(align_down $(($winrestart - $datastart)) "$1")"
	#Now we print the script to stdout
	cat <<EOF
start=$systemstart, size=$systemsize, type=7, bootable
start=$datastart, size=$datasize, type=7
start=$winrestart, size=$winresize, type=27
EOF
	return 0
}
function generate_sfdisk_script_uefi {
	#This function is going to be even more of a nightmare
	is_blk "$1"
	local total="$(total_sectors "$1")"
	#The GPT header lives in the last 33 usable sectors on disk
	#As such, we get the last sector that can be used for partitioning by subtracting 34 from the total number of sectors
	local last="$(($total - 34))"
	#Now we align that value to the nearest one MiB boundary
	local alignedend="$(align_down "$last" "$1")"
	#Our used space starts at the 1 MiB boundary
	local used="$(alignment_value "$1")"
	#The ESP starts at the 1 MiB boundary, so we set it equal to the used space
	local efistart=$used
	local efisize="$(align_down $(size_to_sectors 300000000 "$1") "$1")"
	#We add that to the used space
	used=$(($used + $efisize))
	#Now for the system reserved partition
	local msrstart=$used
	local msrsize="$(align_down $(size_to_sectors 16000000 "$1") "$1")"
	#Just like before, we add that value to the already used space
	used=$(($used + $msrsize))
	#This is also the main data partition start
	local datastart=$used
	if is_removable "$1"; then
		#The size of the data partition takes up the rest of the disk, as there is no recovery
		#We subtract the data partition start from the aligned end of the disk to get its size
		local datasize="$(align_down $(($alignedend - $datastart)) "$1")"
	else
		#Non-removable media does have recovery, so we calculate the recovery partition size
		local winresize="$(align_down $(size_to_sectors 650000000 "$1") "$1")"
		#Now we use this data to calculate the start of the recovery partition
		local winrestart="$(align_up $(($alignedend - $winresize)) "$1")"
		#Now we subtract the data partition start from the start of the recovery partition to get the data partition's size
		local datasize="$(align_down $(($winrestart - $datastart)) "$1")"
	fi
	#Begin to print the script to stdout
	cat <<EOF
label: gpt
device: $1
unit: sectors
start=$efistart, size= $efisize, type=uefi, name="EFI system partition"
start=$msrstart, size=$msrsize, type=E3C9E316-0B5C-4DB8-817D-F92DF00215AE, name="Microsoft reserved"
start=$datastart, size=$datasize, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, name="Microsoft basic data"
EOF
	if ! is_removable "$1"; then
		cat <<EOF
start=$winrestart, size=$winresize, type=DE94BBA4-06D1-4D40-A16A-BFD50179D6AC, uuid=06FA0E52-4F8C-480A-BF8C-EE24B612F689, name="Windows RE", attrs="RequiredPartition GUID:63"
EOF
	fi
	return 0
}
function get_version {
	if [ "$1" ]; then
		#The version was passed to the function as an argument
		echo "$1" | awk '{print $2}'
	else
		#No arguments were passed, so run the autodetect_windows_version function
		autodetect_windows_version
	fi
}
function image_select {
	#First we export all of the image names to a file
	xmlstarlet sel -t -m '/WIM/IMAGE' -v 'NAME' -n "$tempdir/wiminfo.xml" >"$tempdir/images"
	local index_count="$(cat "$tempdir/images" | wc -l)"
	if [ "$index_count" -gt 1 ]; then
		create_menu "$tempdir/images" "Select the Windows edition to install"
		local image="$option"
	else
		local image=1
	fi
	echo "Selected edition: $(sed -n "${image}p" "$tempdir/images")" 1>&2
	echo $image
}
function is_blk {
	if [ -z "$1" ] || ! lsblk -nloNAME -p | grep -qw "$1"; then
		echo "Error: $disk: Not a block device" 1>&2
		exit 1
	fi
}
function is_mounted {
	#$1 is assumed to be the disk
	#First wait for udev to gather information about disks
	udevadm settle
	#Next we check if the disk is a block device
	is_blk "$1"
	#Next we check if disk is mounted
	if [ "$(lsblk -nloMOUNTPOINT "$1" | sed '/^$/d' | wc -l)" -gt 0 ]; then
		#Disk is mounted
		true
	else
		#Disk is not mounted
		false
	fi
}
function is_removable {
	is_blk $1
	#Check if disk is removable
	case "$(lsblk -dnloHOTPLUG "$1")" in
	1)
		#Disk is removable
		true
		;;
	0)
		#Disk is not removable
		false
		;;
	esac
}
function iso_mount {
	mount --mkdir -r "$iso" "$tempdir/iso"
}
function iso_select {
	while [ -z "$iso" ]; do
		#Prompt the user for the ISO file path
		echo "Please enter the path of the ISO file to install" 1>&2
		read -e iso
		#Checks
		if [ -z "$iso" ]; then
			#User didn't input anything
			echo "Error: you didn't input anything. Try again." 1>&2
			#Unset ISO so the loop will restart
			unset iso
		elif [ -d "$iso" ]; then
			#Path is a directory and not a file
			echo "Error: $iso: Is a directory" 1>&2
			unset iso
		elif [ ! -f "$iso" ]; then
			#The user typed input, but the path is invalid
			echo "Error: $iso: No such file or directory" 1>&2
			#Again we unset the iso variable
			unset iso
		elif ! file_is_iso "$iso"; then
			echo "Error: $iso: Not an ISO file" 1>&2
			#Once again we unset the iso variable
			unset iso
		fi
		#If the loop has come this far then the file exists and is an ISO
	done
	#Relative paths are accepted when typing the ISO path, but we use realpath when printing it to SDTout to avoid errors
	iso="$(realpath "$iso")"
	echo $iso
}
function iso_umount {
	umount -q "$tempdir/iso"
}
function make_log_img {
	#Generate and format a small FAT32 image, which will be used to capture the Windows PE output
	#Create the image
	truncate -s 64m "$tempdir/log.img"
	#Parttition it with sfdisk
	sfdisk -q "$tempdir/log.img" <<EOF
label: dos
type=0b
EOF
	#Set it up as a loop device
	losetup -fP "$tempdir/log.img" || return 1
	export logloop="$(losetup -lnONAME,BACK-FILE | awk -v imagepath="$tempdir/log.img" '$2==imagepath {print $1}')"
	#We're not done yet, we still have to format the virtual disk as FAT32
	mkfs.vfat -F32 "${logloop}p1"
}
function min_size {
	#Loop through the array elements
	for i in "${!supported_versions[@]}"; do
		if [ "${supported_versions[$i]}" = "$majorversion" ]; then
			#Found version, so we print its size to STDout
			echo "${size[$i]}"
			return
		fi
	done
	#If nothing is found we print nothing and return 1
	return 1
}
function partition {
	#$1 is assumed to be the disk
	#$2 is the path to the sfdisk layout file
	#Check that both arguments were passed to the function
	if [ -z "$1" ] || [ -z "$2" ]; then
		echo "Error: invalid usage" 1>&2
		return 1
	elif [ ! -f "$2" ]; then
		#Disk layout can't be found, so we return a code of 1
		echo "Error: $2: No such file or directory" 1>&2
		return 1
	fi
	is_blk "$1"
	#Wipe filesystem signatures on the disk
	#Repartition disk
	sfdisk --wipe always -q "$1" <"$2"
}
function part_table {
	is_blk "$1"
	#Prints the disk partition table type
	lsblk -dnloPTTYPE "$1"
}
function print_in_human_readable_format {
	numfmt --to=si --format '%1f' "$1"
}
function read_log {
	is_blk "$logloop"
	mount --mkdir "${logloop}p1" "$tempdir/log"
	if [ -f "$tempdir/log/log.txt" ]; then
		cat "$tempdir/log/log.txt"
		umount "$tempdir/log"
		return
	else
		echo "Error: $tempdir/log: No such file or directory" 1>&2
		umount "$tempdir/log"
		return 1
	fi
}
function root_check {
	#Check if running as root
	if [ "$(id -u)" != "0" ]; then
		#We're not running as root, so rerun script using sudo
		sudo $0
		exit
	fi
}
function size_to_sectors {
	#$1 is assumed to be the size
	#$2 is assumed to be the disk
	is_blk "$2"
	echo $(($1 / $(cat /sys/block/$(basename $2)/queue/hw_sector_size)))
}
function supported_windows_version {
	#Check if the Windows version being installed is at least Windows 7 or higher
	#The major version must be passed as an argument
	#Because bash doesn't support decimal values we have to explisitely check for Windows 8.1 to
	#avoid errors in the following conditional statement
	if [ "$1" = "Vista" ]; then
		#Selected Windows version is Windows Vista (not supported)
		echo "Error: Windows Vista installation images are not supported at this time" 1>&2
		false
	elif [ "$majorversion" = "8.1" ] || [ "$majorversion" -ge 7 ]; then
		#Version is supported
		true
	else
		#Version can't be recognized
		#This should never execute when using a genuine windows ISO
		echo "Warning: Unrecognized Windows version" 1>&2
	fi
}
function total_sectors {
	is_blk "$1"
	cat "/sys/block/$(basename "$1")/size"
}
function umount_disk {
	is_blk "$1"
	if is_mounted "$1"; then
		#Try to unmount the disk
		umount -Aq ${1}*
		#Now check again to see if disk is mounted
		if is_mounted "$1"; then
			#Unmounting obviously failed, so now we return an error
			return 1
		fi
		return 0
	fi
}
function verify_partitions_bios {
	udevadm settle || sleep 1
	#Check to make sure $1 is actually a disk
	is_blk $1
	#Check that the disk is in DOS format
	if [ "$(part_table "$1")" != "dos" ]; then
		echo "Error: "$1": Disk partition table is not DOS" 1>&2
		return 1
	fi
	#Get an array containing the disk partitions
	mapfile -t parts < <(lsblk -blnoPARTN,NAME,SIZE,TYPE,PARTTYPE,PARTFLAGS -p "$1" | awk '$4=="part"')
	#Parse the partition array
	for i in "${parts[@]}"; do
		#Get the partition type
		local type="$(echo "$i" | awk '{print $5}')"
		case "$type" in
		#Check for boot partition
		"0x7")
			if [ "$(echo "$i" | awk '{print $6}')" = "0x80" ]; then
				#Partition is a boot partition
				local bootparts+=("$i")
			else
				#Partition is a data partition
				local dataparts+=("$i")
			fi
			;;
		#Detect WinrePartition
		"0x27")
			local winreparts+=("$i")
			;;
		esac
	done
	#Now we need to check that the user didn't mess up the partitions
	if [ "${#bootparts[@]}" -gt 1 ]; then
		#There is more than 1 active partition
		echo "Error: Only 1 partition can be set as active" 1>&2
		return 1
	elif [ "${#bootparts[@]}" = 0 ]; then
		echo "Error: Disk does not contain a boot System Partition" 1>&2
		return 1
	else
		export bootpart="$(echo "$bootparts" | awk '{print $2}')"
		export bootnum="$(echo "$bootparts" | awk '{print $1}')"
	fi
	if [ "${#dataparts[@]}" -gt 1 ]; then
		#There is more than 1 data partition, so we have to prompt the user to select which one they want
		clear
		echo "Your main Windows partition could not be detected automatically" 1>&2
		#Dump partition path and sizes to a file
		for i in "${dataparts[@]}"; do
			echo "$i" | awk '{print $2 $3}' | numfmt --field=2 --to=si >>"$tempdir/dataparts"
		done
		create_menu "$tempdir/dataparts" "Select Your Main Windows Partition" 1>&2
		#Now we get the device path and number for the datapartition
		export datapart="$(echo "$itemname" | awk '{print $2}')"
		export datanum="$(echo "${dataparts[$(($option - 1))]}" | awk '{print $1}')"
	else
		export datapart="$(echo "$dataparts" | awk '{print $2}')"
		export datanum="$(echo "$dataparts" | awk '{print $1}')"
	fi
	if [ "${#winreparts[@]}" -gt 1 ]; then
		#There is more than 1 recovery partition, so we have to prompt the user to select which one they want
		clear
		echo "Your recovery partition could not be detected automatically" 1>&2
		#Dump partition path and sizes to a file
		for i in "${winreparts[@]}"; do
			echo "$i" | awk '{print $2 $3}' | numfmt --field=2 --to=si >>"$tempdir/winreparts"
		done
		create_menu "$tempdir/winreparts" "Select Your Recovery Partition"
		#Now we get the device path and number for the recovery partition
		export winrepart="$(echo "$itemname" | awk '{print $1}')"
		export winrenum="$(echo "${winreparts[$(($option - 1))]}" | awk '{print $1}')"
	else
		export winrepart="$(echo "$winreparts" | awk '{print $2}')"
		export winrenum="$(echo "$winreparts" | awk '{print $1}')"
	fi
	cat <<EOF
MBR has been verified:
Boot partition number: $bootnum
Boot partition path: $bootpart
EOF
	if [ "$datanum" ] && [ "$datapart" ]; then
		cat <<EOF
Data partition number: $datanum
Data partition path: $datapart
EOF
	fi
	if [ "$winrenum" ] && [ "$winrepart" ]; then
		cat <<EOF
Recovery partition number: $winrenum
Recovery partition path: $winrepart
EOF
	fi
}
function verify_partitions_uefi {
	udevadm settle || sleep 1
	#Check to make sure $1 is actually a disk
	is_blk $1
	#Check that the disk is in GPT format
	if [ "$(part_table "$1")" != "gpt" ]; then
		echo "Error: "$1": Disk partition table is not GPT" 1>&2
		return 1
	fi
	#Get an array containing the disk partitions
	mapfile -t parts < <(lsblk -blnoPARTN,NAME,SIZE,TYPE,PARTTYPE -p "$1" | awk '$4=="part"')
	#Parse the partition array
	for i in "${parts[@]}"; do
		#Get the guid of the partition
		local guid="$(echo "$i" | awk '{print $5}')"
		case "$guid" in
		#Check for ESP
		"c12a7328-f81f-11d2-ba4b-00a0c93ec93b")
			local efiparts+=("$i")
			;;
		#Check for MSR
		"e3c9e316-0b5c-4db8-817d-f92df00215ae")
			local msrparts+=("$i")
			;;
		#Check for data partition
		"ebd0a0a2-b9e5-4433-87c0-68b6b72699c7")
			local dataparts+=("$i")
			;;
		#Detect WinrePartition
		"de94bba4-06d1-4d40-a16a-bfd50179d6ac")
			local winreparts+=("$i")
			;;
		esac
	done
	#Now we need to check that the user didn't mess up the partitions
	if [ "${#efiparts[@]}" -gt 1 ]; then
		#There is more than 1 EFI partition
		echo "Error: Only one EFI System Partition is allowed per disk" 1>&2
		return 1
	elif [ "${#efiparts[@]}" = 0 ]; then
		echo "Error: Disk does not contain an EFI System Partition" 1>&2
		return 1
	else
		export efipart="$(echo "$efiparts" | awk '{print $2}')"
		export efinum="$(echo "$efiparts" | awk '{print $1}')"
	fi
	#Now we check for MSR
	if [ "${#msrparts[@]}" -gt 1 ]; then
		#There is more than 1 MSR partition
		echo "Error: Only one Microsoft reserved Partition is allowed per disk" 1>&2
		return 1
	elif [ "${#msrparts[@]}" = 0 ]; then
		echo "Error: Disk does not contain a Microsoft system reserved partition" 1>&2
		return 1
	else
		export msrpart="$(echo "$msrparts" | awk '{print $2}')"
		export msrnum="$(echo "$msrparts" | awk '{print $1}')"
	fi
	if [ "${#dataparts[@]}" -gt 1 ]; then
		#There is more than 1 data partition, so we have to prompt the user to select which one they want
		clear
		echo "Your main Windows partition could not be detected automatically" 1>&2
		#Dump partition path and sizes to a file
		for i in "${dataparts[@]}"; do
			echo "$i" | awk '{print $2 $3}' | numfmt --field=2 --to=si >>"$tempdir/dataparts"
		done
		create_menu "$tempdir/dataparts" "Select Your Main Windows Partition" 1>&2
		#Now we get the device path and number for the datapartition
		export datapart="$(echo "$itemname" | awk '{print $2}')"
		export datanum="$(echo "${dataparts[$(($option - 1))]}" | awk '{print $1}')"
	elif [ "${#dataparts[@]}" = 0 ]; then
		echo "Error: Disk does not contain a main data partition" 1>&2
		return 1
	else
		export datapart="$(echo "$dataparts" | awk '{print $2}')"
		export datanum="$(echo "$dataparts" | awk '{print $1}')"
	fi
	if [ "${#winreparts[@]}" -gt 1 ]; then
		#There is more than 1 recovery partition, so we have to prompt the user to select which one they want
		clear
		echo "Your recovery partition could not be detected automatically" 1>&2
		#Dump partition path and sizes to a file
		for i in "${winreparts[@]}"; do
			echo "$i" | awk '{print $2 $3}' | numfmt --field=2 --to=si >>"$tempdir/winreparts"
		done
		create_menu "$tempdir/winreparts" "Select Your Recovery Partition"
		#Now we get the device path and number for the recovery partition
		export winrepart="$(echo "$itemname" | awk '{print $1}')"
		export winrenum="$(echo "${winreparts[$(($option - 1))]}" | awk '{print $1}')"
	else
		export winrepart="$(echo "$winreparts" | awk '{print $2}')"
		export winrenum="$(echo "$winreparts" | awk '{print $1}')"
	fi
	cat <<EOF
GPT has been verified:
EFI System partition number: $efinum
EFI System partition path: $efipart
Microsoft reserved partition number: $msrnum
Microsoft reserved partition path: $msrpart
Data partition number: $datanum
Data partition path: $datapart
EOF
	if [ "$winrenum" ] && [ "$winrepart" ]; then
		cat <<EOF
Recovery partition number: $winrenum
Recovery partition path: $winrepart
EOF
	fi
}
function yes_no {
	#Print the prompt
	echo "$1 (y/n)" 1>&2
	while [ -z "$yn" ]; do
		#Read user input
		read -esn 1 yn
		case "$yn" in
		[yY])
			echo y
			;;
		[nN])
			#export the choice
			echo n
			;;
		*)
			continue
			;;
		esac
	done
}
#We first do some initialization
#Ensure that all requirements exist
export reqs=("awk" "fdisk" "mkfs.ntfs" "mkfs.vfat" "mkisofs" "mkwinpeimg" "ntfs-3g" "qemu-system-x86_64" "wimapply" "wimlib-imagex" "wimmount" "xmlstarlet")
check_reqs "${reqs[@]}"
#Trap the EXIT signal so that the cleanup function runs first
trap cleanup EXIT
#Make sure we're running as root
root_check
#Create temp directory
export tempdir=$(mktemp -d)
#Make some directories
mkdir -p $tempdir/{iso,log,scripts,winre,wim,windows}
#Detect firmware
export fw=$(detect_fw)
#Store supported Windows versions in an array
export supported_versions=("7" "8" "8.1" "10" "11")
#And the minimum disk requirements for each OS
export size=("20000000000" "20000000000" "20000000000" "32000000000" "64000000000")
#Ensure that all requirements exist
check_reqs "${reqs[@]}"
#Call ISO select, which prompts the user to select a Windows ISO.
clear
export iso="$(iso_select)"
#Mount the selected ISO and exit if it fails
if ! iso_mount; then
	echo "Error: Could not mount ISO image" 1>&2
	exit 1
fi
#Now we detect if the ISO was made with Microsoft's Media Creation Tool
if detect_mct; then
	#Error out, because MCT sucks!
	echo "Error: ISOs containing an install.esd file, such as those created with Microsoft's Media Creation Tool, are not supported" 1>&2
	exit 1
#Also check if ISO contains an install.wim file
elif ! contains_wim; then
	echo "Error: ISO does not contain an install.wim file" 1>&2
	exit 1
fi
#Now we need to extract the WIM XML and parse it
extract_xml "$wimpath"
#Next we run the get_version function to detect the Windows version we're dealing with
export majorversion=$(get_version)
#Check if version is supported
if ! supported_windows_version "$majorversion" ]; then
	exit 1
fi
#print the Windows version to the terminal
if [ "$majorversion" ]; then
	clear
	echo "Windows $majorversion detected."
fi
if [ "$majorversion" = "7" ] && [ "$fw" != "bios" ]; then
	echo "Warning: Installing Windows 7 on UEFI firmware is unsupported, reverting to BIOS" 1>&2
	export fw="bios"
	read -t 1
fi
#Get the minimum required space for this Windows version
export minsize=$(min_size "$majorversion")
#Select the WIM image to be installed
export image=$(image_select)
#Now we get the target disk
disk_select
#Check to see if the disk is mounted
if is_mounted $disk; then
	case "$(yes_no "The disk $disk is currently mounted. Attempt to unmount it?")" in
	y)
		echo "Attempting to unmount disk..."
		if ! umount_disk "$disk"; then
			echo "Error: $disk is mounted on the filesystem" 1>&2
			exit 1
		fi
		#Else we just keep right on going like nothing ever happened
		echo "Success"
		;;
	n)
		echo "Error: $disk is mounted on the filesystem" 1>&2
		exit 1
		;;
	esac
fi
#Get path to Windows Recovery Image if present
if ! is_removable "$disk"; then
	export winre="$(detect_winre)"
fi
#Now we generate the partition layout based on the firmware
generate_sfdisk_script_$fw "$disk" >"$tempdir/disklayout"
clear
#Warn of the impending disk format
echo "Warning: All data on disk $disk will be lost. Press enter to continue, or control+C to abort." 1>&2
#Wait for the user to press enter
read
clear
#Wait 5 more seconds, just to be sure
echo "Warning: $disk: Destroying all data in 5 seconds, press control+c to abort" 1>&2
sleep 5
clear
echo "Formatting..." 1>&2
partition "$disk" "$tempdir/disklayout"
#The verify_partitions_bios and verify_partitions_uefi  functions spit out junk to stdout and stderr.
#It's mainly meant for manual partitioning which I may add later, but we redirect its output to /dev/null when doing automation
verify_partitions_$fw "$disk" &>/dev/null 2>&1
#Now we generate the diskpart and install scripts
#These scripts will do the following:
#Mount the correct partitions
#Create BCDBoot entries
#Register WinRE (if present)
generate_install_scripts
format_partitions_$fw
#The script needs to exit if any of the below commands fail
set -e
#Make Windows PE image
echo "Making Windows PE ISO (required for some steps that Linux cannot do natively)"
mkwinpeimg -s "$tempdir/scripts/logoutput.bat" -W "$tempdir/iso" -O "$tempdir/scripts" -i "$tempdir/winpe.iso"
#Make log image
echo "Making log image (required to see the output from Windows PE)"
make_log_img
if ! is_removable "$disk"; then
	#We copy the recovery environment
	echo "Copying Windows Recovery Environment..."
	copy_winre
fi
#The next step is to apply the WIM file itself
echo "Applying the Windows image"
wimapply "$wimpath" "$image" "$datapart"
set +e
echo "Running the Windows PE in QEMU to finish install"
qemu-system-x86_64 -machine pc,accel=kvm:tcg -cpu host -m 1024 -boot order=d,once=d,menu=off,strict=on -drive file="$tempdir/winpe.iso",if=ide,media=cdrom,readonly=on -drive file="$disk",if=ide,format=raw -drive file="$logloop",if=ide,format=raw -nographic
#Cat the log, which probably doesn't contain much but is still worth looking at
if read_log; then
	echo "Installation completed successfully"
else
	echo "Error: Installation failed" 1>&2
	exit 1
fi
exit
