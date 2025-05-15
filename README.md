# micromdm munki

## Control micromdm by munki

By: ISLAM ADEL

## Concept

**Manage micromdm using munki**

This script can be run as a cronjob to automate running
micromdm commands entered in munki manifests

## How it works

The **micromdm_munki.sh** bash script is intended to run on the micromdm server. It connects to one or multiple munki repositories and scans for all manifests (in the root folder of manifests) having an included manifest inside manifests/micromdm/

The notes field inside this included manifest, example: [munki_repo]/manifests/micromdm/example_manifest
contains an interval in days to re-run micromdm api commands and the required parameters.

for example:

inside the manifests folder of your munki repo, create micromdm folder and create a manifest with any desired name, for example DESKTOP
Now in the Notes field, add lines like this:

```
# install kernel extensions every 90 days
90:[api_path]/commands/install_profile [udid] [url=https://munki_repo.url/munki/pkgs/profiles/kernel_extensions.mobileconfig]
# re-enroll every 90 days
90:[api_path]/commands/install_profile [udid] [url=https://https://your-micromdm.url/mdm/enroll]
# register and install Keynote
7:[api_path]/commands/register_install_vpp_application [udid] 409183694 [sn]
```

Leave the values inside the brackets "[udid]", "[sn]" as they are, they will be interpreted automatically for the client. Only change the URLs for the mobileconfigs and iTunes App ID for installing Apps.
use hash "#" for comments.

Now add the above manifest as an included manifest to the client you want to assign the commands above.
Note: It will work only if added as included manifest to a client in manifest's root and not to a nested client.

How often a task has been executed is tracked by history log located at:
micromdm_munki/munki_servers/client_name_1/history/history.log

## Setup

Tested on Linux Debian

### Requirements

The only steps where **root** account is required:

```
apt-get install coreutils
apt-get install curl
apt-get install wget
apt-get install unzip
apt-get install libplist-utils
apt-get install jq
```

create non privileged mdm user, example: mdm

```
useradd -m -r -s /bin/bash mdm
```

Beginning from here, do all the following commands with the created mdm user - **Don't use root**

login in with the created user mdm

copy/clone micromdm_munki to /home/mdm/

```
cd /home/mdm
```

```
wget -O ./micromdm_munki_main.zip https://github.com/islamadel/micromdm_munki/archive/refs/heads/main.zip
unzip -o ./micromdm_munki_main.zip
mv ./micromdm_munki-main ./micromdm_munki
rm micromdm_munki_main.zip
```

### Change settings

rename settings example to settings

```
mv ./micromdm_munki/settings_example ./micromdm_munki/settings
```

modify settings as required

#### micromdm_env

enter micromdm API_TOKEN, VPP_TOKEN, SERVER_URL of yout micromdm server

**settings/micromdm_env**

```
export API_TOKEN=your-micromdm-api-token
export SERVER_URL=https://your-micromdm.url
export VPP_TOKEN="your-vpp-token"
```

#### micromdm_settings

set the directory containing micromdm_munki and the path for micromdm_env and api path for micromdm tools

**settings/micromdm_settings**

```
export work_dir="/home/mdm/micromdm_munki"
export MICROMDM_ENV_PATH="$work_dir/settings/micromdm_env"
api_path="$work_dir/micromdm-main/tools/api"
```

#### munki_settings

enter htaccess username and password in base64 and munki server url

**settings/munki_servers/client_name_1/munki_settings**

```
munki_user=your-munki-user
munki_pass_enc=base64-munki-password
munki_server=https://munki_repo1.url/munki
```

## How to run

Modify Settings as described above  
Make the required scripts executable

```
cd /home/mdm/micromdm_munki
chmod +x /home/mdm/micromdm_munki/micromdm_munki.sh
chmod +x /home/mdm/micromdm_munki/download_micromdm_api_tools.sh
```

Run download_micromdm_api_tools

This will copy some extra api scripts and set them as executable

```
/home/mdm/micromdm_munki/download_micromdm_api_tools.sh
```

From now on the standard script to use as cron job is:

```
/home/mdm/micromdm_munki/micromdm_munki.sh
```

### Example Cron Job

```
crontab -e
```

```
*/2 * * * * /home/mdm/micromdm_munki/micromdm_munki.sh >/dev/null 2>&1
```

I recommend running the script every 2 minutes, so you don't have to wait long till the profiles are loaded. It has locking mechanism, that will prevent parallel instances.

## Some Examples for commands

  
Install Keynote VPP App

```
7:[api_path]/commands/register_install_vpp_application [udid] 409183694 [sn]
```

Re-Install Enrollment Profile

```
90:[api_path]/commands/install_profile [udid] [url=https://https://your-micromdm.url/mdm/enroll]
```

Remove Numbers VPP App

```
90:[api_path]ommands/unregister_remove_vpp_application [udid] 409203825 [sn] com.apple.iWork.Numbers
```

Remove remote management / enrollment

```
90:[api_path]/commands/remove_profile [udid] com.github.micromdm.micromdm.enroll
```

Remove device from micromdm database

```
90:[api_path]ommands/remove_device [sn]
```

## Update micromdm_munki

```
cd /home/mdm
```

```
wget -O ./micromdm_munki_main.zip https://github.com/islamadel/micromdm_munki/archive/refs/heads/main.zip
unzip -o ./micromdm_munki_main.zip
cp -r ./micromdm_munki-main/ ./micromdm_munki/
rm micromdm_munki_main.zip
```

```
cd /home/mdm/micromdm_munki
chmod +x /home/mdm/micromdm_munki/micromdm_munki.sh
chmod +x /home/mdm/micromdm_munki/download_micromdm_api_tools.sh
```

```
/home/mdm/micromdm_munki/download_micromdm_api_tools.sh
```

## Troubleshooting

#### Reset / Re-Run Task for a certain client

replace "DEVICE-SERIAL-NUMBER" by client's serial number

```
sed -i '/DEVICE-SERIAL-NUMBER/d' ./micromdm_munki/munki_servers/client_name_1/history/history.log
```

#### Reset / Re-Run Tasks for all Clients

```
rm ./micromdm_munki/munki_servers/client_name_1/history/history.log
```

Created on: 2024-06-26  
Updated on: 2025-05-15
