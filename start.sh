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
    # 🔧 لیست رِزولور برای nginx.
    #    ⚠️ باگ واقعی (کرش پنل روی Railway): در /etc/resolv.conf اینجا
    #    «nameserver fd12::10» است و nginx آدرس IPv6 را *فقط* داخل [] قبول
    #    می‌کند؛ بدون براکت خطای «invalid port in resolver "fd12::10"» می‌دهد
    #    و کل کانفیگ رد می‌شود ⇒ nginx بالا نمی‌آمد و کانتینر کرش می‌کرد.
    _ib_res=""
    _add_res() {   # $1 = آدرس؛ اگر معتبر بود به لیست اضافه کن (بدون تکرار)
        [ -n "$1" ] || return 0
        case "$1" in
            *:*)
                case "$1" in *[!0-9A-Fa-f:.]*) return 0;; esac   # IPv6 غیرمعتبر = رد
                set -- "[$1]"                                     # ← براکت لازم است
                ;;
            *)
                case "$1" in *[!0-9.A-Za-z-]*) return 0;; esac
                ;;
        esac
        case " $_ib_res " in *" $1 "*) return 0;; esac
        _ib_res="${_ib_res:+$_ib_res }$1"
    }
    while read -r _ns; do _add_res "$_ns"; done <<EOF
