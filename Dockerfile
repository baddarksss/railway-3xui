FROM alpine:3.22

# نسخه 3x-ui — برای آپدیت در آینده فقط همین عدد را عوض کنید
ARG XUI_VERSION=3.8.5

RUN apk add --no-cache \
    curl \
    bash \
    ca-certificates \
    socat \
    tzdata \
    sqlite \
    nginx \
    gettext \
    openssl \
    jq \
    fail2ban \
    iptables \
    && ln -sf /usr/share/zoneinfo/Asia/Tehran /etc/localtime

# دانلود و نصب 3x-ui
RUN curl -L https://github.com/mhsanaei/3x-ui/releases/download/v${XUI_VERSION}/x-ui-linux-amd64.tar.gz -o /tmp/x-ui.tar.gz \
    && tar -xzf /tmp/x-ui.tar.gz -C /usr/local/ \
    && rm /tmp/x-ui.tar.gz \
    && chmod +x /usr/local/x-ui/x-ui \
    && chmod +x /usr/local/x-ui/bin/* 2>/dev/null || true

RUN mkdir -p /etc/x-ui /var/log/x-ui

# پیکربندی fail2ban: jail های پیش‌فرض ssh را خاموش می‌کنیم
# (در کانتینر sshd وجود ندارد و باعث خطای استارت می‌شوند)
RUN rm -f /etc/fail2ban/jail.d/alpine-ssh.conf \
  && cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local \
  && sed -i "s/^\[ssh\]$/&\nenabled = false/" /etc/fail2ban/jail.local \
  && sed -i "s/^\[sshd\]$/&\nenabled = false/" /etc/fail2ban/jail.local \
  && sed -i "s/#allowipv6 = auto/allowipv6 = auto/g" /etc/fail2ban/fail2ban.conf

COPY nginx.conf.template /etc/nginx/nginx.conf.template
COPY start.sh /start.sh
COPY auto-sockopt.sh /auto-sockopt.sh
COPY sub-path-watch.sh /sub-path-watch.sh
RUN chmod +x /start.sh /auto-sockopt.sh /sub-path-watch.sh

# --- متغیرهای محیطی مورد نیاز نسخه 3.8.x ---
ENV TZ=Asia/Tehran
ENV XUI_IN_DOCKER="true"
ENV XUI_MAIN_FOLDER="/usr/local/x-ui"
ENV XUI_BIN_FOLDER="/usr/local/x-ui/bin"
ENV XUI_DB_FOLDER="/etc/x-ui"
ENV XUI_LOG_FOLDER="/var/log/x-ui"
# fail2ban برای فعال بودن قابلیت IP Limit لازم است.
# اگر Railway اجازه‌ی iptables ندهد، بن کردن عملی نمی‌شود ولی کادر IP Limit
# در پنل فعال می‌ماند و مقدارها صفر نمی‌شوند.
ENV XUI_ENABLE_FAIL2BAN="true"
# TLS توسط خود Railway ترمینیت می‌شود، پس HSTS پنل را رد می‌کنیم
ENV XUI_SKIP_HSTS="true"
# تنظیم خودکار sockopt.trustedXForwardedFor روی اینباندهای جدید
# برای خاموش کردن: XUI_AUTO_SOCKOPT=false
# توجه: مقدار این متغیر «نام هدر» است نه آدرس IP — Xray همین را چک می‌کند.
ENV XUI_AUTO_SOCKOPT="true"
# نگهبان مسیر ساب: هم‌گام‌سازی زندهٔ nginx با تغییرات Sub Path در پنل
# برای خاموش کردن: XUI_SUB_WATCH=false
ENV XUI_SUB_WATCH="true"
ENV XUI_TRUSTED_XFF="X-Forwarded-For"
ENV XUI_DB_TYPE=""
ENV XUI_DB_DSN=""

# نکته: دستور VOLUME عمداً حذف شده — Railway آن را نمی‌پذیرد.
# برای ماندگاری دیتابیس، از داشبورد Railway یک Volume روی مسیر /etc/x-ui وصل کنید.

# Railway پورت رو از طریق متغیر $PORT تزریق می‌کند
CMD ["/start.sh"]
