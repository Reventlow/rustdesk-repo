# Static package repository server. The build pipeline puts the finished
# repo tree in ./out; this image just serves it.
FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY out/ /usr/share/nginx/html/
