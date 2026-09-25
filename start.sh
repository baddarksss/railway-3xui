#!/bin/bash
set -e

echo "🚀 Starting X-UI + nginx reverse proxy..."

# nginx همیشه روی پورت ثابت 3000 گوش می‌دهد
export NGINX_PORT=3000

cd /usr/local/x-ui

echo "ℹ️  x-ui version: $(./x-ui -v 2>/dev/null || echo unknown)"

echo "🔧 Applying panel settings via x-ui CLI..."
./x-ui setting -port 2053 -webBasePath /managepanel/ || true

# --- fail2ban برای قابلیت IP Limit ---
# پنل فقط وقتی کادر IP Limit را فعال می‌کند که fail2ban-client در دسترس باشد،
# وگرنه مقدار limitIp همه‌ی کلاینت‌ها را صفر می‌کند.
if [ "$XUI_ENABLE_FAIL2BAN" = "true" ]; then
    echo "🔧 Setting up fail2ban (3x-ipl jail)..."
    LOG_FOLDER="${XUI_LOG_FOLDER:-/var/log/x-ui}"
    mkdir -p "$LOG_FOLDER" /etc/fail2ban/jail.d /etc/fail2ban/filter.d /etc/fail2ban/action.d /var/run/fail2ban
    touch "$LOG_FOLDER/3xipl.log" "$LOG_FOLDER/3xipl-banned.log"

    cat > /etc/fail2ban/jail.d/3x-ipl.conf << EOF
[3x-ipl]
enabled=true
backend=auto
filter=3x-ipl
action=3x-ipl
logpath=$LOG_FOLDER/3xipl.log
maxretry=1
findtime=32
bantime=30m
EOF

    cat > /etc/fail2ban/filter.d/3x-ipl.conf << 'EOF'
[Definition]
datepattern = ^%%Y/%%m/%%d %%H:%%M:%%S
failregex   = \[LIMIT_IP\]\s*Email\s*=\s*<F-USER>.+</F-USER>\s*\|\|\s*Disconnecting OLD IP\s*=\s*<ADDR>\s*\|\|\s*Timestamp\s*=\s*\d+
ignoreregex =
EOF

    # پورت پنل و nginx از بن معاف می‌شوند تا خودتان قفل بیرون نمانید
    cat > /etc/fail2ban/action.d/3x-ipl.conf << EOF
[INCLUDES]
before = iptables-allports.conf

[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> -j f2b-<name>

actionstop = <iptables> -D <chain> -j f2b-<name>
             <actionflush>
             <iptables> -X f2b-<name>

actioncheck = <iptables> -n -L <chain> | grep -q 'f2b-<name>[ \t]'

actionban = <iptables> -I f2b-<name> 1 -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
            echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   BAN   [Email] = <F-USER> [IP] = <ip> banned for <bantime> seconds." >> $LOG_FOLDER/3xipl-banned.log

actionunban = <iptables> -D f2b-<name> -s <ip> -p tcp -m multiport ! --dports <exemptports> -j <blocktype>
              echo "\$(date +"%%Y/%%m/%%d %%H:%%M:%%S")   UNBAN   [Email] = <F-USER> [IP] = <ip> unbanned." >> $LOG_FOLDER/3xipl-banned.log

[Init]
name = default
chain = INPUT
exemptports = 2053,3000
EOF

    # روی Railway معمولاً iptables اجازه ندارد؛ اگر استارت شکست خورد ادامه می‌دهیم
    # چون صرفِ در دسترس بودن fail2ban-client کادر IP Limit را فعال نگه می‌دارد.
    if fail2ban-client -x start 2>/dev/null; then
        echo "✅ fail2ban started (IP limit fully enforced)"
    else
        echo "⚠️  fail2ban could not start (no iptables permission on this host)."
        echo "   کادر IP Limit در پنل فعال می‌ماند و مقادیر ذخیره می‌شوند،"
        echo "   ولی بن کردن خودکار انجام نمی‌شود."
    fi
fi

# --- رویدادهای اینباند (برای نمایش «کاربر روی کدام اینباند است» در ربات) ---
# nginx در لحظهٔ شروع هر اتصال و در لحظهٔ پایانش، یک درخواست کوتاه به ربات
# می‌فرستد تا ربات بفهمد آن کاربر (با آن IP) روی کدام اینباند وصل شده است.
#
# 🔑 آدرس پوش از «متغیر محیطی» خوانده می‌شود و هیچ آدرس/کلیدی داخل سورس نیست:
#      Railway → سرویس پنل → Variables → IB_PUSH_URL = آدرس پوش
#   • آدرس را از کج بگیرم؟ در ربات: «🔐 امنیت و کلیدها» → «🔌 رویداد اینباند (پوش پنل)»
#   • خاموش کردن: متغیر IB_PUSH_URL را برابر off بگذارید (یا متغیر را نسازید).
# اگر خاموش باشد، هر دو فایل «return 204» می‌شوند (هیچ ارسالی، رفتار پنل مثل قبل).
IB_PUSH_URL_DEFAULT=""   # ← عمداً خالی: سورس هیچ کلید شخصی ندارد
_esc() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }
mkdir -p /etc/nginx/ib
printf 'return 204;\n' > /etc/nginx/ib/push_start.conf
printf 'return 204;\n' > /etc/nginx/ib/push_close.conf

