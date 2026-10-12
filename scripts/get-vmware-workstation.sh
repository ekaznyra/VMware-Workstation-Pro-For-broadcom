#!/usr/bin/env bash
#
# Tải VMware Workstation Pro / VMware Fusion từ mirror Archive.org
# (vĩnh viễn, không cần tài khoản) và tự động kiểm tra MD5.
#
# Cách dùng:
#   ./get-vmware-workstation.sh                           # menu tương tác (Linux)
#   ./get-vmware-workstation.sh --list                    # liệt kê phiên bản Linux
#   ./get-vmware-workstation.sh --platform macos --list   # liệt kê phiên bản macOS Fusion
#   ./get-vmware-workstation.sh --platform windows --list # liệt kê phiên bản Windows
#   ./get-vmware-workstation.sh --version 26H1            # tải thẳng bản 26H1
#   ./get-vmware-workstation.sh --out ~/Downloads --version 17.6.4
#
set -euo pipefail

ITEM="vmwareworkstationarchive"
METADATA_URL="https://archive.org/metadata/${ITEM}"
DOWNLOAD_BASE="https://archive.org/download/${ITEM}"

VERSION=""
OUTDIR="${PWD}"
LIST_ONLY=0

# Tự động nhận diện hệ điều hành mặc định (macOS -> macos, Linux -> linux)
if [[ "$(uname -s)" == "Darwin" ]]; then
    PLATFORM="macos"
else
    PLATFORM="linux"
fi

usage() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --platform|-p) PLATFORM="${2:-}"; shift 2 ;;
        --version|-v)  VERSION="${2:-}"; shift 2 ;;
        --out|-o)      OUTDIR="${2:-}"; shift 2 ;;
        --list|-l)     LIST_ONLY=1; shift ;;
        --help|-h)     usage ;;
        *) echo "Tham số không hợp lệ: $1" >&2; exit 1 ;;
    esac
done

command -v curl >/dev/null 2>&1 || { echo "Cần cài 'curl'." >&2; exit 1; }

# Chuẩn hoá platform
PLATFORM="$(echo "$PLATFORM" | tr '[:upper:]' '[:lower:]')"
case "$PLATFORM" in
    linux)                   PLAT_LABEL="Linux" ;;
    windows|win)             PLAT_LABEL="Windows"; PLATFORM="windows" ;;
    macos|darwin|fusion|mac) PLAT_LABEL="macOS"; PLATFORM="macos" ;;
    *) echo "Platform không hợp lệ: $PLATFORM (hỗ trợ: linux, windows, macos)" >&2; exit 1 ;;
esac

# --- Lấy catalog: in ra các dòng "path<TAB>md5<TAB>size<TAB>ver<TAB>leaf" sắp xếp mới nhất lên đầu ---
fetch_catalog() {
    local tmp_json
    tmp_json="$(mktemp 2>/dev/null || echo "/tmp/archive_meta_$$.json")"
    trap 'rm -f "$tmp_json"' RETURN

    curl -fsSL "$METADATA_URL" -o "$tmp_json"

    local py_bin=""
    if command -v python3 >/dev/null 2>&1; then
        py_bin="python3"
    elif command -v python >/dev/null 2>&1; then
        py_bin="python"
    fi

    if [[ -n "$py_bin" ]]; then
        "$py_bin" - "$PLATFORM" "$tmp_json" <<'PYEOF'
import sys, json, re

platform = sys.argv[1].lower()
json_file = sys.argv[2]

with open(json_file, 'r', encoding='utf-8', errors='ignore') as f:
    data = json.load(f)

def parse_entry(f):
    name = f.get("name", "")
    if platform == "linux":
        if not name.endswith(".bundle") or "orkstation" not in name or not re.search(r"(^|/)Linux/", name):
            return None
    elif platform == "windows":
        if not name.endswith(".exe") or "orkstation" not in name or re.search(r"(^|/)Linux/", name):
            return None
    elif platform in ("macos", "darwin", "fusion"):
        if not name.endswith(".dmg") or not re.search(r"(^|/)Fusion/", name):
            return None

    leaf = name.split("/")[-1]
    m_h = re.search(r"-(\d{2}H\d(?:u\d)?)-", leaf)
    m_v = re.search(r"-(\d+\.\d+\.\d+)-", leaf)
    if m_h:
        ver = m_h.group(1)
        sort_key = (3, ver)
    elif m_v:
        ver = m_v.group(1)
        try:
            parts = [int(x) for x in ver.split(".")]
        except Exception:
            parts = [0, 0, 0]
        sort_key = (2, parts)
    else:
        ver = leaf
        sort_key = (1, [0])

    return (sort_key, name, f.get("md5", ""), str(f.get("size", "0")), ver, leaf)

items = [parse_entry(f) for f in data.get("files", [])]
items = [x for x in items if x is not None]
items.sort(key=lambda x: x[0], reverse=True)

for _, path, md5, size, ver, leaf in items:
    print(f"{path}\t{md5}\t{size}\t{ver}\t{leaf}")
PYEOF
    elif command -v jq >/dev/null 2>&1; then
        # Fallback jq cho Linux nếu không có Python
        jq -r --arg p "$PLATFORM" '
            .files[]
            | select(
                if $p == "linux" then (.name | test("\\.bundle$") and test("orkstation") and test("(^|/)Linux/"))
                elif $p == "windows" then (.name | test("\\.exe$") and test("orkstation") and (test("(^|/)Linux/") | not))
                else (.name | test("\\.dmg$") and test("(^|/)Fusion/")) end
            )
            | [.name, .md5, (.size|tostring), (.name | split("/")[-1]), (.name | split("/")[-1])] | @tsv' "$tmp_json"
    else
        echo "Cần 'python3', 'python' hoặc 'jq' để phân tích metadata." >&2
        exit 1
    fi
}

