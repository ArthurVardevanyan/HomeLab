***************************** WARNING *****************************
Do NOT edit this file directly, unless you REALLY know what you are doing !!


[profile_global]
appName=luckyBackup
appVersion=0.5
TotalTasks=1

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
LastExecutionTime=20210728030001
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
Args=--filter=protect .luckybackup-snaphots/
Args=--log-file=/home/arthur/.luckyBackup/snaps/changes.log
Args=--log-file-format=[changed_data]%i[LB]%n
Args=/home/arthur/docker
Args=/backup/Timeshift/
ConnectRestore=
KeepSnapshots=120
SnapshotsListItem=20210625210422
SnapshotsListItem=20210625210518
SnapshotsListItem=20210626030002
SnapshotsListItem=20210627030002
SnapshotsListItem=20210628030002
SnapshotsListItem=20210629030002
SnapshotsListItem=20210630030002
SnapshotsListItem=20210701030001
SnapshotsListItem=20210702030002
SnapshotsListItem=20210703030001
SnapshotsListItem=20210704030001
SnapshotsListItem=20210705030001
SnapshotsListItem=20210706030002
SnapshotsListItem=20210707030002
SnapshotsListItem=20210708030001
SnapshotsListItem=20210710030001
SnapshotsListItem=20210711030001
SnapshotsListItem=20210712030001
SnapshotsListItem=20210713030001
SnapshotsListItem=20210714030001
SnapshotsListItem=20210715030001
SnapshotsListItem=20210716030001
SnapshotsListItem=20210717030001
SnapshotsListItem=20210718030001
SnapshotsListItem=20210719030002
SnapshotsListItem=20210720030001
SnapshotsListItem=20210721030001
SnapshotsListItem=20210722030002
SnapshotsListItem=20210723030001
SnapshotsListItem=20210724030001
SnapshotsListItem=20210725030001
SnapshotsListItem=20210726030002
SnapshotsListItem=20210727030001
SnapshotsListItem=20210728030001
Exclude=0
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
LuckyBackupDir=/home/arthur/.luckyBackup/
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


[profile end]
