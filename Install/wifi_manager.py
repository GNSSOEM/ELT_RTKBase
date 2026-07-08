#!/usr/bin/python
"""Wi-Fi manager backend for the RTKBase configurator.

Implements the NetworkManager side of the Wi-Fi manager popup:
scanning, client profile CRUD, access-point profile, regulatory domain,
validation. server.py keeps only thin Socket.IO handlers on top of this
module.

Persistence is NetworkManager profiles only (client: WiFi_<SSID>, AP: Hotspot).
The wlan0 role derives from the profiles' autoconnect flags — no settings.conf flag.
"""

import ipaddress
import logging
import os
import re
import shutil
import subprocess
import time

import nmcli

log = logging.getLogger(__name__)

WIFI_IFACE = "wlan0"
AP_PROFILE = "Hotspot"
CLIENT_PREFIX = "WiFi_"
ONETIME_SUFFIX = ".onetime"
HOTSPOT_FLAG = "/usr/local/rtkbase/HOTSPOT.flg"
ISO3166_SYSTEM = "/usr/share/zoneinfo/iso3166.tab"   # tzdata; present on any Debian/RPi OS

AP_DEFAULTS = {
    "ssid": "RtkBase",
    "security": "mixed",     # mixed | wpa3 | wpa2 | open
    "password": "",
    "hidden": False,
    "band": "all",           # all | 2.4 | 5
    "mode80211": "auto",
    "channel": 0,            # 0 = auto
    "ip": "192.168.50.1",
    "prefix": 24,
}

# In-memory "last seen channel" per SSID, refreshed on every scan. Needed for the
# `Unavailable in <CC>` badge on saved networks: a profile stores no channel, and a
# network on a DISABLED channel is not scanned at all, so the last sighting is the
# only channel source. Empty until the first scan of this server process.
_seen_channels = {}

# Regdomain state for hosts without `iw` (x86 bench, some DIY): set_country() stores
# the CC here so the UI flow still works; allowed channels come from _FALLBACK_REG.
_fallback_country = None

# BSSIDs our own hotspot has beaconed with (the wlan0 MAC while in AP mode). NM randomizes
# the MAC, so after the AP is turned off its cached scan entry no longer matches the CURRENT
# wlan0 address — remember every address we beaconed from and keep filtering those entries
# until they age out of the scan cache. (Filtering by SSID instead would hide a neighbouring
# station broadcasting the same name — the default SSID is the same on every unit.)
_own_ap_bssids = set()

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


def parse_security(sec):
    """nmcli SECURITY string -> (kind, label). kind: open|wep|wpa1|wpa2|wpa3|mixed23"""
    s = (sec or "").upper()
    if not s.strip():
        return "open", "open"
    if "WPA3" in s and "WPA2" in s:
        return "mixed23", "WPA2/WPA3"
    if "WPA3" in s:
        return "wpa3", "WPA3"
    if "WPA2" in s:
        return "wpa2", "WPA2"
    if "WPA1" in s or s.strip() == "WPA":
        return "wpa1", "WPA"
    if "WEP" in s:
        return "wep", "WEP"
    return "wpa2", sec


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


def _iw(*args):
    out = subprocess.check_output(("iw",) + args, text=True, timeout=10,
                                  stderr=subprocess.STDOUT)
    return out


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
        nmcli.device.wifi_rescan()
    except Exception:
        pass


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
    for band in chans:
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


def channel_usable(band, ch, chans, country):
    """Gating -> 'ok' | 'no_region' | 'disabled'."""
    entry = next((e for e in chans.get(band, []) if e["ch"] == ch), None)
    if entry is None or entry.get("disabled"):
        # unknown to / disabled in the current domain
        return "no_region" if not country else "disabled"
    if entry.get("no_ir") and not country:
        return "no_region"
    return "ok"


