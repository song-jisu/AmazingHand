#!/usr/bin/env bash
# ah_devices.sh - 연결된 AmazingHand 로봇/카메라를 찾아내서
#                 고정된 이름(/dev/ah, /dev/ahv)으로 매핑한다.
#
#   /dev/ah    ← 로봇 (Feetech 서보 시리얼 어댑터)
#   /dev/ahv   ← 카메라 (실제 영상이 나오는 노드)
#
# 매핑은 udev 규칙으로 만들기 때문에 재부팅하거나 USB를 다른 포트에 꽂아도,
# 카메라가 /dev/video4 든 /dev/video7 이든 상관없이 /dev/ahv 로 잡힙니다.
#
# 사용법:
#   ./ah_devices.sh              # 훑어보기 (= ah_scan)
#   ./ah_devices.sh install      # 지금 연결된 장치로 udev 규칙 설치 (sudo 필요)
#   ./ah_devices.sh status       # /dev/ah, /dev/ahv 상태 확인
#   ./ah_devices.sh uninstall    # 규칙 제거
#
#   source ah_devices.sh         # 함수만 로드해서 직접 쓰고 싶을 때
#   ah_help

# ─────────────────────────────────────────────────────────────
# 설정
# ─────────────────────────────────────────────────────────────
AH_ROBOT_LINK="${AH_ROBOT_LINK:-ah}"     # → /dev/ah
AH_CAM_LINK="${AH_CAM_LINK:-ahv}"        # → /dev/ahv
AH_RULES_FILE="${AH_RULES_FILE:-/etc/udev/rules.d/99-amazinghand.rules}"

# 로봇으로 인정할 USB 시리얼 어댑터 (vendor:product). 흔한 것들을 미리 넣어둡니다.
#   1a86:55d3 CH340 (USB Single Serial)   1a86:7523 CH340G
#   0403:6001 FTDI FT232                  10c4:ea60 CP2102
#   067b:2303 PL2303                      2e8a:*    RP2040 계열
AH_ROBOT_USB_IDS=("1a86:55d3" "1a86:7523" "0403:6001" "10c4:ea60" "067b:2303")

# ─────────────────────────────────────────────────────────────
# 내부 헬퍼
# ─────────────────────────────────────────────────────────────
_ah_red()    { printf '\033[31m%s\033[0m\n' "$*"; }
_ah_green()  { printf '\033[32m%s\033[0m\n' "$*"; }
_ah_yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
_ah_bold()   { printf '\033[1m%s\033[0m\n' "$*"; }

_ah_prop() {
    udevadm info -q property -n "$1" 2>/dev/null | sed -n "s/^$2=//p" | head -n1
}

_ah_dir() {
    local src="${BASH_SOURCE[0]}"
    cd -- "$(dirname -- "$src")" >/dev/null 2>&1 && pwd
}

# 파이썬 인터프리터 찾기 (표준 라이브러리만 쓰므로 시스템 python3 로 충분)
_ah_python() {
    local p
    for p in python3 "$AH_VENV_PYTHON" "$(_ah_dir)/.venv/bin/python"; do
        [[ -n "$p" ]] && command -v "$p" >/dev/null 2>&1 && { command -v "$p"; return 0; }
    done
    return 1
}

# ─────────────────────────────────────────────────────────────
# 탐지 결과가 담기는 전역 변수
#   AH_ROBOT_DEV / AH_ROBOT_VID / AH_ROBOT_PID / AH_ROBOT_SERIAL
#   AH_CAM_DEV   / AH_CAM_VID   / AH_CAM_PID   / AH_CAM_IFACE / AH_CAM_INDEX
# ─────────────────────────────────────────────────────────────

