#!/usr/bin/env bash
#
# Tải VMware Workstation Pro (Linux .bundle) từ mirror Archive.org
# (vĩnh viễn, không cần tài khoản) và tự động kiểm tra MD5.
#
# Cách dùng:
#   ./get-vmware-workstation.sh                 # menu tương tác
#   ./get-vmware-workstation.sh --list          # liệt kê các phiên bản
#   ./get-vmware-workstation.sh --version 26H1  # tải thẳng bản 26H1
#   ./get-vmware-workstation.sh --out ~/Downloads --version 17.6.4
#
set -euo pipefail

ITEM="vmwareworkstationarchive"
METADATA_URL="https://archive.org/metadata/${ITEM}"
DOWNLOAD_BASE="https://archive.org/download/${ITEM}"

VERSION=""
OUTDIR="${PWD}"
LIST_ONLY=0

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|-v) VERSION="${2:-}"; shift 2 ;;
        --out|-o)     OUTDIR="${2:-}"; shift 2 ;;
        --list|-l)    LIST_ONLY=1; shift ;;
        --help|-h)    usage ;;
        *) echo "Tham số không hợp lệ: $1" >&2; exit 1 ;;
    esac
done

command -v curl >/dev/null 2>&1 || { echo "Cần cài 'curl'." >&2; exit 1; }

# --- Lấy catalog: in ra các dòng "path<TAB>md5<TAB>size" cho bản Linux .bundle ---
fetch_catalog() {
    local json
    json="$(curl -fsSL "$METADATA_URL")"
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$json" | jq -r '
            .files[]
            | select(.name|test("\\.bundle$"))
            | select(.name|test("orkstation"))
            | select(.name|test("(^|/)Linux/"))
            | [.name, .md5, (.size|tostring)] | @tsv'
    elif command -v python3 >/dev/null 2>&1; then
        printf '%s' "$json" | python3 -c '
import sys, json, re
data = json.load(sys.stdin)
for f in data.get("files", []):
    n = f.get("name","")
    if not n.endswith(".bundle"): continue
    if "orkstation" not in n: continue
    if not re.search(r"(^|/)Linux/", n): continue
    print("\t".join([n, f.get("md5",""), str(f.get("size",""))]))'
    else
        echo "Cần 'jq' hoặc 'python3' để phân tích metadata." >&2
        exit 1
    fi
}

# --- Suy ra nhãn phiên bản từ tên file ---
parse_version() {
    local leaf="$1"
    if [[ "$leaf" =~ -([0-9]{2}H[0-9](u[0-9])?)- ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$leaf" =~ full-([0-9]+\.[0-9]+\.[0-9]+)- ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$leaf" =~ -([0-9]+\.[0-9]+\.[0-9]+)- ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "$leaf"
    fi
}

echo "Đang lấy danh sách từ Archive.org..." >&2
mapfile -t LINES < <(fetch_catalog)
[[ ${#LINES[@]} -gt 0 ]] || { echo "Không tìm thấy phiên bản Linux nào." >&2; exit 1; }

# Mảng song song
declare -a P_PATH P_MD5 P_SIZE P_VER P_LEAF
for line in "${LINES[@]}"; do
    IFS=$'\t' read -r path md5 size <<<"$line"
    leaf="$(basename "$path")"
    P_PATH+=("$path"); P_MD5+=("$md5"); P_SIZE+=("$size")
    P_LEAF+=("$leaf"); P_VER+=("$(parse_version "$leaf")")
done

human_mb() { awk "BEGIN{ printf \"%.2f\", ${1:-0}/1048576 }"; }

if [[ $LIST_ONLY -eq 1 ]]; then
    echo
    echo "Các phiên bản Linux có sẵn:"
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
    echo "Các phiên bản Linux có sẵn:"
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
echo "Phiên bản : ${P_VER[$idx]} (Linux)"
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
    echo "   Thực tế : $ACTUAL"
    echo "File có thể bị hỏng — hãy tải lại." >&2
    exit 1
fi

echo
echo "Hoàn tất. File tại: $OUT"