$(awk '/^nameserver/{print $2}' /etc/resolv.conf 2>/dev/null || true)
EOF
    _add_res "1.1.1.1"      # پشتیبان
    _add_res "8.8.8.8"      # پشتیبان دوم
    IB_RESOLVER="$_ib_res"
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
            sed -i "s|__RES__|$(_esc "$IB_RESOLVER")|; \
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
# مسیرِ داخل یک URI (مثل Subscription URI): پنل اگر Subscription URI پر باشد،
# مسیر ساب را از pathname همان می‌سازد (در فرانت‌اند پنل هم دقیقاً همین کار را می‌کند).
_sub_uri_path() {
    _u="$(printf '%s' "$1" | tr -d '\r\n')"
    [ -n "$_u" ] || return 0
    case "$_u" in
        *://*) _r="${_u#*://}"; case "$_r" in */*) _u="/${_r#*/}";; *) _u="/";; esac;;
        /*) ;;
        *) _u="/$_u";;
    esac
    _u="${_u%%\?*}"; _u="${_u%%#*}"
    [ "$_u" = "/" ] && return 0
    _norm_sub_path "$_u"
}

SUB_LOCATIONS=""
_add_sub_loc() {   # $1=مسیر  $2=برچسب
    case "$1" in ""|"/") return 0;; esac
    # گارد: مسیرهای رزرو‌شده یا نامعتبر هرگز وارد کانفیگ نمی‌شوند
    case "$1" in /managepanel*|/ib|/ib/*|/_ib*|/in[0-9]*) return 0;; esac
    case "$1" in *[!A-Za-z0-9/_.-]*) return 0;; esac
    [ "${#1}" -le 60 ] || return 0
    case "$SUB_LOCATIONS" in *"location $1 {"*) return 0;; esac   # ← ستارهٔ آخر لازم است: case تمام رشته را تطبیق می‌دهد
    if [ -n "$SUB_LOCATIONS" ]; then SUB_LOCATIONS="$SUB_LOCATIONS
"; fi
    # ⚠️ متن کامنت عمداً ثابت است و برچسب مسیر ($2) داخلش نمی‌آید؛ چون نگهبانِ ساب
    #    فایل کانفیگ را با cmp مقایسه می‌کند و فرقِ کامنت باعث ریلود بی‌مورد می‌شد.
    SUB_LOCATIONS="${SUB_LOCATIONS}        # ساب‌لینک → سرور ساب روی پورت داخلی ${SUB_UPSTREAM_PORT}
        location ${1} {
            proxy_pass http://127.0.0.1:${SUB_UPSTREAM_PORT}${1};
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$client_real_ip;
            proxy_set_header X-Forwarded-For \$client_real_ip;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }"
    SUB_PATHS_SERVED="$SUB_PATHS_SERVED $1"   # فقط برای لاگ
    return 0
}
SUB_PATHS_SERVED=""
# پورت داخلی سرور ساب — از تنظیمات خود پنل (پیش‌فرض 2096). اگر پنل را عوض کنید،
# نگهبان ساب (sub-path-watch.sh) خودکار nginx را بازسازی می‌کند.
SUB_UPSTREAM_PORT="$(_sqlset subPort)"
case "$SUB_UPSTREAM_PORT" in ''|*[!0-9]*) SUB_UPSTREAM_PORT=2096;; esac

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
# سرور ساب پنل ممکن است روی یکی از این مسیرها بالا بیاید؛ برای اینکه ساب‌لینک در هیچ
# حالتی ۴۰۴ نشود، هر سه نامزد سرو می‌شوند: مسیرِ Subscription URI، Subscription Path و
# مسیر پیش‌فرض /sub/. (مسیرهای تکراری/رزرو‌شده خودکار حذف می‌شوند.)
# اگر ساب در پنل خاموش باشد (subEnable=false) هیچ مسیری سرو نمی‌شود.
if [ "$(_sqlset subEnable)" = "false" ]; then
    echo "ℹ️  ساب‌لینک در پنل خاموش است (subEnable=false) ⇒ هیچ مسیر سابی سرو نمی‌شود."
else
_add_sub_loc "$(_sub_uri_path "$(_sqlset subURI)")" "URI"
_add_sub_loc "$SUB_PATH_EFF" "اصلی"
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
# ⚠️ این متغیر را باید export کنیم؛ envsubst فقط متغیرهای محیطی را می‌بیند.
export SUB_LOCATIONS

echo "📎 مسیر ساب‌لینک: $SUB_PATH_EFF (پورت داخلی سرور ساب: $SUB_UPSTREAM_PORT)"
echo "📎 مسیرهایی که برای ساب سرو می‌شوند:${SUB_PATHS_SERVED:- (هیچ — ساب خاموش است)}"
_subdom="$(_sqlset subDomain)"
if [ -n "$_subdom" ]; then
    echo "ℹ️  Sub Domain پنل روی «$_subdom» است ⇒ سرور ساب فقط با همین دامنه جواب می‌دهد."
    echo "    اگر ساب‌لینک باز نمی‌شود، این فیلد را در پنل خالی کنید."
fi

envsubst '${NGINX_PORT} ${SUB_LOCATIONS}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

# 🛡️ تورِ اطمینان: اگر مسیر سفارشی ساب، کانفیگ nginx را خراب کرد، خودکار به /sub/ برگرد
#    تا یک اشتباه در Sub Path هرگز پنل را از دست ندهد.
_revert_sub() {   # برگشت مسیر ساب سفارشی به /sub/ و بازسازی کانفیگ
    [ "$SUB_PATH_EFF" = "/sub/" ] && return 0
    echo "⚠️  مسیر ساب «$SUB_PATH_EFF» کانفیگ nginx را خراب کرد ⇒ برگشت به /sub/ (پنل سالم می‌ماند)."
    SUB_PATH_EFF="/sub/"
    SUB_LOCATIONS=""
    _add_sub_loc "/sub/" "پیش‌فرض"
    echo "📎 مسیر ساب‌لینک (اصلاح‌شده): /sub/"
    envsubst '${NGINX_PORT} ${SUB_LOCATIONS}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
}
_disable_ib() {   # خنثی‌کردن رویدادهای اینباند تا پنل سالم بالا بیاید
    printf 'return 204;\n' > /etc/nginx/ib/push_start.conf
    printf 'return 204;\n' > /etc/nginx/ib/push_close.conf
}

# 🛡️ تورهای اطمینان — ترتیب مهم است: اول مطمئن شو مشکل از «قابلیت» است نه پنل.
#    (قبلاً هر خطای کانفیگ به‌غلط به مسیر ساب نسبت داده می‌شد و پیام گمراه‌کننده
#     می‌داد؛ باگِ resolver هم همین‌جا پنل را از دست می‌داد.)
if ! nginx -t -q >/tmp/nginx_sub_test.log 2>&1; then
    _fixed=0
    # ۱) کانفیگ «رویدادهای اینباند» مشکوک است؟ موقتاً خاموشش کن و تست بگیر.
    if grep -q "proxy_pass" /etc/nginx/ib/push_start.conf 2>/dev/null; then
        cp -f /etc/nginx/ib/push_start.conf /tmp/ib_start.bak 2>/dev/null || true
        cp -f /etc/nginx/ib/push_close.conf /tmp/ib_close.bak 2>/dev/null || true
        _disable_ib
        if nginx -t -q >/dev/null 2>&1; then
            echo "⚠️  کانفیگ «رویدادهای اینباند» معتبر نبود ⇒ برای بالا ماندن پنل، این قابلیت خاموش شد."
            head -3 /tmp/nginx_sub_test.log | sed 's/^/    /'
            echo "    پنل و کانفیگ‌ها عادی کار می‌کنند. برای روشن‌کردن دوباره: IB_PUSH_URL را درست کن و Redeploy بزن."
            _fixed=1
        else
            [ -f /tmp/ib_start.bak ] && cp -f /tmp/ib_start.bak /etc/nginx/ib/push_start.conf
            [ -f /tmp/ib_close.bak ] && cp -f /tmp/ib_close.bak /etc/nginx/ib/push_close.conf
        fi
    fi
    # ۲) اگر هنوز خراب است، مسیر ساب سفارشی را بردار.
    if [ "$_fixed" = "0" ]; then
        _revert_sub
        nginx -t -q >/dev/null 2>&1 && _fixed=1
    fi
    # ۳) آخرین تور: هم IB خاموش، هم مسیر ساب پیش‌فرض.
    if [ "$_fixed" = "0" ]; then
        _disable_ib
        _revert_sub
        nginx -t -q >/dev/null 2>&1 && _fixed=1
    fi
    if [ "$_fixed" = "0" ]; then
        echo "❌ کانفیگ nginx حتی با تنظیمات پیش‌فرض هم معتبر نیست — جزئیات:"
        head -8 /tmp/nginx_sub_test.log | sed 's/^/    /'
    fi
fi

# ── راهنمای «آدرس درست ساب‌لینک» + هم‌گام‌سازی زندهٔ nginx ──────────────────
# ⚠️ پنل آدرسی که به کاربر نشان می‌دهد را از این‌ها می‌سازد:
#      Subscription URI   (اگر پر باشد، همین استفاده می‌شود)
#      وگرنه:  (http|https)://SubDomain:SubPort + SubPath
#    پیش‌فرض‌ها روی Railway غلط‌اند: SubPort=2096 و بدون سرتیفیکیت ⇒ http
#    یعنی لینکی مثل http://domain:2096/... که از بیرون باز نمی‌شود.
_PUB="$(printf '%s' "${RAILWAY_PUBLIC_DOMAIN:-${RAILWAY_STATIC_URL:-}}" | sed 's|^https\?://||; s|/.*$||')"
_SUB_URI_DB="$(_sqlset subURI)"
_SUBPORT_DB="$(_sqlset subPort)"; [ -n "$_SUBPORT_DB" ] || _SUBPORT_DB=2096
_SUBDOM_DB="$(_sqlset subDomain)"
if [ -n "$_PUB" ]; then
    echo "📎 آدرس درست ساب روی این دامنه: https://${_PUB}${SUB_PATH_EFF}<subId>"
fi
# همان آدرسی که پنل الان به کاربر نشان می‌دهد (بازسازی قانون BuildSubURIBase)
if [ -n "$_SUB_URI_DB" ]; then
    _ADV="$_SUB_URI_DB"
else
    _adv_host="${_SUBDOM_DB:-${_PUB:-دامنه}}"
    _omit_port=0
    if [ "$_SUBPORT_DB" = "443" ] && [ -n "$(_sqlset subCertFile)" ] && [ -n "$(_sqlset subKeyFile)" ]; then _omit_port=1; fi
    if [ "$_SUBPORT_DB" = "80" ] && [ -z "$(_sqlset subCertFile)" ]; then _omit_port=1; fi
    _adv_scheme=http
    [ -n "$(_sqlset subCertFile)" ] && _adv_scheme=https
    if [ "$_omit_port" = "1" ]; then
        _ADV="${_adv_scheme}://${_adv_host}${SUB_PATH_EFF}"
    else
        _ADV="${_adv_scheme}://${_adv_host}:${_SUBPORT_DB}${SUB_PATH_EFF}"
    fi
fi
echo "ℹ️  آدرسی که پنل الان به کاربر نشان می‌دهد: ${_ADV}<subId>  (SubPort=$_SUBPORT_DB | SubDomain=${_SUBDOM_DB:-خالی} | SubPath=$(_sqlset subPath))"
if [ -z "$_PUB" ]; then
    echo "ℹ️  برای دیدن آدرس درست ساب: Railway → Settings → Networking → Generate Domain"
fi
case "$_ADV" in
    https://*)
        # آدرس درست است (روی https و بدون پورت داخلی) — فقط اگر پورت داخلی داخلش باشد هشدار بده
        case "$_ADV" in *:2096/*) echo "⚠️  پورت 2096 داخل آدرس ساب است ⇒ همان لینک نادرست است. Subscription URI را روی https://${_PUB:-دامنه}${SUB_PATH_EFF} بگذارید.";; esac
        ;;
    *)
        echo "⚠️  آدرس ساب فعلی («${_ADV}…») از بیرون باز نمی‌شود؛ چون Railway فقط https روی دامنه را"
        echo "    به بیرون می‌دهد (نه پورت داخلی). یک بار در پنل این را ست کنید:"
        echo "    پنل → Settings → Subscription → Subscription URI = https://${_PUB:-دامنهٔ-خودت}${SUB_PATH_EFF}"
        echo "    (SubDomain خالی بماند؛ SubPort و SubPath را لازم نیست عوض کنید — nginx هر دو مسیر را سرو می‌کند)"
        ;;
esac
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

# نگهبان مسیر ساب: اگر مسیر ساب در پنل عوض شود، nginx را بدون Redeploy ریلود می‌کند
if [ "${XUI_SUB_WATCH:-true}" = "true" ] && [ -x /sub-path-watch.sh ]; then
    /sub-path-watch.sh &
fi

sleep 2

echo "▶️  Starting nginx in foreground on port $NGINX_PORT..."
if ! nginx -t; then
    echo "❌ nginx با کانفیگ نامعتبر بالا نمی‌آید — لاگ بالا دلیل را نشان می‌دهد."
    exit 1
fi
exec nginx -g "daemon off;"
