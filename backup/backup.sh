#!/bin/bash
#Script to make a snapshot / file backup of the system and data

#Set Configuration Location
config='/etc/backup-scripts/backup.conf';

#Check if running as root
if [ $UID != 0 ]; then
  echo 'You need to be root to run this script!';
  exit 1;
fi

#Log activities
function log() {
    if [ ! -d "$LOG_DIR" ]; then mkdir -p $LOG_DIR; fi
    if [ ! -f "$LOG_FILE" ]; then touch $LOG_FILE; fi
    echo "$1" | tee -a $LOG_FILE;
    echo "$1" >> $VLOG_FILE;
}

function check_array() {
    local n=$#
    local value=${!n}
    for ((i=1;i < $#;i++)) {
        if [ "${!i}" == "${value}" ]; then return 0; fi
    }
    return 1
}

function space_check() {
    log "Checking for working space on drive"
}

function test_permissions() {
  if [ -w "$MOUNT_POINT" ] ; then
    log '  + Drive is writable';
    return 0;
  else
    log '  ! Drive is not writable, please check drive permissions';
    return 1;
  fi
}

function mount_check() {
  log "Checking Mountpoint for: $1";
  dev=$(blkid |grep "$1"|cut -d ":" -f1);
  if grep "$dev $MOUNT_POINT" /proc/mounts > /dev/null 2>&1 ; then
    log "  + Drive mounted" &&
    return 0 ;
  else
    log "  - Mounting drive";
    mkdir -p /mnt/backup > /dev/null 2>&1 &&
    mount UUID=$1 /mnt/backup &&
    return 0 ;
  fi
  return 1 ;
}

function drive_check() {
  log "Checking for Drive:  $1" ;
  if ls '/dev/disk/by-uuid/' | grep "$1" > /dev/null 2>&1 ; then
    log "  + drive found attached to system" ;
    active_drives+=("$1") ;
  else
    log "  - drive not found" ;
  fi
}

function build_weblog() {
  log 'Building Weblogs';
  echo '<html><body>' > $LOG_DIR/index.html &&
  echo '<h1>Weblog for Backup</h1>' >> $LOG_DIR/index.html &&
  cat $LOG_FILE | sed -e 's/$/\ <br>/' >> $LOG_DIR/index.html &&
  echo '<hr>' >> $LOG_DIR/index.html &&
  echo "<a href=\"http://$SERVER_ADDRESS/log.html\">View Sync Log" >> $LOG_DIR/index.html &&
  echo '</body></html>' >> $LOG_DIR/index.html &&
  log '  + index complete';
  echo '<html><body>' > $LOG_DIR/log.html &&
  echo '<h1>Weblog for Backup</h1>' >> $LOG_DIR/log.html &&
  cat $SYNC_LOG | sed -e 's/$/\ <br>/' >> $LOG_DIR/log.html &&
  echo '<hr>' >> $LOG_DIR/log.html &&
  echo "<a href=\"http://$SERVER_ADDRESS/index.html\">Backup to Main Log" >> $LOG_DIR/log.html &&
  echo '</body></html>' >> $LOG_DIR/log.html &&
  log '  + sync complete';
}

function rotate_log() {
  log 'Rotating Log Files';
  mv $LOG_FILE $LOG_FILE.old &&
  mv $SYNC_LOG $SYNC_LOG.old &&
  mv $VLOG_FILE $VLOG_FILE.old;
}

function mail_log() {
  log 'Mailing Log';
  log "Sync Log: http://$SERVER_ADDRESS/log.html" &&
  for email in ${EMAIL_ADDRESS[@]}
  do
      cat "$LOG_FILE" |mailx -r "$FROM_EMAIL_ADDRESS" -s "$EMAIL_SUBJECT" $email
  done
  #cat "$LOG_FILE" |mailx -r "$FROM_EMAIL_ADDRESS" -s "$EMAIL_SUBJECT" $EMAIL_ADDRESS &&
  log '  +  message sent';
}

function make_snapshot() {
    kernel_used=$(uname -r);
    lib_mod_dir=${lib_mod_dir:="/lib/modules/"};
    ata_dir=${ata_dir:="kernel/drivers/ata"};
    mksq_opt="-comp xz";
    
    ps_initrd.sh "$SNAPSHOT_ISO_DIR"/antiX/initrd.gz open;
    mkdir -p "$SNAPSHOT_ISO_DIR"/antiX/initrd.gz-image/"$lib_mod_dir"/$kernel_used;
    cp -R "$lib_mod_dir"/$kernel_used/"$ata_dir" "$SNAPSHOT_ISO_DIR"/antiX/initrd.gz-image/"$lib_mod_dir"/$kernel_used/;
    ps_initrd.sh "$SNAPSHOT_ISO_DIR"/antiX/initrd.gz close;
    
    #Copy kernel modules to initrd
    log "Copying kernel modules to initrd";
    if [ ! -d "$SNAPSHOT_WORK_DIR/initrd/" ]; then mkdir "$SNAPSHOT_WORK_DIR/initrd"; fi &&
    cp "$SNAPSHOT_ISO_DIR/antiX/initrd.gz" "$SNAPSHOT_WORK_DIR/initrd/" &&
    CWD=$(pwd)
    cd "$SNAPSHOT_WORK_DIR/initrd/" &&
    gunzip initrd.gz  &&
    ls ./
    cpio -i <initrd &&
    copy-initrd-modules --from "$SNAPSHOT_COPY_DIR" -k "$kernel_used" &&
    find . | cpio -o -H newc --owner root:root > initrd &&
    ls ./
    gzip -f initrd -9 &&
    mv "$SNAPSHOT_WORK_DIR/initrd/initrd.gz" "$SNAPSHOT_ISO_DIR/antiX/" &&
    rm -r "$SNAPSHOT_WORK_DIR/initrd/" &&
    cd "$CWD"
    log "  +  Success";
    
    cp /boot/vmlinuz-$kernel_used "$SNAPSHOT_ISO_DIR"/antiX/vmlinuz;
    
    # /etc/fstab should exist, even if it's empty,
    # to prevent error messages at boot
    touch "$SNAPSHOT_COPY_DIR/etc/fstab";
    for ID in "${HOME_DRIVE_IDS[@]}"
    do
        echo "UUID=$ID  /home  ext4  defaults  1 1" >> "$SNAPSHOT_COPY_DIR/etc/fstab";
    done
    
    snapshot_date=$(date +%Y-%m-%d_%H-%M);
    filename="$SNAPSHOT_BASENAME"_$snapshot_date;
    
    #remove old squashed file system and make new
    if [ -f "$SNAPSHOT_ISO_DIR/antiX/linuxfs" ]; then rm "$SNAPSHOT_ISO_DIR"/antiX/linuxfs; fi;
    mksquashfs $SNAPSHOT_COPY_DIR $SNAPSHOT_ISO_DIR/antiX/linuxfs ${mksq_opt};
    
    #Remove Extra snapshot iso images
    log "Removing Extra Snapshot iso images"
    iso_amount=$(find -maxdepth '1' -path "*.iso" |wc -l)
    if [ "$iso_amount" > "$SNAPSHOT_COPIES" ]; then
    filter_number=$(expr "$SNAPSHOT_COPIES" + "1" )
        for item in $( stat -c "%X|%n" "$SNAPSHOT_WORK_DIR"/*.iso |sort -r |tail -n "+$filter_number" )
        do
            file=$(echo $item | cut -d "|" -f2)
            log "$file"
            rm $file;
            rm ${file%.*}.md5;
        done
    fi
    log "  +  Done"
        
    #Clean live usb boot loader if existant 
    if [ -d "$SNAPSHOT_ISO_DIR/boot/extlinux" ]; then 
        chattr -i "$SNAPSHOT_ISO_DIR/boot/extlinux/ldlinux.sys" > /dev/null &&
        rm -r "$SNAPSHOT_ISO_DIR/boot/extlinux" ; 
    fi;
    
    #Generate snapshot iso image and resulting md5 of the file
    genisoimage -l -V antiXlive -R -J -pad -no-emul-boot -boot-load-size 4 -boot-info-table -b "boot/isolinux/isolinux.bin" -c "boot/isolinux/isolinux.cat" -o "$SNAPSHOT_WORK_DIR"/"$filename".iso "$SNAPSHOT_ISO_DIR";
    isohybrid "$SNAPSHOT_WORK_DIR"/"$filename.iso";
    md5sum "$SNAPSHOT_WORK_DIR"/$filename.iso > "$SNAPSHOT_WORK_DIR"/"$filename".md5;
}

function home() {
    log "Starting Home Backup";
    active_drives=();
    drive_count=${#HOME_DRIVE_IDS[@]};
    log "Total Number of Drives to Check: $drive_count";
    for ID in "${HOME_DRIVE_IDS[@]}"
    do
        drive_check $ID;
    done
    if [ ${#active_drives[@]} -eq 0 ]; then 
        log 'No Drives Found!';
        exit 1;
    fi
    for drive in "${active_drives[@]}"
    do
        if ! (mount_check $drive); then log "Could not Mount Drive" && exit 1; fi
        if ! (test_permissions); then log "Mount Location is not Writable" && exit 1; fi
        log "Syncing Home directory to $drive";
        echo "Syncing Home directory to $drive" >> $SYNC_LOG &&
        rsync -a -v -u -c -H -I -h --progress --delete --partial --numeric-ids -s $HOME_SOURCE $MOUNT_POINT/ >> $SYNC_LOG && 
        echo '' >> $SYNC_LOG &&
        log "  + success";
        umount $MOUNT_POINT;
    done
    log "Finishing: $(date)";
    build_weblog; 
    mail_log
    rotate_log;
}

function full() {
    log "Starting Full Backup";
    active_drives=();
    drive_count=${#FULL_DRIVE_IDS[@]};
    log "Total Number of Drives to Check: $drive_count";
    for ID in "${FULL_DRIVE_IDS[@]}"
    do
        drive_check $ID;
    done
    if [ ${#active_drives[@]} -eq 0 ]; then 
        log 'No Drives Found!';
        exit 1;
    fi
    
    #Snapshot Prep (Install Live Services)
    log "Installing Live Services for Snapshot";
    #apt-get update && 
    apt-get --force-yes -y install live-init-antix >> $VLOG_FILE 2>&1 &&
    log "  + success";
    
    #Sync Root Dir to Root Backup Dir(s)
    for drive in "${active_drives[@]}"
    do
        if ! (mount_check $drive); then log "Could not Mount Drive" && exit 1; fi
        if ! (test_permissions); then log "Mount Location is not Writable" && exit 1; fi
        
        #Make sure there is enough space to sync root file system
        #If there is, do stuff
        usage=$(df $MOUNT_POINT --total -h --output='source','pcent'|grep "total")
        TotalPercent=${usage##* }
        if [ "${TotalPercent%*%}" -gt 75 ]; then
            log "This disk is too full to backup reliably."
            log "Please increase the disk or partition size!"
            log "  -  Error: Not enough space to perform sync and snapshot"
        else
            log "Disk Usage: $TotalPercent"    
            #Snapshot Prep (Check for Directory Structure)
            log "Checking Snapshot Directory Structure for $drive";
            if [ ! -d "$SNAPSHOT_WORK_DIR" ]; then mkdir -p $SNAPSHOT_WORK_DIR > /dev/null 2>&1; fi &&
            if [ ! -d "$SNAPSHOT_COPY_DIR" ]; then mkdir -p $SNAPSHOT_COPY_DIR > /dev/null 2>&1; fi  &&
            if [ ! -d "$SNAPSHOT_ISO_DIR" ]; then mkdir -p $SNAPSHOT_ISO_DIR > /dev/null 2>&1; fi  &&
            log "  + success";
        
            log "Syncing Root directory to $drive";
            echo "Syncing Root directory to $drive" >> $SYNC_LOG &&
            rsync -a -v -u -c -H -I -h --progress --delete --partial --numeric-ids -s $ROOT_SOURCE $SNAPSHOT_COPY_DIR/ --delete --exclude="$MOUNT_POINT" --exclude="$SNAPSHOT_WORK_DIR" --exclude="$SNAPSHOT_COPY_DIR" --exclude-from="$SNAPSHOT_EXCLUDES" >> $SYNC_LOG && 
            echo '' >> $SYNC_LOG &&
            log "  + success";
        
            #Make Snapshot from Root Backup Dir
            log "Making Snapshot";
            make_snapshot  >> $VLOG_FILE 2>&1;
            log "  + success";
        
            #Get Drive Device name from uuid of partition
            devname=$(blkid |grep "$drive" |cut -d ":" -f1|head -1|sed "s/[0-9]//ig");
        
            #Make ISO dir live usb boot
            #Install boot loader on drive
            log "Making backup drive live boot";
            log "Installing boot loader";
            cp -r "$SNAPSHOT_ISO_DIR/boot/syslinux/" "$SNAPSHOT_ISO_DIR/boot/extlinux/" >> $VLOG_FILE 2>&1 &&
            mv "$SNAPSHOT_ISO_DIR/boot/extlinux/syslinux.cfg" "$SNAPSHOT_ISO_DIR/boot/extlinux/extlinux.conf" >> $VLOG_FILE 2>&1 &&
            touch "$SNAPSHOT_ISO_DIR/boot/extlinux/gfxsave.on" >> $VLOG_FILE 2>&1 &&
            $(echo "1" > "$SNAPSHOT_ISO_DIR/boot/extlinux/gfxsave.on") >> $VLOG_FILE 2>&1 &&
            extlinux --install "$SNAPSHOT_ISO_DIR/boot/extlinux" >> $VLOG_FILE 2>&1 &&
            if [ -f "/usr/lib/syslinux/mbr.bin" ]; then inputfile="/usr/lib/syslinux/mbr.bin"; fi
            if [ -f "/usr/lib/syslinux/mbr/mbr.bin" ]; then inputfile="/usr/lib/syslinux/mbr/mbr.bin"; fi
            dd bs=440 conv=notrunc count=1 if=$inputfile of=$devname >> $VLOG_FILE 2>&1 &&
            parted "$devname" set 1 boot on >> $VLOG_FILE 2>&1 &&
            log "  +  Success";
        
            #Unmount Drive when all Done
            log "Unmounting Drive";
            umount "$MOUNT_POINT" &&
            log "  +  Success";
        fi
    done    
    
    #Snapshot Cleanup (Remove Live Services)
    log "Removing Live Services for Snapshot";
    apt-get --force-yes -y purge live-init-antix &&
    log "  + success";
    
    #Sync Homes now that All roots are synced with live copies.
    home;
}

#Starting function
function main() {
    #Test and Load Backup Configuration
    test -r $config || continue;
    if ! /bin/bash -n $config; then
        log "Errors in $config. Backup is likely to fail! Will not continue.";
        exit 1;
    fi
    . $config;
    
    #Check Date and determine backup type
    log "Today is:  $(date)";
    day=$(date +%a);

    if   (check_array "${FULL_BACKUP[@]}" $day); then full;
    elif (check_array "${HOME_BACKUP[@]}" $day); then home;
    else log "Day Not Set for Backup";
    fi
}

main;
