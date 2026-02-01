FROM openresty/openresty:1.21.4.1-alpine

# 安装必要的依赖
RUN apk add --no-cache \
    curl \
    bash \
    unzip

#curl -fSL https://github.com/openresty/lua-resty-redis/archive/v0.30.tar.gz -o lua-resty-redis.tar.gz
#curl -fSL https://github.com/ledgetech/lua-resty-http/archive/v0.17.1.tar.gz -o lua-resty-http.tar.gz

ADD lua-resty-http.tar.gz /tmp/
ADD lua-resty-redis.tar.gz /tmp/

RUN cd /tmp \
    && cp -r lua-resty-http-0.17.1/lib/resty/* /usr/local/openresty/lualib/resty/ \
    && rm -rf lua-resty-http*

# 手动下载并安装 lua-resty-redis
RUN cd /tmp \
    && cp lua-resty-redis-0.30/lib/resty/redis.lua /usr/local/openresty/lualib/resty/ \
    && rm -rf lua-resty-redis*

# 创建必要的目录并链接日志到 stdout/stderr
RUN mkdir -p /usr/local/openresty/nginx/lua \
    && mkdir -p /var/log/nginx \
    && mkdir -p /usr/local/openresty/nginx/conf \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log

# 复制 Lua 脚本
COPY lua/*.lua /usr/local/openresty/nginx/lua/

# 复制 Nginx 配置
COPY conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

# 暴露端口
EXPOSE 8080

# 健康检查
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

# 启动 OpenResty
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
