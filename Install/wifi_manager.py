#!/usr/bin/python
"""WiFi manager backend for the RTKBase configurator.

Implements the NetworkManager side of the WiFi manager popup:
scanning, client profile CRUD, access-point profile, regulatory domain,
validation. server.py keeps only thin Socket.IO handlers on top of this
module.

Persistence is NetworkManager profiles only (client: WiFi_<SSID>, AP: Hotspot).
The wlan0 role derives from the profiles' autoconnect flags — no settings.conf flag.
"""

import fcntl
import functools
import ipaddress
import json
import logging
import os
import re
import shutil
import socket
import subprocess
import threading
import time

import nmcli

log = logging.getLogger(__name__)

WIFI_IFACE = "wlan0"
# The access point runs on its OWN virtual interface, never on wlan0: that is what lets the
# station keep a client connection and an access point at the same time, and it is where the
# station provisioning puts its hotspot too, so both sides manage one interface instead of
# two. Created on demand when the system does not have it (a Debian PC does not).
AP_IFACE = "ap0"
AP_PROFILE = "Hotspot"
CLIENT_PREFIX = "WiFi_"
ONETIME_SUFFIX = ".onetime"
rtkbase_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "../"))
system_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../"))
HOTSPOT_FLAG = os.path.join(system_path, "HOTSPOT.flg")

ISO3166_SYSTEM = "/usr/share/zoneinfo/iso3166.tab"   # tzdata; present on any Debian/RPi OS

AP_DEFAULTS = {
    "ssid": "RtkBase",
    "security": "mixed",     # mixed | wpa3 | wpa2 | open
    "password": "",
    "hidden": False,
    "band": "all",           # all | 2.4 | 5
    "channel": 0,            # 0 = auto
    "ip": "192.168.50.1",
    "prefix": 24,
}

# Per-SSID "last seen channel" (chan, freq), refreshed on every scan. Needed for the
# region badges on saved networks: a client profile stores no channel, so the last
# sighting is the only channel source. Persisted to disk so the badge survives a service
# restart (and spells where a client scan is impossible — 5 GHz in world domain, or the
# AP owning the single radio); in-memory alone it was lost on restart and the badge
# silently vanished.
_SEEN_CHANNELS_FILE = os.path.join(system_path, "wifi_seen_channels.json")


def _load_json(path, default):
    """A state file that is missing or corrupt is an empty one, never an error."""
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, type(default)) else default
    except Exception:
        return default