def get_countries(hide_codes=()):
    """Full ISO 3166 list, sorted by name, from the system tzdata file."""
    if not os.path.exists(ISO3166_SYSTEM):
        raise WifiError("Country list unavailable: {} not found (tzdata not installed?)"
                        .format(ISO3166_SYSTEM))
    out = []
    hide = {c.strip().upper() for c in hide_codes if c.strip()}
    with open(ISO3166_SYSTEM, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            cc, _, name = line.partition("\t")
            if len(cc) == 2 and name and cc.upper() not in hide:
                out.append({"code": cc.upper(), "name": name.strip()})
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
            details = nmcli.connection.show(conn.name)
        except nmcli.NotExistException:
            continue
        bound = details.get("connection.interface-name")
        if bound and bound != WIFI_IFACE:
            continue
        profiles[conn.name] = details
    return profiles


def _is_ap(details):
    return details.get("802-11-wireless.mode") == "ap"


def get_role(profiles=None):
    """'ap' when the AP profile has autoconnect=yes, else 'client'."""
    profiles = profiles if profiles is not None else _wifi_profiles()
    ap = profiles.get(AP_PROFILE)
    if ap and ap.get("connection.autoconnect") == "yes":
        return "ap"
    return "client"


def _ap_active():
    try:
        details = nmcli.connection.show(AP_PROFILE)
    except nmcli.NotExistException:
        return False
    return details.get("GENERAL.STATE") == "activated"


def radio_wifi_on():
    """Spec §7.4: NM does not persist the radio state reliably — force it on."""
    if not nmcli.radio.wifi():
        nmcli.radio.wifi_on()


def set_radio(on):
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
            for part in addr.split(","):
                part = part.strip()
                if "/" in part:
                    nets.append({"net": part, "conn": conn.name})
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
                nets.append({"net": addr, "conn": dev.device})
                seen.add(addr)
    except Exception as e:
        log.warning("device subnet scan failed: %s", e)
    return nets


def local_ip_addresses():
    """IPv4 addresses currently assigned to this device's interfaces (except the Wi-Fi
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
    # address of a local radio). Subnet overlap with the target Wi-Fi network is fine — a
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
            return "Subnet overlaps {} ({})".format(item["net"], item["conn"])
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

    scan = []
    if nmcli.radio.wifi():
        # While our AP holds the (single) radio, scanning is impossible — a forced
        # --rescan just blocks for its timeout with the client list disabled anyway.
        # Serve the cached list instead.
        do_rescan = rescan and not ap_live
        try:
            scan = nmcli.device.wifi(rescan=True) if do_rescan else nmcli.device.wifi()
        except Exception as e:
            # NM refuses a rescan too soon after the previous one; fall back to
            # the cached list rather than showing nothing.
            log.warning("wifi scan failed (rescan=%s): %s", do_rescan, e)
            if do_rescan:
                try:
                    scan = nmcli.device.wifi()
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

    # strongest AP per ssid; skip hidden (empty ssid) entries
    by_ssid = {}
    for n in scan:
        if not n.ssid or n.ssid == "--":
            continue
        # Our own hotspot is not a joinable network: skip its beacon by BSSID (current MAC
        # or any address it has beaconed with — see _own_ap_bssids), and as a fallback the
        # IN-USE entry nmcli shows while the hotspot is up.
        bssid = (n.bssid or "").upper()
        if bssid and (bssid == my_mac or bssid in _own_ap_bssids):
            continue
        if ap_live and n.in_use:
            continue
        cur = by_ssid.get(n.ssid)
        if cur is None or n.signal > cur.signal or n.in_use:
            by_ssid[n.ssid] = n
    for ssid, n in by_ssid.items():
        _seen_channels[ssid] = (n.chan, n.freq)

    # client profiles by ssid (skip AP profile); drop stale one-time profiles
    client_profiles = {}
    for name, details in profiles.items():
        if _is_ap(details):
            continue
        ssid = details.get("802-11-wireless.ssid") or name
        if name.endswith(ONETIME_SUFFIX) and details.get("GENERAL.STATE") != "activated":
            try:
                nmcli.connection.delete(name)
            except Exception:
                pass
            continue
        client_profiles[ssid] = (name, details)

    def entry(ssid, scan_item, prof):
        name, details = prof if prof else (None, {})
        chan = scan_item.chan if scan_item else None
        freq = scan_item.freq if scan_item else None
        if chan is None and ssid in _seen_channels:
            chan, freq = _seen_channels[ssid]
        band = freq_to_band(freq) if freq else None
        kind, label = parse_security(scan_item.security if scan_item else None)
        if not scan_item and details:
            km = details.get("802-11-wireless-security.key-mgmt")
            kind = {"sae": "wpa3", "wpa-psk": "wpa2", "none": "wep", None: "open"}.get(km, "wpa2")
            label = {"wpa3": "WPA3", "wpa2": "WPA2", "wep": "WEP", "open": "open"}[kind]
        usable = channel_usable(band, chan, chans, country) if chan and band else "ok"
        e = {
            "ssid": ssid,
            "signal": scan_item.signal if scan_item else None,
            "security": kind, "security_label": label,
            "band": band, "chan": chan, "freq": freq,
            "saved": bool(name) and not (name or "").endswith(ONETIME_SUFFIX),
            "profile": name,
            "autoconnect": details.get("connection.autoconnect") == "yes" if details else None,
            "in_use": bool(scan_item and scan_item.in_use),
            "usable": usable,
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
        return e

    connected, saved, available = [], [], []
    for ssid, n in sorted(by_ssid.items(), key=lambda kv: -kv[1].signal):
        prof = client_profiles.pop(ssid, None)
        e = entry(ssid, n, prof)
        if e["in_use"]:
            connected.append(e)
        elif e["saved"]:
            saved.append(e)
        else:
            # country set: networks on DISABLED channels are not scannable at all;
            # if one still shows up, hide it from Available
            if not (country and e["usable"] == "disabled"):
                available.append(e)
    for ssid, prof in client_profiles.items():   # saved but not in scan
        e = entry(ssid, None, prof)
        if e["in_use"]:
            connected.append(e)
        else:
            saved.append(e)
    saved.sort(key=lambda e: e["ssid"].lower())

    return {
        "radio": nmcli.radio.wifi(),
        "country": country,
        "role": role,
        "ap_active": role == "ap" and ap_live,
        "connected": connected, "saved": saved, "available": available,
    }


def _augment_wifi_iface(interfaces):
    """Always surface the Wi-Fi interface in the popup header, even with no IP.

    network_infos.get_interfaces_infos() only lists interfaces that have an IP, so
    a disconnected wlan0 never appears. Users expect to see the Wi-Fi adapter (with
    its MAC) regardless, so add it when it's not already present.
    """
    ifaces = list(interfaces or [])
    if any(i.get("device") == WIFI_IFACE for i in ifaces):
        return ifaces
    try:
        hw = nmcli.device.show(WIFI_IFACE).get("GENERAL.HWADDR")
    except Exception as e:
        log.warning("wifi iface info failed: %s", e)
        return ifaces
    entry = {"device": WIFI_IFACE, "ipv4": None, "ipv6": None}
    if hw and hw != "(unknown)":
        entry["hwaddr"] = hw
    ifaces.append(entry)
    return ifaces


def augment_ipv6_linklocal(interfaces):
    """Add link-local IPv6 (fe80::…) back to the interface list.

    network_infos.get_interfaces_infos() drops link-local addresses, so on a host
    with no global IPv6 (no IPv6 router — the common case) the Network Infos block
    shows no IPv6 at all even though every up interface has one. Used by both the
    Wi-Fi popup header and the page's sys_informations feed.
    """
    ifaces = interfaces or []
    try:
        import psutil
        ll = {}
        for name, addrs in psutil.net_if_addrs().items():
            for a in addrs:
                if a.family.name == "AF_INET6" and a.address.startswith("fe80"):
                    # drop the %zone suffix — the interface is clear from the context
                    ll.setdefault(name, []).append(a.address.split("%")[0])
        for itf in ifaces:
            extra = ll.get(itf.get("device"))
            if extra:
                itf["ipv6"] = (itf.get("ipv6") or []) + extra
    except Exception as e:
        log.warning("ipv6 link-local scan failed: %s", e)
    return ifaces


def get_status(hide_country_codes=()):
    """Header/status payload for the popup."""
    cap = capability()
    status = {"capability": cap}
    if not cap["nm"]:
        return status
    global _last_interfaces
    try:
        import network_infos
        _last_interfaces = network_infos.get_interfaces_infos()
    except Exception as e:
        # keep the last good list rather than blanking the header on a transient failure
        log.warning("network_infos failed (keeping last known): %s", e)
    status["interfaces"] = augment_ipv6_linklocal(_augment_wifi_iface(_last_interfaces))
    status.update({
        "radio": nmcli.radio.wifi(),
        "country": get_country(),
        "channels": allowed_channels(),
        "bands": available_bands(),
        "role": get_role(),
        "occupied": occupied_subnets(),
    })
    return status


# --------------------------------------------------------------------------
# connect / disconnect / forget
# --------------------------------------------------------------------------

def _ipv4_options(ipconf):
    """ipconf: None|{method, ip, prefix, gateway, dns} -> nmcli option dict."""
    if not ipconf or ipconf.get("method") != "manual":
        return {"ipv4.method": "auto", "ipv4.addresses": "", "ipv4.gateway": "", "ipv4.dns": ""}
    opts = {"ipv4.method": "manual",
            "ipv4.addresses": "{}/{}".format(ipconf["ip"].strip(), int(ipconf["prefix"]))}
    opts["ipv4.gateway"] = (ipconf.get("gateway") or "").strip()
    dns = ",".join(s.strip() for s in (ipconf.get("dns") or "").split(",") if s.strip())
    opts["ipv4.dns"] = dns
    return opts


def connect(ssid, password=None, security=None, hidden=False, remember=True,
            ipconf=None, status_cb=None):
    """Create/update the profile for ssid and activate it.

    security: explicit kind for hidden networks; otherwise resolved from the scan.
    Returns the final network list. Raises WifiError with a readable message on failure.
    """
    notify = status_cb or (lambda *a: None)
    if get_role() == "ap":
        raise WifiError("Client connection is not available while Access Point mode is on")

    if ipconf and ipconf.get("method") == "manual":
        err = validate_ip_config(ipconf.get("ip", ""), ipconf.get("prefix", 0),
                                 ipconf.get("gateway"), ipconf.get("dns"),
                                 occupied_subnets(), local_ip_addresses())
        if err:
            raise WifiError(err)

    if security is None:
        for n in nmcli.device.wifi():
            if n.ssid == ssid:
                security, _ = parse_security(n.security)
                break
        else:
            security = "wpa2" if password else "open"

    # A secured network needs a usable key. Reject early with a clear message instead of the
    # cryptic nmcli "802-11-wireless-security.psk: property is invalid".
    if security in ("wpa1", "wpa2", "wpa3", "mixed23") and not 8 <= len(password or "") <= 64:
        raise WifiError("This network needs a password of 8–63 characters")
    if security == "wep" and not (password or ""):
        raise WifiError("This network needs a WEP key")

    name = sanitize_profile_name(ssid) + ("" if remember else ONETIME_SUFFIX)
    key_mgmt = _key_mgmt_for(security)

    options = {"802-11-wireless.ssid": ssid}
    if hidden:
        options["802-11-wireless.hidden"] = "yes"
    if security == "wep":
        options["802-11-wireless-security.key-mgmt"] = "none"
        options["802-11-wireless-security.wep-key-type"] = "key"
        options["802-11-wireless-security.wep-key0"] = password or ""
    elif key_mgmt:
        options["802-11-wireless-security.key-mgmt"] = key_mgmt
        options["802-11-wireless-security.psk"] = password or ""
    options.update(_ipv4_options(ipconf))

    profiles = _wifi_profiles()
    existed = name in profiles
    notify("connecting", ssid)
    try:
        if existed:
            nmcli.connection.modify(name, options)
        else:
            nmcli.connection.add("wifi", options, WIFI_IFACE, name,
                                 autoconnect=remember)
        nmcli.connection.up(name, wait=45)
    except Exception as e:
        if not existed:
            try:
                nmcli.connection.delete(name)
            except Exception:
                pass
        log.warning("wifi connect '%s' failed: %s", ssid, _err_detail(e))
        notify("failed", _readable_error(e))
        raise WifiError(_readable_error(e))
    notify("connected", ssid)
    return list_networks()


def activate(profile, status_cb=None):
    """Bring up an already-saved client profile without touching it.

    The password is stored in the profile (psk-flags=0), so reconnecting
    must NOT prompt for it again — just activate. (connect() can't be reused here: with
    no password it would rewrite the stored psk to empty.)
    """
    notify = status_cb or (lambda *a: None)
    _guard_client_profile(profile)
    if get_role() == "ap":
        raise WifiError("Client connection is not available while Access Point mode is on")
    # user-facing name: the SSID, not the internal WiFi_<SSID> profile name
    disp = profile[len(CLIENT_PREFIX):] if profile.startswith(CLIENT_PREFIX) else profile
    notify("connecting", disp)
    try:
        nmcli.connection.up(profile, wait=45)
    except Exception as e:
        log.warning("wifi activate '%s' failed: %s", profile, _err_detail(e))
        notify("failed", _readable_error(e))
        raise WifiError(_readable_error(e))
    notify("connected", disp)
    return list_networks()


def disconnect():
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
    return list_networks()


def forget(profile):
    _guard_client_profile(profile)
    try:
        nmcli.connection.delete(profile)
    except nmcli.NotExistException:
        pass
    except Exception as e:
        raise WifiError(_readable_error(e))
    return list_networks()


def change_password(profile, password):
    _guard_client_profile(profile)
    try:
        details = nmcli.connection.show(profile)
        if details.get("802-11-wireless-security.key-mgmt") == "none":
            nmcli.connection.modify(profile, {"802-11-wireless-security.wep-key0": password})
        else:
            nmcli.connection.modify(profile, {"802-11-wireless-security.psk": password})
    except Exception as e:
        raise WifiError(_readable_error(e))
    return list_networks()


def set_ip_config(profile, ipconf):
    """Change the IP configuration of an existing (saved) profile."""
    _guard_client_profile(profile)
    if ipconf and ipconf.get("method") == "manual":
        err = validate_ip_config(ipconf.get("ip", ""), ipconf.get("prefix", 0),
                                 ipconf.get("gateway"), ipconf.get("dns"),
                                 occupied_subnets(), local_ip_addresses())
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
    """Allow the operation only on a Wi-Fi CLIENT profile — judged by what the profile
    IS, not by its name: hand-made profiles (plain `nmcli device wifi connect`) lack our
    WiFi_ prefix but are legitimate saved networks the user must be able to manage."""
    if not profile or profile == AP_PROFILE:
        raise WifiError("Not a Wi-Fi client profile: {}".format(profile))
    try:
        details = nmcli.connection.show(profile)
    except nmcli.NotExistException:
        raise WifiError("No such Wi-Fi profile: {}".format(profile))
    if details.get("connection.type") not in ("802-11-wireless", "wifi") or _is_ap(details):
        raise WifiError("Not a Wi-Fi client profile: {}".format(profile))


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
    deadline = time.time() + seconds
    while time.time() < deadline:
        cur = wifi_state()
        if cur != last:
            status_cb("reconnecting" if "connect" in cur["state"] else cur["state"], cur)
            last = cur
        if cur["state"] == "connected":
            break
        time.sleep(interval)


# --------------------------------------------------------------------------
# access point
# --------------------------------------------------------------------------

_AP_KEY_MGMT = {
    # WPA2+WPA3 mixed: NM has no dual key-mgmt; wpa-psk + pmf=optional is the
    # compatible choice (WPA3 clients associate via WPA2). Verify on VM/Pi (план §4).
    "mixed": {"802-11-wireless-security.key-mgmt": "wpa-psk",
              "802-11-wireless-security.pmf": "1"},
    "wpa3": {"802-11-wireless-security.key-mgmt": "sae",
             "802-11-wireless-security.pmf": "3"},
    "wpa2": {"802-11-wireless-security.key-mgmt": "wpa-psk"},
    "open": {},
}


def get_ap_config():
    try:
        details = nmcli.connection.show(AP_PROFILE, show_secrets=True)
    except nmcli.NotExistException:
        return dict(AP_DEFAULTS, enabled=False, configured=False, has_password=False)
    km = details.get("802-11-wireless-security.key-mgmt")
    pmf = details.get("802-11-wireless-security.pmf") or ""
    if km == "sae":
        security = "wpa3"
    elif km == "wpa-psk":
        security = "mixed" if pmf in ("1", "optional") else "wpa2"
    else:
        security = "open"
    band = {"bg": "2.4", "a": "5"}.get(details.get("802-11-wireless.band"), "all")
    addr = details.get("ipv4.addresses") or "{}/{}".format(AP_DEFAULTS["ip"], AP_DEFAULTS["prefix"])
    ip, _, prefix = addr.partition("/")
    chan = details.get("802-11-wireless.channel")
    return {
        "ssid": details.get("802-11-wireless.ssid") or AP_DEFAULTS["ssid"],
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
        "channel": int(chan) if chan and chan.isdigit() else 0,
        "ip": ip, "prefix": int(prefix) if prefix.isdigit() else 24,
        "enabled": get_role() == "ap",
        "configured": True,
    }


def set_ap(config, status_cb=None):
    """Create/update the Hotspot profile and switch the wlan0 role."""
    notify = status_cb or (lambda *a: None)
    enabled = bool(config.get("enabled"))

    # Validation gates TURNING THE AP ON (and saving its settings). Turning it OFF must
    # always be possible — even from an out-of-band state (AP enabled by hand, no region,
    # odd key): otherwise the UI has no way out. On disable with invalid form values we
    # skip saving the settings and only switch the role off.
    profiles = _wifi_profiles()
    # is a key already stored in the profile? (an empty password field means "keep it" —
    # the stored key is never sent to the browser, see get_ap_config)
    stored_key = False
    if AP_PROFILE in profiles:
        try:
            det = nmcli.connection.show(AP_PROFILE, show_secrets=True)
            stored_key = bool(det.get("802-11-wireless-security.psk")
                              or det.get("802-11-wireless-security.sae-password"))
        except Exception:
            pass

    verr = None
    if not get_country():
        verr = "Access Point mode requires a Wi-Fi region (country)"
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
    ip_err = validate_ip_config(ip, prefix, occupied=occupied_subnets())
    verr = verr or ip_err
    if enabled and verr:
        raise WifiError(verr)

    options = {
        "802-11-wireless.mode": "ap",
        "802-11-wireless.ssid": config.get("ssid") or AP_DEFAULTS["ssid"],
        "802-11-wireless.hidden": "yes" if config.get("hidden") else "no",
        "ipv4.method": "shared",
        "ipv4.addresses": "{}/{}".format(ip, prefix),
        "802-11-wireless-security.key-mgmt": "",
        "802-11-wireless-security.pmf": "",
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
            if AP_PROFILE in profiles:
                nmcli.connection.modify(AP_PROFILE, options)
            else:
                add_opts = {k: v for k, v in options.items() if v != ""}
                nmcli.connection.add("wifi", add_opts, WIFI_IFACE, AP_PROFILE,
                                     autoconnect=False)
        except Exception as e:
            raise WifiError(_readable_error(e))

    # role switch = flip autoconnect flags on NM profiles (no settings.conf flag)
    try:
        for name, details in profiles.items():
            if name == AP_PROFILE or _is_ap(details):
                continue
            nmcli.connection.modify(name, {"connection.autoconnect": "no" if enabled else "yes"})
        nmcli.connection.modify(AP_PROFILE, {"connection.autoconnect": "yes" if enabled else "no"})
        if enabled:
            notify("starting", "hotspot")
            nmcli.connection.up(AP_PROFILE, wait=30)
            _set_hotspot_flag(True)
        else:
            if _ap_active():
                try:
                    nmcli.connection.down(AP_PROFILE)
                except Exception:
                    pass
            _set_hotspot_flag(False)
    except Exception as e:
        raise WifiError(_readable_error(e))
    return get_ap_config()


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

# Exact property keys to replicate. A curated allowlist (not a prefix match) — nmcli exposes
# dozens of sibling props whose `show` value is a display artifact ("-1 (default)", "auto",
# per-secret *-flags) that is not valid `nmcli add/modify` input and would break restore.
_BACKUP_KEYS = frozenset({
    "connection.id", "connection.autoconnect",
    "802-11-wireless.ssid", "802-11-wireless.hidden", "802-11-wireless.mode",
    "802-11-wireless.band", "802-11-wireless.channel",
    "802-11-wireless-security.key-mgmt", "802-11-wireless-security.psk",
    "802-11-wireless-security.sae-password", "802-11-wireless-security.pmf",
    "802-11-wireless-security.proto", "802-11-wireless-security.pairwise",
    "802-11-wireless-security.group", "802-11-wireless-security.auth-alg",
    "802-11-wireless-security.wep-key0", "802-11-wireless-security.wep-key-type",
    "802-11-wireless-security.wep-tx-keyidx",
    "802-11-wireless-security.leap-username", "802-11-wireless-security.leap-password",
    "ipv4.method", "ipv4.addresses", "ipv4.gateway", "ipv4.dns",
})


def _backup_value(v):
    """Clean an nmcli-show value for export; None to drop it. nmcli annotates defaults as
    'value (default)', which is not valid input — such fields are dropped (the target uses
    the same default)."""
    if v is None:
        return None
    v = str(v).strip()
    if not v or v.endswith("(default)"):
        return None
    return v


def backup_profiles():
    """Export Wi-Fi profiles (with secrets) for replication to identical stations."""
    out = {"version": 1, "profiles": []}
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
                cv = _backup_value(v)
                if cv is not None:
                    keep[k] = cv
        out["profiles"].append(keep)
    return out


def restore_profiles(data):
    if not isinstance(data, dict) or data.get("version") != 1:
        raise WifiError("Unsupported Wi-Fi backup format")
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
            if k == "connection.id" or k not in _BACKUP_KEYS or v is None:
                continue
            v = str(v).strip()
            if not v or v.endswith("(default)"):
                continue
            options[k] = v
        autoconnect = options.pop("connection.autoconnect", "yes") == "yes"
        try:
            nmcli.connection.delete(name)
        except Exception:
            pass
        try:
            nmcli.connection.add("wifi", options, WIFI_IFACE, name, autoconnect=autoconnect)
            count += 1
        except Exception as e:
            raise WifiError("Restore failed on '{}': {}".format(name, _readable_error(e)))
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
