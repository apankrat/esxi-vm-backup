## esxi-vm-backup

A shell script for [ESXi](https://en.wikipedia.org/wiki/VMware_ESXi) that backs
up VM snapshots to remote storage via SSH.

## In short

This is a substantially reworked fork of [ghettoVCB](https://github.com/lamw/ghettoVCB)
script by William Lam. For the background, general requirements and the setup see there.

The script does the following:

```
for each specified VM
    create VM snapshot
        clone all its VMDKs into a local temp folder
        copy the .vmx there
        copy nvram there
        tar and copy this folder to a remote host via ssh
        trim older tars on the remote host to the specified total count
        remove local temp folder
    remove VM snapshot
send email report
clean up temp files and what not
```

That is, VMs are snapshot and backed up (as timestamped tar archives) to
a remote host **over SSH**.

The SSH bit is **the** reason for this script's existence.

## Caveats

There's no restore script (yet), but restoration is largely trivial.

The script is used with one specific pair of ESXi boxes with spectacular results. *Your* mileage may vary.

Before using - 
* read through the code, at the very least the config section at the top of the script
* try and understand what it actually does

Test next.

Test again.

If you found a bug, [open an issue](https://github.com/apankrat/esxi-vm-backup/issues/new).

## Syntax

```
$ ./vm-backup.sh

Syntax: vm-backup.sh [-c config] [-w workdir] [-m vm-name] [-a] [-v]

   -m     Name of the VM to be backed up (can be repeated)
   -a     Backup all VMs on this host (overrides -m)
   -c     File with overrides for default config options
   -v     Verbose logging

Based on ghettoVCB by William Lam, https://github.com/lamw/ghettoVCB
Reworked by Alexander Pankratov, https://github.com/apankrat/esxi-vm-backup
```

## Typical run

```
$ ./vm-backup.sh -m "Le petit"
2020-03-29 19:55:12 | 100202563 | info  | === New run 2020.03.29-19.55.11 ===
2020-03-29 19:55:12 | 100202563 | info  | logfile: /tmp/vm-backup-2020.03.29-19.55.11.log
2020-03-29 19:55:12 | 100202563 | info  | workdir: /vmfs/volumes/primary/vm-backup-workdir
2020-03-29 19:55:12 | 100202563 | info  | --- Backing up [Le petit] ---
2020-03-29 19:55:13 | 100202563 | info  | Listing vmdks ...
2020-03-29 19:55:13 | 100202563 | info  |   scsi0:0 -- included, 1 GB, /vmfs/volumes/primary/Le petit/Le petit.vmdk
2020-03-29 19:55:13 | 100202563 | info  |   Total: 1 vmdk(s), 1 GB
2020-03-29 19:55:13 | 100202563 | info  | Creating directory - [/vmfs/volumes/primary/vm-backup-workdir/Le petit/2020.03.29-19.55.11] ...
2020-03-29 19:55:13 | 100202563 | info  | Creating snapshot - 'vm-backup-snapshot-2020-03-29' ...
2020-03-29 19:55:16 | 100202563 | info  | Copying vmx file ...
2020-03-29 19:55:16 | 100202563 | info  | Cloning /vmfs/volumes/primary/Le petit/Le petit.vmdk ...
2020-03-29 19:55:18 | 100202563 | info  | Creating [/vmfs/volumes/backups/Le petit] on 10.0.0.123 ...
2020-03-29 19:55:18 | 100202563 | info  | Copying /vmfs/volumes/primary/vm-backup-workdir/Le petit/2020.03.29-19.55.11 ...
2020-03-29 19:55:18 | 100202563 | info  |   -> 10.1.2.123:/vmfs/volumes/backups/Le petit/2020.03.29-19.55.11.tar
2020-03-29 19:55:33 | 100202563 | info  | Trimming backup set, keeping 3 most recent ...
2020-03-29 19:55:34 | 100202563 | info  |   2022.03.29-16.59.22.tar - kept
2020-03-29 19:55:34 | 100202563 | info  |   2022.03.29-16.50.53.tar - kept
2020-03-29 19:55:34 | 100202563 | info  |   2022.03.29-16.48.31.tar - kept
2020-03-29 19:55:34 | 100202563 | info  |   2020.03.29-19.55.11.tar - removing ...
2020-03-29 19:55:35 | 100202563 | info  | Removing snapshot - 'vm-backup-snapshot-2020-03-29' ...
2020-03-29 19:55:39 | 100202563 | info  | --- End of backup of [Le petit] -- Completed OK in 00:00:26 ----
2020-03-29 19:55:39 | 100202563 | info  | All backups are completed
2020-03-29 19:55:39 | 100202563 | info  |   1 OK
2020-03-29 19:55:39 | 100202563 | info  |   0 failed
2020-03-29 19:55:39 | 100202563 | info  | Sending email...
2020-03-29 19:55:41 | 100202563 | info  | === End of the run, elapsed 00:00:30, exit code 0 ===
```

Can also be told to be verbose:

    $ ./vm-backup.sh -m "Le petit" -v
    
in which case it will look something like this - [vm-backup-2020.03.29-19.55.49.log](https://raw.githubusercontent.com/apankrat/esxi-vm-backup/master/vm-backup-2020.03.29-19.55.49.log)

## Changes from ghettoVCB

Reworked and cleaned up the code a bit. In particular:

* Split into functions so to avoid nested IF blocks
* Reworked logging for consistency and columnized output
* Reworked email notifications a bit
* Exiting on signal now removes VM snapshot if one was created and not yet removed

Changed how the script reacts to the errors *during the prep phase*. It now
treats all configuration errors as fatal and aborts the run. During the main
phase, when it is backing up VMs, any errors will abort the backup of current
VM, but not the whole run. This part is the same as the ghettoVCB logic.

**Removed** quite a few things, because I don't need them and had no time
to properly port them over. These include:

* Support for per-VM config files
* Support for loading VM list from a file
* Support for NFS
* Support for powering down/up VM before/after the backup
* Support for dryruns
* Support for backing up VMs with existing snapshots
* Logging of the storage info (probably will need to add it back at some point)

## Note on using compression

Once local backup is created there are several options for moving it over
the remote storage over SSH:

1. Using `scp` - the fastest option, gives you a timestamped backup _folder_
2. Using `tar | ssh` - slightly slower, gives you a timestamped backup _tar_

Enabling **local** compression during the transfer slows things down
**dramatically**, e.g. `scp -C` or `tar -z... | ssh` or `tar | ssh -C ...`
will cause the run-time to double or triple.

Enabling **remote** (post-transfer) compression slows things down less
severly, but still very noticeably.

**Keep in mind** that the only option actually implemented is `tar | ssh`.

## Acknowledgment

Kudos to William, the ghettoVCB author. For a change it was easier to rework 
someone else's work than to rewrite it from scratch >_<
