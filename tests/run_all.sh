#!/bin/bash
# End-to-end check of a Jetson Xavier NX set up as in this repository:
# system state, storage, native C/C++/CUDA programs (CPU cores and NEON, CUDA, cuBLAS,
# cuFFT, cuRAND, cuDNN, TensorRT on GPU and both DLAs, OpenCV CUDA, VPI on CUDA and PVA),
# the same stack from Python (PyTorch, torchvision, TensorRT, OpenCV, VPI), the hardware
# multimedia engines (NVENC, NVDEC, NVJPG, VIC) through GStreamer, and board interfaces.
#
#   ./run_all.sh              run everything
#   ./run_all.sh --no-sudo    skip the checks that need root (SMART, kernel log, boot slots)
#
# Nothing here writes to a disk outside a temporary directory, and nothing changes
# system settings. Takes about 4 minutes, plus a minute to compile on the first run. Exit code 0 means no test failed.
# Written for Jetson Linux 35.x (JetPack 5). Other Jetsons will work for most of it.

cd "$(dirname "$0")" || exit 1
export PATH=/usr/local/cuda/bin:$PATH
USE_SUDO=1; [ "$1" = "--no-sudo" ] && USE_SUDO=0
T=$(mktemp -d /tmp/jetson_tests.XXXXXX); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0; SKIP=0

report() {  # status name detail
  printf "%-4s  %-38s %s\n" "$1" "$2" "$3"
  case $1 in PASS) PASS=$((PASS+1));; FAIL) FAIL=$((FAIL+1));; SKIP) SKIP=$((SKIP+1));; esac
}
section() { printf "\n== %s\n" "$1"; }
root() { if [ $USE_SUDO = 1 ]; then sudo -n "$@" 2>/dev/null; else return 99; fi; }
have_root() { [ $USE_SUDO = 1 ] && sudo -n true 2>/dev/null; }

# ------------------------------------------------------------------ system
section "System"
if [ -f /etc/nv_tegra_release ]; then
  report PASS l4t_release "$(head -1 /etc/nv_tegra_release | sed 's/^# //; s/, GCID.*//')"
else
  report FAIL l4t_release "/etc/nv_tegra_release not found: is this a Jetson?"
fi
report PASS model "$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"
report PASS root_device "$(findmnt -no SOURCE,FSTYPE,SIZE / | tr -s ' ')"
report PASS cpu_cores_online "$(nproc) of $(grep -c ^processor /proc/cpuinfo) online"

if have_root; then
  M=$(root nvpmodel -q | head -1 | sed 's/NV Power Mode: //')
  report PASS power_mode "$M"
else
  report SKIP power_mode "needs root"
fi

HOT=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)
if [ -n "$HOT" ] && [ "$HOT" -lt 85000 ]; then
  report PASS temperature "hottest zone $((HOT/1000)) C"
else
  report FAIL temperature "hottest zone $((HOT/1000)) C (limit used here: 85 C)"
fi

AV=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo); TOT=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
if [ "$AV" -gt 1500 ]; then report PASS memory_available "$AV MiB of $TOT MiB"
else report FAIL memory_available "only $AV MiB of $TOT MiB free: GPU tests may fail for lack of memory"; fi

if have_root; then
  S=$(root nvbootctrl dump-slots-info 2>/dev/null | grep -c "status: normal")
  if [ "$S" -ge 1 ]; then report PASS boot_slots "$S slot(s) in status normal"
  else report FAIL boot_slots "no boot slot reports status normal"; fi
else
  report SKIP boot_slots "needs root"
fi

F=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
if [ "$F" -eq 0 ]; then report PASS systemd_units "no failed units"
else report FAIL systemd_units "$F failed unit(s): $(systemctl --failed --no-legend | awk '{print $1}' | tr '\n' ' ')"; fi

# ------------------------------------------------------------------ storage
section "Storage"
if [ -e /dev/nvme0 ]; then
  if have_root && command -v nvme >/dev/null; then
    SM=$(root nvme smart-log /dev/nvme0)
    CW=$(echo "$SM" | awk -F: '/critical_warning/{gsub(/ /,"",$2); print $2}')
    ME=$(echo "$SM" | awk -F: '/media_errors/{gsub(/ /,"",$2); print $2}')
    PU=$(echo "$SM" | awk -F: '/percentage_used/{gsub(/ /,"",$2); print $2}')
    if [ "$CW" = "0" ] && [ "$ME" = "0" ]; then report PASS nvme_smart "no warnings, 0 media errors, wear $PU"
    else report FAIL nvme_smart "critical_warning=$CW media_errors=$ME"; fi
  else
    report SKIP nvme_smart "needs root and nvme-cli (sudo apt install nvme-cli)"
  fi
  if have_root; then
    A=$(root dmesg | grep -c "PCIe Bus Error"); R=$(root dmesg | grep -c "frozen state"); I=$(root dmesg | grep -c "I/O error")
    if [ "$A" = 0 ] && [ "$R" = 0 ] && [ "$I" = 0 ]; then report PASS nvme_link_errors "0 AER, 0 controller resets, 0 I/O errors since boot"
    else report FAIL nvme_link_errors "since boot: $A AER, $R controller resets, $I I/O errors (see docs/02-nvme-ssd.md)"; fi
    L=$(root lspci -vv 2>/dev/null | awk '/Non-Volatile memory controller/{f=1} f && /LnkSta:/{print $2,$3,$4,$5,$6; exit}')
    [ -n "$L" ] && report PASS nvme_link_speed "$L"
  else
    report SKIP nvme_link_errors "needs root"
  fi