def _save_json(path, data, what):
    """Atomic best-effort write — a state file must never take an operation down with it."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(data, f)
        os.replace(tmp, path)
    except Exception as e:
        log.warning("could not persist %s: %s", what, e)


def _load_seen_channels():
    return {k: tuple(v) for k, v in _load_json(_SEEN_CHANNELS_FILE, {}).items()
            if isinstance(v, (list, tuple)) and len(v) == 2}


def _save_seen_channels():
    _save_json(_SEEN_CHANNELS_FILE, {k: list(v) for k, v in _seen_channels.items()},
               "the seen-channels cache")


_seen_channels = _load_seen_channels()

# What the operator asked the access point to be, when the NM profile cannot hold it. The
# profile carries what the radio is actually doing, because that is what NetworkManager
# raises on boot; but the point sometimes has to move off the operator's choice — its subnet
# collides with a network the station joined. Without this file that choice is lost and the
# point never comes back once the conflict is gone.
_AP_PREFS_FILE = os.path.join(system_path, "wifi_ap_prefs.json")


def _load_ap_prefs():
    return _load_json(_AP_PREFS_FILE, {})


def _save_ap_prefs(prefs):
    _save_json(_AP_PREFS_FILE, prefs, "the AP preferences")


def _without_loan(prefs):
    """prefs with the borrowed-channel markers dropped — the loan is over.

    One place on purpose: a stale `*_written` marker left behind by a missed site would make
    ap_return_to_preferred move the point off a channel the operator set by hand.
    """
    return {k: v for k, v in prefs.items()
            if k not in ("band_written", "channel_written")}

# Regdomain state for hosts without `iw` (x86 bench, some DIY): set_country() stores
# the CC here so the UI flow still works; allowed channels come from _FALLBACK_REG.
_fallback_country = None

# BSSIDs our own hotspot has beaconed with (the wlan0 MAC while in AP mode). NM randomizes
# the MAC, so after the AP is turned off its cached scan entry no longer matches the CURRENT
# wlan0 address — remember every address we beaconed from and keep filtering those entries
# until they age out of the scan cache. (Filtering by SSID instead would hide a neighbouring
# station broadcasting the same name — the default SSID is the same on every unit.)
_own_ap_bssids = set()

# Last access-point start failure, shown persistently in the AP card (a toast alone
# disappears; reopening the dialog must still tell WHY the AP is not running). Cleared
# on a successful start and on an intentional disable. In-process only by design.
_last_ap_error = None

# Why the access point is switched on but not running: the network the station joined sits on
# a channel the point may not use, and the radio has only one channel to give. Shown in the AP
# card, cleared the moment the point can stand somewhere again. In-process only, like the above.
_ap_yielded = ""

# When the coupling last moved the access point on its own. A realign costs the client
# link for a moment, so it is rate-limited: two disagreeing views in a row are a reason
# to act, a flapping link is not.
_last_realign = 0.0

# When we last raised, lowered or moved the access point ourselves. Taking the point down frees
# the radio but leaves NetworkManager holding a client connection the radio no longer has, and
# the dialog would announce a dropped link exactly when the operator switched the point off —
# reading as "Wi-Fi turned itself off". Inside this window the announcement is held back; NM
# reconnects the client by itself, because its autoconnect is no longer cleared.
_last_ap_action = 0.0
_AP_ACTION_QUIET_S = 15

# The radio is a single resource and the watchdog is not the only one moving it: an operator
# joining a network moves the point too. Without this, a watchdog tick landing in the middle of
# a connection moves the point again and tears down the association being negotiated — the
# attempt then dies on a 45-second timeout for no visible reason. Reentrant because the
# operations nest (connect lowers the point through set_ap).
_radio_lock = threading.RLock()
_radio_depth = 0

# ...and the in-process lock alone is not enough. The web service starts its background thread
# before gunicorn forks its worker, and under gevent that thread is a greenlet, so the fork
# leaves a copy running in BOTH processes — measured on the station: two PIDs realigning the
# channel, one of them straight through an operator's connection, which died on
# `ip-config -> failed`. A lock file is the part both processes can see.
_RADIO_LOCKFILE = os.path.join(system_path, "wifi_radio.lock")
_radio_fd = None


def _radio_flock(wait_s=0.0):
    """Take the cross-process radio lock. True when held — or when there is no file to use.

    Fails open on a filesystem problem: refusing every Wi-Fi operation because a lock file
    cannot be created would be worse than the race it guards against.
    """
    global _radio_fd
    if _radio_fd is None:
        try:
            _radio_fd = os.open(_RADIO_LOCKFILE, os.O_CREAT | os.O_RDWR, 0o644)
        except OSError as e:
            log.warning("no radio lock file (%s) — continuing without the cross-process guard", e)
            return True
    deadline = time.time() + wait_s
    while True:
        try:
            fcntl.flock(_radio_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError:
            if time.time() >= deadline:
                return False
            time.sleep(0.2)


def _radio_funlock():
    if _radio_fd is not None:
        try:
            fcntl.flock(_radio_fd, fcntl.LOCK_UN)
        except OSError:
            pass

# An explicit "disconnect" means stay off, and the watchdog must not undo it. Without this the
# pass would see a saved network with autoconnect on, decide the station belongs there, and put
# the connection the operator just dropped straight back up. NetworkManager blocks its own
# autoconnect after a manual disconnect for the same reason.
_client_off_by_operator = False


def _set_client_off(flag):
    """Record an operator's explicit disconnect where BOTH watchdog processes can see it.

    The web service forks after starting the watchdog thread, so a twin of the watchdog runs
    in the other process too (see _RADIO_LOCKFILE); a process-local flag is invisible there,
    and the twin would put the connection the operator just dropped straight back up. The
    prefs file is the state the two processes already share.
    """
    global _client_off_by_operator
    _client_off_by_operator = flag
    prefs = _load_ap_prefs()
    if bool(prefs.get("client_off")) != bool(flag):
        _save_ap_prefs(dict(prefs, client_off=bool(flag)))


def _holds_radio(fn):
    """Operations that own the radio while they run; the watchdog stands aside for them."""
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        global _radio_depth
        with _radio_lock:
            if _radio_depth == 0 and not _radio_flock(wait_s=30):
                # another process is mid-operation; this one was asked for by the operator, so
                # it goes ahead rather than failing — but the wait goes on record
                log.warning("radio is busy in another process — running %s anyway", fn.__name__)
            _radio_depth += 1
            try:
                return fn(*args, **kwargs)
            finally:
                _radio_depth -= 1
                if _radio_depth == 0:
                    _radio_funlock()
    return wrapper

# Last successfully read interface list (network_infos.get_interfaces_infos). That upstream
# helper is all-or-nothing: one nmcli.device.show() raising on an interface in a transient
# state (e.g. a wlan device mid radio-toggle) makes the whole call fail. Reusing the last good
# result keeps the popup header populated instead of blanking on a momentary hiccup.
_last_interfaces = None


# --------------------------------------------------------------------------
# capability / degradation (Bullseye and beyond)
# --------------------------------------------------------------------------

def capability():
    """What is available on this host; drives soft degradation in the UI."""
    cap = {"nm": False, "nm_running": False, "iw": bool(shutil.which("iw")),
           "raspi_config": bool(shutil.which("raspi-config")), "reason": None}
    try:
        nmcli.device()          # cheap round-trip through the nmcli binary
        cap["nm"] = True
        cap["nm_running"] = True
    except Exception as e:
        cap["reason"] = "NetworkManager is not available: {}".format(e)
    return cap


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

def sanitize_profile_name(ssid):
    """Spec §8: profile name WiFi_<SSID>, '/' replaced, control chars stripped."""
    clean = ssid.replace("/", "_")
    clean = "".join(ch for ch in clean if ch.isprintable())
    return CLIENT_PREFIX + clean


def freq_to_band(freq_mhz):
    return "5" if freq_mhz and freq_mhz > 3000 else "2.4"


def _default_ap_ssid():
    """Hostname as the default AP SSID — stations become tellable apart out of the box;
    falls back to the fixed default when the hostname is empty. Used only while no
    Hotspot profile exists yet (a saved profile keeps whatever SSID it has)."""
    try:
        name = socket.gethostname().strip()
    except Exception:
        name = ""
    return name[:32] or AP_DEFAULTS["ssid"]


def parse_security(sec):
    """nmcli SECURITY string -> (kind, label). kind: open|wep|wpa1|wpa2|wpa3|mixed23

    The label names EVERY protocol the beacon advertises, in ascending order — an access
    point still offering legacy WPA1 alongside WPA2 shows up as "WPA1/WPA2", not as plain
    WPA2. Collapsing it hid exactly the fact worth seeing: such a network can negotiate
    TKIP. The kind is separate and drives the connect path, where WPA1+WPA2 is the same
    wpa-psk profile as WPA2."""
    s = (sec or "").upper()
    if not s.strip():
        return "open", "open"
    proto = [p for p in ("WPA1", "WPA2", "WPA3") if p in s]
    if not proto and "WPA" in s:          # bare "WPA" from older nmcli = WPA1
        proto = ["WPA1"]
    if not proto:
        return ("wep", "WEP") if "WEP" in s else ("wpa2", sec)
    label = "/".join(proto)
    if "WPA3" in proto:
        kind = "mixed23" if "WPA2" in proto else "wpa3"
    elif "WPA2" in proto:
        kind = "wpa2"
    else:
        kind = "wpa1"
    return kind, label


def _key_mgmt_for(kind):
    """NM wifi-sec.key-mgmt for a scanned/declared security kind (client side)."""
    return {
        "open": None,
        "wep": "none",       # legacy WEP: key-mgmt none + wep-key0
        "wpa1": "wpa-psk",
        "wpa2": "wpa-psk",
        "mixed23": "wpa-psk",  # WPA2+WPA3 AP: wpa-psk associates via WPA2
        "wpa3": "sae",
    }.get(kind, "wpa-psk")


def _first_key(details, prefix):
    for k, v in details.items():
        if k.startswith(prefix) and v:
            return v
    return None


# --------------------------------------------------------------------------
# regulatory domain
# --------------------------------------------------------------------------

# Fallback allowed-channel profiles for hosts without `iw` (table is
# UI/demo only; on a real device the kernel via `iw` is authoritative).
_NA_24 = list(range(1, 12))
_WORLD_24 = [{"ch": c, "no_ir": c in (12, 13)} for c in range(1, 14)]
_FCC = set("US CA MX PR GU VI AS MP UM FM MH PW".split())
_WIDE5 = set("US CA MX BR AR CL CO PE VE AU NZ CN IN KR TW ZA PR GU VI".split())


def _chan_freq(ch):
    return 2484 if ch == 14 else (2407 + ch * 5 if ch <= 14 else 5000 + ch * 5)


def _mk(chs, **flags):
    return [dict({"ch": c, "freq": _chan_freq(c)}, **flags) for c in chs]


def _fallback_channels(cc):
    if not cc:                       # world/neutral 00
        return {
            "2.4": _mk(range(1, 12)) + _mk([12, 13], no_ir=True) + _mk([14], disabled=True),
            "5": _mk([36, 40, 44, 48], no_ir=True),
        }
    c24 = _mk(range(1, 12)) if cc in _FCC else _mk(range(1, 14))
    c5 = _mk([36, 40, 44, 48]) + (_mk([149, 153, 157, 161, 165]) if cc in _WIDE5 else [])
    return {"2.4": c24, "5": c5}


# Our own settings file, deliberately NOT settings.conf: RTKBase's "Reset settings" rewrites
# that one from settings.conf.default and drops every key the default lacks — which for a
# regulatory setting fails in the wrong direction (an outdoor station would quietly become
# indoor again). It sits next to settings.conf and follows the same convention: the shipped
# .default documents the keys, the live file holds this station's overrides and is created
# from the default by the installer. Provisioning writes it; the configurator reads it all
# and writes back the keys the UI owns a control for (hotspot_rescue, via the access-point
# mode switch) — surgically, see set_station_flag, so hand-written lines survive.
#
#   [wifi]
#   outdoor = true          # station installed outdoors
#   hotspot_rescue = true   # raise the hotspot when the station has no network at all
#
WIFI_CONF = os.path.join(rtkbase_path, "wifi_manager.conf")
# shipped with the software: documents every setting and holds the defaults, so a station
# without its own file still has a readable answer for "what is this set to?"
WIFI_CONF_DEFAULT = os.path.join(rtkbase_path, "wifi_manager.conf.default")
_TRUE = ("1", "true", "yes", "on")
_FALSE = ("0", "false", "no", "off")


def station_setting(key, default="", section="wifi"):
    """Raw value of a station setting. Absent file, section or key -> default.

    Quotes are stripped: the station config is written by provisioning and uses the
    ("outdoor='true'") style in places.
    """
    import configparser
    try:
        cp = configparser.ConfigParser(interpolation=None)
        cp.read([WIFI_CONF_DEFAULT, WIFI_CONF])   # the station's own file wins
        if not cp.has_option(section, key):
            return default
        return (cp.get(section, key) or "").strip().strip("'\"")
    except Exception as e:
        log.warning("could not read %s: %s", WIFI_CONF, e)
        return default


def station_flag(key, default=False, section="wifi"):
    """Read a boolean station setting. Absent file, section, key or value -> default."""
    raw = station_setting(key, None, section)
    if raw is None:
        return default
    raw = raw.lower()
    if raw in _TRUE:
        return True
    if raw in _FALSE:
        return False
    log.warning("%s: %s=%r is not a boolean", WIFI_CONF, key, raw)
    return default


def set_station_flag(key, value, section="wifi"):
    """Write one boolean into the station's own wifi_manager.conf.

    The file is also written by provisioning and edited by hand, so the edit is surgical:
    only the key's own line changes, every other line — comments, quoting style, unknown
    keys, other sections — survives byte for byte. A configparser round-trip would lose
    all of that, hence the line-based pass.
    """
    word = "true" if value else "false"
    try:
        with open(WIFI_CONF) as f:
            lines = f.readlines()
    except OSError:
        lines = []
    key_re = re.compile(r"^\s*{}\s*=".format(re.escape(key)))
    sec_re = re.compile(r"^\s*\[([^]]+)\]")
    out, current, section_end, replaced = [], None, None, False
    for line in lines:
        m = sec_re.match(line)
        if m:
            current = m.group(1).strip().lower()
        elif current == section and not replaced and key_re.match(line):
            line = "{} = {}\n".format(key, word)
            replaced = True
        if current == section:
            section_end = len(out) + 1     # insertion point: right after this line
        out.append(line)
    if not replaced:
        entry = "{} = {}\n".format(key, word)
        if section_end is not None:
            out.insert(section_end, entry)
        else:
            if out and not out[-1].endswith("\n"):
                out[-1] += "\n"
            if out:
                out.append("\n")
            out.extend(["[{}]\n".format(section), entry])
    try:
        tmp = WIFI_CONF + ".tmp"
        with open(tmp, "w") as f:
            f.writelines(out)
        os.replace(tmp, WIFI_CONF)
    except OSError as e:
        raise WifiError("could not write {}: {}".format(WIFI_CONF, e))


def unavailable_channels():
    """Channels this station's adapter refuses for an access point, from `wifi_manager.conf`.

    Some adapters accept a channel in every regulatory table and then refuse it in firmware.
    Measured on a Raspberry Pi (brcmfmac): the upper 5 GHz band comes back as
    `brcmf_cfg80211_start_ap: Set Channel failed: chspec=..., -52`, right after
    `Firmware rejected country setting` — the radio keeps its own domain and does not hand that
    band over. Nothing in `iw reg get` or `iw phy` predicts it: both list the channel as
    allowed, at full power. So the list is declared per station, like the outdoor flag.

    No default: an empty setting means nothing is excluded, and a station whose adapter is
    fine keeps every channel its region allows.
    """
    raw = station_setting("unavailable_channels")
    out = set()
    for part in re.split(r"[,\s]+", str(raw or "")):
        if part.isdigit():
            out.add(int(part))
    return out


def outdoor_station():
    """Is this station installed outdoors? Regulatory rules differ (NO-OUTDOOR ranges).

    Indoor/outdoor cannot be detected — only the owner knows — so it comes from the station
    config, set when the station is built.
    """
    return station_flag("outdoor")


def no_outdoor_ranges():
    """(start, end) MHz ranges the current regdomain marks NO-OUTDOOR.

    The per-channel table (`iw phy`) does NOT carry this flag — it only exists on the range
    lines of `iw reg get` — so outdoor filtering has to map channels onto these ranges.
    """
    ranges = []
    if not shutil.which("iw"):
        return ranges
    try:
        out = _iw("reg", "get")
    except Exception as e:
        log.warning("iw reg get failed: %s", e)
        return ranges
    for line in out.splitlines():
        if line.strip().startswith("phy#"):
            # only the global domain: a self-managed phy appends its own table, whose vendor
            # domain can mark ranges NO-OUTDOOR that the selected country does not
            break
        if "NO-OUTDOOR" not in line:
            continue
        m = re.search(r"\((\d+)\s*-\s*(\d+)\s*@", line)
        if m:
            ranges.append((int(m.group(1)), int(m.group(2))))
    return ranges


def _iw(*args):
    out = subprocess.check_output(("iw",) + args, text=True, timeout=10,
                                  stderr=subprocess.STDOUT)
    return out


def sta_link():
    """What the radio actually has on the client interface, read from `iw dev <iface> link`.

    NetworkManager lags here. Starting the access point drops the client link inside the
    firmware — the radio holds one channel, and the point takes it — and NM keeps reporting
    the profile as activated for about three and a half seconds afterwards (measured), address
    still on the interface. The dialog refreshes faster than that, so it lands inside the
    window and shows a working connection to a network the station has already left.

    Returns the association as {"ssid", "bssid", "freq"}, {} when the radio says it is not
    associated, and None when we cannot tell (no `iw`, no interface, call failed) — the
    caller then leaves NM's answer alone rather than inventing a disconnect.
    """
    if not shutil.which("iw"):
        return None
    # no interface at all (a host without Wi-Fi): honest "cannot tell", quietly — the
    # background asks every tick, and a warning per tick is log litter, not information
    if not os.path.isdir("/sys/class/net/" + WIFI_IFACE):
        return None
    try:
        out = _iw("dev", WIFI_IFACE, "link")
    except Exception as e:
        log.warning("iw link failed: %s", e)
        return None
    if "not connected" in out.lower():
        return {}
    link = {}
    for line in out.splitlines():
        line = line.strip()
        low = line.lower()
        if low.startswith("connected to"):
            link["bssid"] = line.split()[2].upper()
        elif low.startswith("ssid:"):
            link["ssid"] = line.split(":", 1)[1].strip()
        elif low.startswith("freq:"):
            freq = line.split(":", 1)[1].strip().split()[0]
            if freq.isdigit():
                link["freq"] = int(freq)
    return link


def ap_air_channel():
    """(band, chan) the access point is really beaconing on — ("", 0) when it is not.

    Asked of wpa_supplicant, not of `iw`. The channel line of `iw dev <ap> info` is the radio's
    momentary tuning, not the point's operating channel: while a scan runs it walks the whole
    band, and if the point is not actually beaconing (NetworkManager still calls the profile
    activated after the firmware handed the radio to a client link) that walk is what gets
    reported. Measured over six seconds on a station: 4, 112, 13, 104, 140, 64 — and the dialog
    told the operator the access point was on channels it had never used, once even that ch100
    was illegal in his region while the form said ch48 and the client sat on ch1.

    The supplicant answers about the point itself: `mode=AP` with `wpa_state=COMPLETED` means a
    beacon is up, and `freq` is where it is. `iw` stays as a fallback for a host without
    wpa_cli, where a wrong channel is still better than no indication at all.

    One more liar: with a CLIENT LINK live on the same radio, the firmware quietly moves the
    beacon onto the client's channel and tells nobody — the supplicant keeps reporting the
    channel the point was configured with (seen in the field: form says 5 GHz ch 132, the
    beacon sits on 2.4 ch 1 next to the client, and this function repeated the 132). A single
    radio cannot beacon away from its own association, so while a client link is up, ITS
    channel is the point's channel — the supplicant's number is trusted only when no client
    holds the radio.
    """
    def follow_client(band, chan):
        link = sta_link()
        freq = link.get("freq") if link else None
        if freq:
            return freq_to_band(freq) or "", freq_to_chan(freq)
        return band, chan


    wpa_cli = shutil.which("wpa_cli")
    if wpa_cli:
        try:
            out = subprocess.run([wpa_cli, "-i", AP_IFACE, "status"], capture_output=True,
                                 text=True, timeout=10).stdout
        except Exception as e:
            log.warning("wpa_cli status on %s failed: %s", AP_IFACE, e)
            out = ""
        if "wpa_state=" in out:
            state = re.search(r"^wpa_state=(\S+)", out, re.MULTILINE)
            mode = re.search(r"^mode=(\S+)", out, re.MULTILINE)
            freq = re.search(r"^freq=(\d+)", out, re.MULTILINE)
            if not (state and state.group(1) == "COMPLETED" and mode
                    and mode.group(1) == "AP" and freq):
                return "", 0        # the supplicant says no beacon; that is the answer
            freq = int(freq.group(1))
            return follow_client(freq_to_band(freq) or "", freq_to_chan(freq))
    if not shutil.which("iw"):
        return "", 0
    try:
        out = _iw("dev", AP_IFACE, "info")
    except Exception:
        return "", 0            # no such interface: nothing is beaconing
    if not re.search(r"^\s*type AP\s*$", out, re.MULTILINE):
        return "", 0
    m = re.search(r"^\s*channel (\d+) \((\d+) MHz\)", out, re.MULTILINE)
    if not m:
        return "", 0
    return follow_client(freq_to_band(int(m.group(2))) or "", int(m.group(1)))


def probe_hidden(ssid):
    """Ask a hidden network about itself: {"bssid", "band", "chan", "freq", "security",
    "security_label"} or None when nothing answers.

    A hidden access point is missing from an ordinary scan — it does not put its name in the
    beacon — but it does answer a probe addressed to that name, and the answer carries the
    same RSN/WPA information a beacon would. So neither the channel nor the security type has
    to be guessed or asked for: the point can follow the client onto a hidden network like any
    other, and the security selector can be filled in instead of interrogated.
    """
    ssid = (ssid or "").strip()
    if not ssid or not shutil.which("iw"):
        return None
    log.info("wifi: hidden probe for '%s'", ssid)
    out = None
    for attempt in range(3):
        try:
            out = _iw("dev", WIFI_IFACE, "scan", "ssid", ssid)
            break
        except Exception as e:
            # the radio refuses a second scan while one is running (EBUSY, `iw` exits 240) —
            # and something usually is: the dialog refreshes the network list on a timer
            busy = getattr(e, "returncode", None) == 240 or "busy" in _err_detail(e).lower()
            if not busy or attempt == 2:
                log.warning("directed scan for a hidden network failed: %s", _err_detail(e))
                return None
            time.sleep(2.5)
    if out is None:
        return None
    best = None
    for block in re.split(r"^BSS ", out, flags=re.MULTILINE)[1:]:
        name = re.search(r"^\s*SSID: (.*)$", block, re.MULTILINE)
        if not name or name.group(1).strip() != ssid:
            continue           # the same probe also returns the nameless beacon — skip it
        m = re.match(r"([0-9a-fA-F:]{17})", block)
        freq = re.search(r"^\s*freq: (\d+)", block, re.MULTILINE)
        freq = int(freq.group(1)) if freq else 0
        rsn = re.search(r"^\s*RSN:(?:.|\n)*?(?=^\t[A-Za-z]|\Z)", block, re.MULTILINE)
        akm = re.search(r"Authentication suites: ([^\n]*)", rsn.group(0)) if rsn else None
        akm = akm.group(1) if akm else ""
        protos = []
        if re.search(r"^\s*WPA:", block, re.MULTILINE):
            protos.append("WPA1")
        if rsn:
            protos.append("WPA2")
            if "SAE" in akm:
                protos.append("WPA3")
        if protos:
            kind, label = parse_security(" ".join(protos))
        elif "Privacy" in block:
            kind, label = "wep", "WEP"       # encrypted, but no RSN/WPA element: legacy WEP
        else:
            kind, label = "open", "open"
        hit = {"bssid": (m.group(1).upper() if m else None),
               "freq": freq, "band": freq_to_band(freq) or "", "chan": freq_to_chan(freq),
               "security": kind, "security_label": label}
        if best is None or (hit["chan"] and not best["chan"]):
            best = hit
    return best


def _link_says_in_use(entry, link):
    """Does the radio's own association match this row of the network list?

    True/False when the radio can answer, None when it cannot (see sta_link) — then the row
    keeps whatever NM said. Matching prefers the BSSID: after roaming, NM still points at the
    profile while the radio sits on a different BSS of the same SSID.
    """
    if link is None:
        return None
    if not link:
        return False
    bssid = (link.get("bssid") or "").upper()
    if bssid and entry.get("bssid"):
        return (entry["bssid"] or "").upper() == bssid
    return bool(link.get("ssid")) and entry.get("ssid") == link.get("ssid")


def _ap_iface_macs():
    """Every MAC of the interfaces that share the radio of WIFI_IFACE.

    Our own beacons must never appear as a joinable network. A hotspot can run on a virtual
    AP interface of the SAME radio (`iw dev wlan0 interface add ap0 type __ap`, which is how
    the station provisioning sets one up) whose address differs from wlan0's — filtering by
    the wlan0 address alone let the station's own hotspot show up in the list as a stranger.

    Not restricted to interfaces currently in AP mode: when a start fails, the interface can
    read back as `managed` while the firmware still beacons — that is exactly when the
    station's own network appeared in the list as somebody else's. An address that belongs to
    this radio is never a network to join, whatever mode the interface reports.

    Deliberately scoped to that one radio: an access point running on a *different* adapter
    of the same host is a separate device as far as wlan0 is concerned, and hiding it would
    drop a real, joinable network from the list."""
    if not shutil.which("iw"):
        return set()
    try:
        out = _iw("dev")
    except Exception as e:
        log.warning("iw dev failed: %s", e)
        return set()
    # `iw dev` lists interfaces grouped under the radio ("phy#N") that owns them
    radios = {}
    phy = None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("phy#"):
            phy = radios.setdefault(line, {"ifaces": set(), "macs": set()})
        elif line.startswith("Interface ") and phy is not None:
            phy["ifaces"].add(line.split()[1])
        elif line.startswith("addr ") and phy is not None:
            phy["macs"].add(line.split()[1].upper())
    for radio in radios.values():
        if WIFI_IFACE in radio["ifaces"]:
            return set(radio["macs"])
    # radio of WIFI_IFACE not found (no Wi-Fi at all, or the interface was renamed): keep the
    # safe side of the trade-off and treat every wireless address of this host as ours
    return {mac for radio in radios.values() for mac in radio["macs"]}


RESCUE_CHECK_S = 30          # how often the watchdog looks at the station
RESCUE_ISOLATED_S = 180      # unreachable this long -> raise the hotspot
RESCUE_ONLINE_S = 60         # reachable again this long -> lower what we raised
STARTUP_GRACE_S = 10         # keep the background off the radio right after service start:
                             # provisioning and NetworkManager are still settling the boot
NM_RUN_DIR = "/run/NetworkManager"   # exists once NetworkManager has started this boot
RESCUE_HEARTBEAT_TICKS = 20  # one "alive" journal line this many ticks (~10 min)

_rescue_raised = False       # only ever lower an access point the watchdog itself raised
_last_isolated = None        # isolation state at the previous look, None = never looked


def _heartbeat_due(tick):
    """True on the ticks that get an "alive" line: the first one (so the journal confirms
    the watchdog started at all — its silent freeze is otherwise indistinguishable from
    idling), then every RESCUE_HEARTBEAT_TICKS."""
    return tick % RESCUE_HEARTBEAT_TICKS == 1


def _note_isolation(isolated):
    """One journal line per isolation change; returns "lost" | "online" | None.

    The journal must answer "was the station ever without a network, and when" without
    logging every tick. Booting straight into isolation is a change worth a line too;
    booting online is not."""
    global _last_isolated
    prev, _last_isolated = _last_isolated, isolated
    if isolated and not prev:
        log.info("wifi: station lost all networks (no wifi link, no wired carrier)")
        return "lost"
    if prev and not isolated:
        log.info("wifi: station back online")
        return "online"
    return None


def rescue_enabled():
    """Should the station raise its hotspot when it ends up with no network at all?"""
    return station_flag("hotspot_rescue")


def ap_flags(role_is_ap, ap_live, rescue):
    """Truth for the two independent controls: (enabled, raised_by_auto).

    `enabled` is the operator's own point: the AP role, or a live point with neither the
    role nor the rescue flag (NetworkManager clears autoconnect after repeated failures) —
    that one must still read ON so the toggle keeps a way to switch it off. A live point
    next to the rescue flag is the watchdog's doing: the operator never chose ON there, so
    the toggle stays OFF and `raised_by_auto` tells the air indicator whose beacon it is.
    """
    if role_is_ap:
        return True, False
    if ap_live:
        return (not rescue), rescue
    return False, False


def ethernet_carrier():
    """True when some wired interface has a cable in it.

    Read from the kernel rather than NetworkManager: a station can be perfectly reachable
    over a wired link NM does not manage, and raising a rescue hotspot there would be noise.
    """
    try:
        for name in os.listdir("/sys/class/net"):
            if name == "lo" or name.startswith(("wlan", "ap", "p2p", "tailscale", "docker", "veth")):
                continue
            try:
                with open("/sys/class/net/{}/carrier".format(name)) as f:
                    if f.read().strip() == "1":
                        return True
            except OSError:
                continue          # carrier is unreadable while the link is down
    except OSError as e:
        log.warning("could not inspect wired interfaces: %s", e)
    return False


def station_isolated():
    """No way in: no Wi-Fi client connection and no wired carrier."""
    if ethernet_carrier():
        return False
    try:
        return wifi_state().get("state") != "connected"
    except Exception as e:
        log.warning("could not read the Wi-Fi state: %s", e)
        return False          # unknown state is not proof of isolation


def _rescue_set_ap(up):
    """Raise/lower the hotspot as a rescue path — WITHOUT touching autoconnect flags.

    The manual toggle switches roles: it clears autoconnect on the client networks so the
    radio stays with the access point. The watchdog must not do that. If it did, a station
    that lost its network for five minutes would keep the hotspot forever and never rejoin
    the network when it came back. Here the hotspot is only brought up next to untouched
    client profiles, so NetworkManager reconnects on its own the moment the network returns.
    """
    ref = _ap_ref()
    if not ref:
        return False
    try:
        if up:
            # the profile is bound to the AP interface, which does not survive a reboot on a
            # station whose provisioning does not recreate it — without this the rescue fails
            # with a bare "Connection activation failed"
            ensure_ap_iface()
            nmcli.connection.up(ref, wait=30)
        else:
            nmcli.connection.down(ref)
        return True
    except Exception as e:
        log.warning("rescue hotspot could not be %s: %s", "raised" if up else "lowered", e)
        return False


def rescue_tick(isolated, ap_active, isolated_for, online_for):
    """Decide what the watchdog should do. Pure, so the policy is testable on its own.

    Returns (action, isolated_for, online_for) where action is None | 'up' | 'down'.
    """
    if isolated:
        isolated_for, online_for = isolated_for + RESCUE_CHECK_S, 0
        if not ap_active and isolated_for >= RESCUE_ISOLATED_S:
            return "up", 0, 0
    else:
        online_for, isolated_for = online_for + RESCUE_CHECK_S, 0
        if _rescue_raised and ap_active and online_for >= RESCUE_ONLINE_S:
            return "down", 0, 0
    return None, isolated_for, online_for


def freq_to_chan(freq):
    """Channel number for a 2.4/5 GHz centre frequency in MHz, or 0 when it is neither."""
    try:
        freq = int(freq)
    except (TypeError, ValueError):
        return 0
    if freq == 2484:
        return 14
    if 2412 <= freq <= 2472:
        return (freq - 2407) // 5
    if 5000 < freq < 5900:
        return (freq - 5000) // 5
    return 0


def couple_tick(link, ap_active, ap_band, ap_chan, loaned, pending=None):
    """What the coupling needs next, given the radio's own view. Pure, so it is testable.

    link: sta_link() — None when the radio cannot answer, {} when nothing is associated.
    loaned: the point stands on a channel borrowed for a client link, not the operator's own.
    pending: (band, chan) of a network the station is meant to be on but is not.

    Two ways the point ends up in the client's way. It can hold a channel while the link sits
    on another one — and it can hold a channel while the client cannot get onto its network at
    all, because a point on the wrong channel starves the handshake and NetworkManager reports
    that as a missing key. The second one is what actually happens on a single-channel radio:
    the client never reaches the state where both are up on different channels, it just keeps
    failing. Both are answered the same way — move the point to where the client needs to be.

    Returns ("follow", band, chan) | ("return", None, None) | (None, None, None). Nothing is
    decided from NetworkManager's state: it lags the radio by seconds, and acting on that lag
    would move the point for a link that no longer exists.
    """
    if link is None:
        return None, None, None
    if link:
        band, chan = freq_to_band(link.get("freq")), freq_to_chan(link.get("freq"))
        if band and chan and ap_active:
            # A profile without an explicit channel (Auto) stands wherever the radio put it,
            # and next to a live link that is the link's channel — the single radio has no
            # other. Realigning there would only pin the operator's Auto and bounce both
            # sides for nothing. A profile pinned elsewhere, or locked to the other band,
            # is a real mismatch.
            pinned_elsewhere = ap_chan and (ap_band, ap_chan) != (band, chan)
            band_locked_elsewhere = not ap_chan and ap_band and ap_band != band
            if pinned_elsewhere or band_locked_elsewhere:
                return "follow", band, chan
        return None, None, None
    if pending and ap_active and tuple(pending) != (ap_band, ap_chan):
        return "follow", pending[0], pending[1]
    if ap_active and loaned:
        return "return", None, None
    return None, None, None


def _pending_client():
    """A saved network the station should be on but is not: {"band", "chan", "profile"} or None.

    Only networks whose beacon is in the current scan count. NetworkManager retries such a
    profile on its own, and every attempt dies while our point holds a different channel; a
    profile whose network is simply out of range must not pull the point off the operator's
    channel for nothing.
    """
    try:
        profiles = _wifi_profiles()
    except Exception as e:
        log.warning("could not list profiles: %s", e)
        return None
    by_bssid, by_ssid = {}, {}
    for name, details in profiles.items():
        if name == AP_PROFILE or _is_ap(details):
            continue
        if details.get("connection.autoconnect") != "yes":
            continue
        bssid = (details.get("802-11-wireless.bssid") or "").upper()
        if bssid and bssid != "--":
            by_bssid[bssid] = name
        else:
            by_ssid[details.get("802-11-wireless.ssid") or
                    (name[len(CLIENT_PREFIX):] if name.startswith(CLIENT_PREFIX)
                     else name)] = name
    if not (by_bssid or by_ssid):
        return None
    try:
        # pinned to the client interface: other wifi devices' caches (the AP's own) must not
        # nominate a network the client interface cannot actually see
        scan = nmcli.device.wifi(ifname=WIFI_IFACE)
    except Exception as e:
        log.warning("could not scan while looking for a network to rejoin: %s", e)
        return None
    best = None
    chans = allowed_channels()          # once, not per scan row — it shells out to iw
    for n in scan:
        bssid = (n.bssid or "").upper()
        if bssid in _own_ap_bssids:
            continue                     # our own beacon is not a network to rejoin
        profile = by_bssid.get(bssid) or by_ssid.get(n.ssid)
        if not profile:
            continue
        band, chan = freq_to_band(n.freq), freq_to_chan(n.freq)
        if not (band and chan and ap_channel_ok(band, chan, chans)):
            continue                     # the point cannot follow there anyway
        if best is None or (n.signal or 0) > best["signal"]:
            best = {"signal": n.signal or 0, "band": band, "chan": chan, "profile": profile}
    return best


def _ap_live_channel():
    """(band, channel) the access-point profile currently carries."""
    ref = _ap_ref()
    if not ref:
        return None, 0
    try:
        details = nmcli.connection.show(ref)
    except Exception as e:
        log.warning("could not read the AP channel: %s", e)
        return None, 0
    band = {"bg": "2.4", "a": "5"}.get(details.get("802-11-wireless.band"))
    chan = details.get("802-11-wireless.channel")
    return band, int(chan) if (chan or "").isdigit() else 0


def _active_client_profile():
    """Name of the client profile NetworkManager currently has up, if any."""
    try:
        profiles = _wifi_profiles()
    except Exception as e:
        log.warning("could not list profiles: %s", e)
        return None
    for name, details in profiles.items():
        if name == AP_PROFILE or _is_ap(details):
            continue
        if details.get("GENERAL.STATE") == "activated":
            return name
    return None


def couple_reconcile():
    """Keep the point and the client on one channel when the connection was made elsewhere.

    Connections do not only come from this dialog: NetworkManager autoconnects at boot, the
    client roams, and the station's own WPS script joins networks with plain nmcli. Any of
    those can leave the point on one channel and the client on another, which starves the
    handshake and looks like a wrong password. Here that is repaired after the fact.

    Moving the point drops the client link (the radio hands the channel over), so the client
    profile is activated again right after — in that order it comes back, since the point is
    already standing where the client is going.
    """
    if not _radio_lock.acquire(blocking=False):
        return None            # an operator operation owns the radio — it knows better
    try:
        if not _radio_flock():
            return None        # ...or one in another process, including the twin watchdog
        try:
            return _couple_reconcile_locked()
        finally:
            _radio_funlock()
    finally:
        _radio_lock.release()


def _couple_reconcile_locked():
    global _last_realign
    prefs = _load_ap_prefs()
    ap_band, ap_chan = _ap_live_channel()
    link = sta_link()
    ap_live = _ap_active()
    # only worth asking when the station is not connected and the point is up — that is the
    # state where our own beacon can be the reason the client cannot get back on
    waiting = (_pending_client()
               if (link == {} and ap_live
                   and not (_client_off_by_operator or prefs.get("client_off"))) else None)
    action, band, chan = couple_tick(link, ap_live, ap_band, ap_chan,
                                     bool(prefs.get("band_written")),
                                     (waiting["band"], waiting["chan"]) if waiting else None)
    if action == "follow":
        if time.time() - _last_realign < RESCUE_CHECK_S * 2:
            return None          # one move per two ticks: never trade a link for a loop
        if not ap_channel_ok(band, chan):
            log.info("client is on %s GHz ch%s, where the access point may not run — leaving "
                     "the point where it is", band, chan)
            return None
        profile = _active_client_profile()
        _last_realign = time.time()
        log.warning("access point is on %s ch%s while the client needs %s ch%s — realigning",
                    ap_band, ap_chan, band, chan)
        if not _ap_follow_channel(band, chan):
            return None
        # the client goes up explicitly: moving the point drops an existing link, and a client
        # that was failing on the wrong channel should not wait for NM's next retry
        for name in (profile, waiting["profile"] if waiting else None):
            if not name:
                continue
            try:
                nmcli.connection.up(name, wait=45)
                break
            except Exception as e:
                log.warning("could not bring '%s' up after realigning: %s", name,
                            _err_detail(e))
        return "follow"
    if action == "return":
        return "return" if ap_return_to_preferred() else None
    return None


def _rescue_step(isolated_for, online_for):
    """One pass of the rescue policy, under the radio locks.

    Raising or lowering the point is a radio operation like any other: without the locks a
    tick can land inside an operator's connect() that just took the point down for the
    attempt, and put it back up across the association being negotiated — on a shared
    channel that starves the handshake, and the join dies on a bare timeout every time.
    A busy radio simply skips the pass; the counters pick up on the next tick.
    """
    global _rescue_raised
    if not _radio_lock.acquire(blocking=False):
        return isolated_for, online_for
    try:
        if not _radio_flock():
            return isolated_for, online_for
        try:
            isolated = station_isolated()
            _note_isolation(isolated)
            action, isolated_for, online_for = rescue_tick(
                isolated, _ap_active(), isolated_for, online_for)
            if action == "up":
                log.warning("no network for %ss — raising the rescue hotspot",
                            RESCUE_ISOLATED_S)
                _rescue_raised = _rescue_set_ap(True)
            elif action == "down":
                log.info("station is back online — lowering the rescue hotspot")
                if _rescue_set_ap(False):
                    _rescue_raised = False
        finally:
            _radio_funlock()
    finally:
        _radio_lock.release()
    return isolated_for, online_for


def rescue_watchdog(stop=None):
    """A station whose network is gone must not become unreachable, and the access point must
    not sit on a channel the client is not using.

    Survives a reboot because the web service itself starts at boot — no extra unit to
    install. Deliberately conservative: it only acts on a station configured for it
    (`[wifi] hotspot_rescue` in wifi_manager.conf), only after RESCUE_ISOLATED_S of no
    network at all, and it only lowers a hotspot it raised itself, so an access point
    switched on by the operator is never touched.
    """
    # the service starts together with the boot-time provisioning; give it (and
    # NetworkManager) the first seconds of the radio without our background on top
    time.sleep(STARTUP_GRACE_S)
    # A cold boot brings NetworkManager up well after us. Until its run dir exists, every
    # nmcli call is doomed to exit 8 ("NM is not running") — and those exits litter the
    # boot log, so the wait must not spawn a single subprocess. The directory test is the
    # cheapest honest probe there is.
    while not (stop and stop.is_set()) and not os.path.isdir(NM_RUN_DIR):
        time.sleep(RESCUE_CHECK_S)
    if not os.path.isdir(NM_RUN_DIR):
        return      # stopped while NetworkManager never appeared — nothing to reconcile
    if _radio_lock.acquire(blocking=False):
        try:
            if _radio_flock(wait_s=5):
                try:
                    migrate_legacy_autoconnect()
                finally:
                    _radio_funlock()
        finally:
            _radio_lock.release()
    isolated_for = online_for = 0
    ticks = 0
    while not (stop and stop.is_set()):
        time.sleep(RESCUE_CHECK_S)
        try:
            ticks += 1
            rescue = rescue_enabled()
            if _heartbeat_due(ticks):
                # the only periodic line: proves the watchdog is alive (a frozen one is
                # otherwise indistinguishable from one with nothing to do)
                log.debug("wifi: watchdog alive (rescue=%s, isolated for %ss, online for %ss)",
                         "on" if rescue else "off", isolated_for, online_for)
            # the coupling is not part of the rescue feature and runs on every station: an
            # access point and a client on different channels break each other whatever the
            # rescue flag says
            couple_reconcile()
            if not rescue:
                isolated_for = online_for = 0
                continue
            isolated_for, online_for = _rescue_step(isolated_for, online_for)
        except Exception as e:                  # a watchdog must never die
            log.warning("rescue watchdog: %s", e)


def start_rescue_watchdog():
    """Start the watchdog in the background (gunicorn runs a single gevent worker)."""
    t = threading.Thread(target=rescue_watchdog, name="wifi-rescue", daemon=True)
    t.start()
    return t


def migrate_legacy_autoconnect():
    """One-time repair after the role-model change: give client networks their autoconnect back.

    set_ap used to clear autoconnect on every client profile while the access point ran, and
    put the flags back on disable. The current code touches only the point's own flag, so a
    station upgraded while its point was up would keep the cleared flags forever: the operator
    turns the point off, nothing reconnects, and a reboot leaves the station offline. The
    legacy state is unmistakable — point in the AP role and EVERY client profile cleared (the
    old code also refused to turn a single flag back on while the point ran); mixed flags are
    somebody's own choice and are left alone. Runs once per station: the marker lives in the
    prefs file, so the watchdog's twin in the other process does not repeat the pass.
    """
    prefs = _load_ap_prefs()
    if prefs.get("legacy_autoconnect_migrated"):
        return False
    _save_ap_prefs(dict(prefs, legacy_autoconnect_migrated=True))
    try:
        if get_role() != "ap":
            return False
        clients = {name: d for name, d in _wifi_profiles().items()
                   if name != AP_PROFILE and not _is_ap(d)}
        if not clients or any(d.get("connection.autoconnect") == "yes"
                              for d in clients.values()):
            return False
        for name in clients:
            try:
                nmcli.connection.modify(name, {"connection.autoconnect": "yes"})
            except Exception as e:
                log.warning("could not give '%s' its autoconnect back: %s", name, e)
        log.warning("restored autoconnect on %d client networks cleared by the previous "
                    "role model", len(clients))
        return True
    except Exception as e:
        log.warning("legacy autoconnect repair skipped: %s", e)
        return False


def get_country():
    """Current regdomain CC, or None when there is no single real country in effect.

    Besides world ('00'), the kernel reports pseudo-codes when it can't settle on one
    country — '99' (custom) and '98' (intersection of two domains, e.g. a manual `iw reg
    set DE` while associated to an AP whose 802.11d country IE says US). None of those is a
    selectable country, so treat them all as "no region".
    """
    if not shutil.which("iw"):
        return _fallback_country
    try:
        out = _iw("reg", "get")
    except Exception as e:
        log.warning("iw reg get failed: %s", e)
        return _fallback_country
    m = re.search(r"^country (\S\S):", out, re.MULTILINE)   # first (global) country line
    if not m:
        return None
    cc = m.group(1)
    return cc if re.fullmatch(r"[A-Z]{2}", cc) and cc not in ("00", "99", "98", "97") else None


def set_country(cc):
    """Apply the regdomain: raspi-config on Pi, iw elsewhere."""
    global _fallback_country
    cc = (cc or "").strip().upper()
    log.info("wifi: country change to %s requested", cc or "<empty>")
    if not re.fullmatch(r"[A-Z]{2}", cc):
        raise ValueError("invalid country code")
    if shutil.which("raspi-config"):
        subprocess.check_call(["raspi-config", "nonint", "do_wifi_country", cc],
                              timeout=30)
    elif shutil.which("iw"):
        subprocess.check_call(["iw", "reg", "set", cc], timeout=10)
    else:
        _fallback_country = cc      # bench/DIY without iw: remember for UI flow
    try:
        nmcli.device.wifi_rescan(ifname=WIFI_IFACE)
    except Exception:
        pass
    log.info("wifi: country set to %s", cc)


def allowed_channels():
    """Per-band channel lists with flags from the kernel (`iw list`), or fallback.

    Returns {"2.4": [{ch, freq, no_ir?, disabled?, dfs?}], "5": [...]}.
    """
    if not shutil.which("iw"):
        return _fallback_channels(get_country())
    try:
        out = _iw("list")
    except Exception as e:
        log.warning("iw list failed: %s", e)
        return _fallback_channels(get_country())
    chans = {"2.4": [], "5": []}
    # lines like: * 2412 MHz [1] (20.0 dBm)   / (no IR)  / (disabled) / (radar detection)
    for m in re.finditer(r"\*\s+(\d+)(?:\.\d+)? MHz \[(\d+)\](.*)", out):
        freq, ch, rest = int(m.group(1)), int(m.group(2)), m.group(3)
        entry = {"ch": ch, "freq": freq}
        if "disabled" in rest:
            entry["disabled"] = True
        if "no IR" in rest:
            entry["no_ir"] = True
        if "radar detection" in rest:
            entry["dfs"] = True
        band = freq_to_band(freq)
        if all(e["ch"] != ch for e in chans[band]):
            chans[band].append(entry)
    # NO-OUTDOOR is a property of the frequency RANGE, not of the channel, so it is matched
    # here against the 20 MHz the channel occupies. Marked always; whether it restricts
    # anything depends on the station being declared outdoor.
    outdoor_bad = no_outdoor_ranges()
    unavailable = unavailable_channels()
    for band in chans:
        for e in chans[band]:
            lo, hi = e["freq"] - 10, e["freq"] + 10
            if any(lo >= start and hi <= end for start, end in outdoor_bad):
                e["no_outdoor"] = True
            if e["ch"] in unavailable:
                # declared for this station: the adapter refuses it in firmware, and no
                # regulatory table shows that (see unavailable_channels)
                e["unavailable"] = True
        chans[band].sort(key=lambda e: e["ch"])
    return chans


def available_bands():
    """Bands the adapter supports, from `iw phy`; None = unknown."""
    if not shutil.which("iw"):
        return None
    try:
        out = _iw("phy")
    except Exception:
        return None
    bands = []
    if re.search(r"Band 1:", out):
        bands.append("2.4")
    if re.search(r"Band 2:", out):
        bands.append("5")
    return bands or None


def ap_channel_ok(band, ch, chans=None):
    """Can the ACCESS POINT beacon on this channel right now?

    Beaconing needs a channel the adapter reports as usable: not disabled, not NO-IR
    (no transmission allowed) and not DFS (radar detection — we never start an AP there).
    The adapter's own table is authoritative and can be stricter than the country table:
    on a self-managed phy (brcmfmac on a Pi) the firmware disables e.g. 5 GHz 149-165 even
    where the country rules permit them, and hostapd then fails with a cryptic supplicant
    timeout instead of "this channel is not allowed"."""
    if not ch or band not in ("2.4", "5"):
        return True                      # Auto (0) / band not pinned — NM picks
    chans = chans if chans is not None else allowed_channels()
    outdoor = outdoor_station()
    for e in chans.get(band, []):
        if e["ch"] == ch:
            if e.get("unavailable"):
                return False        # declared unusable on this station's adapter
            if outdoor and e.get("no_outdoor"):
                return False        # indoor-only channel on a station declared outdoor
            return not (e.get("disabled") or e.get("no_ir") or e.get("dfs"))
    return False


def outdoor_nowhere(chans=None):
    """True when the region leaves an outdoor station no channel for an access point at all.

    In some regions every range is marked indoor-only — Indonesia marks all five, 2.4 GHz
    included. The per-band note then says "not allowed on 2.4 GHz, use the other band" twice
    and never says the plain thing: here an outdoor station cannot run an access point.
    """
    if not outdoor_station():
        return False
    chans = allowed_channels() if chans is None else chans
    for band, rows in chans.items():
        for e in rows:
            if ap_channel_ok(band, e["ch"], chans):
                return False
    return True


def channel_usable(band, ch, chans, country):
    """Gating -> 'ok' | 'no_region' | 'disabled'."""
    if not country:
        # No region selected: don't trust the kernel's CURRENT channel flags — a
        # self-managed phy (e.g. brcmfmac on a Pi) or an 802.11d intersection can leave
        # the kernel in a permissive domain that allows e.g. 5 GHz ch 100 while the UI
        # says "no region". Gate by the world-safe set instead (what the dialog
        # promises): only 2.4 GHz ch 1-11 beacons everywhere.
        return "ok" if band == "2.4" and 1 <= (ch or 0) <= 11 else "no_region"
    entry = next((e for e in chans.get(band, []) if e["ch"] == ch), None)
    if entry is None or entry.get("disabled"):
        return "disabled"   # unknown to / disabled in the selected domain
    return "ok"


REGDB_FILE = "/lib/firmware/regulatory.db"


def _regdb_countries():
    """Alpha2 codes the kernel regulatory database actually contains, or None.

    `iw reg set XX` with a code the database doesn't know is silently ignored by the
    kernel (the domain falls back to world '00'), so offering such a country in the
    picker can only ever fail. Binary fwdb format: 8-byte header (magic 'RGDB',
    version), then 4-byte records {alpha2[2], be16 pointer}; a zero pointer ends the
    list. None (no/unreadable/unknown-format file) means "can't tell — don't filter".
    """
    try:
        with open(REGDB_FILE, "rb") as f:
            data = f.read()
        if data[:4] != b"RGDB":
            log.warning("%s: unexpected format, country list not filtered", REGDB_FILE)
            return None
        codes = set()
        off = 8
        while off + 4 <= len(data):
            alpha2 = data[off:off + 2]
            if not int.from_bytes(data[off + 2:off + 4], "big"):
                break
            if alpha2.isalpha():
                codes.add(alpha2.decode("ascii").upper())
            off += 4
        return codes or None
    except FileNotFoundError:
        return None
    except Exception as e:
        log.warning("could not read %s: %s", REGDB_FILE, e)
        return None


def get_countries(hide_codes=()):
    """ISO 3166 names (from the system tzdata file) for the countries the kernel's
    regulatory database supports, sorted by name."""
    if not os.path.exists(ISO3166_SYSTEM):
        raise WifiError("Country list unavailable: {} not found (tzdata not installed?)"
                        .format(ISO3166_SYSTEM))
    out = []
    hide = {c.strip().upper() for c in hide_codes if c.strip()}
    supported = _regdb_countries()
    with open(ISO3166_SYSTEM, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            cc, _, name = line.partition("\t")
            cc = cc.upper()
            if len(cc) != 2 or not name or cc in hide:
                continue
            if supported is not None and cc not in supported:
                continue
            out.append({"code": cc, "name": name.strip()})
    out.sort(key=lambda c: c["name"].lower())
    return out


# --------------------------------------------------------------------------
# profiles / role
# --------------------------------------------------------------------------

def _wifi_profiles():
    """NM wifi profiles for OUR interface -> {name: details}.

    Excludes non-wifi types and profiles pinned to another interface (e.g. a test
    client on wlan1) — those are not this radio's saved networks. Profiles without
    an interface-name are kept: a hand-made `nmcli device wifi connect` profile
    may lack both our WiFi_ prefix and the binding, but it still drives wlan0.
    """
    profiles = {}
    for conn in nmcli.connection():
        if conn.conn_type != "wifi":
            continue
        try:
            # by uuid: two profiles can share a name (a hotspot on ap0 plus ours on wlan0)
            details = nmcli.connection.show(conn.uuid)
        except nmcli.NotExistException:
            continue
        bound = details.get("connection.interface-name")
        if bound and bound != WIFI_IFACE:
            continue
        profiles[conn.name] = details
    return profiles


def _is_ap(details):
    return details.get("802-11-wireless.mode") == "ap"


_sae_supported = None


def sae_supported():
    """Can this adapter offer WPA3 alongside WPA2 on one access point?

    NetworkManager adds SAE to a `wpa-psk` access point only when wpa_supplicant reports SAE
    among its key_mgmt capabilities. Without it, `wpa-psk` beacons plain WPA2 no matter what
    `pmf` says — so "WPA2 + WPA3" would be a promise the hardware does not keep, and it must
    not be offered. Measured on a Raspberry Pi (brcmfmac): SAE is absent from key_mgmt (it
    appears under auth_alg, which is the driver's SAE offload, not an AKM the AP can announce).

    Cached: a capability of the adapter, it cannot change while the service runs. Unreadable
    capabilities leave the choice available rather than silently removing it.
    """
    global _sae_supported
    if _sae_supported is None:
        _sae_supported = True
        wpa_cli = shutil.which("wpa_cli")
        if wpa_cli:
            try:
                out = subprocess.run([wpa_cli, "-i", WIFI_IFACE, "get_capability", "key_mgmt"],
                                     capture_output=True, text=True, timeout=10).stdout
                if out.strip():
                    _sae_supported = "SAE" in out.split()
            except Exception as e:
                log.warning("could not read supplicant key_mgmt capabilities: %s", e)
    return _sae_supported


def ap_security_kinds():
    """Security choices the AP form may offer on this adapter, default first.

    Without SAE the "WPA2 + WPA3" choice is dropped (it would be indistinguishable from plain
    WPA2 on the air) and WPA2 leads instead: on such an adapter WPA3-only would turn away every
    client that does not speak SAE, which is the opposite of a sensible default.
    """
    if sae_supported():
        return ["mixed", "wpa3", "wpa2", "open"]
    return ["wpa2", "wpa3", "open"]


def default_ap_security():
    return ap_security_kinds()[0]


def ap_iface_present():
    """Does the dedicated AP interface exist right now?"""
    return os.path.exists("/sys/class/net/" + AP_IFACE)


def ensure_ap_iface():
    """Make AP_IFACE exist and be usable by NetworkManager; raise WifiError if impossible.

    Three steps, all of them needed (measured):
      1. `iw dev wlan0 interface add ap0 type __ap` — the virtual AP interface. Station
         provisioning does this at every boot, so on those images step 1 is a no-op.
      2. NM sees a freshly added interface as UNMANAGED, and a profile bound to an unmanaged
         device cannot be activated — hand it over explicitly.
      3. report failure honestly: some drivers refuse a second virtual interface. We do NOT
         fall back to wlan0 — an access point there would take the radio away from the client
         connection, which is exactly what this interface exists to avoid.
    """
    if not ap_iface_present():
        if not shutil.which("iw"):
            raise WifiError("Cannot create the access-point interface: `iw` is not installed")
        try:
            _iw("dev", WIFI_IFACE, "interface", "add", AP_IFACE, "type", "__ap")
        except Exception as e:
            log.warning("could not add %s: %s", AP_IFACE, e)
            raise WifiError(
                "This Wi-Fi adapter does not support a separate access-point interface "
                "({}), so the access point cannot be started".format(AP_IFACE))
    # idempotent: a no-op when the interface is already managed (the python nmcli binding
    # has no wrapper for this, hence the direct call)
    try:
        subprocess.run(["nmcli", "device", "set", AP_IFACE, "managed", "yes"],
                       timeout=15, check=False, capture_output=True)
    except Exception as e:
        log.warning("could not hand %s to NetworkManager: %s", AP_IFACE, e)
    # NM needs a moment to pick the interface up, and activating too early fails with a
    # misleading "no suitable device found ... device wlan0 ... mismatching interface name":
    # with ap0 still unmanaged/unavailable NM looks at the other radio and refuses. Wait for
    # the device to become usable instead of racing it.
    for _ in range(30):
        try:
            state = next((d.state for d in nmcli.device.status() if d.device == AP_IFACE), "")
        except Exception:
            state = ""
        if state and state not in ("unmanaged", "unavailable"):
            break
        time.sleep(0.5)
    else:
        log.warning("%s did not become usable in time", AP_IFACE)
    return AP_IFACE


def get_role(profiles=None):
    """'ap' when the AP profile has autoconnect=yes, else 'client'.

    Resolved through _ap_ref() rather than the caller's profile map: the access point lives on
    AP_IFACE, and _wifi_profiles() deliberately drops profiles bound to an interface other than
    wlan0, so looking it up there would always report 'client'. The `profiles` argument is still
    honoured for the pre-move case (a profile on wlan0 or unbound) and to save a query.
    """
    ap = (profiles or {}).get(AP_PROFILE)
    if ap is None:
        ref = _ap_ref()
        if ref:
            try:
                ap = nmcli.connection.show(ref)
            except Exception:
                ap = None
    if ap and ap.get("connection.autoconnect") == "yes":
        return "ap"
    return "client"


def _ap_ref():
    """uuid of the station's access-point profile, or None when there is none yet.

    Several connections can share the name "Hotspot" — nmcli then refuses to guess ("There is
    another connection with the name 'Hotspot'. Reference the connection by its uuid") — so
    every call addresses it by uuid. Preference order:
      1. bound to AP_IFACE: the access point of this station, whoever created it (ours, or the
         one station provisioning puts on ap0). Managing that single profile is what keeps the
         form showing what is really on the air instead of a second, invisible hotspot.
      2. not bound to any interface.
      3. bound to WIFI_IFACE: a profile from before the access point moved off wlan0; picked up
         so its settings are not lost, and rebound to AP_IFACE on the next save.
    """
    unbound = legacy = None
    try:
        for conn in nmcli.connection():
            if conn.conn_type != "wifi" or conn.name != AP_PROFILE:
                continue
            try:
                d = nmcli.connection.show(conn.uuid)
            except Exception:
                continue
            bound = d.get("connection.interface-name") or ""
            if bound == AP_IFACE:
                return conn.uuid
            if not bound and unbound is None:
                unbound = conn.uuid
            elif bound == WIFI_IFACE and legacy is None:
                legacy = conn.uuid
        unbound = unbound or legacy
    except Exception as e:
        log.warning("could not resolve the AP profile: %s", e)
    return unbound


def _ap_active():
    ref = _ap_ref()
    if not ref:
        return False
    try:
        details = nmcli.connection.show(ref)
    except nmcli.NotExistException:
        return False
    return details.get("GENERAL.STATE") == "activated"


def _radio_ensure_on():
    """(usable, just_powered): raise a radio that went down on its own, leave an operator's
    OFF alone.

    A radio can be down without anyone asking for it: NM persists the radio state across
    reboots (WirelessEnabled=false in its state file brings a station up with the radio off),
    and rfkill can flip during early boot. Those are repaired here. The dialog's own toggle
    is different — that OFF was a person's choice, recorded by set_radio(), and undoing it
    on every list refresh would make the toggle useless.

    just_powered tells the caller the scan cache is empty (nothing could scan while the
    radio was down) — a plain cached list right after power-on would wrongly read as
    "no networks found"."""
    if nmcli.radio.wifi():
        return True, False
    if _load_ap_prefs().get("radio_off"):
        return False, False
    nmcli.radio.wifi_on()
    return True, True


def radio_wifi_on():
    """Bring the radio back if it went down on its own (see _radio_ensure_on) — called when
    the popup opens. An OFF chosen via the dialog's toggle is respected."""
    _radio_ensure_on()


def set_radio(on):
    """The dialog's radio toggle. The choice is recorded where both web processes see it, so
    an explicit OFF is not undone by the automatic raise on the next popup open or list
    refresh — only the operator (or a join request) turns the radio back on."""
    log.info("wifi: radio %s requested", "on" if on else "off")
    prefs = _load_ap_prefs()
    if bool(prefs.get("radio_off")) != (not on):
        _save_ap_prefs(dict(prefs, radio_off=not on))
    if on:
        nmcli.radio.wifi_on()
    else:
        nmcli.radio.wifi_off()


def occupied_subnets():
    """Statically pinned ethernet subnets from NM: eth0, Septentrio, 4G modem."""
    nets = []
    for conn in nmcli.connection():
        if conn.conn_type != "ethernet":
            continue
        try:
            details = nmcli.connection.show(conn.name)
        except nmcli.NotExistException:
            continue
        addr = _first_key(details, "IP4.ADDRESS") or details.get("ipv4.addresses")
        if addr:
            # the device, not just the profile name: "Wired connection 2" says nothing about
            # WHERE the subnet is, while "septentrio" or "eth0" names it at a glance
            dev = (conn.device if conn.device not in ("", "--") else
                   details.get("connection.interface-name") or "")
            for part in addr.split(","):
                part = part.strip()
                if "/" in part:
                    nets.append({"net": part, "conn": conn.name, "dev": dev})
    # Also take the LIVE addresses of ethernet devices: an unmanaged NIC (no NM connection —
    # e.g. the bench's enp0s3, or anything configured outside NM) still occupies its subnet,
    # and `nmcli device show` reports IP4.ADDRESS even for unmanaged devices.
    seen = {n["net"] for n in nets}
    try:
        for dev in nmcli.device.status():
            if dev.device_type != "ethernet":
                continue
            try:
                det = nmcli.device.show(dev.device)
            except Exception:
                continue
            addr = _first_key(det, "IP4.ADDRESS")
            if addr and "/" in addr and addr not in seen:
                nets.append({"net": addr, "conn": dev.device, "dev": dev.device})
                seen.add(addr)
    except Exception as e:
        log.warning("device subnet scan failed: %s", e)
    return nets


def local_ip_addresses():
    """IPv4 addresses currently assigned to this device's interfaces (except the WiFi
    client iface itself and loopback) — a static client IP must not duplicate any of them."""
    ips = []
    try:
        for dev in nmcli.device.status():
            if dev.device in (WIFI_IFACE, "lo") or dev.device_type == "loopback":
                continue
            try:
                det = nmcli.device.show(dev.device)
            except Exception:
                continue
            for k, v in det.items():
                if k.startswith("IP4.ADDRESS") and v and "/" in v:
                    ips.append({"ip": v.split("/")[0].strip(), "iface": dev.device})
    except Exception as e:
        log.warning("local ip scan failed: %s", e)
    return ips


def live_ipv4_networks(exclude=(AP_IFACE,)):
    """Subnets this station's interfaces really hold right now, read from `ip -j addr`.

    occupied_subnets() covers ethernet profiles, which is what the form needs to validate
    against. This one is wider on purpose: it also sees the subnet handed out by the Wi-Fi
    network the station has joined, which is invisible to NM's profile view and is exactly
    where the access point can end up standing on its own feet.
    """
    nets = []
    try:
        data = json.loads(subprocess.check_output(["ip", "-j", "addr"], text=True,
                                                  timeout=10))
    except Exception as e:
        log.warning("could not read live addresses: %s", e)
        return nets
    for it in data:
        name = it.get("ifname")
        if not name or name == "lo" or name in tuple(exclude):
            continue
        for a in it.get("addr_info", []):
            if a.get("family") != "inet" or not a.get("local"):
                continue
            try:
                iface = ipaddress.IPv4Interface("{}/{}".format(a["local"],
                                                               a.get("prefixlen", 32)))
            except ValueError:
                continue
            nets.append({"net": str(iface.network), "conn": name})
    return nets


def _ap_subnet_candidates(net, prefix):
    """Blocks to offer the access point: the next ones of its own size, then the other private
    ranges. Stepping alone is not enough — a /16 choice has nowhere to step to inside
    192.168/16, the very next block is already outside private space."""
    base, size = int(net.network_address), net.num_addresses
    for step in range(1, 33):
        try:
            yield ipaddress.IPv4Network((base + step * size, prefix))
        except (ValueError, ipaddress.AddressValueError):
            break
    for other in ("10.42.0.0", "172.31.0.0"):
        try:
            yield ipaddress.IPv4Network("{}/{}".format(other, prefix), strict=False)
        except ValueError:
            continue


def ap_addr_effective(ip, prefix, taken=None):
    """Where the access point should really stand: (ip, prefix, what_forced_the_move).

    Every station ships the same hotspot subnet, so a station that joins another station's
    hotspot is handed an address out of the block its own point already owns — the radio link
    is fine and routing is not. A customer LAN numbered the same way collides identically.
    The point moves one block at a time until it is clear, keeping the operator's host
    position (…50.1 -> …51.1). Silent by design: the operator's address stays the preference
    and comes back when the conflict does not, and the status shows where the point actually
    is, so nothing has to be guessed.
    """
    try:
        want = ipaddress.IPv4Interface("{}/{}".format(str(ip).strip(), int(prefix)))
    except (ValueError, AttributeError, TypeError):
        return ip, prefix, None
    if taken is None:
        taken = live_ipv4_networks() + occupied_subnets()

    def clash(net):
        for item in taken:
            try:
                other = ipaddress.IPv4Network(item["net"], strict=False)
            except (ValueError, KeyError, TypeError):
                continue
            if net.overlaps(other):
                return item
        return None

    first = clash(want.network)
    if not first:
        return str(want.ip), int(prefix), None
    host_off = int(want.ip) - int(want.network.network_address)
    for cand in _ap_subnet_candidates(want.network, int(prefix)):
        if not cand.is_private or cand.is_link_local or clash(cand):
            continue
        return str(ipaddress.IPv4Address(int(cand.network_address) + host_off)), int(prefix), first
    log.warning("no free subnet for the access point near %s/%s", ip, prefix)
    return str(want.ip), int(prefix), None


def _ap_channel_preferred(live_band, live_chan, prefs=None):
    """(band, channel, moved_to) for the form — the same rule as the address.

    While a client link is up the point does not stand on the channel the operator picked but
    on the one the network uses, because the radio has only one. The form keeps showing the
    choice; `moved_to` says where the point actually is. And as with the address, a remembered
    choice only counts while the profile still holds the channel we put there.
    """
    prefs = _load_ap_prefs() if prefs is None else prefs
    want_band, want_chan = prefs.get("band"), prefs.get("channel")
    if not want_band or want_chan is None:
        return live_band, live_chan, ""
    if (prefs.get("band_written"), prefs.get("channel_written")) != (live_band, live_chan):
        return live_band, live_chan, ""
    if (want_band, want_chan) == (live_band, live_chan):
        return live_band, live_chan, ""
    return want_band, int(want_chan), "{} GHz ch{}".format(live_band, live_chan)


def _ap_addr_preferred(live_ip, live_prefix, prefs=None):
    """(ip, prefix, moved_to) for the form: the operator's address, and where the point is.

    The preference only wins when the profile still holds the very address we shifted it to.
    Anything else in the profile — provisioning, an import, a hand edit — is the operator's
    current intent by definition, and a stale preference must not shadow it.
    """
    prefs = _load_ap_prefs() if prefs is None else prefs
    want, want_pfx = prefs.get("ip"), prefs.get("prefix")
    if not want or not want_pfx:
        return live_ip, live_prefix, ""
    try:
        written = (str(prefs.get("ip_written")), int(prefs.get("prefix_written") or 0))
    except (TypeError, ValueError):
        return live_ip, live_prefix, ""
    if written != (live_ip, live_prefix):
        return live_ip, live_prefix, ""
    if (want, int(want_pfx)) == (live_ip, live_prefix):
        return live_ip, live_prefix, ""
    return want, int(want_pfx), "{}/{}".format(live_ip, live_prefix)


# --------------------------------------------------------------------------
# validation — pure functions
# --------------------------------------------------------------------------

def validate_ip_config(ip, prefix, gateway=None, dns=None, occupied=None, local_ips=None):
    """Returns None when valid, else a human-readable error string."""
    try:
        prefix = int(prefix)
        if not 8 <= prefix <= 30:
            return "Subnet prefix must be between /8 and /30"
        iface = ipaddress.IPv4Interface("{}/{}".format(ip.strip(), prefix))
    except (ValueError, AttributeError):
        return "Invalid IPv4 address"
    net = iface.network
    if iface.ip == net.network_address:
        return "Address is the network address for this mask"
    if iface.ip == net.broadcast_address:
        return "Address is the broadcast address for this mask"
    # exact-address clash with another interface of THIS device (e.g. picking the AP/gateway
    # address of a local radio). Subnet overlap with the target WiFi network is fine — a
    # static client address MUST be inside it — but a duplicate address never is.
    for item in local_ips or []:
        if str(iface.ip) == item.get("ip"):
            return "Address {} is already used by this device ({})".format(item["ip"], item.get("iface", "?"))
    if gateway:
        try:
            gw = ipaddress.IPv4Address(gateway.strip())
        except ValueError:
            return "Invalid gateway address"
        if gw not in net:
            return "Gateway is not inside the selected subnet"
        if gw == iface.ip:
            return "Address must differ from the gateway"
    for server in (dns or "").split(","):
        server = server.strip()
        if server:
            try:
                ipaddress.IPv4Address(server)
            except ValueError:
                return "Invalid DNS server address: {}".format(server)
    for item in occupied or []:
        try:
            other = ipaddress.IPv4Network(item["net"], strict=False)
        except ValueError:
            continue
        if net.overlaps(other):
            return "Subnet overlaps {} ({})".format(
                item["net"], item.get("dev") or item["conn"])
    return None


def validate_dns_list(dns):
    """DNS override with DHCP: only the server list needs checking. None when valid."""
    for server in (dns or "").split(","):
        server = server.strip()
        if server:
            try:
                ipaddress.IPv4Address(server)
            except ValueError:
                return "Invalid DNS server address: {}".format(server)
    return None


# --------------------------------------------------------------------------
# network list
# --------------------------------------------------------------------------

def list_networks(rescan=False):
    """Grouped network list + gating info for the popup.

    rescan=True forces a fresh scan and blocks until it finishes (nmcli
    `device wifi list --rescan yes`). Needed right after the radio is powered on
    and for the manual Rescan button, where the cached scan is empty/stale and a
    plain list would wrongly render "No networks found".
    """
    country = get_country()
    chans = allowed_channels()
    profiles = _wifi_profiles()
    role = get_role(profiles)
    ap_live = _ap_active()
    # read once: the radio's answer decides which row is really connected (see sta_link)
    link = sta_link()
    link_stale = False
    ap_settling = time.time() - _last_ap_action < _AP_ACTION_QUIET_S
    outdoor = outdoor_station()
    # Two profiles for one network are normal here — one pinned to a BSSID, one not (their
    # provisioning makes the plain one, our BSSID pinning the other). Only the profile
    # NetworkManager actually has up may read as connected: the radio's own answer matches BOTH
    # of them by SSID or BSSID, and promoting on that alone showed one network as connected
    # twice.
    nm_has_active = any(d.get("GENERAL.STATE") == "activated" for _, d in profiles.items())

    scan = []
    usable, just_powered = _radio_ensure_on()
    if usable:
        # A running access point no longer blocks scanning. It used to: the point lived on
        # the client interface itself, so a forced --rescan had nothing to scan with. Now it
        # runs on its own AP interface and the client interface can still leave the channel
        # for a moment — measured on the station, a forced rescan takes ~4 s, returns the full
        # list including other bands, and the beacon does not even blink.
        #
        # The scan is pinned to the client interface. Without ifname nmcli merges the scan
        # caches of EVERY wifi device — with the client interface down, the list could be fed
        # entirely by the AP interface's cache: networks that look joinable while no join can
        # possibly work. A radio that was just powered on has an empty cache for the same
        # reason nothing could scan — force a fresh scan then, whatever the caller asked.
        do_rescan = rescan or just_powered
        try:
            scan = (nmcli.device.wifi(ifname=WIFI_IFACE, rescan=True) if do_rescan
                    else nmcli.device.wifi(ifname=WIFI_IFACE))
        except Exception as e:
            # NM refuses a rescan too soon after the previous one; fall back to
            # the cached list rather than showing nothing.
            log.warning("wifi scan failed (rescan=%s): %s", do_rescan, e)
            if do_rescan:
                try:
                    scan = nmcli.device.wifi(ifname=WIFI_IFACE)
                except Exception as e2:
                    log.warning("wifi cached scan failed: %s", e2)

    # our own AP's beacons (live or lingering in the scan cache after it was turned off)
    # are matched by BSSID — the SSID alone could hide a neighbour broadcasting the same name
    my_mac = None
    try:
        my_mac = (nmcli.device.show(WIFI_IFACE).get("GENERAL.HWADDR") or "").upper() or None
    except Exception:
        pass
    if my_mac and ap_live:
        _own_ap_bssids.add(my_mac)   # this is the BSSID our hotspot beacons with right now
    # Any AP-mode interface of this host is us, not a network to join: a hotspot may run on
    # a virtual AP interface of the same radio (ap0) whose MAC differs from wlan0's. Remember
    # them too, so the entries stay filtered while they age out of the scan cache.
    _own_ap_bssids.update(_ap_iface_macs())

    # One row per BSSID (access point), not per SSID: this is a stationary base station,
    # so the user picks the exact AP — a dual-band AP shows as two rows (2.4 and 5 GHz),
    # several APs sharing one SSID (roaming setup) each show separately. Skip hidden
    # (empty ssid) entries.
    by_bssid = {}
    for n in scan:
        if not n.ssid or n.ssid == "--":
            continue
        # Our own hotspot is not a joinable network: skip its beacon by BSSID (current MAC
        # or any address it has beaconed with — see _own_ap_bssids), and as a fallback the
        # IN-USE entry nmcli shows while the hotspot is up.
        bssid = (n.bssid or "").upper()
        if bssid and (bssid == my_mac or bssid in _own_ap_bssids):
            continue
        # nmcli marks our own hotspot IN-USE while it runs, and that row is not a network to
        # join. It is only ours when the radio has no client link on that BSS: with the point
        # and a client up together (they share one channel), the IN-USE row IS the connection
        # and dropping it would hide the network the station is actually on.
        if ap_live and n.in_use and not (link and (link.get("bssid") or "").upper() == bssid):
            continue
        by_bssid[bssid or n.ssid] = n
    changed = False
    for key, n in by_bssid.items():
        val = (n.chan, n.freq)
        if _seen_channels.get(key) != val:
            _seen_channels[key] = val
            changed = True
    if changed:
        _save_seen_channels()

    # client profiles (skip AP profile); drop stale one-time profiles. New profiles are
    # pinned to an exact BSSID and matched to the scan by it; profiles saved before BSSID
    # pinning (and hidden networks) carry only an SSID — those still match by SSID.
    profs_by_bssid, profs_by_ssid = {}, {}
    for name, details in profiles.items():
        if _is_ap(details):
            continue
        if name.endswith(ONETIME_SUFFIX) and details.get("GENERAL.STATE") != "activated":
            try:
                nmcli.connection.delete(name)
            except Exception:
                pass
            continue
        p_bssid = (details.get("802-11-wireless.bssid") or "").upper()
        if p_bssid:
            profs_by_bssid[p_bssid] = (name, details)
        else:
            ssid = details.get("802-11-wireless.ssid") or name
            profs_by_ssid[ssid] = (name, details)

    def entry(ssid, scan_item, prof):
        nonlocal link_stale
        name, details = prof if prof else (None, {})
        bssid = ((scan_item.bssid if scan_item else None)
                 or details.get("802-11-wireless.bssid") or "").upper()
        chan = scan_item.chan if scan_item else None
        freq = scan_item.freq if scan_item else None
        if chan is None and (bssid or ssid) in _seen_channels:
            chan, freq = _seen_channels[bssid or ssid]
        band = freq_to_band(freq) if freq else None
        kind, label = parse_security(scan_item.security if scan_item else None)
        if not scan_item and details:
            km = details.get("802-11-wireless-security.key-mgmt")
            kind = {"sae": "wpa3", "wpa-psk": "wpa2", "none": "wep", None: "open"}.get(km, "wpa2")
            label = {"wpa3": "WPA3", "wpa2": "WPA2", "wep": "WEP", "open": "open"}[kind]
        usable = channel_usable(band, chan, chans, country) if chan and band else "ok"
        # Справочные пометки, не запреты: клиенту DFS-канал законен, а indoor-only —
        # ограничение для того, кто вещает. Оператору всё равно стоит видеть, почему точка
        # доступа на этом канале работать не сможет.
        chan_entry = next((e for e in chans.get(band, []) if e["ch"] == chan), None) if chan else None
        row_dfs = bool(chan_entry and chan_entry.get("dfs"))
        row_indoor_only = bool(chan_entry and chan_entry.get("no_outdoor") and outdoor)
        e = {
            "ssid": ssid,
            "bssid": bssid or None,
            "signal": scan_item.signal if scan_item else None,
            "security": kind, "security_label": label,
            "band": band, "chan": chan, "freq": freq,
            "saved": bool(name) and not (name or "").endswith(ONETIME_SUFFIX),
            # profiles created via "Add hidden network" carry hidden=yes and no BSSID pin —
            # marked in the list so a duplicate next to a pinned profile of the same SSID
            # is tellable apart (and the right one can be forgotten)
            "hidden_profile": details.get("802-11-wireless.hidden") == "yes" if details else False,
            "profile": name,
            "autoconnect": details.get("connection.autoconnect") == "yes" if details else None,
            "in_use": bool(scan_item and scan_item.in_use),
            "usable": usable,
            "dfs": row_dfs,
            "indoor_only": row_indoor_only,
            "onetime": bool(name) and (name or "").endswith(ONETIME_SUFFIX),
        }
        if details:
            # current IP configuration of the saved profile, so the "IP settings"
            # dialog can pre-fill what is actually stored (not always reset to DHCP)
            addr = (details.get("ipv4.addresses") or "").split(",")[0].strip()
            ip4, _, pfx = addr.partition("/")
            e["ipconf"] = {
                "method": "manual" if details.get("ipv4.method") == "manual" else "auto",
                "ip": ip4,
                "prefix": int(pfx) if pfx.isdigit() else 24,
                "gateway": details.get("ipv4.gateway") or "",
                "dns": details.get("ipv4.dns") or "",
            }
        if details.get("GENERAL.STATE") == "activated":
            e["in_use"] = True
            addr = _first_key(details, "IP4.ADDRESS")
            e["ip"] = addr
        verdict = _link_says_in_use(e, link)
        if verdict is False and e["in_use"]:
            # NM still points at this network, the radio has already left it — usually the
            # access point taking the channel. The stored address goes too: it is no longer
            # reachable and would read as a working connection.
            link_stale = link_stale or not ap_settling
            e.pop("ip", None)
            e["in_use"] = False
        elif verdict is True and not e["in_use"] and not nm_has_active:
            # the radio is on a network no profile claims (activated outside NM's bookkeeping)
            e["in_use"] = True
        return e

    connected, saved, available = [], [], []
    for key, n in sorted(by_bssid.items(), key=lambda kv: -(kv[1].signal or 0)):
        prof = profs_by_bssid.pop((n.bssid or "").upper(), None)
        if prof is None:
            # legacy profile without a BSSID pin: attach it to the strongest BSS of the
            # SSID (list is signal-sorted, pop makes it match only once)
            prof = profs_by_ssid.pop(n.ssid, None)
        e = entry(n.ssid, n, prof)
        if e["in_use"]:
            connected.append(e)
        elif e["saved"]:
            saved.append(e)
        else:
            # Networks on channels DISABLED in the selected country are not scannable, but
            # entries linger in the scan cache right after a region change. Show them
            # greyed out with the "Unavailable in <CC>" badge instead of silently hiding —
            # a network vanishing with no trace right after picking a country reads as a
            # bug. They drop off naturally as the cache ages out.
            available.append(e)
    # saved but not in scan (the pinned AP is out of range/off — strict BSSID matching
    # deliberately does NOT fall back to a same-SSID sibling)
    for name, details in list(profs_by_bssid.values()) + list(profs_by_ssid.values()):
        ssid = details.get("802-11-wireless.ssid") or name
        e = entry(ssid, None, (name, details))
        if e["in_use"]:
            connected.append(e)
        else:
            saved.append(e)
    # One link is one row. Two profiles for the same network are normal here — theirs without
    # a BSSID, ours pinned to one — and both used to surface: as two "connected" rows (nmcli
    # marks the BSS in use, and the radio's answer matches both), or as the same network sitting
    # in Connected and in Saved at once, which is what the operator objected to.
    # The row that stays is the one NetworkManager actually has up; a second profile of that
    # very access point is not shown at all, and comes back in Saved once disconnected. A
    # genuinely different access point of the same SSID keeps its own row.
    link_bssid = ((link or {}).get("bssid") or "").upper()
    if len(connected) > 1:
        active = {n for n, d in profiles.items() if d.get("GENERAL.STATE") == "activated"}
        keep = (next((e for e in connected if e.get("profile") in active), None)
                or next((e for e in connected
                         if link_bssid and (e.get("bssid") or "").upper() == link_bssid), None)
                or connected[0])
        for e in connected:
            if e is keep:
                continue
            e["in_use"] = False
            e.pop("ip", None)
            (saved if e["saved"] else available).append(e)
        connected = [keep]
    if connected and link_bssid:
        conn = connected[0]

        def _same_access_point(e):
            bssid = (e.get("bssid") or "").upper()
            return e["ssid"] == conn["ssid"] and (not bssid or bssid == link_bssid)

        saved = [e for e in saved if not _same_access_point(e)]
        available = [e for e in available if not _same_access_point(e)]
    saved.sort(key=lambda e: e["ssid"].lower())

    return {
        "radio": nmcli.radio.wifi(),
        "country": country,
        "role": role,
        # actual runtime state, not the autoconnect-derived role: an AP can be live while
        # its role reads "client" (Hotspot activated but autoconnect!=yes, e.g. NM blocked
        # autoconnect after failures). The UI needs the real state to keep the card usable.
        "ap_active": ap_live,
        # NM claimed a connection the radio does not have — the UI says so instead of showing
        # a network as connected while nothing flows through it
        "link_stale": link_stale,
        "connected": connected, "saved": saved, "available": available,
    }


def _interfaces_fallback():
    """Interface list without NetworkManager, from `ip -j addr` (kernel state).

    Mirrors network_infos.get_interfaces_infos() shape and filtering: loopback and
    link-local IPv6 are dropped, only interfaces holding an address are listed (plus
    the Wi-Fi interface, kept even bare). conn_name is absent — it's an NM concept.
    """
    try:
        data = json.loads(subprocess.check_output(["ip", "-j", "addr"], text=True,
                                                  timeout=10))
    except Exception as e:
        log.warning("ip -j addr fallback failed: %s", e)
        return None
    ifaces = []
    for it in data:
        name = it.get("ifname")
        if not name or name == "lo":
            continue
        v4 = [a.get("local") for a in it.get("addr_info", []) if a.get("family") == "inet"]
        v6 = [a.get("local") for a in it.get("addr_info", [])
              if a.get("family") == "inet6" and not (a.get("local") or "").startswith("fe80")]
        if not v4 and not v6 and name != WIFI_IFACE:
            continue
        entry = {"device": name, "ipv4": v4 or None, "ipv6": v6 or None}
        if it.get("address"):
            entry["hwaddr"] = it["address"].upper()
        ifaces.append(entry)
    return ifaces or None


def _augment_wifi_iface(interfaces):
    """Always surface the Wi-Fi interfaces in the popup header, even with no IP.

    network_infos.get_interfaces_infos() only lists interfaces that have an IP, so a
    disconnected wlan0 never appears. Users expect to see the Wi-Fi adapter (with its MAC)
    regardless. The access-point interface is missing for a different reason — that helper skips
    it even when it holds an address — and it is the one the operator is usually connected
    THROUGH, so its address is the most useful line in the table.
    """
    ifaces = list(interfaces or [])
    for dev in (WIFI_IFACE, AP_IFACE):
        if any(i.get("device") == dev for i in ifaces):
            continue
        try:
            det = nmcli.device.show(dev)
        except Exception:
            continue          # no such interface (ap0 exists only while a point is set up)
        hw = det.get("GENERAL.HWADDR")
        addr = _first_key(det, "IP4.ADDRESS")
        if dev == AP_IFACE and not (hw or addr):
            continue
        entry = {"device": dev, "ipv4": [addr.split("/")[0]] if addr else None, "ipv6": None}
        if hw and hw != "(unknown)":
            entry["hwaddr"] = hw
        ifaces.append(entry)
    return ifaces


def get_status(hide_country_codes=()):
    """Header/status payload for the popup."""
    cap = capability()
    status = {"capability": cap}
    if not cap["nm"]:
        # No NetworkManager (Debian 11 with NM stopped/absent): the interface table can
        # still be served — addresses and MACs come straight from the kernel. Only the
        # connection name is an NM concept and stays empty.
        status["interfaces"] = _interfaces_fallback()
        return status
    global _last_interfaces
    try:
        import network_infos
        _last_interfaces = network_infos.get_interfaces_infos()
    except Exception as e:
        # keep the last good list rather than blanking the header on a transient failure
        log.warning("network_infos failed (keeping last known): %s", e)
    # link-local (fe80::) intentionally NOT added: the interface list mirrors the client's
    # original Network Infos logic (network_infos.get_interfaces_infos strips link-local)
    status["interfaces"] = _augment_wifi_iface(_last_interfaces)
    # a station without any WiFi adapter renders an empty dialog otherwise — let the UI
    # say so explicitly (seen on x86/DIY installs; the Pi always has wlan0)
    try:
        status["wifi_present"] = any(d.device == WIFI_IFACE for d in nmcli.device.status())
    except Exception:
        status["wifi_present"] = True   # can't tell — don't alarm
    chans = allowed_channels()      # one pass: it shells out to iw and parses the config
    status.update({
        "radio": nmcli.radio.wifi(),
        "country": get_country(),
        "channels": chans,
        "bands": available_bands(),
        "ap_security_kinds": ap_security_kinds(),
        "outdoor": outdoor_station(),
        # region leaves an outdoor station nothing to beacon on at all — the per-band note
        # reads as "not in this band" and hides that there is no other band either
        "outdoor_nowhere": outdoor_nowhere(chans),
        "role": get_role(),
        "ap_active": _ap_active(),
        "occupied": occupied_subnets(),
    })
    return status


# --------------------------------------------------------------------------
# connect / disconnect / forget
# --------------------------------------------------------------------------

def _ipv4_options(ipconf):
    """ipconf: None|{method, ip, prefix, gateway, dns} -> nmcli option dict.

    DHCP with a manual DNS is a supported combination (the DHCP-provided DNS is not
    always usable): dns set with method=auto maps to ipv4.ignore-auto-dns=yes."""
    dns = ",".join(s.strip() for s in ((ipconf or {}).get("dns") or "").split(",") if s.strip())
    if not ipconf or ipconf.get("method") != "manual":
        return {"ipv4.method": "auto", "ipv4.addresses": "", "ipv4.gateway": "",
                "ipv4.dns": dns, "ipv4.ignore-auto-dns": "yes" if dns else "no"}
    opts = {"ipv4.method": "manual",
            "ipv4.addresses": "{}/{}".format(ipconf["ip"].strip(), int(ipconf["prefix"]))}
    opts["ipv4.gateway"] = (ipconf.get("gateway") or "").strip()
    opts["ipv4.dns"] = dns
    return opts


def _ap_yield_reason(prefs):
    """Why the point is switched on but not running, when nothing else explains it.

    The in-process reason is the good one; after a service restart it is gone, and the bare
    state is ambiguous — "wanted, not running, no recorded error" also happens when a
    boot-time start failed in a previous process life (no ap0 after a reboot, a channel gone
    illegal with a region change). Blaming the client's channel is only honest while a client
    link actually exists; with nothing associated the card stays silent rather than sending
    the diagnosis the wrong way.
    """
    if _ap_yielded:
        return _ap_yielded
    if not prefs.get("wanted") or _ap_active() or _last_ap_error:
        return ""
    return ("the connected network uses a channel the access point cannot use"
            if sta_link() else "")


def _ap_snapshot_for_safe_apply():
    """Settings of a running access point, so a failed connection can bring it back."""
    try:
        cfg = get_ap_config()
    except Exception as e:
        log.warning("could not read the AP config before connecting: %s", e)
        return None
    return cfg if cfg.get("configured") else None


def _restore_ap_after_failure(snap, notify):
    """Put the access point back after a connection attempt failed.

    The operator reaches the station THROUGH the hotspot, so switching to a client network
    is a one-way door — if the network turns out to be wrong, the station is gone.
    Restoring it here keeps the way in.
    """
    if not snap:
        return
    try:
        notify("restoring-hotspot", None)
        set_ap(dict(snap, enabled=True, password=""), intent=False)
        log.warning("connection failed — the access point was restored")
    except Exception as e:
        log.warning("could not restore the access point: %s", e)


def _lower_ap_for_connect(snap, notify):
    """Take the access point down so the radio is free for the client connection."""
    if not snap:
        return
    notify("stopping-hotspot", None)
    set_ap(dict(snap, enabled=False, password=""), intent=False)


def _target_channel(ssid, bssid=None):
    """(band, channel) of the network about to be joined, from the scan or the last sighting."""
    # a profile with no pin reads back as "--" from nmcli; treated as "no BSSID", otherwise the
    # lookup matches nothing and the point is taken down instead of following
    bssid = (bssid or "").strip().upper()
    bssid = bssid if bssid not in ("", "--") else None
    try:
        scan = nmcli.device.wifi(ifname=WIFI_IFACE)
    except Exception as e:
        log.warning("could not read the scan for the target channel: %s", e)
        scan = []
    for n in scan:
        if ((n.bssid or "").upper() == bssid) if bssid else (n.ssid == ssid):
            band = freq_to_band(n.freq)
            if n.chan and band:
                return band, int(n.chan)
    seen = _seen_channels.get(bssid) or _seen_channels.get(ssid)
    if seen:
        chan, freq = seen
        band = freq_to_band(freq)
        if chan and band:
            return band, int(chan)
    # a hidden network is in no scan by definition, and without its channel the point has to be
    # taken down for the attempt — ask the network itself instead
    hit = probe_hidden(ssid)
    if hit and hit.get("band") and hit.get("chan"):
        log.info("hidden network '%s' answered a directed probe: %s GHz ch%s",
                 ssid, hit["band"], hit["chan"])
        return hit["band"], hit["chan"]
    return None, None


def _ap_follow_channel(band, chan):
    """Move the access point to `chan` and raise it there. True when it is up on that channel.

    Deliberately not set_ap(): that switches roles — it clears autoconnect on the client
    networks so the radio stays with the point — and following a client must not do that. Only
    the channel changes here; who autoconnects stays as the operator left it.
    """
    ref = _ap_ref()
    if not ref:
        return False
    nm_band = {"2.4": "bg", "5": "a"}.get(band)
    if not nm_band:
        return False
    try:
        details = nmcli.connection.show(ref)
    except Exception as e:
        log.warning("could not read the AP profile before following: %s", e)
        return False
    was_band = {"bg": "2.4", "a": "5"}.get(details.get("802-11-wireless.band"), "all")
    was_chan = details.get("802-11-wireless.channel")
    was_chan = int(was_chan) if (was_chan or "").isdigit() else 0
    prefs = _load_ap_prefs()
    # the operator's channel is whatever stands in the profile now, unless the profile is
    # already holding a channel we put there ourselves for an earlier client link
    keep_band, keep_chan, _ = _ap_channel_preferred(was_band, was_chan, prefs)
    try:
        nmcli.connection.modify(ref, {"802-11-wireless.band": nm_band,
                                      "802-11-wireless.channel": str(chan)})
        ensure_ap_iface()
        nmcli.connection.up(ref, wait=30)
    except Exception as e:
        log.warning("could not move the access point to ch%s: %s", chan, _err_detail(e))
        return False
    global _last_ap_action
    _last_ap_action = time.time()
    _save_ap_prefs(dict(prefs, band=keep_band, channel=keep_chan,
                        band_written=band, channel_written=int(chan)))
    log.info("access point follows the client to %s GHz ch%s (operator's choice: %s ch%s)",
             band, chan, keep_band, keep_chan)
    return True


def ap_return_to_preferred():
    """Put a following access point back on the channel the operator chose.

    Called when the client link is gone: nothing owns the channel any more, so the borrowed
    one has no reason to stay. Silent no-op when the point is not standing on a channel we
    borrowed for it, or when it is not running at all.
    """
    prefs = _load_ap_prefs()
    band, chan = prefs.get("band"), prefs.get("channel")
    if not prefs.get("band_written") or band is None or chan is None:
        return False
    # only take back a channel that is still the one we borrowed: an operator who set the
    # channel by hand meanwhile (nmcli, an import) means it, and our remembered preference is
    # not an excuse to move the point off it
    live_band, live_chan = _ap_live_channel()
    if (live_band, live_chan) != (prefs.get("band_written"), prefs.get("channel_written")):
        log.info("access point is on %s ch%s, not on the channel we borrowed (%s ch%s) — "
                 "leaving it alone", live_band, live_chan, prefs.get("band_written"),
                 prefs.get("channel_written"))
        _save_ap_prefs(_without_loan(prefs))
        return False
    if not _ap_active():
        # nothing to move; the borrowed channel is dropped so a later read does not report
        # the point as standing somewhere it is not
        _save_ap_prefs(_without_loan(prefs))
        return False
    ref = _ap_ref()
    if not ref:
        return False
    nm_band = {"2.4": "bg", "5": "a"}.get(band, "")
    try:
        nmcli.connection.modify(ref, {"802-11-wireless.band": nm_band,
                                      "802-11-wireless.channel": str(chan) if chan and nm_band
                                                                 else ""})
        nmcli.connection.up(ref, wait=30)
    except Exception as e:
        log.warning("could not put the access point back on %s ch%s: %s", band, chan,
                    _err_detail(e))
        return False
    _save_ap_prefs(_without_loan(prefs))
    log.info("access point back on the operator's channel: %s ch%s", band, chan)
    return True


def _ap_prepare_for_client(snap, ssid, bssid, notify):
    """Put the access point where the client is about to go — or take it down for the attempt.

    The radio holds one channel. A point standing on another one lets the client associate and
    then starves the handshake, and NM reports that as "Secrets were required, but not
    provided" — a wrong-password message for a right password. Raising the point AFTER the
    client is connected is no better: that drops the fresh link. So the point moves first.

    When the target channel is one the point may not use — DFS, no-IR, not enough power for
    the region — it cannot follow at all and goes down for the duration; the dialog asks the
    operator about that before we get here. Returns "followed", "lowered", or None when there
    was no point to begin with.
    """
    global _ap_yielded
    if not snap:
        return None
    band, chan = _target_channel(ssid, bssid)
    if band and chan and ap_channel_ok(band, chan) and _ap_follow_channel(band, chan):
        _ap_yielded = ""
        notify("moving-hotspot", "{} GHz ch{}".format(band, chan))
        return "followed"
    _lower_ap_for_connect(snap, notify)
    _ap_yielded = ("{} is on {} GHz channel {}, which the access point cannot use here"
                   .format(ssid, band, chan) if band and chan else
                   "the channel of {} could not be determined".format(ssid))
    return "lowered"


def _ap_start_error(message, want_band, want_chan):
    """The start error, with what the radio actually did appended when the two disagree.

    NetworkManager reports a failed hotspot start as "802.1X supplicant took too long to
    authenticate" — a message about authentication for what is really a channel problem: the
    radio has one channel, a client link owns it, and the beacon lands there instead of where
    it was asked to. Left alone, the operator reads it as a password fault and looks in the
    wrong place, so what actually happened is spelled out next to it.
    """
    air_band, air_chan = ap_air_channel()
    if not air_chan:
        # nothing on the air to compare with: either the client link owns the radio, or the
        # adapter refused the channel outright (some firmware does that on channels every
        # regulatory table allows — see unavailable_channels). Both read as a supplicant
        # timeout, and both leave the operator guessing.
        link = sta_link()
        if link:
            band, chan = freq_to_band(link.get("freq")), freq_to_chan(link.get("freq"))
            if band and chan:
                return ("{} — the client connection on {} GHz channel {} holds the radio, and "
                        "the adapter has only one channel".format(message, band, chan))
        if want_chan:
            return ("{} — the adapter did not accept {} GHz channel {}. Some adapters refuse a "
                    "channel their regulatory tables allow; such channels can be listed in "
                    "wifi_manager.conf so they are no longer offered"
                    .format(message, want_band, want_chan))
        return message
    if want_chan and (want_band, want_chan) != (air_band, air_chan):
        return ("{} — the access point is on {} GHz channel {}, not the requested {} GHz "
                "channel {}: the adapter has a single channel and something else is using it"
                .format(message, air_band, air_chan, want_band, want_chan))
    return ("{} — the access point is on {} GHz channel {} despite this"
            .format(message, air_band, air_chan))


def _wep_key_options(password):
    """WEP key options for a profile: the key itself plus how NetworkManager should read it.

    WEP has two literal key forms — 5 or 13 characters, 10 or 26 hex digits — and anything
    else used to be refused outright. But access points also accept a *passphrase* and derive
    the key from it, which is what a key of any other length means in practice (the operator
    had a 12-digit key from an access point doing exactly that and no way to enter it). So the
    literal forms stay literal, and everything else is handed over as a passphrase instead of
    being rejected.
    """
    key = password or ""
    if re.fullmatch(r"[0-9a-fA-F]{10}|[0-9a-fA-F]{26}", key) or len(key) in (5, 13):
        kind = "key"
    else:
        kind = "passphrase"
    return {"802-11-wireless-security.wep-key-type": kind,
            "802-11-wireless-security.wep-key0": key}


def _validate_psk(password):
    """A usable WPA key is an 8–63 character passphrase or a 64-hex-digit raw PSK.
    Reject anything else early, with a clear message instead of the cryptic nmcli
    "802-11-wireless-security.psk: property is invalid"."""
    if 8 <= len(password) <= 63:
        return
    if len(password) == 64 and re.fullmatch(r"[0-9a-fA-F]{64}", password):
        return
    raise WifiError("This network needs a password of 8–63 characters")


def _drop_security(options):
    """Modify-options for switching an existing profile to open. nmcli rejects clearing
    key-mgmt with an empty value ("key-mgmt: property is missing"), and a leftover
    key-mgmt/psk makes NM look for a secured BSS ("no suitable network found") — drop
    the whole security setting instead (harmless when the profile never had one)."""
    mod = {k: v for k, v in options.items()
           if not k.startswith("802-11-wireless-security.")}
    mod["remove"] = "802-11-wireless-security"
    return mod


def _up_client(name, ssid, bssid, ap_state, notify, wait=45):
    """Activate a client profile, with one retry when the network moved off the channel.

    A stale scan row sends the access point to the wrong channel, and the client then fails
    with NM's "Secrets were required" — indistinguishable from a wrong key by its message. The
    retry only fires when a fresh look says the network is somewhere else than where the point
    was put, so a genuinely wrong password still fails once, not twice.
    """
    try:
        nmcli.connection.up(name, wait=wait)
        return
    except Exception:
        if ap_state != "followed":
            raise
        band, chan = _target_channel(ssid, bssid)
        prefs = _load_ap_prefs()
        if not (band and chan) or (band, int(chan)) == (prefs.get("band_written"),
                                                       prefs.get("channel_written")):
            raise
        log.warning("retrying '%s': it is on %s GHz ch%s, the access point was on ch%s",
                    ssid, band, chan, prefs.get("channel_written"))
        if not (ap_channel_ok(band, chan) and _ap_follow_channel(band, chan)):
            raise
        notify("moving-hotspot", "{} GHz ch{}".format(band, chan))
        nmcli.connection.up(name, wait=wait)


@_holds_radio
def connect(ssid, password=None, security=None, hidden=False, remember=True,
            ipconf=None, bssid=None, status_cb=None):
    """Create/update the profile for ssid and activate it.

    security: explicit kind for hidden networks; otherwise resolved from the scan.
    bssid: pin the profile to this exact access point (stationary station — the user
    picks the AP/band; NetworkManager must not roam to a same-SSID sibling). Hidden
    networks have no scan entry, so they connect by SSID only.
    Returns the final network list. Raises WifiError with a readable message on failure.
    """
    notify = status_cb or (lambda *a: None)
    _set_client_off(False)
    bssid = (bssid or "").strip().upper() or None
    # the operation trail (never the password): every join attempt must be readable from
    # the journal, not just the failed ones
    log.info("wifi: connect '%s' requested (security=%s, bssid=%s, remember=%s, ip=%s)",
             ssid, security or "auto", bssid or "any", remember,
             (ipconf or {}).get("method") or "dhcp")

    if ipconf and ipconf.get("method") == "manual":
        # client STA: overlap with an occupied ethernet subnet is NOT blocked (Ethernet
        # and WiFi legitimately share one L2 network with a common DHCP) — the UI warns;
        # exact-address clashes and the rest still validate
        err = validate_ip_config(ipconf.get("ip", ""), ipconf.get("prefix", 0),
                                 ipconf.get("gateway"), ipconf.get("dns"),
                                 None, local_ip_addresses())
        if err:
            raise WifiError(err)
    elif ipconf and ipconf.get("dns"):        # DHCP + manual DNS override
        err = validate_dns_list(ipconf.get("dns"))
        if err:
            raise WifiError(err)

    # Joining is an explicit "the radio must be up": a saved row can be clicked while the
    # radio is down (the list keeps saved profiles), whether it went down on its own over a
    # reboot or the operator's own toggle is being superseded by this request.
    if not nmcli.radio.wifi():
        set_radio(True)

    if security is None:
        for n in nmcli.device.wifi(ifname=WIFI_IFACE):
            # with a BSSID pin resolve security from that exact BSS, not a namesake
            if ((n.bssid or "").upper() == bssid) if bssid else (n.ssid == ssid):
                security, _ = parse_security(n.security)
                break
        else:
            security = "wpa2" if password else "open"

    if security in ("wpa1", "wpa2", "wpa3", "mixed23"):
        _validate_psk(password or "")
    if security == "wep" and not (password or ""):
        raise WifiError("This network needs a WEP key")

    name = sanitize_profile_name(ssid)
    if bssid:
        # one profile per access point: two APs (or two bands of one AP) share an SSID,
        # so a plain WiFi_<SSID> name would overwrite the other's settings — tag the
        # name with the last three octets of the BSSID
        name += "_" + bssid.replace(":", "")[-6:]
    name += "" if remember else ONETIME_SUFFIX
    key_mgmt = _key_mgmt_for(security)

    options = {"802-11-wireless.ssid": ssid}
    if bssid:
        options["802-11-wireless.bssid"] = bssid
    if hidden:
        options["802-11-wireless.hidden"] = "yes"
    if security == "wep":
        options["802-11-wireless-security.key-mgmt"] = "none"
        options.update(_wep_key_options(password or ""))
    elif key_mgmt:
        options["802-11-wireless-security.key-mgmt"] = key_mgmt
        options["802-11-wireless-security.psk"] = password or ""
    options.update(_ipv4_options(ipconf))

    profiles = _wifi_profiles()
    existed = name in profiles
    # Connecting from access-point mode used to be refused outright, which left the operator
    # to switch the hotspot off by hand and lose the station when the network did not work.
    # Now the hotspot follows the client onto its channel — the radio has only one — and is
    # restored where the operator put it if the attempt fails. The point is touched only
    # AFTER everything above validated: a refused request must leave a running access point
    # exactly as it was, because the operator may be reaching the station through it and the
    # restore below only covers a failed connection attempt.
    ap_snap = _ap_snapshot_for_safe_apply() if (get_role() == "ap" or _ap_active()) else None
    ap_state = _ap_prepare_for_client(ap_snap, ssid, bssid, notify)
    notify("connecting", ssid)
    try:
        if existed:
            # connecting to a now-open network: the saved profile may carry an old
            # key-mgmt/psk (the AP was secured before)
            mod_opts = _drop_security(options) if security == "open" else options
            nmcli.connection.modify(name, mod_opts)
        else:
            nmcli.connection.add("wifi", options, WIFI_IFACE, name,
                                 autoconnect=remember)
        _up_client(name, ssid, bssid, ap_state, notify)
    except Exception as e:
        if not existed:
            try:
                nmcli.connection.delete(name)
            except Exception:
                pass
        log.warning("wifi connect '%s' failed: %s", ssid, _err_detail(e))
        _restore_ap_after_failure(ap_snap, notify)
        notify("failed", _readable_error(e))
        raise WifiError(_readable_error(e))
    log.info("wifi: connected '%s'", ssid)
    notify("connected", ssid)
    return list_networks()


@_holds_radio
def activate(profile, bssid=None, status_cb=None):
    """Bring up an already-saved client profile without touching its credentials.

    The password is stored in the profile (psk-flags=0), so reconnecting
    must NOT prompt for it again — just activate. (connect() can't be reused here: with
    no password it would rewrite the stored psk to empty.)

    bssid: the access point of the row the user clicked. A profile saved before BSSID
    pinning carries only an SSID — pin it now, so joining targets exactly that AP and
    the pin appears in the profile (and therefore in export) from here on.
    """
    notify = status_cb or (lambda *a: None)
    _set_client_off(False)
    log.info("wifi: activate '%s' requested (bssid=%s)", profile,
             (bssid or "").strip().upper() or "profile's own")
    # same as connect(): a join request implies the radio — up it if anything took it down
    if not nmcli.radio.wifi():
        set_radio(True)
    details = _guard_client_profile(profile)
    # same as connect(): the hotspot follows onto the client's channel, and is put back where
    # the operator had it if the network cannot be joined — it is the way into the station
    ap_snap = _ap_snapshot_for_safe_apply() if (get_role() == "ap" or _ap_active()) else None
    bssid = (bssid or "").strip().upper() or None
    ap_state = _ap_prepare_for_client(ap_snap, details.get("802-11-wireless.ssid") or profile,
                                      bssid or details.get("802-11-wireless.bssid"), notify)
    pinned_now = False
    if bssid and (details.get("802-11-wireless.bssid") or "") in ("", "--"):
        try:
            nmcli.connection.modify(profile, {"802-11-wireless.bssid": bssid})
            pinned_now = True
        except Exception as e:   # best-effort: an unpinnable profile must still connect
            log.warning("could not pin '%s' to %s: %s", profile, bssid, e)
    # user-facing name: the SSID, not the internal WiFi_<SSID>[_<bssid tag>] profile name
    disp = (details.get("802-11-wireless.ssid")
            or (profile[len(CLIENT_PREFIX):] if profile.startswith(CLIENT_PREFIX) else profile))
    notify("connecting", disp)
    try:
        _up_client(profile, disp, bssid or details.get("802-11-wireless.bssid"), ap_state, notify)
    except Exception as e:
        if pinned_now:
            # don't leave the profile pinned to an AP it never actually joined — that
            # would also block its autoconnect to the AP it used before
            try:
                nmcli.connection.modify(profile, {"802-11-wireless.bssid": ""})
            except Exception:
                pass
        log.warning("wifi activate '%s' failed: %s", profile, _err_detail(e))
        _restore_ap_after_failure(ap_snap, notify)
        notify("failed", _readable_error(e))
        raise WifiError(_readable_error(e))
    log.info("wifi: connected '%s'", disp)
    notify("connected", disp)
    return list_networks()


@_holds_radio
def disconnect():
    log.info("wifi: disconnect requested")
    _set_client_off(True)
    try:
        nmcli.device.disconnect(WIFI_IFACE)
    except Exception as e:
        # already disconnected (e.g. a repeated click on a stale list) — not an error
        if "not active" not in _err_detail(e).lower():
            raise WifiError(_readable_error(e))
    # `nmcli device disconnect` returns while NM is still tearing the connection down;
    # an immediate list would still see GENERAL.STATE=activated and show the network as
    # connected. Wait until the device actually leaves the active states.
    deadline = time.time() + 5
    while time.time() < deadline:
        state = wifi_state()["state"] or ""
        if not state.startswith("connected") and "deactivating" not in state:
            break
        time.sleep(0.3)
    log.info("wifi: disconnected")
    # the client no longer owns the channel, so the point goes back where the operator put it
    ap_return_to_preferred()
    return list_networks()


def forget(profile):
    log.info("wifi: forget '%s' requested", profile)
    _guard_client_profile(profile)
    try:
        nmcli.connection.delete(profile)
    except nmcli.NotExistException:
        pass
    except Exception as e:
        raise WifiError(_readable_error(e))
    return list_networks()


def change_password(profile, password):
    log.info("wifi: change password for '%s' requested", profile)   # the fact only, never the key
    details = _guard_client_profile(profile)
    if details.get("802-11-wireless-security.key-mgmt") == "none":
        if not (password or ""):
            raise WifiError("This network needs a WEP key")
        # the key type travels with the key: a profile that held a literal key and now gets a
        # passphrase (or the other way round) would keep the old type and stop working
        opts = _wep_key_options(password)
    else:
        _validate_psk(password or "")
        opts = {"802-11-wireless-security.psk": password}
    try:
        nmcli.connection.modify(profile, opts)
    except Exception as e:
        raise WifiError(_readable_error(e))
    log.info("wifi: password changed for '%s'", profile)
    return list_networks()


def set_autoconnect(profile, on):
    """Turn NetworkManager's autoconnect on/off for a saved client network.

    Connecting only activates a profile; the autoconnect flag decides whether NM brings it
    up on its own (after a reboot, or when the network reappears). This used to be refused
    while the access point was running, because the point and a client could not share the
    radio — now the point follows the client's channel, so the two work together and the
    switch does what it says whatever the point is doing."""
    on = bool(on)
    log.info("wifi: autoconnect %s for '%s'", "on" if on else "off", profile)
    _guard_client_profile(profile)
    try:
        nmcli.connection.modify(profile, {"connection.autoconnect": "yes" if on else "no"})
    except Exception as e:
        raise WifiError(_readable_error(e))
    return list_networks()


def set_ip_config(profile, ipconf):
    """Change the IP configuration of an existing (saved) profile."""
    log.info("wifi: ip config change for '%s' requested (%s)", profile,
             (ipconf or {}).get("method") or "dhcp")
    _guard_client_profile(profile)
    if ipconf and ipconf.get("method") == "manual":
        # client STA: overlap with an occupied ethernet subnet is NOT blocked (Ethernet
        # and WiFi legitimately share one L2 network with a common DHCP) — the UI warns;
        # exact-address clashes and the rest still validate
        err = validate_ip_config(ipconf.get("ip", ""), ipconf.get("prefix", 0),
                                 ipconf.get("gateway"), ipconf.get("dns"),
                                 None, local_ip_addresses())
        if err:
            raise WifiError(err)
    elif ipconf and ipconf.get("dns"):        # DHCP + manual DNS override
        err = validate_dns_list(ipconf.get("dns"))
        if err:
            raise WifiError(err)
    try:
        nmcli.connection.modify(profile, _ipv4_options(ipconf))
        details = nmcli.connection.show(profile)
        if details.get("GENERAL.STATE") == "activated":
            nmcli.connection.up(profile, wait=45)   # re-activate to apply
    except Exception as e:
        raise WifiError(_readable_error(e))
    return list_networks()


def _guard_client_profile(profile):
    """Allow the operation only on a WiFi CLIENT profile — judged by what the profile
    IS, not by its name: hand-made profiles (plain `nmcli device wifi connect`) lack our
    WiFi_ prefix but are legitimate saved networks the user must be able to manage."""
    if not profile or profile == AP_PROFILE:
        raise WifiError("Not a WiFi client profile: {}".format(profile))
    try:
        details = nmcli.connection.show(profile)
    except nmcli.NotExistException:
        raise WifiError("No such WiFi profile: {}".format(profile))
    if details.get("connection.type") not in ("802-11-wireless", "wifi") or _is_ap(details):
        raise WifiError("Not a WiFi client profile: {}".format(profile))
    return details


def wifi_state():
    """Current wlan0 device state, for reconnect status polling."""
    try:
        for dev in nmcli.device.status():
            if dev.device == WIFI_IFACE:
                return {"state": dev.state, "connection": dev.connection}
    except Exception:
        pass
    return {"state": "unknown", "connection": None}


def poll_reconnect(seconds, status_cb, interval=1.0):
    """Emit wlan0 state changes for `seconds` — used after a country change
    re-applies the regdomain and NM may re-associate."""
    last = None
    idle = 0
    deadline = time.time() + seconds
    while time.time() < deadline:
        cur = wifi_state()
        if cur != last:
            # NM's transitional states all read "connecting (...)" — report them as one
            # "reconnecting" stage. Terminal states must pass through verbatim: a
            # substring test on "connect" would swallow "connected"/"disconnected" too.
            status_cb("reconnecting" if (cur["state"] or "").startswith("connecting")
                      else cur["state"], cur)
            last = cur
        if cur["state"] == "connected":
            break
        # NM starts a re-association within a couple of seconds if it's going to at all.
        # A device sitting in a settled state (disconnected, no candidate profile,
        # unavailable) has nothing to wait for — exit early instead of stalling the
        # caller (and the UI busy lock) for the full window. NB: substring checks like
        # "connect" would also match "DISconnectED" — use an explicit settled-state list.
        if (cur["state"] or "") in ("disconnected", "unavailable", "unmanaged", "failed"):
            idle += 1
            if idle >= 4:
                break
        else:
            idle = 0
        time.sleep(interval)


# --------------------------------------------------------------------------
# access point
# --------------------------------------------------------------------------

# RSN/CCMP only for every secured kind: left unset, wpa_supplicant also advertises the
# legacy WPA1/TKIP information element, so scanners (ours included) label the access point
# plain "WPA" and old clients can negotiate TKIP — while the spec says WPA(1) is not
# supported for the AP at all.
_AP_RSN_ONLY = {
    "802-11-wireless-security.proto": "rsn",
    "802-11-wireless-security.pairwise": "ccmp",
    "802-11-wireless-security.group": "ccmp",
}

_AP_KEY_MGMT = {
    # `key-mgmt` holds one value, but NetworkManager expands it for wpa_supplicant, and for
    # "wpa-psk" it appends SAE unless PMF is disabled — so the ONE profile property that
    # decides whether the beacon carries WPA3 is `pmf` (enum: 0=default 1=disable
    # 2=optional 3=required). Measured on the air with a second radio:
    #   wpa-psk + pmf optional/default -> AKM PSK + PSK-SHA256 + SAE  (scanners: WPA2 WPA3)
    #   wpa-psk + pmf disable          -> AKM PSK + PSK-SHA256        (scanners: WPA2)
    #   sae     + pmf required         -> AKM SAE                     (scanners: WPA3)
    # Hence WPA2-PSK pins pmf=disable: without it the two choices are indistinguishable in
    # the air, and a station showing two settings that broadcast the same thing is a bug.
    "mixed": dict(_AP_RSN_ONLY, **{"802-11-wireless-security.key-mgmt": "wpa-psk",
                                   "802-11-wireless-security.pmf": "2"}),
    "wpa3": dict(_AP_RSN_ONLY, **{"802-11-wireless-security.key-mgmt": "sae",
                                  "802-11-wireless-security.pmf": "3"}),
    "wpa2": dict(_AP_RSN_ONLY, **{"802-11-wireless-security.key-mgmt": "wpa-psk",
                                  "802-11-wireless-security.pmf": "1"}),
    "open": {},
}


_ENUM_DISPLAY_RE = re.compile(r"\d+\s+\((\w[\w-]*)\)")


def _nmcli_enum_word(v):
    """nmcli shows enum properties in display form "N (word)" (e.g. pmf "2 (optional)"),
    which `nmcli add/modify` rejects — return just the word; anything else unchanged."""
    m = _ENUM_DISPLAY_RE.fullmatch(v)
    return m.group(1) if m else v


def get_ap_config():
    ref = _ap_ref()
    try:
        if not ref:
            raise nmcli.NotExistException(AP_PROFILE)
        details = nmcli.connection.show(ref, show_secrets=True)
    except nmcli.NotExistException:
        # security default follows the adapter: offering "mixed" where the radio cannot deliver
        # WPA3 would put a value in the form that is not even in its own list of choices
        return dict(AP_DEFAULTS, ssid=_default_ap_ssid(), security=default_ap_security(),
                    enabled=False, auto=rescue_enabled(), on_air=False, raised_by_auto=False,
                    configured=False, has_password=False, last_error=_last_ap_error)
    km = details.get("802-11-wireless-security.key-mgmt")
    pmf = _nmcli_enum_word((details.get("802-11-wireless-security.pmf") or "").strip())
    if km == "sae":
        security = "wpa3"
    elif km == "wpa-psk":
        # Report what the profile actually broadcasts, not what it was once picked as: only
        # PMF=disable keeps SAE out of the beacon. A profile with pmf unset (ours from before
        # this rule, or one from provisioning) does advertise WPA2+WPA3, so it reads as mixed
        # — re-saving as WPA2-PSK writes pmf=disable and makes it plain WPA2 for real.
        # On an adapter that cannot add SAE at all, every wpa-psk profile is plain WPA2 in the
        # air whatever pmf says, so it reads as WPA2 — and "mixed" is not offered (see
        # ap_security_kinds).
        security = "wpa2" if (pmf in ("1", "disable") or not sae_supported()) else "mixed"
    else:
        security = "open"
    live_band = {"bg": "2.4", "a": "5"}.get(details.get("802-11-wireless.band"), "all")
    addr = details.get("ipv4.addresses") or "{}/{}".format(AP_DEFAULTS["ip"], AP_DEFAULTS["prefix"])
    live_ip, _, live_pfx = addr.partition("/")
    live_pfx = int(live_pfx) if live_pfx.isdigit() else 24
    prefs = _load_ap_prefs()
    ip, prefix, moved = _ap_addr_preferred(live_ip, live_pfx, prefs)
    chan = details.get("802-11-wireless.channel")
    live_chan = int(chan) if chan and chan.isdigit() else 0
    band, chan_pref, chan_moved = _ap_channel_preferred(live_band, live_chan, prefs)
    air_band, air_chan = ap_air_channel()
    # A channel that was fine in one region is not in another, and switching the region does
    # not move a running point. Judged on where the point actually IS, not on what the form
    # holds, because those differ exactly in the cases worth reporting.
    illegal = ""
    if air_chan and air_band and not ap_channel_ok(air_band, air_chan):
        illegal = ("channel {} is not allowed for an access point in region {}"
                   .format(air_chan, get_country() or "00"))
    yielded = _ap_yield_reason(prefs)
    role_ap = get_role() == "ap"
    ap_live = details.get("GENERAL.STATE") == "activated"
    enabled, raised = ap_flags(role_ap, ap_live, rescue_enabled())
    return {
        "ssid": details.get("802-11-wireless.ssid") or _default_ap_ssid(),
        "last_error": _last_ap_error,
        "security": security,
        # The stored key is shown in the form ONLY under the CSS masking (a type=text
        # input the browser's password manager ignores — no save prompts). Browsers
        # without -webkit-text-security keep a real password field, so the UI leaves it
        # empty there (has_password drives the •••• placeholder) and an empty submit
        # means "keep the stored key" (see set_ap).
        "password": details.get("802-11-wireless-security.psk")
                    or details.get("802-11-wireless-security.sae-password") or "",
        "has_password": bool(details.get("802-11-wireless-security.psk")
                             or details.get("802-11-wireless-security.sae-password")),
        "hidden": details.get("802-11-wireless.hidden") in ("yes", "true"),
        "band": band,
        "channel": chan_pref,
        "ip": ip, "prefix": prefix,
        # set only while the point had to give the operator's choice away: the form shows what
        # was chosen, the UI adds where the point actually stands
        "ip_active": moved,
        "channel_active": chan_moved,
        # where the beacon really is, and whether that spot is legal here
        "air_band": air_band,
        "air_channel": air_chan,
        "channel_illegal": illegal,
        # why the point is not running even though it is switched on: the network the station
        # joined sits on a channel the point may not use
        "yielded": yielded,
        # two independent controls plus the air indicator (see ap_flags): the toggle is the
        # operator's point, `auto` is the watchdog flag, `on_air` is the beacon itself
        "enabled": enabled,
        "auto": rescue_enabled(),
        "on_air": bool(air_chan),
        "raised_by_auto": raised,
        "configured": True,
    }


# Profile keys set_ap writes — snapshotted before a change so a failed start can put the
# previous access point back (see _ap_snapshot/_ap_restore).
_AP_SETTING_KEYS = (
    "802-11-wireless.ssid", "802-11-wireless.hidden", "802-11-wireless.band",
    "802-11-wireless.channel", "802-11-wireless-security.key-mgmt",
    "802-11-wireless-security.pmf", "802-11-wireless-security.psk",
    "ipv4.addresses",
)


def _ap_snapshot(details):
    """Values of the keys set_ap overwrites, cleaned of nmcli display forms."""
    if not details:
        return None
    snap = {}
    for k in _AP_SETTING_KEYS:
        v = details.get(k)
        v = "" if v is None else _nmcli_enum_word(str(v).strip())
        snap[k] = "" if v.endswith("(default)") else v
    return snap


def _ap_restore(ref, snap, autoconnect, reactivate):
    """Undo a failed AP change: put the previous settings and role flags back, and bring the
    previously working access point up again. Best-effort — a rollback failure must not mask
    the original error, so everything here only logs."""
    try:
        if ref and snap is not None:
            mod = dict(snap)
            if not mod.get("802-11-wireless-security.key-mgmt"):
                mod = _drop_security(mod)
            nmcli.connection.modify(ref, mod)
    except Exception as e:
        log.warning("AP rollback: settings not restored: %s", e)
    for name, val in (autoconnect or {}).items():
        try:
            nmcli.connection.modify(name, {"connection.autoconnect": val})
        except Exception as e:
            log.warning("AP rollback: autoconnect not restored on '%s': %s", name, e)
    if reactivate:
        try:
            nmcli.connection.up(ref, wait=30)
            _set_hotspot_flag(True)
        except Exception as e:
            log.warning("AP rollback: previous access point not restarted: %s", e)


@_holds_radio
def set_ap(config, status_cb=None, intent=True):
    """Create/update the Hotspot profile and switch the wlan0 role.

    intent=False for our own internal use of this function — lowering the point for a client
    attempt and putting it back. Only the operator's toggle states whether the station is
    meant to run an access point at all, and that answer has to survive the roles being
    juggled in between, so it is recorded separately from NM's autoconnect flags.
    """
    notify = status_cb or (lambda *a: None)
    enabled = bool(config.get("enabled"))
    # Save carries the Auto toggle's position in `auto`; the point's own toggle and Auto are
    # independent (a toggle-off does NOT disarm the watchdog — confirmed as intended: an
    # isolated station gets its point back). Internal callers (restore, channel juggling)
    # pass plain `enabled` and never carry `auto`, so the flag is left alone there.
    auto = config.get("auto")
    if intent:
        # the operation trail (never the password); internal juggling (intent=False) is
        # not an operator action and stays out of the journal
        log.info("wifi: access point %s requested (ssid=%s, band=%s, chan=%s, security=%s%s)",
                 "on" if enabled else "off",
                 config.get("ssid") or "<current>", config.get("band", "all"),
                 config.get("channel") or "auto",
                 config.get("security", AP_DEFAULTS["security"]),
                 "" if auto is None else (", auto={}".format("on" if auto else "off")))

    # Validation gates TURNING THE AP ON (and saving its settings). Turning it OFF must
    # always be possible — even from an out-of-band state (AP enabled by hand, no region,
    # odd key): otherwise the UI has no way out. On disable with invalid form values we
    # skip saving the settings and only switch the role off.
    profiles = _wifi_profiles()
    # is a key already stored in the profile? (an empty password field means "keep it" —
    # the stored key is never sent to the browser, see get_ap_config)
    stored_key = False
    prev_ap = None            # settings to put back if the new access point fails to start
    ap_ref = _ap_ref()        # uuid: a same-name profile may exist on a sibling interface
    if ap_ref:
        try:
            det = nmcli.connection.show(ap_ref, show_secrets=True)
            stored_key = bool(det.get("802-11-wireless-security.psk")
                              or det.get("802-11-wireless-security.sae-password"))
            prev_ap = _ap_snapshot(det)
        except Exception:
            pass
    # only the point's own flag is the role now, so that is all a rollback has to put back —
    # client networks are not touched any more and have nothing to restore
    prev_autoconnect = ({ap_ref: "yes" if get_role(profiles) == "ap" else "no"}
                        if ap_ref else {})
    was_ap_active = _ap_active()
    created_ap = False        # a profile we add now must be removed again if the start fails

    verr = None
    if not get_country():
        verr = "Access Point mode requires a WiFi region (country)"
    security = config.get("security", AP_DEFAULTS["security"])
    if security not in _AP_KEY_MGMT:
        verr = verr or "Unsupported AP security: {}".format(security)
        security = AP_DEFAULTS["security"]
    password = config.get("password") or ""
    if security != "open":
        if password:
            if not 8 <= len(password) <= 63:
                verr = verr or "AP password must be 8–63 characters"
        elif not stored_key:
            verr = verr or "AP password must be 8–63 characters"
    ip = config.get("ip", AP_DEFAULTS["ip"])
    prefix = int(config.get("prefix", AP_DEFAULTS["prefix"]))
    # validated against what the operator typed — an error has to point at their own value,
    # not at the block the point may be shifted into below
    ip_err = validate_ip_config(ip, prefix, occupied=occupied_subnets())
    verr = verr or ip_err
    chan_req = int(config.get("channel") or 0)
    band_req = config.get("band", "all")
    if chan_req and band_req in ("2.4", "5") and not ap_channel_ok(band_req, chan_req):
        # reject BEFORE touching NM: a forbidden channel (usually inherited from
        # provisioning or an import, our picker never offers one) otherwise surfaces as an
        # unrelated "802.1X supplicant took too long to authenticate"
        cc = get_country() or "00"
        chans_now = allowed_channels()
        entry = next((e for e in chans_now.get(band_req, []) if e["ch"] == chan_req), None)
        if entry and entry.get("unavailable"):
            verr = verr or ("Channel {} is listed in wifi_manager.conf as unusable on this "
                            "station's adapter — choose another channel or Auto"
                            .format(chan_req))
        elif outdoor_station() and entry and entry.get("no_outdoor"):
            verr = verr or ("Channel {} is indoor-only in region {} and this station is "
                            "configured as outdoor — choose another channel or Auto"
                            .format(chan_req, cc))
        else:
            verr = verr or ("Channel {} is not available for the access point in region {} — "
                            "choose another channel or Auto".format(chan_req, cc))
    # arming auto saves the profile the watchdog will later raise, and test-starts it
    # below — both need settings as valid as an actual start does
    if (enabled or auto) and verr:
        raise WifiError(verr)

    # The access point needs its own interface before a profile can point at it. Only when
    # actually starting it (or test-starting for 'auto'): saving settings with the control
    # off must not fail on hardware that cannot host a second interface, and must not
    # create one for nothing.
    if enabled or auto:
        ensure_ap_iface()

    # The address the operator typed is the preference; the profile gets the block that is
    # actually free, because that is the one NetworkManager will raise on boot. Both are
    # remembered: reading the form back has to tell our own shift apart from an address
    # someone else (provisioning, an import) wrote into the profile.
    eff_ip, eff_prefix, moved_by = ap_addr_effective(ip, prefix)
    if moved_by:
        log.warning("access point moved to %s/%s: %s/%s overlaps %s (%s)",
                    eff_ip, eff_prefix, ip, prefix, moved_by.get("net"), moved_by.get("conn"))
    if not verr:
        # writing the channel from the form (or from a snapshot, which carries the operator's
        # own channel) ends any loan the point was on — otherwise stale loan keys would linger
        prefs = _without_loan(_load_ap_prefs())
        if intent:
            prefs["wanted"] = enabled
        _save_ap_prefs(dict(prefs, ip=ip, prefix=prefix, ip_written=eff_ip,
                            prefix_written=eff_prefix, band=band_req, channel=chan_req))

    options = {
        "802-11-wireless.mode": "ap",
        "802-11-wireless.ssid": config.get("ssid") or _default_ap_ssid(),
        "802-11-wireless.hidden": "yes" if config.get("hidden") else "no",
        # pin the profile to the AP interface: also migrates a profile from before the access
        # point moved off wlan0, so old settings survive the change instead of being orphaned
        "connection.interface-name": AP_IFACE if enabled or ap_iface_present() else "",
        "ipv4.method": "shared",
        "ipv4.addresses": "{}/{}".format(eff_ip, eff_prefix),
        "802-11-wireless-security.key-mgmt": "",
        "802-11-wireless-security.pmf": "",
        "802-11-wireless-security.proto": "",
        "802-11-wireless-security.pairwise": "",
        "802-11-wireless-security.group": "",
    }
    band = config.get("band", "all")
    options["802-11-wireless.band"] = {"2.4": "bg", "5": "a"}.get(band, "")
    chan = int(config.get("channel") or 0)
    options["802-11-wireless.channel"] = str(chan) if chan and band != "all" else ""
    options.update(_AP_KEY_MGMT[security])
    if security == "open":
        options["802-11-wireless-security.psk"] = ""     # drop the stored key
    elif password:
        options["802-11-wireless-security.psk"] = password
    # else: empty field with a stored key — leave the profile's key untouched

    if verr and not enabled:
        # disabling with an invalid form: don't rewrite the profile with bad values —
        # keep whatever is stored and just switch the role off below
        log.warning("AP settings not saved on disable: %s", verr)
    else:
        try:
            if ap_ref:
                # switching a secured AP to Open: the base options carry empty-string
                # security keys (meant to clear values), which modify would reject
                mod_opts = _drop_security(options) if security == "open" else options
                nmcli.connection.modify(ap_ref, mod_opts)
            else:
                add_opts = {k: v for k, v in options.items() if v != ""}
                nmcli.connection.add("wifi", add_opts, AP_IFACE, AP_PROFILE,
                                     autoconnect=False)
                ap_ref = _ap_ref()          # address the fresh profile by uuid from now on
                created_ap = True
        except Exception as e:
            raise WifiError(_readable_error(e))

    # The access point's own autoconnect is the whole role now. Client networks keep theirs:
    # they used to be cleared so NetworkManager could not steal the single radio, but the point
    # follows the client's channel these days, so the two coexist and clearing was only taking
    # away the station's ability to rejoin its network on its own.
    try:
        # no profile AND switching off: nothing to modify or lower — a point that was never
        # configured is already off, and that must not stop the mode from being recorded
        if ap_ref:
            nmcli.connection.modify(ap_ref, {"connection.autoconnect": "yes" if enabled else "no"})
        global _last_ap_error, _ap_yielded, _last_ap_action
        _last_ap_action = time.time()
        if enabled:
            notify("starting", "hotspot")
            nmcli.connection.up(ap_ref, wait=30)
            _set_hotspot_flag(True)
            # standing again: whatever made the point yield the radio no longer applies
            _ap_yielded = ""
        else:
            if ap_ref and _ap_active():
                try:
                    nmcli.connection.down(ap_ref)
                except Exception:
                    pass
            _set_hotspot_flag(False)
            if auto:
                # prove the point can come up with exactly these settings before arming the
                # watchdog — nothing short of a real start catches a channel the firmware
                # refuses. Up and straight down: the station is not isolated, the point
                # must not stay.
                notify("starting", "hotspot")
                nmcli.connection.up(ap_ref, wait=30)
                nmcli.connection.down(ap_ref)
        _last_ap_error = None
    except Exception as e:
        _last_ap_error = _ap_start_error(_readable_error(e), band, chan_req)
        # transactional: undo the role switch (and the settings, restarting the previous
        # access point when one was running) so a failed start cannot strand the station
        # with every client network's autoconnect cleared
        if created_ap and ap_ref:
            # we added this profile in this very call and it never came up — deleting it
            # keeps a station that already has a hotspot profile elsewhere (ap0) from
            # collecting a second connection with the same name
            try:
                nmcli.connection.delete(ap_ref)
            except Exception as de:
                log.warning("AP rollback: could not remove the new profile: %s", de)
            _ap_restore(None, None, {}, reactivate=False)
        else:
            # a failed auto-arming test start rolls back like a failed start: the new settings
            # proved unusable, so the previous ones (and a previously running point) return
            wrote = enabled or bool(auto)
            _ap_restore(ap_ref, prev_ap if wrote else None,
                        prev_autoconnect, reactivate=wrote and was_ap_active)
        raise WifiError(_last_ap_error)
    if auto is not None and intent:
        # recorded only after the role switch went through: a failed switch raised above,
        # and writing the flag there would desync the station config from reality
        set_station_flag("hotspot_rescue", bool(auto))
    if intent:
        log.info("wifi: access point %s", "up" if enabled
                 else ("down, watchdog armed" if auto else "down"))
    return get_ap_config()


def set_ap_auto(on):
    """The Auto toggle alone: arm or disarm the rescue watchdog without touching the form.

    Off is always allowed and applies immediately. If the beacon in the air right now is the
    watchdog's own (the role is still client), the point goes down together with the flag —
    a disarmed watchdog would never lower it, and leaving an ownerless beacon standing after
    "auto off" is exactly the surprise the toggle exists to prevent. The operator's own
    point (AP role) is not touched: the toggles are independent.

    On arms only next to a point that is ON THE AIR right now — a live beacon is the proof
    the stored settings can stand. For a sleeping or unsaved point arming goes through Save
    (set_ap with `auto`) together with starting the point: the flag is recorded only after
    that start succeeds, so the watchdog is never armed with settings that never came up.

    Returns (config, lowered). The flag write itself changes neither the status header nor
    the network list — `lowered` tells the caller when the heavy broadcasts are actually
    due, so a plain toggle answers with one ap-config and nothing else.
    """
    if on:
        if not _ap_ref():
            raise WifiError("Auto mode needs a saved access point — "
                            "set up and save the access point first")
        if not _ap_active():
            raise WifiError("Auto mode arms only while the access point is online — "
                            "turn the access point on first")
        set_station_flag("hotspot_rescue", True)
        return get_ap_config(), False
    set_station_flag("hotspot_rescue", False)
    lowered = False
    ref = _ap_ref()
    if ref and _ap_active() and get_role() != "ap":
        try:
            nmcli.connection.down(ref)
            lowered = True
        except Exception as e:
            log.warning("auto off: could not lower the rescue point: %s", e)
        global _rescue_raised
        _rescue_raised = False
    return get_ap_config(), lowered


def _set_hotspot_flag(up):
    """LED indication flag; ignore failure off-device (no /usr/local/rtkbase)."""
    try:
        if up:
            with open(HOTSPOT_FLAG, "w") as f:
                f.write("")
        elif os.path.exists(HOTSPOT_FLAG):
            os.remove(HOTSPOT_FLAG)
    except OSError as e:
        log.warning("HOTSPOT.flg: %s", e)


# --------------------------------------------------------------------------
# optional JSON backup/restore
# --------------------------------------------------------------------------

# Exact property keys to replicate — only the ones connect()/set_ap() actually write. A
# curated allowlist (not a prefix match): nmcli show emits dozens of sibling props whose
# value is a display artifact ("-1 (default)", "auto", per-secret *-flags) or an NM-negotiated
# default (proto/pairwise/group ciphers, auth-alg) that the configurator never sets — those
# are neither needed to restore state nor valid `nmcli add/modify` input, and would break
# restore. WPA3 stores its key in .psk (not .sae-password); WEP uses .wep-key-type=key.
_BACKUP_KEYS = frozenset({
    "connection.id", "connection.autoconnect", "connection.interface-name",
    "802-11-wireless.ssid", "802-11-wireless.bssid", "802-11-wireless.hidden",
    "802-11-wireless.mode", "802-11-wireless.band", "802-11-wireless.channel",
    "802-11-wireless-security.key-mgmt", "802-11-wireless-security.psk",
    "802-11-wireless-security.pmf", "802-11-wireless-security.proto",
    "802-11-wireless-security.pairwise", "802-11-wireless-security.group",
    "802-11-wireless-security.wep-key0", "802-11-wireless-security.wep-key-type",
    "ipv4.method", "ipv4.addresses", "ipv4.gateway", "ipv4.dns", "ipv4.ignore-auto-dns",
})


# Per-key "unset" sentinels: nmcli show emits a placeholder for unconfigured props that is
# NOT valid `nmcli add/modify` input (channel 0 = auto; wep-* left over on a WPA profile).
# Dropping them lets the target fall back to the same default.
_BACKUP_UNSET = {
    "802-11-wireless.channel": {"0"},
    "802-11-wireless-security.wep-key-type": {"0", "unknown"},
}


# Only these keys hold enum values needing the "N (word)" display-form unwrap. The
# unwrap must NOT run on free-text fields: a passphrase "12 (secret)" or SSID
# "2 (guest)" has the same shape and must survive the round-trip verbatim.
_BACKUP_ENUM_KEYS = frozenset({
    "802-11-wireless-security.pmf",
    "802-11-wireless-security.wep-key-type",
})


def _backup_value(k, v):
    """Clean an nmcli-show value for export; None to drop it. Drops display defaults
    ('value (default)') and per-key unset sentinels — the target uses the same default."""
    if v is None:
        return None
    v = str(v).strip()
    if k in _BACKUP_ENUM_KEYS:
        # unwrap before the sentinel check so "0 (unknown)" matches "unknown";
        # "default" is the display word for enum 0 = property not set
        v = _nmcli_enum_word(v)
        if v == "default":
            return None
    if not v or v.endswith("(default)") or v in _BACKUP_UNSET.get(k, ()):
        return None
    return v


def backup_profiles():
    """Export WiFi profiles (with secrets) + the regulatory region for replication."""
    log.info("wifi: backup requested")
    out = {"version": 1, "country": get_country(), "profiles": []}
    for conn in nmcli.connection():
        if conn.conn_type != "wifi":
            continue
        try:
            details = nmcli.connection.show(conn.name, show_secrets=True)
        except Exception:
            continue
        keep = {}
        for k, v in details.items():
            if k in _BACKUP_KEYS:
                cv = _backup_value(k, v)
                if cv is not None:
                    keep[k] = cv
        out["profiles"].append(keep)
    log.info("wifi: backup served (%d profiles)", len(out["profiles"]))
    return out


def restore_profiles(data):
    log.info("wifi: restore requested")
    if not isinstance(data, dict) or data.get("version") != 1:
        raise WifiError("Unsupported WiFi backup format")
    # restore the regulatory region first (best-effort — a missing/invalid code or a host
    # without iw must not abort the profile import)
    country = (data.get("country") or "").strip().upper()
    if country:
        try:
            set_country(country)
        except Exception as e:
            log.warning("restore: could not apply region '%s': %s", country, e)
    count = 0
    for prof in data.get("profiles", []):
        name = prof.get("connection.id")
        if not name:
            continue
        # tolerate older backups that captured extra props / nmcli display artifacts
        # ("… (default)", mtu "auto", per-secret *-flags) — none are valid `nmcli add` input;
        # keep only the curated replication keys, cleaned
        options = {}
        for k, v in prof.items():
            if k == "connection.id" or k not in _BACKUP_KEYS:
                continue
            cv = _backup_value(k, v)
            if cv is not None:
                options[k] = cv
        autoconnect = options.pop("connection.autoconnect", "yes") == "yes"
        # honour the exported device binding (wlan0 / ap0 / a USB dongle): restoring onto
        # the wrong adapter is exactly what the binding is meant to prevent. Passed as the
        # add ifname (which IS connection.interface-name) — popped to avoid a duplicate.
        ifname = options.pop("connection.interface-name", None) or WIFI_IFACE
        try:
            nmcli.connection.delete(name)
        except Exception:
            pass
        try:
            nmcli.connection.add("wifi", options, ifname, name, autoconnect=autoconnect)
            count += 1
        except Exception as e:
            raise WifiError("Restore failed on '{}': {}".format(name, _readable_error(e)))
    log.info("wifi: restore done (%d profiles)", count)
    return count


# --------------------------------------------------------------------------
# errors
# --------------------------------------------------------------------------

class WifiError(Exception):
    """Operation failed; str(e) is safe to show in the UI."""


def _err_detail(e):
    """Full failure reason. The nmcli lib collapses activation/deactivation/delete errors
    to a generic message ('Connection activation failed') and drops nmcli's stderr — the
    real reason survives on the chained CalledProcessError, so recover it from there."""
    cause = getattr(e, "__cause__", None)
    raw = getattr(cause, "stderr", None)
    if raw:
        try:
            text = raw.decode() if isinstance(raw, (bytes, bytearray)) else str(raw)
            if text.strip():
                return text.strip()
        except Exception:
            pass
    return str(e) or e.__class__.__name__


def _readable_error(e):
    msg = _err_detail(e)
    # NM stderr is noisy: glib "(process:N): nm-CRITICAL ... assertion failed" lines, a
    # developer-only "Hint: use journalctl ..." trailer. Keep the first line that carries
    # the actual reason (prefer the "Error:"-prefixed one nmcli prints).
    lines = [l.strip() for l in msg.split("Hint:")[0].strip().splitlines()
             if l.strip() and "CRITICAL" not in l and "assertion" not in l]
    first = next((l for l in lines if l.startswith("Error")), lines[0] if lines else "")
    low = first.lower()
    if "secrets were required" in low:
        return "Wrong password (secrets were required, but not provided)"
    if any(s in low for s in ("no suitable network found", "no network with ssid",
                              "network could not be found")):
        return "Network not found — it may be out of range or on a restricted channel"
    if "ip configuration could not be reserved" in low or ("dhcp" in low and "timeout" in low):
        return "Associated, but no IP was assigned — no DHCP on this network (use a static IP)"
    if "interrupted" in low:
        return "Connection was interrupted — please try again"
    # strip NM's boilerplate prefixes for anything else, and show SSIDs instead of the
    # internal WiFi_<SSID> profile names in user-facing text
    cleaned = first.replace("Error:", "").replace("Connection activation failed:", "").strip()
    cleaned = re.sub(r"'{}([^']*)'".format(re.escape(CLIENT_PREFIX)), r"'\1'", cleaned)
    return cleaned or (str(e) or e.__class__.__name__)
