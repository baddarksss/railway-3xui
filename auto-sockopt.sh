#!/bin/bash
# ---------------------------------------------------------------------------
# auto-sockopt.sh
#
# پنل پشت nginx است، پس Xray فقط 127.0.0.1 را می‌بیند. برای اینکه IP واقعی
# کاربر در پنل ثبت شود، هر اینباند باید sockopt.trustedXForwardedFor داشته باشد.
#
# ⚠️ نکته‌ی مهم: مقدار این فیلد در Xray «نام هدر» است، نه آدرس IP.
# Xray چک می‌کند که هدری با آن نام وجود داشته باشد و بعد اولین آی‌پی داخل
# X-Forwarded-For را به عنوان آی‌پی کاربر برمی‌دارد. اگر اشتباهاً آی‌پی بگذارید
# (مثل "127.0.0.1")، Xray هدر را «جعلی» تشخیص می‌دهد، نادیده می‌گیرد و در نتیجه
# آی‌پی همه‌ی کاربرها 127.0.0.1 می‌شود که خود Xray دورش می‌ریزد → جدول IP پنل
# خالی می‌ماند.
#
# این اسکریپت دیتابیس را می‌پاید و هر اینباند جدیدی که بدون این تنظیم ساخته
# شود را خودکار اصلاح می‌کند، تا لازم نباشد دستی ست کنید.
#
# فقط اینباندهای ws / xhttp / httpupgrade را دست می‌زند (همان‌هایی که از
# nginx عبور می‌کنند). بقیه دست‌نخورده می‌مانند.
#
# اینباندهایی که مقدار قدیمی و غلط ["127.0.0.1"] را دارند هم خودکار اصلاح
# می‌شوند تا نصب‌های قبلی بدون کار دستی درست شوند.
# ---------------------------------------------------------------------------
set -u

DB="${XUI_DB_FOLDER:-/etc/x-ui}/x-ui.db"
TRUSTED="${XUI_TRUSTED_XFF:-X-Forwarded-For}"
INTERVAL="${XUI_SOCKOPT_INTERVAL:-20}"

echo "🔧 auto-sockopt: watching $DB (trustedXForwardedFor=$TRUSTED, every ${INTERVAL}s)"

# صبر تا ساخته شدن دیتابیس در اولین اجرا
for _ in $(seq 1 60); do
    [ -f "$DB" ] && break
    sleep 2
done
[ -f "$DB" ] || { echo "⚠️  auto-sockopt: database not found, exiting"; exit 0; }

fix_once() {
    # اینباندهایی که transport شان از nginx رد می‌شود ولی trustedXForwardedFor ندارند
    local rows
    rows=$(sqlite3 "$DB" "
        SELECT id FROM inbounds
        WHERE json_valid(stream_settings)
          AND json_extract(stream_settings, '\$.network') IN ('ws','xhttp','httpupgrade')
          AND (
                json_extract(stream_settings, '\$.sockopt.trustedXForwardedFor') IS NULL
             OR json_array_length(json_extract(stream_settings, '\$.sockopt.trustedXForwardedFor')) = 0
             OR json_extract(stream_settings, '\$.sockopt.trustedXForwardedFor[0]') = '127.0.0.1'
          );
    " 2>/dev/null)

    [ -z "$rows" ] && return 1

    local changed=0
    for id in $rows; do
        sqlite3 "$DB" "
            UPDATE inbounds
            SET stream_settings = json_set(
                    stream_settings,
                    '\$.sockopt.trustedXForwardedFor',
                    json_array('$TRUSTED')
                )
            WHERE id = $id;
        " 2>/dev/null && {
            echo "✅ auto-sockopt: applied trustedXForwardedFor to inbound id=$id"
            changed=1
        }
    done
    return $((1 - changed))
}

# ---------------------------------------------------------------------------
# پیدا کردن پروسه‌ی خود x-ui (پنل) و ریلود کردن Xray
#
# ⚠️ نکته ۱: سیگنال درست SIGUSR1 است، نه SIGHUP. در 3x-ui، SIGHUP فقط وب‌سرور
# پنل و سرور سابسکریپشن را ری‌استارت می‌کند و اصلاً به Xray کاری ندارد؛ فقط
# SIGUSR1 است که RestartXray() را صدا می‌زند. با SIGHUP تنظیم در دیتابیس ذخیره
# می‌شود ولی Xrayی که در حال اجراست تا ری‌استارت بعدی آن را نمی‌بیند (IP جدول
# پنل خالی می‌ماند).
#
# ⚠️ نکته ۲: به pkill/pgrep تکیه نمی‌کنیم. پنل با `./x-ui` اجرا می‌شود، پس
# cmdline آن «./x-ui» است و الگوی مسیری مثل /usr/local/x-ui/x-ui هیچ‌وقت مچ
# نمی‌شد؛ آنوقت خطا هم با `|| true` بی‌صدا رد می‌شد. اول از PIDی که start.sh
# پاس داده استفاده می‌کنیم، بعد به‌عنوان پشتیبان /proc را می‌گردیم.
# ---------------------------------------------------------------------------
xui_pids() {
    # PIDی که start.sh پاس داده (مطمئن‌ترین راه)
    if [ -n "${XUI_PID:-}" ] && [ -r "/proc/$XUI_PID/cmdline" ]; then
        echo "$XUI_PID"
    fi
    # پشتیبان: گشتن در /proc. دنبال توکنی می‌گردیم که «x-ui» یا «.../x-ui» باشد،
    # نه هر جایی که کلمه‌ی x-ui رد پایی دارد (مثل /etc/x-ui/x-ui.db یا نام خودِ
    # این اسکریپت). فقط argv[0] را نگاه نمی‌کنیم چون پروسه‌های اسکریپتی
    # (shebang) argv[0]شان خود مفسر است، نه نام اسکریپت.
    local d c tok p match
    for d in /proc/[0-9]*; do
        [ -r "$d/cmdline" ] || continue
        p=${d#/proc/}
        [ "$p" = "$$" ] && continue
        c=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null) || continue
        match=0
        for tok in $c; do
            case "$tok" in
                x-ui|*/x-ui) match=1; break;;
            esac
        done
        [ "$match" = "1" ] && echo "$p"
    done
}

reload_xray() {
    local pid sent=0
    for pid in $(xui_pids | sort -u); do
        if kill -USR1 "$pid" 2>/dev/null; then
            echo "🔁 auto-sockopt: signaled xray reload (USR1 -> pid $pid)"
            sent=$((sent + 1))
        fi
    done
    if [ "$sent" -eq 0 ]; then
        echo "⚠️  auto-sockopt: could not find the x-ui process to reload."
        echo "   trustedXForwardedFor is saved in the database, but the running"
        echo "   Xray will keep the old config until it is restarted:"
        echo "   panel -> Settings -> Restart Xray, or restart the service."
    fi
}

while true; do
    if fix_once; then
        reload_xray
    fi
    sleep "$INTERVAL"
done