else
  report SKIP nvme "no NVMe drive present"
fi

# ------------------------------------------------------------------ native code
section "Native code: C, C++ and CUDA (tests/native)"
# Run a command that prints result lines, show them and add them to the totals.
# (Reads from a file, not a pipe, so the counters are updated in this shell.)
run_counted() {
  "$@" >"$T/out.txt" 2>"$T/err.txt"; RC=$?
  while IFS= read -r line; do
    case "$line" in
      PASS*) PASS=$((PASS+1)); echo "$line";; FAIL*) FAIL=$((FAIL+1)); echo "$line";; SKIP*) SKIP=$((SKIP+1)); echo "$line";;
    esac
  done < "$T/out.txt"
  return $RC
}
if command -v nvcc >/dev/null && command -v make >/dev/null; then
  make -C native >"$T/make.log" 2>&1
  for B in cpu_openmp_neon cuda_basics cuda_libs cudnn_conv tensorrt_engine opencv_cuda vpi_backends; do
    if [ -x native/$B ]; then
      QUIET_TRT=1 run_counted timeout 300 native/$B
      [ $RC -ge 124 ] && report FAIL "$B" "crashed or timed out: $(tail -1 "$T/err.txt" | cut -c1-120)"
    else
      report FAIL "$B" "did not compile: $(grep -m1 -iE "error|No such file" native/build_$B.log 2>/dev/null | cut -c1-120)"
    fi
  done
else
  report FAIL native_toolchain "nvcc or make not found (install nvidia-cuda-dev, build-essential; add /usr/local/cuda/bin to PATH)"
fi

# ------------------------------------------------------------------ Python stack
section "Python GPU stack"
# One process per group: the accelerator runtimes are more reliable when not sharing a process.
for G in numpy cudnn torch_ torchvision tensorrt opencv vpi; do
  run_counted timeout 600 python3 test_python_stack.py $G
  [ $RC -ge 124 ] && report FAIL "python_$G" "crashed or timed out: $(tail -1 "$T/err.txt" | cut -c1-120)"
done

# ------------------------------------------------------------------ multimedia engines
section "Hardware multimedia engines (GStreamer)"
gst() {  # name, pipeline...   runs with a timeout and reports PASS/FAIL
  local name=$1; shift
  if timeout 60 gst-launch-1.0 -q "$@" >"$T/gst.log" 2>&1; then return 0
  else LASTERR=$(grep -iE "error|not found|no element" "$T/gst.log" | head -1 | cut -c1-150); return 1; fi
}
has() { gst-inspect-1.0 "$1" >/dev/null 2>&1; }
SRC="videotestsrc num-buffers=90 ! video/x-raw,width=1920,height=1080,framerate=30/1"

if ! command -v gst-launch-1.0 >/dev/null; then
  report SKIP gstreamer "gst-launch-1.0 not installed"
