#!/usr/bin/env python3
"""Flight recorder for unexplained freezes and resets.

Every INTERVAL seconds it appends one line to /var/log/blackbox.log and fsyncs it, so the
last line on disk is at most INTERVAL seconds older than a hard freeze. Each line has: time,
uptime, load, available memory, swap used, temperatures, fan PWM, the process using most CPU
since the previous line, the process holding most memory, and the newest command line started.

Install: see blackbox.service next to this file. Read: tail /var/log/blackbox.log
"""
import os, time, glob

LOG = "/var/log/blackbox.log"
INTERVAL = 5
MAX_BYTES = 5 * 1024 * 1024
HZ = os.sysconf("SC_CLK_TCK")
PAGE = os.sysconf("SC_PAGE_SIZE")


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def meminfo():
    d = {}
    for line in read("/proc/meminfo").splitlines():
        k, v = line.split(":", 1)
        d[k] = int(v.split()[0]) // 1024
    return d


def temps():
    out = []
    for z in sorted(glob.glob("/sys/class/thermal/thermal_zone*")):
        name, t = read(z + "/type"), read(z + "/temp")
        if name and t.lstrip("-").isdigit() and name != "thermal-fan-est" and "fan" not in name:
            out.append("%s=%d" % (name.replace("-therm", ""), int(t) // 1000))
    return ",".join(out)


def fan():
    for path in glob.glob("/sys/devices/platform/pwm-fan/hwmon/hwmon*/pwm1"):
        return read(path, "?")
    return "?"


def processes():
    """pid -> (comm, cpu ticks, rss MiB, start ticks)"""
    procs = {}
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        s = read("/proc/%s/stat" % p)
        if not s:
            continue
        try:
            comm = s[s.index("(") + 1:s.rindex(")")]
            f = s[s.rindex(")") + 2:].split()
            procs[int(p)] = (comm, int(f[11]) + int(f[12]), int(f[21]) * PAGE // 1048576, int(f[19]))
        except (ValueError, IndexError):
            pass
    return procs


def cmdline(pid):
    return read("/proc/%d/cmdline" % pid).replace("\0", " ").strip()[:160]


def write(f, text):
    f.write(text + "\n")
    f.flush()
    os.fsync(f.fileno())


def main():
    f = open(LOG, "a")
    pmc = glob.glob("/sys/devices/platform/*pmc*/reset_reason")
    write(f, "%s START boot=%s reset_reason=%s" % (time.strftime("%F %T"), read("/proc/sys/kernel/random/boot_id")[:8],
                                                   read(pmc[0]) if pmc else "?"))
    prev = processes()
    me = os.getpid()
    while True:
        time.sleep(INTERVAL)
        cur = processes()
        m = meminfo()
        busiest, ticks = None, 0
        for pid, (comm, cpu, rss, start) in cur.items():
            d = cpu - prev[pid][1] if pid in prev and prev[pid][3] == start else cpu
            if d > ticks and pid != me:
                busiest, ticks = pid, d
        biggest = max(cur, key=lambda p: cur[p][2]) if cur else None
        new = [p for p in cur if p not in prev and p != me]
        newest = max(new, key=lambda p: cur[p][3]) if new else None
        line = "%s up=%s load=%s avail=%dM swap=%dM temp=%s fan=%s procs=%d" % (
            time.strftime("%F %T"), read("/proc/uptime").split(".")[0], read("/proc/loadavg").split()[0],
            m.get("MemAvailable", 0), m.get("SwapTotal", 0) - m.get("SwapFree", 0), temps(),
            fan(), len(cur))
        if busiest:
            line += " cpu=%s[%d]:%d%%" % (cur[busiest][0], busiest, 100 * ticks // (HZ * INTERVAL))
        if biggest:
            line += " mem=%s[%d]:%dM" % (cur[biggest][0], biggest, cur[biggest][2])
        if newest:
            line += " new(%d)=[%d] %s" % (len(new), newest, cmdline(newest) or cur[newest][0])
        write(f, line)
        prev = cur
        if f.tell() > MAX_BYTES:
            f.close()
            os.replace(LOG, LOG + ".1")
            f = open(LOG, "a")


if __name__ == "__main__":
    main()
