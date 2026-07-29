# /opt/chatapp/nginx-upstream.conf.tpl
# deploy_local.sh substitutes __PORT__ with the live slot's port and writes the
# result to /etc/nginx/conf.d/chatapp-upstream.conf, then reloads nginx.
upstream chatapp_backend {
    server 127.0.0.1:__PORT__ max_fails=3 fail_timeout=10s;
    keepalive 32;
}

server {
    listen 443 ssl;
    server_name chat.internal.corp;

    ssl_certificate     /etc/nginx/tls/chatapp.crt;
    ssl_certificate_key /etc/nginx/tls/chatapp.key;

    location /health {
        proxy_pass http://chatapp_backend/health;
    }

    location / {
        proxy_pass http://chatapp_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Request-ID $request_id;   # correlate logs end-to-end
        proxy_read_timeout 120s;                     # LLM streaming responses
        proxy_buffering off;                         # required for SSE/streaming
    }
}
