#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════
#  نگهبان «مسیر ساب‌لینک»  (Railway 3x-ui)
#
#  دو کار انجام می‌دهد:
#   ۱) مسیرهای ساب را از تنظیمات خودِ پنل می‌خواند و nginx را با آن‌ها می‌سازد.
#      سرور ساب پنل هر بار که تنظیمات ذخیره شود با مسیر جدید بالا می‌آید، ولی
#      nginx فقط یک‌بار هنگام بوت مسیر را می‌خواند. نتیجه: با عوض‌کردن Sub Path
#      ساب‌لینک‌ها ۴۰۴ می‌شدند تا سرویس دوباره دیپلوی شود. حالا حداکثر ۱۵ ثانیه
#      بعد از ذخیره‌ی تنظیمات، nginx خودکار ریلود می‌شود.
#
#   ۲) چند مسیر ممکن را هم‌زمان سرو می‌کند: مسیرِ داخل «Subscription URI»،
#      «Subscription Path» و مسیر پیش‌فرض (/sub/) — چون پنل ممکن است مسیر ساب را
#      از Subscription URI بسازد (در فرانت‌اند پنل دقیقاً همین کار انجام می‌شود).
#      پورت داخلی سرور ساب هم از تنظیمات پنل خوانده می‌شود (پیش‌فرض 2096).
#
#  امنیت: اگر کانفیگ جدید معتبر نباشد، اعمال نمی‌شود و کانفیگ فعلی دست‌نخورده
#  می‌ماند ⇒ پنل هرگز به‌خاطر این نگهبان از دست نمی‌رود.
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

# ── مسیرِ داخل یک URI (مثل Subscription URI) ───────────────────────────────
#    پنل وقتی Subscription URI پر باشد، مسیر ساب را از pathname همان می‌سازد.
_sub_uri_path() {
    local u r
    u="$(printf '%s' "$1" | tr -d '\r\n')"
    [ -n "$u" ] || return 0
    case "$u" in
        *://*) r="${u#*://}"; case "$r" in */*) u="/${r#*/}" ;; *) u="/" ;; esac ;;
        /*) ;;
        *) u="/$u" ;;
    esac
    u="${u%%\?*}"; u="${u%%#*}"
    [ "$u" = "/" ] && return 0
    _norm_sub_path "$u"
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
    _usable_sub_path "$1" || return 0
    case "$SUB_LOCATIONS" in *"location $1 {"*) return 0 ;; esac
    if [ -n "$SUB_LOCATIONS" ]; then SUB_LOCATIONS="$SUB_LOCATIONS
"; fi
    # ⚠️ متن کامنت باید با خروجی start.sh یکی باشد (مقایسه با cmp) ⇒ بدون برچسب مسیر
    SUB_LOCATIONS="${SUB_LOCATIONS}        # ساب‌لینک → سرور ساب روی پورت داخلی ${SUB_UPSTREAM_PORT}
        location ${1} {
            proxy_pass http://127.0.0.1:${SUB_UPSTREAM_PORT}${1};
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$client_real_ip;
            proxy_set_header X-Forwarded-For \$client_real_ip;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }"
    SUB_PATHS="$SUB_PATHS $1"
}

# ── ساخت کانفیگ از تمپلیت با تنظیمات فعلی پنل ──────────────────────────────
_build_conf() {
    SUB_LOCATIONS=""
    SUB_PATHS=""

    # پورت داخلی سرور ساب — از تنظیمات پنل (پیش‌فرض 2096)
    SUB_UPSTREAM_PORT="$(_sqlset subPort)"
    case "$SUB_UPSTREAM_PORT" in ''|*[!0-9]*) SUB_UPSTREAM_PORT=2096 ;; esac

    if [ "$(_sqlset subEnable)" != "false" ]; then
        # ۱) مسیرِ داخل Subscription URI (اگر پنل مسیر ساب را از آن بسازد)
        _add_sub_loc "$(_sub_uri_path "$(_sqlset subURI)")" "URI"
        # ۲) Subscription Path (یا متغیر SUB_PATH)
        _add_sub_loc "$(_norm_sub_path "${SUB_PATH:-$(_sqlset subPath)}")" "اصلی"
        # ۳) مسیر پیش‌فرض
        _add_sub_loc "/sub/" "پیش‌فرض"

        if [ "$(_sqlset subJsonEnable)" = "true" ]; then
            _add_sub_loc "$(_sub_uri_path "$(_sqlset subJsonURI)")" "JSON-URI"
            _add_sub_loc "$(_norm_sub_path "${SUB_JSON_PATH:-$(_sqlset subJsonPath)}")" "JSON"
            _add_sub_loc "/json/" "JSON-پیش‌فرض"
        fi
        if [ "$(_sqlset subClashEnable)" = "true" ]; then
            _add_sub_loc "$(_sub_uri_path "$(_sqlset subClashURI)")" "Clash-URI"
            _add_sub_loc "$(_norm_sub_path "${SUB_CLASH_PATH:-$(_sqlset subClashPath)}")" "Clash"
            _add_sub_loc "/clash/" "Clash-پیش‌فرض"
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
                log "🔁 تنظیمات ساب در پنل عوض شد ⇒ nginx بازسازی و ریلود شد — مسیرها:${SUB_PATHS:- (هیچ — ساب خاموش است)} (پورت داخلی: ${SUB_UPSTREAM_PORT})"
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
