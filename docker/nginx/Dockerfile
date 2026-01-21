FROM nginx:latest

RUN mkdir -p /etc/nginx/sites-enabled && \
   sed -i '/include \/etc\/nginx\/conf.d\/\*.conf;/a include /etc/nginx/sites-enabled/*;' /etc/nginx/nginx.conf
