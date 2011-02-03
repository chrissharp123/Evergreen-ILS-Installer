#!/bin/bash
# -----------------------------------------------------------------------
# Copyright (C) 2009  Equinox Software Inc.
# Bill Erickson <erickson@esilibrary.com>
# 
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# -----------------------------------------------------------------------

DOJO_VERSION='1.3.2';

# If you change the jabber password, you will need to 
# edit opensrf_core.xml and srfsh.xml accordingly
JABBER_PASSWORD='password'

BASE_DIR=$PWD

# And they're off...


# Make sure the system is configured to use UTF-8.  Otherwise, Postges setup will fail
if [[ ! $LANG =~ "UTF-8" ]]; then
    cat <<EOF
    Your system locale is not configured to use UTF-8.  This will cause problems with the PostgreSQL installation.  
    
    Do these steps (replace en_US with your locale):

    1. edit /etc/locale-gen and uncomment this line:
    en_US.UTF-8 UTF-8

    2. edit /etc/default/locale and set the follow variable:
    LANG=en_US.UTF-8

    3. run locale-gen
    4. log out
    5. log in
    6. Re-run this script
EOF
    exit;
fi;


# Install some essential tools
apt-get update; 
apt-get -yq dist-upgrade;
apt-get -yq install vim build-essential syslog-ng psmisc automake ntpdate subversion; 
ntpdate pool.ntp.org 
cp $BASE_DIR/evergreen.ld.conf /etc/ld.so.conf.d/
ldconfig;

# Create opensrf user and set up environment
if [ ! "$(grep ^opensrf: /etc/passwd)" ]; then
    useradd -m -s /bin/bash opensrf
    echo '
    export PERL5LIB=/openils/lib/perl5:$PERL5LIB
    export PATH=/openils/bin:$PATH
    export LD_LIBRARY_PATH=/openils/lib:/usr/local/lib:/usr/local/lib/dbd:$LD_LIBRARY_PATH
    export PS1="\[\033[01;32m\]\u@\h\[\033[01;34m\]% \[\033[00m\]";
    export EDITOR="vim";
    alias ls="ls --color=auto"
    ' >> /home/opensrf/.bashrc
fi;


# Force cpan config 
if [ ! "$(grep datapipe /etc/perl/CPAN/Config.pm)" ]; then
    cpan foo
    cd /etc/perl/CPAN/;
    patch -p0 < $BASE_DIR/CPAN_Config.pm.EG.patch
fi;

# Install pre-reqs
mkdir -p /usr/src/evergreen; 
cd /usr/src/evergreen;
wget 'http://svn.open-ils.org/trac/OpenSRF/export/HEAD/trunk/src/extras/Makefile.install'      -O Makefile.install.osrf
wget 'http://svn.open-ils.org/trac/ILS/export/HEAD/trunk/Open-ILS/src/extras/Makefile.install' -O Makefile.install.ils
make -f Makefile.install.osrf debian-lenny
make -f Makefile.install.ils  debian-lenny
make -f Makefile.install.ils  install_pgsql_server_debs_83


# Patch Ejabberd and register users
if [ ! "$(grep 'public.localhost' /etc/ejabberd/ejabberd.cfg)" ]; then
    cd /etc/ejabberd/
    /etc/init.d/ejabberd stop;
    killall beam epmd; # just in case
    cp ejabberd.cfg /root/ejabberd.cfg.orig
    patch -p0 < $BASE_DIR/ejabberd.lenny.EG.patch
    chown ejabberd:ejabberd ejabberd.cfg
    /etc/init.d/ejabberd start
    sleep 2;
    ejabberdctl register router  private.localhost $JABBER_PASSWORD
    ejabberdctl register opensrf private.localhost $JABBER_PASSWORD
    ejabberdctl register router  public.localhost  $JABBER_PASSWORD
    ejabberdctl register opensrf public.localhost  $JABBER_PASSWORD
fi;


# Build and install OpenSRF
OSRF_COMMAND='
mkdir /home/opensrf/OpenSRF;
mkdir /home/opensrf/ILS;
svn co svn://svn.open-ils.org/OpenSRF/trunk /home/opensrf/OpenSRF/trunk;
svn co svn://svn.open-ils.org/ILS/trunk     /home/opensrf/ILS/trunk;
cd /home/opensrf/OpenSRF/trunk;
./autogen.sh;
./configure --prefix=/openils --sysconfdir=/openils/conf;
make;'

