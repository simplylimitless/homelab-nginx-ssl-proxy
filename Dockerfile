FROM nginx:stable

COPY ./nginx.conf /etc/nginx/nginx.conf

RUN mkdir -p /etc/nginx/sites-available \
             /etc/nginx/sites-enabled \
             /etc/letsencrypt/live \
             /etc/nginx/streams-enabled

EXPOSE 80 443

CMD ["nginx", "-g", "daemon off;"]
