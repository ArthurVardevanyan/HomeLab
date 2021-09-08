***************************** WARNING *****************************
Do NOT edit this file directly, unless you REALLY know what you are doing !!


[profile_global]
appName=luckyBackup
appVersion=0.5
TotalTasks=2

[email]
emailCommand=
emailArguments=
emailSubject=luckyBackup report
emailNever=1
emailError=0
emailSchedule=0
emailTLS=0
emailFrom=
emailTo=
emailSMTP=
emailBody=Profile:      %p
emailBody=Date:         %d
emailBody=Time:         %i
emailBody=Errors found: %e

[Task] - 0
Name=docker
TypeDirContents=0
TypeDirName=1
TypeSync=0
Source=/home/arthur/docker
Destination=/backup/Timeshift/
LastExecutionTime=20210908030001
LastExecutionErrors=0
Args=-h
Args=--progress
Args=--stats
Args=-r
Args=-tgo
Args=-p
Args=-l
Args=-D
Args=--update
Args=--delete-after
Args=--delete-excluded
Args=--exclude=docker/gitlab/data/gitlab-rails/shared/registry/docker/registry/v2/
Args=--exclude=/docker/mariadb/data/
Args=--backup
Args=--backup-dir=/backup/Timeshift/docker/.luckybackup-snaphots/20210724030002/
Args=--filter=protect .luckybackup-snaphots/
Args=--log-file=/root/.luckyBackup/snaps/changes.log
Args=--log-file-format=[changed_data]%i[LB]%n
Args=/home/arthur/docker
Args=/backup/Timeshift/
ConnectRestore=
KeepSnapshots=180

Exclude=1
ExcludeFromFile=0
ExcludeFile=
ExcludeTemp=0
ExcludeCache=0
ExcludeBackup=0
ExcludeMount=0
ExcludeLostFound=0
ExcludeSystem=0
ExcludeTrash=0
ExcludeGVFS=0
ExcludeListItem=docker/gitlab/data/gitlab-rails/shared/registry/docker/registry/v2/
ExcludeListItem=/docker/mariadb/data/
Include=0
IncludeFromFile=0
IncludeModeNormal=1
IncludeFile=
Remote=0
RemoteModule=0
RemoteDestination=1
RemoteSource=0
RemoteSSH=0
RemoteHost=
RemoteUser=
RemotePassword=
RemoteSSHPassword=
RemoteSSHPasswordStr=
RemoteSSHOptions=
RemoteSSHPort=0
OptionsUpdate=1
OptionsDelete=1
OptionsRecurse=1
OptionsOwnership=1
OptionsSymlinks=1
OptionsPermissions=1
OptionsDevices=1
OptionsCVS=0
OptionsHardLinks=0
OptionsFATntfs=0
OptionsSuper=0
OptionsNumericIDs=0
OptionsRestorent=0
OptionsVss=0
LuckyBackupDir=/root/.luckyBackup/
VshadowDir=/usr/bin
RsyncCommand=rsync
SshCommand=ssh
DosdevCommand=/usr/bin/dosdev.exe
CygpathCommand=/usr/bin/cygpath.exe
TempPath=/tmp
ByPassWarning=0
CloneWarning=1
RepeatOnFail=0
IncludeState=1
[Task_end] - 0

[Task] - 1
Name=kubernetes
TypeDirContents=0
TypeDirName=1
TypeSync=0
Source=/home/arthur/kubernetes
Destination=/backup/Timeshift/
LastExecutionTime=20210908030010
LastExecutionErrors=1
Args=-h
Args=--progress
Args=--stats
Args=-r
Args=-tgo
Args=-p
Args=-l
Args=-D
Args=--update
Args=--delete-after
Args=--delete-excluded
Args=--exclude=kubernetes/gitlab/data/gitlab-rails/shared/registry/kubernetes/registry/v2/
Args=--exclude=/kubernetes/database/data/
Args=--backup
Args=--backup-dir=/backup/Timeshift/kubernetes/.luckybackup-snaphots/20210724030002/
Args=--filter=protect .luckybackup-snaphots/
Args=--log-file=/root/.luckyBackup/snaps/changes.log
Args=--log-file-format=[changed_data]%i[LB]%n
Args=/home/arthur/kubernetes
Args=/backup/Timeshift/
ConnectRestore=
KeepSnapshots=180

Exclude=1
ExcludeFromFile=0
ExcludeFile=
ExcludeTemp=0
ExcludeCache=0
ExcludeBackup=0
ExcludeMount=0
ExcludeLostFound=0
ExcludeSystem=0
ExcludeTrash=0
ExcludeGVFS=0
ExcludeListItem=kubernetes/gitlab/data/gitlab-rails/shared/registry/docker/registry/v2/
ExcludeListItem=/kubernetes/database/data/
Include=0
IncludeFromFile=0
IncludeModeNormal=1
IncludeFile=
Remote=0
RemoteModule=0
RemoteDestination=1
RemoteSource=0
RemoteSSH=0
RemoteHost=
RemoteUser=
RemotePassword=
RemoteSSHPassword=
RemoteSSHPasswordStr=
RemoteSSHOptions=
RemoteSSHPort=0
OptionsUpdate=1
OptionsDelete=1
OptionsRecurse=1
OptionsOwnership=1
OptionsSymlinks=1
OptionsPermissions=1
OptionsDevices=1
OptionsCVS=0
OptionsHardLinks=0
OptionsFATntfs=0
OptionsSuper=0
OptionsNumericIDs=0
OptionsRestorent=0
OptionsVss=0
LuckyBackupDir=/root/.luckyBackup/
VshadowDir=/usr/bin
RsyncCommand=rsync
SshCommand=ssh
DosdevCommand=/usr/bin/dosdev.exe
CygpathCommand=/usr/bin/cygpath.exe
TempPath=/tmp
ByPassWarning=0
CloneWarning=1
RepeatOnFail=0
IncludeState=1
[Task_end] - 1


[profile end]