IB_PUSH_URL_EFF="${IB_PUSH_URL:-$IB_PUSH_URL_DEFAULT}"
case "$IB_PUSH_URL_EFF" in off|OFF|none|NONE|0|"") IB_PUSH_URL_EFF="";; esac

if [ -z "$IB_PUSH_URL_EFF" ]; then
    if [ -n "${IB_PUSH_URL:-}" ]; then
        echo "⚪️  رویدادهای اینباند: خاموش (خواستهٔ خودت: IB_PUSH_URL=$IB_PUSH_URL) — پنل و کانفیگ‌ها عادی کار می‌کنند."
    else
        echo "⚪️  رویدادهای اینباند: خاموش (متغیر IB_PUSH_URL ست نشده) — پنل و کانفیگ‌ها عادی کار می‌کنند."
        echo "    برای روشن‌کردن: Railway → Variables → IB_PUSH_URL = آدرس پوش ربات"
        echo "    (آدرس را از ربات بگیر: امنیت و کلیدها → رویداد اینباند)"
    fi
fi

if [ -n "$IB_PUSH_URL_EFF" ]; then
    IB_BASE="${IB_PUSH_URL_EFF%%\?*}"            # https://host/path
    IB_HOST="${IB_BASE#*://}"; IB_HOST="${IB_HOST%%/*}"
    IB_QS=""
    case "$IB_PUSH_URL_EFF" in *\?*) IB_QS="${IB_PUSH_URL_EFF#*\?}";; esac
    IB_RESOLVER="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
    [ -n "$IB_RESOLVER" ] || IB_RESOLVER="1.1.1.1"
    if [ -z "$IB_HOST" ] || [ -z "$IB_QS" ]; then
        echo "⚠️  IB_PUSH_URL نامعتبر است (باید مثل https://host/ib?k=KEY باشد) — رویدادهای اینباند خاموش ماند."
    else
        IB_PREFIX="$IB_BASE?$IB_QS"
        for _ev in start close; do
            if [ "$_ev" = "start" ]; then _tag="open"; else _tag="close"; fi
            cat > "/etc/nginx/ib/push_$_ev.conf" <<'NGINXCONF'
