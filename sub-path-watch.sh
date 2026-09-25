#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════
#  نگهبان «مسیر ساب‌لینک»  (Railway 3x-ui)
#
#  چرا لازم است؟
#    سرور ساب پنل (پورت داخلی 2096) هر بار که تنظیمات در پنل ذخیره می‌شود،
#    مسیر ساب را دوباره از دیتابیس می‌خواند و بلافاصله با مسیر جدید بالا
#    می‌آید («Sub server restarted successfully» در لاگ). ولی nginx فقط یک‌بار
#    هنگام بوت مسیر را می‌خواند. نتیجه: به‌محض عوض‌کردن Sub Path در پنل،
#    ساب‌لینک‌ها ۴۰۴ می‌شوند تا سرویس دوباره دیپلوی شود.
#
#  این اسکریپت هر چند ثانیه مسیرهای ساب را از دیتابیس پنل می‌خواند، کانفیگ
#  nginx را از تمپلیت بازمی‌سازد و اگر با کانفیگ فعلی فرق داشت، تست و
#  «ریلود» می‌کند — بدون Redeploy. اگر کانفیگ جدید معتبر نباشد، کانفیگ فعلی
#  دست‌نخورده می‌ماند (پنل هرگز به‌خاطر این نگهبان از دست نمی‌رود).
#
#  خاموش‌کردن:  متغیر محیطی  XUI_SUB_WATCH=false
#  بازهٔ بررسی: متغیر محیطی  SUB_WATCH_INTERVAL=15   (ثانیه)
# ════════════════════════════════════════════════════════════════════════════
set -uo pipefail

INTERVAL="${SUB_WATCH_INTERVAL:-15}"
TEMPLATE="/etc/nginx/nginx.conf.template"
CONF="/etc/nginx/nginx.conf"
NEWCONF="/etc/nginx/nginx.conf.new"
XUI_DB_FILE="${XUI_DB_FOLDER:-/etc/x-ui}/x-ui.db"
NGINX_PORT="${NGINX_PORT:-${PORT:-3000}}"

log() { printf '%s\n' "$*"; }

# ── خواندن یک تنظیم از دیتابیس پنل (مثل start.sh) ──────────────────────────
_sqlset() {
    [ -f "$XUI_DB_FILE" ] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    local q v
    q="select value from settings where key='$1' limit 1;"
    v="$(sqlite3 -noheader -readonly "file:${XUI_DB_FILE}?mode=ro" "$q" 2>/dev/null | tr -d '\r\n')"
    [ -n "$v" ] || v="$(sqlite3 -noheader "$XUI_DB_FILE" "$q" 2>/dev/null | tr -d '\r\n')"
    printf '%s' "$v"
}

# ── نرمال‌سازی مسیر (مثل خودِ پنل: با / شروع و با / تمام شود) ───────────────
_norm_sub_path() {
    local p
    p="$(printf '%s' "$1" | tr -d '\r\n')"
    [ -n "$p" ] || return 0
    case "$p" in /*) ;; *) p="/$p" ;; esac
    case "$p" in */) ;; *) p="$p/" ;; esac
    printf '%s' "$p"
}