# ah_find_robot - 로봇으로 쓸 시리얼 포트 하나 찾기
ah_find_robot() {
    sudo chmod 666 /dev/ah
    AH_ROBOT_DEV=""; AH_ROBOT_VID=""; AH_ROBOT_PID=""; AH_ROBOT_SERIAL=""
    local dev vid pid known id cands=()

    for dev in /dev/ttyACM* /dev/ttyUSB*; do
        [[ -e "$dev" ]] || continue
        vid=$(_ah_prop "$dev" ID_VENDOR_ID)
        pid=$(_ah_prop "$dev" ID_MODEL_ID)
        known=0
        for id in "${AH_ROBOT_USB_IDS[@]}"; do
            [[ "$vid:$pid" == "$id" ]] && { known=1; break; }
        done
        # 알려진 어댑터를 우선하되, 없으면 아무 시리얼 포트나 후보로
        if [[ $known -eq 1 ]]; then
            cands=("$dev" "${cands[@]}")
        else
            cands+=("$dev")
        fi
    done

    if [[ ${#cands[@]} -eq 0 ]]; then
        _ah_red "✗ 로봇: 시리얼 포트를 찾지 못했습니다 (/dev/ttyACM*, /dev/ttyUSB* 없음)"
        return 1
    fi

    AH_ROBOT_DEV="${cands[0]}"
    AH_ROBOT_VID=$(_ah_prop "$AH_ROBOT_DEV" ID_VENDOR_ID)
    AH_ROBOT_PID=$(_ah_prop "$AH_ROBOT_DEV" ID_MODEL_ID)
    AH_ROBOT_SERIAL=$(_ah_prop "$AH_ROBOT_DEV" ID_SERIAL_SHORT)

    printf '  로봇   %s  usb=%s:%s serial=%s\n' \
        "$AH_ROBOT_DEV" "$AH_ROBOT_VID" "$AH_ROBOT_PID" "${AH_ROBOT_SERIAL:-<없음>}"
    if [[ ${#cands[@]} -gt 1 ]]; then
        _ah_yellow "         (후보가 여러 개: ${cands[*]} → 첫 번째를 씁니다)"
    fi
    return 0
}

# _ah_classify_videos - 각 비디오 노드가 어떤 종류인지 판별해 "<devnode> <종류>" 로 출력
#
#   VIDIOC_ENUM_FMT 로 "지원 픽셀 포맷"만 조회합니다. 스트리밍을 시작하지 않으므로
#   장치를 건드리지 않고, RealSense 처럼 예민한 카메라도 안전합니다.
#     color … YUYV/MJPG 등 일반 영상  ← 우리가 원하는 것
#     depth … Z16                     ← RealSense 깊이
#     ir    … GREY/Y8/Y12             ← RealSense 적외선
#     meta  … 포맷 없음               ← 메타데이터 전용 노드
_ah_classify_videos() {
    local py; py=$(_ah_python) || return 2
    "$py" - "$@" <<'PYEOF' 2>/dev/null
import fcntl, struct, sys, os

VIDIOC_ENUM_FMT = 0xC0405602
V4L2_BUF_TYPE_VIDEO_CAPTURE = 1

COLOR = {"YUYV", "MJPG", "NV12", "NV21", "RGB3", "BGR3", "UYVY", "YU12", "YV12", "H264"}
DEPTH = {"Z16", "RW16", "CONF"}
IR    = {"GREY", "Y8  ", "Y8I ", "Y12I", "Y16 ", "Y10 "}


def fourcc(v):
    return "".join(chr((v >> (8 * i)) & 0xFF) for i in range(4))


def formats(path):
    out = []
    fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
    try:
        for i in range(32):
            buf = bytearray(64)
            struct.pack_into("II", buf, 0, i, V4L2_BUF_TYPE_VIDEO_CAPTURE)
            try:
                fcntl.ioctl(fd, VIDIOC_ENUM_FMT, buf, True)
            except OSError:
                break
            out.append(fourcc(struct.unpack_from("I", buf, 44)[0]))
    finally:
        os.close(fd)
    return out


for path in sys.argv[1:]:
    try:
        fs = formats(path)
    except Exception:
        print(f"{path} unknown")
        continue
    names = {f.strip() for f in fs}
    if not fs:
        kind = "meta"
    elif names & DEPTH:
        kind = "depth"
    elif names & {i.strip() for i in IR}:
        kind = "ir"
    elif names & COLOR:
        kind = "color"
    else:
        kind = "unknown"
    print(f"{path} {kind}")
PYEOF
}

# ah_find_camera - 실제로 영상이 나오는 비디오 노드 찾기
#   RealSense 처럼 /dev/video* 를 여러 개 만드는 장치에서 진짜 스트림만 골라냅니다.
ah_find_camera() {
    AH_CAM_DEV=""; AH_CAM_VID=""; AH_CAM_PID=""; AH_CAM_IFACE=""; AH_CAM_INDEX=""
    local dev caps cands=() line path kind color=() rejected=""

    # 1차: capture 능력이 있는 노드만 후보로
    for dev in /dev/video*; do
        [[ -e "$dev" ]] || continue
        caps=$(_ah_prop "$dev" ID_V4L_CAPABILITIES)
        [[ "$caps" == *capture* ]] || continue
        cands+=("$dev")
    done

    if [[ ${#cands[@]} -eq 0 ]]; then
        _ah_red "✗ 카메라: 비디오 장치를 찾지 못했습니다"
        return 1
    fi

    # 2차: 지원 포맷으로 컬러 영상 노드만 골라낸다 (스트리밍 시작 안 함)
    while read -r path kind; do
        [[ -z "$path" ]] && continue
        if [[ "$kind" == "color" ]]; then
            color+=("$path")
        else
            rejected+=" $path($kind)"
        fi
    done < <(_ah_classify_videos "${cands[@]}")

    if [[ ${#color[@]} -gt 0 ]]; then
        AH_CAM_DEV="${color[0]}"
    else
        AH_CAM_DEV="${cands[0]}"
        _ah_yellow "         (컬러 영상 노드를 특정하지 못해 첫 후보를 씁니다)"
    fi

    AH_CAM_VID=$(_ah_prop "$AH_CAM_DEV" ID_VENDOR_ID)
    AH_CAM_PID=$(_ah_prop "$AH_CAM_DEV" ID_MODEL_ID)
    AH_CAM_IFACE=$(_ah_prop "$AH_CAM_DEV" ID_USB_INTERFACE_NUM)
    AH_CAM_INDEX=$(cat "/sys/class/video4linux/$(basename "$AH_CAM_DEV")/index" 2>/dev/null)

    printf '  카메라 %s  usb=%s:%s if=%s idx=%s%s\n' \
        "$AH_CAM_DEV" "$AH_CAM_VID" "$AH_CAM_PID" "${AH_CAM_IFACE:-?}" "${AH_CAM_INDEX:-0}" \
        "$([[ ${#color[@]} -gt 0 ]] && echo '  (컬러 영상 노드)')"
    [[ ${#color[@]} -gt 1 ]] && _ah_yellow "         (컬러 노드가 여러 개: ${color[*]} → 첫 번째 사용)"
    [[ -n "$rejected" ]] && echo "         제외됨:$rejected"
    return 0
}

# ah_detect - 로봇 + 카메라 둘 다 찾기
ah_detect() {
    local rc=0
    _ah_bold "── 장치 탐지 ──"
    ah_find_robot  || rc=1
    ah_find_camera || rc=1
    return $rc
}

# ─────────────────────────────────────────────────────────────
# ah_scan - 연결된 장치 전부 나열 (진단용)
# ─────────────────────────────────────────────────────────────
ah_scan() {
    _ah_bold "── 시리얼 포트 ──"
    local dev vid pid serial iface idx caps name found=0
    for dev in /dev/ttyACM* /dev/ttyUSB*; do
        [[ -e "$dev" ]] || continue
        found=1
        vid=$(_ah_prop "$dev" ID_VENDOR_ID); pid=$(_ah_prop "$dev" ID_MODEL_ID)
        serial=$(_ah_prop "$dev" ID_SERIAL_SHORT)
        printf '  %-14s usb=%s:%s serial=%-16s ' "$dev" "$vid" "$pid" "${serial:-<없음>}"
        [[ -r "$dev" && -w "$dev" ]] && _ah_green "접근가능" || _ah_red "권한없음"
    done
    [[ $found -eq 0 ]] && echo "  (없음)"

    echo; _ah_bold "── 비디오 장치 ──"
    found=0
    for dev in /dev/video*; do
        [[ -e "$dev" ]] || continue
        found=1
        vid=$(_ah_prop "$dev" ID_VENDOR_ID); pid=$(_ah_prop "$dev" ID_MODEL_ID)
        iface=$(_ah_prop "$dev" ID_USB_INTERFACE_NUM)
        caps=$(_ah_prop "$dev" ID_V4L_CAPABILITIES)
        idx=$(cat "/sys/class/video4linux/$(basename "$dev")/index" 2>/dev/null)
        name=$(cat "/sys/class/video4linux/$(basename "$dev")/name" 2>/dev/null)
        printf '  %-14s usb=%s:%s if=%-3s idx=%-3s caps=%-12s %s\n' \
            "$dev" "$vid" "$pid" "${iface:-?}" "${idx:-?}" "${caps:-?}" "$name"
    done
    [[ $found -eq 0 ]] && echo "  (없음)"

    echo; ah_detect
}

# ─────────────────────────────────────────────────────────────
# ah_rules - 탐지 결과로 udev 규칙 생성 (설치는 안 함)
# ─────────────────────────────────────────────────────────────
ah_rules() {
    [[ -z "$AH_ROBOT_DEV" && -z "$AH_CAM_DEV" ]] && { ah_detect >/dev/null 2>&1; }

    echo "# AmazingHand device mapping"
    echo "# generated by ah_devices.sh"
    echo "#   /dev/$AH_ROBOT_LINK  ← 로봇,  /dev/$AH_CAM_LINK ← 카메라"
    echo

    if [[ -n "$AH_ROBOT_DEV" ]]; then
        local r="SUBSYSTEM==\"tty\""
        [[ -n "$AH_ROBOT_VID" ]] && r+=", ATTRS{idVendor}==\"$AH_ROBOT_VID\""
        [[ -n "$AH_ROBOT_PID" ]] && r+=", ATTRS{idProduct}==\"$AH_ROBOT_PID\""
        # 시리얼이 있으면 그 장치 하나만 정확히 지목한다
        [[ -n "$AH_ROBOT_SERIAL" ]] && r+=", ATTRS{serial}==\"$AH_ROBOT_SERIAL\""
        r+=", SYMLINK+=\"$AH_ROBOT_LINK\", MODE=\"0660\", GROUP=\"dialout\", TAG+=\"uaccess\""
        echo "$r"
    fi

    if [[ -n "$AH_CAM_DEV" ]]; then
        local c="SUBSYSTEM==\"video4linux\""
        [[ -n "$AH_CAM_VID" ]] && c+=", ATTRS{idVendor}==\"$AH_CAM_VID\""
        [[ -n "$AH_CAM_PID" ]] && c+=", ATTRS{idProduct}==\"$AH_CAM_PID\""
        # 카메라가 video 노드를 여러 개 만들 때, 영상이 나오는 그 노드만 지목
        [[ -n "$AH_CAM_IFACE" ]] && c+=", ENV{ID_USB_INTERFACE_NUM}==\"$AH_CAM_IFACE\""
        c+=", ATTR{index}==\"${AH_CAM_INDEX:-0}\""
        c+=", SYMLINK+=\"$AH_CAM_LINK\", MODE=\"0660\", GROUP=\"video\", TAG+=\"uaccess\""
        echo "$c"
    fi
}

# ─────────────────────────────────────────────────────────────
# ah_install - 규칙을 설치하고 즉시 적용
# ─────────────────────────────────────────────────────────────
ah_install() {
    ah_detect || { _ah_red "장치를 못 찾아서 설치를 중단합니다."; return 1; }

    echo
    _ah_bold "── 설치할 규칙 ($AH_RULES_FILE) ──"
    local rules; rules=$(ah_rules)
    echo "$rules" | sed 's/^/  /'
    echo

    if [[ -e "$AH_RULES_FILE" ]]; then
        _ah_yellow "기존 파일을 덮어씁니다: $AH_RULES_FILE"
    fi
    echo "sudo 권한이 필요합니다."
    printf '%s\n' "$rules" | sudo tee "$AH_RULES_FILE" >/dev/null || {
        _ah_red "✗ 규칙 파일을 쓰지 못했습니다."; return 1; }

    sudo udevadm control --reload-rules && sudo udevadm trigger || {
        _ah_red "✗ udev 반영에 실패했습니다."; return 1; }

    # 심볼릭 링크가 생길 때까지 잠깐 기다린다
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [[ -e "/dev/$AH_ROBOT_LINK" && -e "/dev/$AH_CAM_LINK" ]] && break
        sleep 0.3
    done

    echo
    ah_status
}

# ─────────────────────────────────────────────────────────────
# ah_uninstall - 규칙 제거
# ─────────────────────────────────────────────────────────────
ah_uninstall() {
    [[ -e "$AH_RULES_FILE" ]] || { _ah_yellow "설치된 규칙이 없습니다: $AH_RULES_FILE"; return 0; }
    sudo rm -f "$AH_RULES_FILE" || return 1
    sudo udevadm control --reload-rules && sudo udevadm trigger
    _ah_green "✓ 규칙을 제거했습니다: $AH_RULES_FILE"
}

# ─────────────────────────────────────────────────────────────
# ah_status - /dev/ah, /dev/ahv 확인
# ─────────────────────────────────────────────────────────────
_ah_report_link() {
    local link="/dev/$1" label="$2"
    printf '  %-10s %s ' "$link" "($label)"
    if [[ ! -e "$link" ]]; then
        _ah_red "없음 (장치 미연결이거나 규칙 미설치)"
        return 1
    fi
    local target; target=$(readlink -f "$link")
    printf '→ %-14s ' "$target"
    if [[ -r "$link" && -w "$link" ]]; then _ah_green "OK"; return 0
    else _ah_red "권한없음"; return 1; fi
}

ah_status() {
    _ah_bold "── 매핑 상태 ──"
    local rc=0
    _ah_report_link "$AH_ROBOT_LINK" "로봇"   || rc=1
    _ah_report_link "$AH_CAM_LINK"   "카메라" || rc=1

    echo
    if [[ -e "$AH_RULES_FILE" ]]; then
        _ah_green "규칙 설치됨: $AH_RULES_FILE"
    else
        _ah_yellow "규칙 없음: $AH_RULES_FILE  →  ./ah_devices.sh install"
    fi

    if [[ $rc -ne 0 && -e "/dev/$AH_ROBOT_LINK" && ! -w "/dev/$AH_ROBOT_LINK" ]]; then
        echo
        _ah_yellow "시리얼 권한이 없다면:  sudo usermod -aG dialout $USER  (로그아웃 후 적용)"
    fi
    return $rc
}

# ─────────────────────────────────────────────────────────────
# ah_check - 권한 점검
# ─────────────────────────────────────────────────────────────
ah_check() {
    local rc=0
    _ah_bold "── 권한 ──"
    if id -nG | tr ' ' '\n' | grep -qx dialout; then
        _ah_green "  ✓ $USER 는 dialout 그룹 (시리얼 접근 가능)"
    else
        _ah_red   "  ✗ $USER 는 dialout 그룹이 아님"
        echo      "      sudo usermod -aG dialout $USER   # 로그아웃/로그인 후 적용"
        rc=1
    fi
    id -nG | tr ' ' '\n' | grep -qx video \
        && _ah_green "  ✓ $USER 는 video 그룹" \
        || _ah_yellow "  · $USER 는 video 그룹이 아님 (데스크톱 세션이면 ACL 로 접근될 수 있음)"

    echo; _ah_bold "── 실제 접근 ──"
    local dev
    for dev in "/dev/$AH_ROBOT_LINK" "/dev/$AH_CAM_LINK"; do
        [[ -e "$dev" ]] || { printf '  '; _ah_yellow "· $dev (아직 없음)"; continue; }
        if [[ -r "$dev" && -w "$dev" ]]; then printf '  '; _ah_green "✓ $dev"
        else printf '  '; _ah_red "✗ $dev"; rc=1; fi
    done
    return $rc
}

# ─────────────────────────────────────────────────────────────
# ah_help
# ─────────────────────────────────────────────────────────────
ah_help() {
    cat <<EOF
AmazingHand 장치 매핑

  ./ah_devices.sh              연결된 장치 훑어보기
  ./ah_devices.sh install      udev 규칙 설치 → /dev/$AH_ROBOT_LINK, /dev/$AH_CAM_LINK 생성 (sudo)
  ./ah_devices.sh status       매핑 상태 확인
  ./ah_devices.sh check        권한 점검
  ./ah_devices.sh rules        설치할 규칙만 출력 (설치 안 함)
  ./ah_devices.sh uninstall    규칙 제거 (sudo)

source 해서 함수로 쓸 수도 있습니다:
  ah_scan  ah_detect  ah_rules  ah_install  ah_uninstall  ah_status  ah_check
  ah_find_robot  ah_find_camera

이름을 바꾸려면:
  AH_ROBOT_LINK=myhand AH_CAM_LINK=mycam ./ah_devices.sh install
EOF
}

# ─────────────────────────────────────────────────────────────
# 직접 실행했을 때의 서브커맨드
# ─────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-scan}" in
        scan|"")   ah_scan ;;
        detect)    ah_detect ;;
        rules)     ah_rules ;;
        install)   ah_install ;;
        uninstall) ah_uninstall ;;
        status)    ah_status ;;
        check)     ah_check ;;
        help|-h|--help) ah_help ;;
        *) _ah_red "알 수 없는 명령: $1"; echo; ah_help; exit 2 ;;
    esac
fi