resolver __RES__ valid=300s ipv6=off;
proxy_pass __URL__&ev=__EV__&u=$ib_path&ip=$client_real_ip&h=$host;
proxy_ssl_server_name on;
proxy_ssl_name __HOST__;
proxy_http_version 1.1;
# ⚠️ هیچ هدری از درخواست کلاینت به ربات نرود. با فرستادن هدرهای WebSocket
#    (Upgrade و Sec-WebSocket-*) کلادفلر درخواست پوش را «آپگرید» می‌بیند و
#    به‌جای یک تماس کوتاه، تونل باز می‌کند و رویداد معلق می‌ماند.
#    همهٔ دادهٔ لازم داخل خود آدرس (query) فرستاده می‌شود.
proxy_pass_request_headers off;
proxy_set_header Connection "";
proxy_connect_timeout 2s;
proxy_send_timeout  3s;
# مهلت خواندن ۶ ثانیه: ربات در رویداد اول (کش سرد) ممکن است تا ~۱٫۵ ثانیه
# سراغ خود پنل برود تا بفهمد رویداد مال کدام پنل است.
proxy_read_timeout  6s;
error_log /var/log/nginx/ib_err.log error;
NGINXCONF
            sed -i "s|__RES__|$(_esc "$IB_RESOLVER 1.1.1.1")|; \
                    s|__URL__|$(_esc "$IB_PREFIX")|; \
                    s|__EV__|$_tag|; \
                    s|__HOST__|$(_esc "$IB_HOST")|" "/etc/nginx/ib/push_$_ev.conf"
        done
        echo "✅ رویدادهای اینباند فعال شد (مقصد: $IB_HOST)"
        # 🩺 تست سلامت کلید پوش (اختیاری): اگر کلید اشتباه/باطل باشد، همین‌جا در
        #    لاگ هشدار می‌بینید — نه بعد از ساعت‌ها سکوت. هیچ حالتی ذخیره نمی‌شود.
        if command -v curl >/dev/null 2>&1; then
            _ibcode="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "${IB_PREFIX}&selftest=1" 2>/dev/null || echo 000)"
            case "$_ibcode" in
                204) echo "✅ تست کلید پوش: موفق (رویدادهای اینباند آماده‌اند)" ;;
                403) echo "⛔ تست کلید پوش: کلید نامعتبر است ⇒ رویدادهای اینباند کار نمی‌کند."
                     echo "    آدرس تازه را از ربات بگیر (امنیت و کلیدها → رویداد اینباند)، متغیر IB_PUSH_URL را به‌روز کن و Redeploy بزن."
                     ;;
                000|"") echo "ℹ️ تست کلید پوش انجام نشد (شبکهٔ خروجی در لحظهٔ بوت آماده نبود) — ایرادی نیست." ;;
                *) echo "ℹ️ تست کلید پوش: پاسخ غیرمنتظرهٔ $_ibcode" ;;
            esac
        fi
    fi
fi

