#!/sbin/sh

SCRIPTNAME="PrepDecrypt"
LOGFILE=/tmp/recovery.log
DEFAULTPROP=prop.default
SETPATCH=false

# Set default log level
# Based on https://stackoverflow.com/questions/8455991/elegant-way-for-verbose-mode-in-scripts
# 0=Errors only; 1=Errors & Information; 2=Errors, Information, & Debugging
__VERBOSE=1

declare -a LOG_LEVELS
LOG_LEVELS=(E I DEBUG)
log_print()
{
	# 0 = Error; 1 = Information; 2 = Debugging
	if [ $__VERBOSE -ge "$1" ]; then
		echo "${LOG_LEVELS[$1]}:$SCRIPTNAME::$2" >> "$LOGFILE"
	fi
}

relink()
{
	log_print 2 "Looking for $1 to update linker path..."
	if [ -f "$1" ]; then
		fname=$(basename "$1")
		target="/sbin/$fname"
		log_print 2 "File found! Relinking $1 to $target..."
		sed 's|/system/bin/linker|///////sbin/linker|' "$1" > "$target"
		chmod 755 "$target"
	else
		log_print 2 "File not found. Proceeding without relinking..."
	fi
}

finish()
{
	if [ "$SETPATCH" = "true" ]; then
		umount "$TEMPSYS"
		rmdir "$TEMPSYS"
		if [ "$MNT_VENDOR" = "true" ]; then
			umount "$TEMPVEN"
			rmdir "$TEMPVEN"
		fi
	fi
	setprop crypto.ready 1
	log_print 1 "crypto.ready=$(getprop crypto.ready)"
	log_print 1 "Script complete. Device ready for decryption."
	exit 0
}

finish_error()
{
	if [ "$SETPATCH" = "true" ]; then
		umount "$TEMPSYS"
		rmdir "$TEMPSYS"
		if [ "$MNT_VENDOR" = "true" ]; then
			umount "$TEMPVEN"
			rmdir "$TEMPVEN"
		fi
	fi
	setprop crypto.ready 1
	log_print 0 "Script run incomplete. Device may not be ready for decryption."
	exit 1
}

osver_default_value()
{
	osver_default=$(grep "$1" /$DEFAULTPROP)
	log_print 2 "$DEFAULTPROP value: $osver_default"
}

patchlevel_default_value()
{
	patchlevel_default=$(grep "$1" /$DEFAULTPROP)
	log_print 2 "$DEFAULTPROP value: $patchlevel_default"
	finish
}

update_default_values()
{
	if [ -z "$1" ]; then
		log_print 2 "$4=$1"
		log_print 0 "No $3. Checking original props..."
		if [ -n "$2" ]; then
			log_print 2 "Original $3 found. $4_orig=$2"
			log_print 2 "Setting $3 to original value..."
			setprop "$4" "$2"
			log_print 2 "$3 set. $4=$1"
			log_print 2 "Updating $DEFAULTPROP with Original $3..."
			echo "$4=$2" >> "/$DEFAULTPROP";
			$5 "$4"
		else
			log_print 0 "No Original $3 found. Setting default value..."
			osver="16.1.0"
			patchlevel="2099-12-31"
			setprop "$4" "$1"
			log_print 2 "$3 set. $4=$1"
			log_print 2 "Updating $DEFAULTPROP with default $3..."
			echo "$4=$1" >> "/$DEFAULTPROP";
			$5 "$4"
		fi
	else
		log_print 2 "$3 exists! $4=$1"
		$5 "$4"
	fi
}

check_resetprop()
{
	if [ -e /system/bin/resetprop ] || [ -e /sbin/resetprop ]; then
		log_print 2 "Resetprop binary found!"
		setprop_bin=resetprop
	else
		log_print 2 "Resetprop binary not found. Falling back to setprop."
		setprop_bin=setprop
	fi
}

temp_mount()
{
	mkdir "$1"
	if [ -d "$1" ]; then
		log_print 2 "Temporary $2 folder created at $1."
	else
		log_print 0 "Unable to create temporary $2 folder."
		finish_error
	fi
	mount -t ext4 -o ro "$3" "$1"
	if [ -n "$(ls -A "$1" 2>/dev/null)" ]; then
		log_print 2 "$2 mounted at $1."
	else
		log_print 0 "Unable to mount $2 to temporary folder."
		finish_error
	fi
}

log_print 1 "Running $SCRIPTNAME script for TWRP..."

osver=$(getprop ro.build.version.release)
osver_orig=$(getprop ro.build.version.release_orig)
sdkver=$(getprop ro.build.version.sdk)
patchlevel=$(getprop ro.build.version.security_patch)
patchlevel_orig=$(getprop ro.build.version.security_patch_orig)

log_print 2 "SDK version: $sdkver"
if [ "$sdkver" -lt 26 ]; then
	DEFAULTPROP=default.prop
	log_print 2 "Legacy device found! DEFAULTPROP variable set to $DEFAULTPROP."