else
  # VIC: nvvidconv scaling and colour conversion in hardware buffers
  if has nvvidconv; then
    if gst vic $SRC ! nvvidconv ! 'video/x-raw(memory:NVMM),width=1280,height=720,format=NV12' ! nvvidconv ! video/x-raw,format=I420 ! filesink location="$T/vic.yuv"; then
      SZ=$(stat -c %s "$T/vic.yuv"); EXP=$((1280*720*3/2*90))
      if [ "$SZ" = "$EXP" ]; then report PASS vic_scale_convert "90 frames 1080p to 720p, $SZ bytes as expected"
      else report FAIL vic_scale_convert "output is $SZ bytes, expected $EXP"; fi
    else report FAIL vic_scale_convert "$LASTERR"; fi
  else report SKIP vic_scale_convert "nvvidconv element not found"; fi

  # NVENC + NVDEC round trip, H.264 and H.265
  for C in h264 h265; do
    if ! has ${C}parse; then
      report SKIP nvenc_${C} "needs ${C}parse: sudo apt install gstreamer1.0-plugins-bad"
      report SKIP nvdec_${C} "needs ${C}parse: sudo apt install gstreamer1.0-plugins-bad"
    elif has nvv4l2${C}enc && has nvv4l2decoder; then
      if gst enc $SRC ! nvvidconv ! 'video/x-raw(memory:NVMM),format=NV12' ! nvv4l2${C}enc bitrate=4000000 ! ${C}parse ! filesink location="$T/v.$C"; then
        SZ=$(stat -c %s "$T/v.$C")
        if [ "$SZ" -gt 10000 ]; then report PASS nvenc_${C} "90 frames 1080p encoded, $((SZ/1024)) KiB"
        else report FAIL nvenc_${C} "encoded file is only $SZ bytes"; fi
        if gst dec filesrc location="$T/v.$C" ! ${C}parse ! nvv4l2decoder ! nvvidconv ! video/x-raw,format=I420 ! filesink location="$T/dec.yuv"; then
          N=$(( $(stat -c %s "$T/dec.yuv") / (1920*1080*3/2) ))
          if [ "$N" -ge 85 ]; then report PASS nvdec_${C} "$N of 90 frames decoded"
          else report FAIL nvdec_${C} "only $N of 90 frames decoded"; fi
        else report FAIL nvdec_${C} "$LASTERR"; fi
      else report FAIL nvenc_${C} "$LASTERR"; report SKIP nvdec_${C} "no encoded stream to decode"; fi
    else report SKIP nvenc_${C} "nvv4l2${C}enc or nvv4l2decoder not found"; fi
  done

  # NVJPG round trip
  if has nvjpegenc && has nvjpegdec; then
    if gst jpgenc videotestsrc num-buffers=1 ! video/x-raw,width=1920,height=1080,format=I420 ! nvjpegenc ! filesink location="$T/f.jpg"; then
      if head -c 2 "$T/f.jpg" | od -An -tx1 | grep -q "ff d8"; then report PASS nvjpg_encode "1080p JPEG, $(( $(stat -c %s "$T/f.jpg") / 1024 )) KiB"
      else report FAIL nvjpg_encode "output is not a JPEG"; fi
      if gst jpgdec filesrc location="$T/f.jpg" ! jpegparse ! nvjpegdec ! video/x-raw,format=I420 ! filesink location="$T/j.yuv"; then
        SZ=$(stat -c %s "$T/j.yuv")
        if [ "$SZ" = $((1920*1080*3/2)) ]; then report PASS nvjpg_decode "decoded back to a full 1080p frame"
        else report FAIL nvjpg_decode "decoded frame is $SZ bytes"; fi
      else report FAIL nvjpg_decode "$LASTERR"; fi
    else report FAIL nvjpg_encode "$LASTERR"; report SKIP nvjpg_decode "no JPEG to decode"; fi
  else report SKIP nvjpg "nvjpegenc or nvjpegdec not found"; fi

  # ISP: only with a CSI camera attached
  if ls /dev/video* >/dev/null 2>&1 && has nvarguscamerasrc; then
    if gst cam nvarguscamerasrc num-buffers=30 ! 'video/x-raw(memory:NVMM),width=1280,height=720' ! nvvidconv ! video/x-raw,format=I420 ! filesink location="$T/cam.yuv"; then
      N=$(( $(stat -c %s "$T/cam.yuv") / (1280*720*3/2) ))
      if [ "$N" -ge 25 ]; then report PASS csi_camera_isp "$N frames captured through the ISP"
      else report FAIL csi_camera_isp "only $N frames captured"; fi
    else report FAIL csi_camera_isp "$LASTERR"; fi
  else
    report SKIP csi_camera_isp "no camera detected (/dev/video* absent)"
  fi
fi

# ------------------------------------------------------------------ interfaces
section "Board interfaces (presence only)"
E=$(cat /sys/class/net/eth0/speed 2>/dev/null)
if [ -n "$E" ] && [ "$E" -gt 0 ] 2>/dev/null; then report PASS ethernet_link "eth0 up at $E Mb/s"
else report SKIP ethernet_link "eth0 has no link"; fi
U=$(ls /sys/bus/usb/devices 2>/dev/null | grep -c "^usb")
if [ "$U" -ge 1 ]; then report PASS usb_host "$U root hub(s), $(lsusb 2>/dev/null | wc -l) device(s) listed"
else report FAIL usb_host "no USB root hub found"; fi
I=$(ls /dev/i2c-* 2>/dev/null | wc -l)
if [ "$I" -ge 1 ]; then report PASS i2c_buses "$I bus(es) exposed in /dev"; else report FAIL i2c_buses "no /dev/i2c-* devices"; fi
G=$(ls -d /sys/class/gpio/gpiochip* 2>/dev/null | wc -l)
if [ "$G" -ge 1 ]; then report PASS gpio_chips "$G GPIO controller(s)"; else report FAIL gpio_chips "no GPIO controller in /sys/class/gpio"; fi
FP=$(cat /sys/class/hwmon/hwmon*/pwm1 2>/dev/null | head -1)
if [ -n "$FP" ]; then report PASS fan_pwm "fan PWM readable, now $FP of 255"; else report SKIP fan_pwm "no PWM fan node"; fi

# ------------------------------------------------------------------ summary
printf "\n== Summary: %d passed, %d failed, %d skipped\n" $PASS $FAIL $SKIP
[ $FAIL -eq 0 ]
