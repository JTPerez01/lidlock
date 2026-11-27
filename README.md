# LidLock

LidLock is a macOS menu bar app that keeps a MacBook awake with the lid closed. It changes the system sleep setting with `pmset` and reads it back to confirm the change. The menu shows the current sleep setting and warns when the Mac is running on battery.

## Install and run

Use a MacBook with Xcode Command Line Tools and an administrator account. From the repository directory, run the installer and start LidLock.

```sh
sudo mkdir -p /usr/local/bin
./install.sh
/usr/local/bin/lidlock
```

The installer builds the app if needed and copies it to `/usr/local/bin/lidlock`. It grants the installing account passwordless `sudo` access to the two `pmset` commands that disable and restore sleep.

## Use the menu

LidLock activates automatically when launched on AC power with normal sleep enabled. Use **Activate LidLock** to disable sleep manually and **Deactivate LidLock** to restore normal sleep. **Quit LidLock** restores normal sleep before exiting. If macOS cannot confirm the change, LidLock stays open and shows the error.

## Check status

Print the current sleep setting and power source from Terminal.

```sh
/usr/local/bin/lidlock --status
```

Use `/usr/local/bin/lidlock --once` to test both the setting change and the return to the original setting. This check temporarily toggles the system sleep setting.

## Uninstall

Choose **Quit LidLock** to restore normal sleep. Remove the installed binary and the sudoers entry created for LidLock.

```sh
sudo rm /usr/local/bin/lidlock /etc/sudoers.d/lidlock
```
