#!/bin/bash
echo "################ LANCEMENT DE L'INSTALL ###################################"
echo "################ UPDATE && UPGRADE && INSTALL #############################"
apt-get update && apt-get upgrade --yes && apt-get install --yes python-virtualenv libpq-dev python-dev postgresql postgresql-contrib nginx supervisor
echo "################ CREATION UTILISATEUR & VIRTUALENV ########################"
read -p 'Entrez le nom du site/projet (sans espace) : ' site
groupadd --system $site
useradd $site --system --gid $site --shell /bin/bash --home /website/$site
mkdir -p /website/$site
chown $site /website/$site
su - $site << EOF
mkdir -p /website/$site/
virtualenv /website/$site
source /website/$site/bin/activate
echo "################ INSTALLATION DE DJANGO & GUNICORN #######################"
pip install django psycopg2 gunicorn
django-admin startproject $site
mkdir -p /website/$site/logs/
EOF
echo "#!/bin/bash
NAME=\"$site\"
DJANGODIR=/website/$site/src
SOCKFILE=/website/$site/run/gunicorn.sock
USER=$site
GROUP=$site
NUM_WORKERS=3
DJANGO_SETTINGS_MODULE=$site.settings
DJANGO_WSGI_MODULE=$site.wsgi" >> /website/$site/bin/gunicorn_start
echo 'cd $DJANGODIR
source ../bin/activate
export DJANGO_SETTINGS_MODULE=$DJANGO_SETTINGS_MODULE
export PYTHONPATH=$DJANGODIR:$PYTHONPATH
 
RUNDIR=$(dirname $SOCKFILE)
test -d $RUNDIR || mkdir -p $RUNDIR
 
exec ../bin/gunicorn ${DJANGO_WSGI_MODULE}:application \
  --name $NAME \
  --workers $NUM_WORKERS \
  --user=$USER --group=$GROUP \
  --bind=unix:$SOCKFILE \
  --log-level=debug \
  --log-file=-' >> /website/$site/bin/gunicorn_start
  chmod u+x /website/$site/bin/gunicorn_start
chown $site /website/$site/bin/gunicorn_start

echo "################ CONFIGURATION DE LA DB ##################################"
read -p 'Entrer le nom d utilisateur de la BDD : ' user
read -p 'Entrer le nom de la base de donnée : ' bdd
su - postgres << EOF2
createuser $user -D -S -R -P
createdb --owner $user $bdd
EOF2
echo "[program:$site]
command = /website/$site/bin/gunicorn_start
user = $site
stdout_logfile = /website/$site/logs/gunicorn_supervisor.log
redirect_stderr = true
environment=LANG=en_US.UTF-8,LC_ALL=en_US.UTF-8" > /etc/supervisor/conf.d/$site.conf
supervisorctl reread
supervisorctl update
supervisorctl status $site
supervisorctl stop $site
supervisorctl start $site
read -p 'Entrez le nom de domaine sans le www (example.com) : ' domaine
echo "upstream $site {
  # fail_timeout=0 means we always retry an upstream even if it failed
  # to return a good HTTP response (in case the Unicorn master nukes a
  # single worker for timing out).
 
  server unix:/website/$site/run/gunicorn.sock fail_timeout=0;
}
 
server {
 
    listen   80;
    server_name $domaine;
 
    client_max_body_size 4G;
 
    access_log /website/$site/logs/nginx-access.log;
    error_log /website/$site/logs/nginx-error.log;
 
    location /static/ {
        alias   /website/$site/src/static/;
    }
    
    location /media/ {
        alias   /website/$site/src/media/;
    }" >> /etc/nginx/sites-available/$site
 echo 'location / {
        # an HTTP header important enough to have its own Wikipedia entry:
        #   http://en.wikipedia.org/wiki/X-Forwarded-For
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # enable this if and only if you use HTTPS, this helps Rack
        # set the proper protocol for doing redirects:
        # proxy_set_header X-Forwarded-Proto https;

        # pass the Host: header from the client right along so redirects
        # can be set properly within the Rack application
        proxy_set_header Host $http_host;

        # we don t want nginx trying to do something clever with
        # redirects, we set the Host: header above already.
        proxy_redirect off;

        # set "proxy_buffering off" *only* for Rainbows! when doing
        # Comet/long-poll stuff.  It s also safe to set if you re
        # using only serving fast clients with Unicorn + nginx.
        # Otherwise you _want_ nginx to buffer responses to slow
        # clients, really.
        # proxy_buffering off;

        # Try to serve static files from nginx, no point in making an
        # *application* server like Unicorn/Rainbows! serve static files.
        if (!-f $request_filename) {
' >> /etc/nginx/sites-available/$site
echo "		proxy_pass http://$site;
            break;
        }
    }
}" >> /etc/nginx/sites-available/$site
ln -s /etc/nginx/sites-available/$site /etc/nginx/sites-enabled/$site
service nginx restart 
