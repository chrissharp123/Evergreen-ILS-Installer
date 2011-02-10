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


# Check that we are root or are using sudo
[ $(whoami) != 'root' ] && echo 'Must run as root or with sudo' && exit;

# If you change the jabber password, you will need to 
# edit opensrf_core.xml and srfsh.xml accordingly
clear
echo "This script will install OpenSRF and Evergreen on Debian 'lenny'."
echo 
read -p "Which Linux distribution (currently supported: debian-lenny, debian-squeeze)? " DISTRO
read -p "Which version of OpenSRF (e.g. '1.6.2')? " OSRF_VERSION
read -p "Which version of Evergreen-ILS (eg. '1.6.1.4)? " EG_VERSION
read -p "What would you like to use for your Jabber password? " JABBER_PASSWORD

#DISTRO="debian-lenny"
PG_VERSION="8.4"
OSRF_TGZ="opensrf-$OSRF_VERSION.tar.gz"
EG_TGZ="Evergreen-ILS-$EG_VERSION.tar.gz"
OSRF_URL="http://evergreen-ils.org/downloads/$OSRF_TGZ"
EG_URL="http://evergreen-ils.org/downloads/$EG_TGZ"

# Define some directories
BASE_DIR=$PWD
WORKING_DIR="/home/opensrf"
EG_DIR="$WORKING_DIR/Evergreen-ILS-$EG_VERSION"
OSRF_DIR="$WORKING_DIR/opensrf-$OSRF_VERSION"
SC_BUILD="rel_$(echo $EG_VERSION | tr "." "_")"

# copy the Jabber password into opensrf_core.xml.patch and srfsh.xml.patch
if [ ! -e "$BASE_DIR/opensrf_core.xml.patch" ]; then	
	cp "$BASE_DIR/opensrf_core.xml.patch.example" "$BASE_DIR/opensrf_core.xml.patch" && sed -i "s^OpenSRF_Password^$JABBER_PASSWORD^g" "$BASE_DIR/opensrf_core.xml.patch" || {
	echo "ERROR: Could not create opensrf_core.xml.patch.";
	exit 1;
	}
else
	echo "opensrf_core.xml.patch has already been created - please review that its settings are correct"
	sleep 2
	vi "$BASE_DIR/opensrf_core.xml.patch"
fi

if [ ! -e "$BASE_DIR/srfsh.xml.patch" ]; then
	cp "$BASE_DIR/srfsh.xml.patch.example" "$BASE_DIR/srfsh.xml.patch" && sed -i "s^OpenSRF_Password^$JABBER_PASSWORD^g" "$BASE_DIR/srfsh.xml.patch" || {
	echo "ERROR: Could not create srfsh.xml.patch.";
	exit 1;
	}
else
	echo "srfsh.xml.patch.example has already been created - please review that its settings are correct"
	sleep 2
	vi "$BASE_DIR/srfsh.xml.patch"
fi

# customize the hosts file and move it into place
sed -i "s^hostname^$(hostname -s)^g" "$BASE_DIR/hosts.template" || {
	echo "ERROR: Could not substitute hostname in hosts.template"
	exit 1;
	}
sed -i "s^domain^$(hostname -d)^g" "$BASE_DIR/hosts.template" || {
        echo "ERROR: Could not substitute domain name in hosts.template"
        exit 1;
        }
mv /etc/hosts /etc/hosts.orig
cp "$BASE_DIR/hosts.template" /etc/hosts || {
        echo "ERROR: Could not move hosts file into place"
        exit 1;
        }

# And they're off...


# Make sure the system is configured to use UTF-8.  Otherwise, Postgres setup will fail
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
if [ $DISTRO == "debian-lenny" ]; then
	apt-get -yq install vim build-essential syslog-ng psmisc automake ntpdate subversion; 
elif [ $DISTRO == "debian-squeeze" ]; then
	apt-get -yq install vim build-essential psmisc automake ntpdate subversion; 
fi
# For Debian Squeeze: Note syslog-ng was removed since it now requires libdbi (squeeze=0.8.2), but if this version of 
# libdbi is installed, the later version installed for Evergreen (0.8.3) will not work.  
# You can hack in syslog-ng with something like this, but it will not survive package updates:
# $ apt-get install syslog-ng;
# $ apt-get remove libdbi0; # removes both, but leave them in the cache
# $ dpkg -i --ignore-depends=libdbi0  /var/cache/apt/archives/syslog-ng_3.1.1*.deb

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
OSRF_COMMAND="
wget $OSRF_URL;
tar xzf $OSRF_TGZ;
wget $EG_URL;
tar xzf $EG_TGZ;"
su - opensrf sh -c "$OSRF_COMMAND"
	cd $OSRF_DIR || {
		echo "ERROR: Cannot cd to OpenSRF directory.";
		exit 1;
	}
	make -f src/extras/Makefile.install $DISTRO