# ── مسیرهای رزرو‌شده/غیرمجاز ───────────────────────────────────────────────
_usable_sub_path() {
    case "$1" in
        ""|"/") return 1 ;;
        /managepanel*|/ib|/ib/*|/_ib*) return 1 ;;
        /in[0-9]*) return 1 ;;
        *[!A-Za-z0-9/_.-]*) return 1 ;;
    esac
    [ "${#1}" -le 60 ] || return 1
    return 0
}

_add_sub_loc() {   # $1=مسیر  $2=برچسب
    case "$1" in ""|"/") return 0 ;; esac
    case "$SUB_LOCATIONS" in *"location $1 {"*) return 0 ;; esac
    if [ -n "$SUB_LOCATIONS" ]; then SUB_LOCATIONS="$SUB_LOCATIONS
"; fi
    SUB_LOCATIONS="${SUB_LOCATIONS}        # ساب‌لینک ($2) → سرور ساب روی پورت داخلی 2096
        location ${1} {
            proxy_pass http://127.0.0.1:2096${1};
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$client_real_ip;
            proxy_set_header X-Forwarded-For \$client_real_ip;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }"
    SUB_PATHS="$SUB_PATHS $1"
}

# ── ساخت کانفیگ از تمپلیت با مسیرهای فعلی پنل ──────────────────────────────
_build_conf() {
    SUB_LOCATIONS=""
    SUB_PATHS=""
    if [ "$(_sqlset subEnable)" = "true" ]; then
        local p
        p="$(_norm_sub_path "${SUB_PATH:-$(_sqlset subPath)}")"
        [ -n "$p" ] || p="/sub/"
        if _usable_sub_path "$p"; then _add_sub_loc "$p" "اصلی"; else log "⚠️  نگهبان ساب: مسیر «$p» قابل استفاده نیست ⇒ نادیده گرفته شد."; fi
        if [ "$(_sqlset subJsonEnable)" = "true" ]; then
            p="$(_norm_sub_path "${SUB_JSON_PATH:-$(_sqlset subJsonPath)}")"
            if _usable_sub_path "$p"; then _add_sub_loc "$p" "JSON"; fi
        fi
        if [ "$(_sqlset subClashEnable)" = "true" ]; then
            p="$(_norm_sub_path "${SUB_CLASH_PATH:-$(_sqlset subClashPath)}")"
            if _usable_sub_path "$p"; then _add_sub_loc "$p" "Clash"; fi
        fi
    fi
    export SUB_LOCATIONS
    [ -f "$TEMPLATE" ] || { log "⚠️  نگهبان ساب: تمپلیت nginx پیدا نشد."; return 1; }
    if ! envsubst '${NGINX_PORT} ${SUB_LOCATIONS}' < "$TEMPLATE" > "$NEWCONF" 2>/dev/null; then
        log "⚠️  نگهبان ساب: ساخت کانفیگ جدید ناموفق بود — کانفیگ فعلی دست‌نخورده ماند."
        rm -f "$NEWCONF"
        return 1
    fi
    return 0
}

# ── اجرای اصلی ─────────────────────────────────────────────────────────────
fails=0

while true; do
    if _build_conf; then
        if cmp -s "$NEWCONF" "$CONF"; then
            # هیچ تغییری نیست ⇒ کاری نکن
            rm -f "$NEWCONF"
            fails=0
        elif ! nginx -t -c "$NEWCONF" >/tmp/sub_watch_test.log 2>&1; then
            log "⚠️  نگهبان ساب: کانفیگ جدید معتبر نیست — کانفیگ فعلی دست‌نخورده ماند."
            head -3 /tmp/sub_watch_test.log 2>/dev/null | sed 's/^/    /'
            rm -f "$NEWCONF"
            fails=$((fails+1)); [ "$fails" -gt 5 ] && fails=5
        else
            mv -f "$NEWCONF" "$CONF"
            if nginx -s reload 2>/tmp/sub_watch_reload.log; then
                log "🔁 مسیرهای ساب از پنل خوانده شد و nginx ریلود شد — مسیرها:${SUB_PATHS:- (هیچ — ساب خاموش است)}"
                fails=0
            else
                log "⚠️  نگهبان ساب: ریلود nginx ناموفق بود:"
                head -3 /tmp/sub_watch_reload.log 2>/dev/null | sed 's/^/    /'
                fails=$((fails+1)); [ "$fails" -gt 5 ] && fails=5
            fi
        fi
    else
        fails=$((fails+1)); [ "$fails" -gt 5 ] && fails=5
    fi

    # در خطا دیرتر تلاش کن (۱۵s → ۶۰s) تا لاگ اسپم نشود
    if [ "$fails" -gt 0 ]; then sleep 60; else sleep "$INTERVAL"; fi
done