echo "Đang lấy danh sách $PLAT_LABEL từ Archive.org..." >&2
mapfile -t LINES < <(fetch_catalog)
[[ ${#LINES[@]} -gt 0 ]] || { echo "Không tìm thấy phiên bản nào cho $PLAT_LABEL." >&2; exit 1; }

# Mảng song song
declare -a P_PATH P_MD5 P_SIZE P_VER P_LEAF
for line in "${LINES[@]}"; do
    IFS=$'\t' read -r path md5 size ver leaf <<<"$line"
    P_PATH+=("$path"); P_MD5+=("$md5"); P_SIZE+=("$size")
    P_VER+=("$ver"); P_LEAF+=("$leaf")
done

human_mb() { awk "BEGIN{ printf \"%.2f\", ${1:-0}/1048576 }"; }

if [[ $LIST_ONLY -eq 1 ]]; then
    echo
    echo "Các phiên bản $PLAT_LABEL có sẵn:"
    for i in "${!P_VER[@]}"; do
        printf '%3d. %-10s %8s MB  %s\n' "$((i+1))" "${P_VER[$i]}" "$(human_mb "${P_SIZE[$i]}")" "${P_LEAF[$i]}"
    done
    exit 0
fi

idx=-1
if [[ -n "$VERSION" ]]; then
    for i in "${!P_VER[@]}"; do
        if [[ "${P_VER[$i],,}" == "${VERSION,,}" ]]; then idx=$i; break; fi
    done
    if [[ $idx -lt 0 ]]; then
        echo "Không tìm thấy phiên bản '$VERSION'. Dùng --list để xem danh sách." >&2
        exit 1
    fi
else
    echo
    echo "Các phiên bản $PLAT_LABEL có sẵn:"
    for i in "${!P_VER[@]}"; do
        printf '%3d. %-10s %8s MB  %s\n' "$((i+1))" "${P_VER[$i]}" "$(human_mb "${P_SIZE[$i]}")" "${P_LEAF[$i]}"
    done
    echo
    read -rp "Chọn số (1-${#P_VER[@]}, mặc định 1): " choice
    choice="${choice:-1}"
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice>=1 && choice<=${#P_VER[@]} )) || { echo "Lựa chọn không hợp lệ." >&2; exit 1; }
    idx=$((choice-1))
fi

URL="${DOWNLOAD_BASE}/${P_PATH[$idx]}"
mkdir -p "$OUTDIR"
OUT="${OUTDIR%/}/${P_LEAF[$idx]}"

echo
echo "Phiên bản : ${P_VER[$idx]} ($PLAT_LABEL)"
echo "File      : ${P_LEAF[$idx]}  [$(human_mb "${P_SIZE[$idx]}") MB]"
echo "Nguồn     : $URL"
echo "Lưu vào   : $OUT"
echo
curl -L --fail --progress-bar --continue-at - --output "$OUT" "$URL"

echo
echo "Đang kiểm tra MD5..."
if command -v md5sum >/dev/null 2>&1; then
    ACTUAL="$(md5sum "$OUT" | awk '{print $1}')"
else
    ACTUAL="$(md5 -q "$OUT")"   # macOS
fi
EXPECT="$(echo "${P_MD5[$idx]}" | tr 'A-Z' 'a-z')"
ACTUAL="$(echo "$ACTUAL" | tr 'A-Z' 'a-z')"

if [[ "$ACTUAL" == "$EXPECT" ]]; then
    echo "✅ MD5 OK: $ACTUAL"
else
    echo "❌ MD5 KHÔNG KHỚP!"
    echo "   Mong đợi: $EXPECT"
    echo "   Thực tế : $actual"
    echo "File có thể bị hỏng — hãy tải lại." >&2
    exit 1
fi

echo
echo "Hoàn tất. File tại: $OUT"