if [ $DISTRO == "debian-lenny" ]; then
	cd $EG_DIR || {
		echo "ERROR: Cannot cd to Evergreen-ILS directory.";
		exit 1;
	}
	make -f Open-ILS/src/extras/Makefile.install $DISTRO
	make -f Open-ILS/src/extras/Makefile.install install_pgsql_server_debs_83
elif [ $DISTRO == "debian-squeeze" ]; then
	wget 'http://svn.open-ils.org/trac/ILS/export/19421/tags/rel_2_0_1/Open-ILS/src/extras/Makefile.install' -O Makefile.install.ils
	make -f Makefile.install.ils $DISTRO
	make -f Open-ILS/src/extras/Makefile.install install_pgsql_server_debs_84
fi


# Patch Ejabberd and register users
if [ ! "$(grep 'public.localhost' /etc/ejabberd/ejabberd.cfg)" ]; then
    cd /etc/ejabberd/
    /etc/init.d/ejabberd stop;
    killall beam epmd; # just in case
    cp ejabberd.cfg /root/ejabberd.cfg.orig
	if [ "$DISTRO" == "debian-lenny" ]; then
    	patch -p0 < $BASE_DIR/ejabberd.lenny.EG.patch
	elif [ "$DISTRO" == "debian-squeeze" ]; then
		patch -p0 < $BASE_DIR/ejabberd.squeeze.EG.patch
	fi;   
	chown ejabberd:ejabberd ejabberd.cfg
    /etc/init.d/ejabberd start
    sleep 2;
    ejabberdctl register router  private.localhost $JABBER_PASSWORD
    ejabberdctl register opensrf private.localhost $JABBER_PASSWORD
    ejabberdctl register router  public.localhost  $JABBER_PASSWORD
    ejabberdctl register opensrf public.localhost  $JABBER_PASSWORD
fi;


OSRF_COMMAND="
cd $OSRF_DIR;
./configure --prefix=/openils --sysconfdir=/openils/conf;
make;"
su - opensrf sh -c "$OSRF_COMMAND"
cd "$OSRF_DIR"
make install

# Build and install the ILS
OSRF_COMMAND="
cd $EG_DIR;
./configure --prefix=/openils --sysconfdir=/openils/conf;
make;"

su - opensrf sh -c "$OSRF_COMMAND"
cd "$EG_DIR";
make STAFF_CLIENT_BUILD_ID=$SC_BUILD install
cp /openils/conf/oils_web.xml.example     /openils/conf/oils_web.xml
cp /openils/conf/opensrf.xml.example      /openils/conf/opensrf.xml
cp /openils/conf/opensrf_core.xml.example /openils/conf/opensrf_core.xml
cp /openils/conf/srfsh.xml.example	  /home/opensrf/.srfsh.xml
cd /openils/var/web/xul
ln -sf $SC_BUILD/server server
patch -p0 < $BASE_DIR/opensrf_core.xml.patch || {
	echo "Could not patch opensrf_core.xml.";
	exit 1;
}
patch -p0 < $BASE_DIR/srfsh.xml.patch || {
	 echo "Could not patch srfsh.xml."; 
	 exit 1;
}

# give it all to opensrf
chown -R opensrf:opensrf /openils
chown opensrf:opensrf /home/opensrf/.srfsh.xml;


# Create the DB
PG_COMMAND='
createdb -T template0 -E UNICODE evergreen;
createlang plperl   evergreen;
createlang plperlu  evergreen;
createlang plpgsql  evergreen;
psql -f /usr/share/postgresql/$PG_VERSION/contrib/tablefunc.sql evergreen;
psql -f /usr/share/postgresql/$PG_VERSION/contrib/tsearch2.sql  evergreen;
psql -f /usr/share/postgresql/$PG_VERSION/contrib/pgxml.sql     evergreen;
echo -e "\n\nPlease enter a password for the evergreen database user.  If you do not want to edit configs, use \"evergreen\"\n"
createuser -P -s evergreen;'
su - postgres sh -c "$PG_COMMAND"

# Apply the DB schema
cd $EG_DIR;
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

# patch the apache files:
patch -p0 < $BASE_DIR/eg.conf.patch
patch -p0 < $BASE_DIR/envvars.patch
patch -p0 < $BASE_DIR/apache2.conf.patch

# disable default site and enable Evergreen
a2dissite default
a2ensite eg.conf

echo "Restarting apache with new config...."
/etc/init.d/apache2 restart

if [ ! "$(grep 'public.localhost' /etc/hosts)" ]; then
    cat <<EOF

* The host file was not changed correctly.  Add these lines to /etc/hosts.

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

EOF