su - opensrf sh -c "$OSRF_COMMAND"
cd /home/opensrf/OpenSRF/trunk
make install

# Build and install the ILS
OSRF_COMMAND='
cd /home/opensrf/ILS/trunk;
./autogen.sh;
./configure --prefix=/openils --sysconfdir=/openils/conf;
make;'

su - opensrf sh -c "$OSRF_COMMAND"
cd /home/opensrf/ILS/trunk;
make install
cp /openils/conf/oils_web.xml.example     /openils/conf/oils_web.xml
cp /openils/conf/opensrf.xml.example      /openils/conf/opensrf.xml
cp /openils/conf/opensrf_core.xml.example /openils/conf/opensrf_core.xml

# fetch and install Dojo
cd /tmp;
wget "http://download.dojotoolkit.org/release-$DOJO_VERSION/dojo-release-$DOJO_VERSION.tar.gz";
tar -zxf dojo-release-$DOJO_VERSION.tar.gz;
cp -r dojo-release-$DOJO_VERSION/* /openils/var/web/js/dojo/;

# give it all to opensrf
chown -R opensrf:opensrf /openils

# copy srfsh config into place
cp /openils/conf/srfsh.xml.example /home/opensrf/.srfsh.xml;
chown opensrf:opensrf /home/opensrf/.srfsh.xml;

# Create the DB
PG_COMMAND='
createdb -E UNICODE evergreen;
createlang plperl   evergreen;
createlang plperlu  evergreen;
createlang plpgsql  evergreen;
psql -f /usr/share/postgresql/8.3/contrib/tablefunc.sql evergreen;
psql -f /usr/share/postgresql/8.3/contrib/tsearch2.sql  evergreen;
psql -f /usr/share/postgresql/8.3/contrib/pgxml.sql     evergreen;
echo -e "\n\nPlease enter a password for the evergreen database user.  If you do not want to edit configs, use \"evergreen\"\n"
createuser -P -s evergreen;'
su - postgres sh -c "$PG_COMMAND"

# Apply the DB schema
cd /home/opensrf/ILS/trunk;
perl Open-ILS/src/support-scripts/eg_db_config.pl --update-config \
    --service all --create-schema --create-bootstrap --create-offline \
    --user evergreen --password evergreen --hostname localhost --database evergreen

# Copy apache configs into place and create SSL cert
cp Open-ILS/examples/apache/eg.conf       /etc/apache2/sites-available/
cp Open-ILS/examples/apache/eg_vhost.conf /etc/apache2/
cp Open-ILS/examples/apache/startup.pl    /etc/apache2/
if [ ! -d /etc/apache2/ssl ] ; then
    mkdir /etc/apache2/ssl
fi
if [ ! -f /etc/apache2/ssl/server.key ] ; then
    echo -e "\n\nConfiguring a new temporary SSL certificate....\n";
    openssl req -new -x509 -days 365 -nodes -out /etc/apache2/ssl/server.crt -keyout /etc/apache2/ssl/server.key
else
    echo -e "\nkeeping existing ssl/server.key file\n";
fi
a2enmod ssl  
a2enmod rewrite
a2enmod expires 

if [ ! "$(grep 'public.localhost' /etc/hosts)" ]; then
    cat <<EOF

* Add these lines to /etc/hosts.

127.0.1.2   public.localhost    public
127.0.1.3   private.localhost   private

EOF

else
    echo "INFO: /etc/hosts already has public.localhost line";
fi

cat <<EOF
* Start services

su - opensrf
osrf_ctl.sh -l -a start_router;
osrf_ctl.sh -l -a start_perl   && sleep 10;
osrf_ctl.sh -l -a start_c      && sleep  3;
/openils/bin/autogen.sh /openils/conf/opensrf_core.xml;

* Test the system

# as opensrf user
echo "request open-ils.cstore open-ils.cstore.direct.actor.user.retrieve 1" | srfsh

* Now finish configuring Apache

EOF


