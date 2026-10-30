#!/usr/bin/env python3
"""The release sweep's inputs for test-page.mjs (KDE_INPUT): what a visitor
opens first, used once each. Its runs are both the release check (their
screenshots and session output) and the first bundle's file list (each run's
KDE_OPENED list; kde/coverage.sh).

    sweep.py kcm|apps

kcm: Konsole, then every System Settings module in turn in one
systemsettings (switched by `systemsettings MODULE`), each module's title
and output in the session's output as `rs:` lines.
apps: Kate (typing, its save and open dialogs), Dolphin, the launcher's
search, the tray's applets and calendar, show desktop, the emoji selector
and KRunner, then the launcher's Lock (refused: kdeglobals) and logout.

A script typed into Konsole is started by the session bus (a D-Bus
activated service), so what it and its programs print is the session's
output, not the terminal's.
"""
import base64, gzip, sys

KCMS = ('kcm_access kcm_activities kcm_autostart kcm_baloofile kcm_colors kcm_componentchooser kcm_cursortheme '
        'kcm_desktoppaths kcm_desktoptheme kcm_fonts kcm_icons kcm_kded kcm_keyboard kcm_keys kcm_kwin_effects '
        'kcm_kwin_scripts kcm_kwin_virtualdesktops kcm_kwindecoration kcm_kwinrules kcm_kwinxwayland kcm_landingpage '
        'kcm_lookandfeel kcm_mouse kcm_nightlight kcm_notifications kcm_plasmasearch kcm_regionandlang kcm_smserver '
        'kcm_soundtheme kcm_splashscreen kcm_style kcm_tablet kcm_touchpad kcm_touchscreen kcm_users '
        'kcm_virtualkeyboard kcm_wallpaper kcm_workspace kcm_clock kcm_device_automounter kcm_filetypes kcm_fontinst '
        'kcm_kwinoptions kcm_kwinscreenedges kcm_kwintabbox kcm_kwintouchscreen kcm_qtquicksettings kcm_recentFiles '
        'kcm_solid_actions kwincompositing kcmspellchecking').split()
TITLE = 'title() { w=$(xprop -root _NET_ACTIVE_WINDOW | awk \'{print $NF}\'); xprop -id $w WM_NAME 2>&1 | cut -d= -f2; }\n'
SERVICES = '/root/.local/share/dbus-1/services'
KONSOLE = 'click 76,-28;wait 40;click 700,300;wait 3'


def bus_run(script, wait):
    """Type one command: the script written, made the session bus's
    service org.kp.rs and started by a call to it."""
    b = base64.b64encode(gzip.compress(script.encode(), 9)).decode()
    return (f"type mkdir -p {SERVICES} && echo {b} | base64 -d | gunzip > /root/rs.sh && "
            f"printf '[D-BUS Service]\\nName=org.kp.rs\\nExec=/bin/bash /root/rs.sh\\n' > {SERVICES}/org.kp.rs.service && "
            "dbus-send --session --type=method_call --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ReloadConfig && "
            f"dbus-send --session --type=method_call --dest=org.kp.rs / org.kp.rs.Go;key Enter;wait {wait};shot")


def kcm():
    s = TITLE + f'''first=1
for k in {' '.join(KCMS)}; do
  echo "rs: == $k"
  systemsettings $k 2>&1 | sed "s/^/rs: [$k] /" &
  if [ $first = 1 ]; then sleep 90; first=0; else sleep 22; fi
  echo "rs: -- $k title: $(title)"
done
pkill -x systemsettings
echo "rs: done"
'''
    return f"wait 20;{KONSOLE};" + bus_run(s, 90 + 22 * len(KCMS) + 30)


def apps():
    progs = ['plasma-emojier', 'krunner']
    s = TITLE + f'''for k in {' '.join(progs)}; do
  echo "rs: == $k"
  $k 2>&1 | sed "s/^/rs: [$k] /" &
  sleep 40
  echo "rs: -- $k title: $(title) alive: $(pgrep -x $k >/dev/null && echo yes || echo no)"
  pkill -x $k
  sleep 5
done
echo "rs: done"
'''
    tray = ';'.join(f'click {x},-28;wait 15;shot;key Escape;wait 5' for x in (1078, 1108, 1137, 1190))
    return ';'.join([
        'wait 20;shot',
        # Kate: a new file, typed, saved (the save dialog), the open dialog
        'click 172,-28;wait 45;click 381,260;wait 15;type hello from kate;wait 5;key Control+s;wait 25;shot',
        'type kp-test.txt;key Enter;wait 15;key Control+o;wait 25;shot;key Escape;wait 5;key Control+q;wait 10',
        # Dolphin: a folder opened
        'click 124,-28;wait 45;key ArrowDown;key Enter;wait 15;shot;key Control+q;wait 10',
        # the launcher's search
        'click 30,-28;wait 15;type konsole;wait 15;shot;key Escape;wait 5',
        tray,
        'click 1248,-28;wait 10;click 1248,-28;wait 10',
        KONSOLE, bus_run(s, 45 * len(progs) + 20),
        'click 30,-28;wait 15;type lock;wait 15;shot;key Enter;wait 20;shot',
        'click 30,-28;wait 15;type log out;wait 15;key Enter;wait 20;key Enter;wait 45;shot'])


if __name__ == '__main__':
    print({'kcm': kcm, 'apps': apps}[sys.argv[1]]())