echo "🔧 Building nginx.conf for fixed port: $NGINX_PORT"
# ─── مسیر ساب‌سکرایب: از تنظیمات خودِ پنل خوانده می‌شود ───
# پیش‌فرض پنل /sub/ است، ولی Sub Path می‌تواند هر مسیری باشد (حتی رندوم).
# در هر بالا آمدن سرویس، مسیر فعلی پنل خوانده و به nginx داده می‌شود.
#   • تغییر مسیر: پنل → Settings → Subscription → Subscription Path
#     (بعد از تغییر، یک بار Redeploy بزنید تا nginx با مسیر جدید بالا بیاید)
#   • override دستی: متغیر SUB_PATH=/my-path/
XUI_DB_FILE="${XUI_DB_FOLDER:-/etc/x-ui}/x-ui.db"
_sqlset() {   # خواندن یک تنظیم از دیتابیس پنل (اول read-only، اگر نشد عادی)
    [ -f "$XUI_DB_FILE" ] || return 0
    command -v sqlite3 >/dev/null 2>&1 || return 0
    _q="select value from settings where key='$1' limit 1;"
    _v="$(sqlite3 -noheader -readonly "file:${XUI_DB_FILE}?mode=ro" "$_q" 2>/dev/null | tr -d '\r\n')"
    [ -n "$_v" ] || _v="$(sqlite3 -noheader "$XUI_DB_FILE" "$_q" 2>/dev/null | tr -d '\r\n')"
    printf '%s' "$_v"
}
_norm_sub_path() {   # مثل خودِ پنل: با / شروع و با / تمام شود
    _p="$(printf '%s' "$1" | tr -d '\r\n')"   # فاصله/کاراکتر غیرمجاز = نامعتبر
    [ -n "$_p" ] || return 0
    case "$_p" in /*) ;; *) _p="/$_p";; esac
    case "$_p" in */) ;; *) _p="$_p/";; esac
    printf '%s' "$_p"
}
SUB_LOCATIONS=""
_add_sub_loc() {   # $1=مسیر  $2=برچسب
    case "$1" in ""|"/") return 0;; esac
    case "$SUB_LOCATIONS" in *"location $1 {"*) return 0;; esac   # ← ستارهٔ آخر لازم است: case تمام رشته را تطبیق می‌دهد
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
    return 0
}
SUB_PATH_EFF="$(_norm_sub_path "${SUB_PATH:-$(_sqlset subPath)}")"
[ -n "$SUB_PATH_EFF" ] || SUB_PATH_EFF="/sub/"
_ok_sub=1
case "$SUB_PATH_EFF" in
    /) _ok_sub=0;;
    /managepanel*|/ib|/ib/*|/_ib*) _ok_sub=0;;
    /in[0-9]*) _ok_sub=0;;
    *[!A-Za-z0-9/_.-]*) _ok_sub=0;;
esac
[ "${#SUB_PATH_EFF}" -le 60 ] || _ok_sub=0
if [ "$_ok_sub" = "0" ]; then
    echo "⚠️  مسیر ساب «$SUB_PATH_EFF» قابل استفاده نیست (هم‌پوشانی با مسیرهای رزرو یا کاراکتر غیرمجاز) ⇒ روی /sub/ برگشتیم."
    SUB_PATH_EFF="/sub/"
fi
_add_sub_loc "$SUB_PATH_EFF" "اصلی"
if [ "$(_sqlset subJsonEnable)" = "true" ]; then
    _add_sub_loc "$(_norm_sub_path "${SUB_JSON_PATH:-$(_sqlset subJsonPath)}")" "JSON"
fi
if [ "$(_sqlset subClashEnable)" = "true" ]; then
    _add_sub_loc "$(_norm_sub_path "${SUB_CLASH_PATH:-$(_sqlset subClashPath)}")" "Clash"
fi
# ⚠️ این متغیر را باید export کنیم؛ envsubst فقط متغیرهای محیطی را می‌بیند.
export SUB_LOCATIONS

echo "📎 مسیر ساب‌لینک: $SUB_PATH_EFF"
_subdom="$(_sqlset subDomain)"
if [ -n "$_subdom" ]; then
    echo "ℹ️  Sub Domain پنل روی «$_subdom» است ⇒ سرور ساب فقط با همین دامنه جواب می‌دهد."
    echo "    اگر ساب‌لینک باز نمی‌شود، این فیلد را در پنل خالی کنید."
fi

envsubst '${NGINX_PORT} ${SUB_LOCATIONS}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

# 🛡️ تورِ اطمینان: اگر مسیر سفارشی ساب، کانفیگ nginx را خراب کرد، خودکار به /sub/ برگرد
#    تا یک اشتباه در Sub Path هرگز پنل را از دست ندهد.
if ! nginx -t -q >/tmp/nginx_sub_test.log 2>&1; then
    if [ "$SUB_PATH_EFF" != "/sub/" ]; then
        echo "⚠️  مسیر ساب «$SUB_PATH_EFF» کانفیگ nginx را خراب کرد ⇒ برگشت به /sub/ (پنل سالم می‌ماند)."
        SUB_LOCATIONS=""
        _add_sub_loc "/sub/" "پیش‌فرض"
        echo "📎 مسیر ساب‌لینک (اصلاح‌شده): /sub/"
        envsubst '${NGINX_PORT} ${SUB_LOCATIONS}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
    fi
    if ! nginx -t -q >/dev/null 2>&1; then
        echo "⚠️  تست کانفیگ nginx موفق نشد — جزئیات:"
        head -5 /tmp/nginx_sub_test.log | sed 's/^/    /'
    fi
fi

echo "▶️  Starting x-ui in background..."
./x-ui &
X_UI_PID=$!
# auto-sockopt این PID را می‌گیرد تا هنگام اصلاح تنظیمات، همان پروسه‌ی Xray را
# ریلود کند (USR1). بدون آن، دنبال پروسه با الگوی مسیر می‌گردد که چون اینجا با
# ./x-ui اجرا شده، پیدا نمی‌شود.
export XUI_PID="$X_UI_PID"

# ناظر خودکار: هر اینباند جدیدی که بسازید را با trustedXForwardedFor تنظیم می‌کند
# تا IP واقعی کاربرها ثبت شود و لازم نباشد دستی ست کنید.
if [ "${XUI_AUTO_SOCKOPT:-true}" = "true" ]; then
    /auto-sockopt.sh &
fi

sleep 2

echo "▶️  Starting nginx in foreground on port $NGINX_PORT..."
nginx -t
exec nginx -g "daemon off;"
