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
# آدرس پوش به‌صورت پیش‌فرض همین‌جا داخل سورس است ⇒ هیچ متغیری لازم نیست.
#   • خاموش کردن: متغیر IB_PUSH_URL را برابر off بگذارید.
#   • آدرس دیگر: متغیر IB_PUSH_URL را برابر آدرس پوش خودتان بگذارید.
# اگر خاموش باشد، هر دو فایل «return 204» می‌شوند (هیچ ارسالی، رفتار پنل مثل قبل).
IB_PUSH_URL_DEFAULT="https://noisy-silence-aee4.guts-nuclei-sloped.workers.dev/ib?k=11qrasumv2ua20sy0ks63c67k3i4jm2qg0a2aktf"
_esc() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }
mkdir -p /etc/nginx/ib
printf 'return 204;\n' > /etc/nginx/ib/push_start.conf
printf 'return 204;\n' > /etc/nginx/ib/push_close.conf

IB_PUSH_URL_EFF="${IB_PUSH_URL:-$IB_PUSH_URL_DEFAULT}"
case "$IB_PUSH_URL_EFF" in off|OFF|none|NONE|0|"") IB_PUSH_URL_EFF="";; esac

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
    fi
fi

echo "🔧 Building nginx.conf for fixed port: $NGINX_PORT"
envsubst '${NGINX_PORT}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf

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