fi
if [ "$sdkver" -lt 29 ]; then
	venbin="/vendor/bin"
	venlib="/vendor/lib"
	abi=$(getprop ro.product.cpu.abi)
	case "$abi" in
		*64*)
			venlib="/vendor/lib64"
			log_print 2 "Device is 64-bit. Vendor library path set to $venlib."
			;;
		*)
			log_print 2 "Device is 32-bit. Vendor library path set to $venlib."
			;;
	esac
	relink "$venbin/qseecomd"
	relink "$venbin/hw/android.hardware.keymaster@3.0-service"
	relink "$venbin/hw/android.hardware.keymaster@3.0-service-qti"
	relink "$venbin/hw/android.hardware.keymaster@4.0-service"
	relink "$venbin/hw/android.hardware.keymaster@4.0-service-qti"
	relink "$venlib/libQSEEComAPI.so"
	if [ -f /init.recovery.qcom_decrypt.fbe.rc ]; then
		log_print 2 "FBE device detected! Performing additional relinking..."
		relink "$venbin/time_daemon"
		relink "$venbin/hw/android.hardware.gatekeeper@1.0-service"
		relink "$venbin/hw/android.hardware.gatekeeper@1.0-service-qti"
	fi
fi

is_fastboot_boot=$(grep skip_initramfs /proc/cmdline)
if [ "$SETPATCH" = false ] || [ -n "$is_fastboot_boot" ]; then
	# Be sure to increase the PLATFORM_VERSION in build/core/version_defaults.mk to override Google's anti-rollback features to something rather insane
	update_default_values "$osver" "$osver_orig" "OS version" "ro.build.version.release" osver_default_value
	update_default_values "$patchlevel" "$patchlevel_orig" "Security Patch Level" "ro.build.version.security_patch" patchlevel_default_value
else
	SETPATCH=true
	BUILDPROP=build.prop
	TEMPSYS=/s
	suffix=$(getprop ro.boot.slot_suffix)
	if [ -z "$suffix" ]; then
		suf=$(getprop ro.boot.slot)
		if [ -n "$suf" ]; then
			suffix="_$suf"
		fi
	fi
	syspath="/dev/block/bootdevice/by-name/system$suffix"

	if [ "$sdkver" -ge 29 ]; then
		MNT_VENDOR=true
		TEMPVEN=/v
		venpath="/dev/block/bootdevice/by-name/vendor$suffix"

		temp_mount "$TEMPVEN" "vendor" "$venpath"

		if [ -f "$TEMPVEN/$BUILDPROP" ]; then
			log_print 2 "Vendor Build.prop exists! Reading vendor properties from build.prop..."
			vensdkver=$(grep -i 'ro.vendor.build.version.sdk=' "$TEMPVEN/$BUILDPROP"  | cut -f2 -d'=' -s)
			log_print 2 "Current vendor Android SDK version: $vensdkver"
			if [ "$vensdkver" -gt 25 ]; then
				log_print 2 "Current vendor is Oreo or above. Proceed with setting vendor security patch level..."
				check_resetprop
				log_print 2 "Current Vendor Security Patch Level: $venpatchlevel"
				venpatchlevel=$(grep -i 'ro.vendor.build.security_patch=' "$TEMPVEN/$BUILDPROP"  | cut -f2 -d'=' -s)
				if [ -n "$venpatchlevel" ]; then
					$setprop_bin "ro.vendor.build.security_patch" "$venpatchlevel"
					sed -i "s/\<ro.vendor.build.security_patch=\>.*/ro.vendor.build.security_patch=""$venpatchlevel""/g" "/$DEFAULTPROP" ;
					log_print 2 "New Vendor Security Patch Level: $venpatchlevel"
				fi
			else
				log_print 2 "Current vendor is Nougat or older. Skipping vendor security patch level setting..."
			fi
		fi
	fi

	temp_mount "$TEMPSYS" "system" "$syspath"

	sar=$(getprop ro.build.system_root_image)
	if [ "$sar" = "true" ]; then
		log_print 2 "System-as-Root device detected! Updating build.prop path variable..."
		BUILDPROP="system/build.prop"
		log_print 2 "Build.prop location set to $BUILDPROP."
	fi
	if [ -f "$TEMPSYS/$BUILDPROP" ]; then
		log_print 2 "Build.prop exists! Reading system properties from build.prop..."
		sdkver=$(grep -i 'ro.build.version.sdk=' "$TEMPSYS/$BUILDPROP"  | cut -f2 -d'=' -s)
		log_print 2 "Current system Android SDK version: $sdkver"
		if [ "$sdkver" -gt 25 ]; then
			log_print 2 "Current system is Oreo or above. Proceed with setting OS version and security patch level..."
			if [ -z "$setprop_bin" ]; then
				check_resetprop
			fi
			# TODO: It may be better to try to read these from the boot image than from /system
			log_print 2 "Current OS Version: $osver"
			osver=$(grep -i 'ro.build.version.release=' "$TEMPSYS/$BUILDPROP"  | cut -f2 -d'=' -s)
			if [ -n "$osver" ]; then
				$setprop_bin "ro.build.version.release" "$osver"
				sed -i "s/\<ro.build.version.release=\>.*/ro.build.version.release=""$osver""/g" "/$DEFAULTPROP" ;
				log_print 2 "New OS Version: $osver"
			fi
			log_print 2 "Current Security Patch Level: $patchlevel"
			patchlevel=$(grep -i 'ro.build.version.security_patch=' "$TEMPSYS/$BUILDPROP"  | cut -f2 -d'=' -s)
			if [ -n "$patchlevel" ]; then
				$setprop_bin "ro.build.version.security_patch" "$patchlevel"
				sed -i "s/\<ro.build.version.security_patch=\>.*/ro.build.version.security_patch=""$patchlevel""/g" "/$DEFAULTPROP" ;
				log_print 2 "New Security Patch Level: $patchlevel"
			fi
			finish
		else
			log_print 2 "Current system is Nougat or older. Skipping OS version and security patch level setting..."
			finish
		fi
	fi
fi
