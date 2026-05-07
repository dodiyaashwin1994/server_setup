# RabbitMQ Management Proxy Snippet
location /rabbitmq/ {
    # Rewrite the path if RabbitMQ expects it at root
    # rewrite ^/rabbitmq/(.*)$ /$1 break;
    
    proxy_pass http://rabbitmq:15672/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}
