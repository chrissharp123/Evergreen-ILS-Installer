#!/bin/bash
# -----------------------------------------------------------------------
# Copyright (C) 2009  Equinox Software Inc.
# Bill Erickson <erickson@esilibrary.com>
# Modifications Copyright (c) 2011 Georgia Public Library Service 
# Chris Sharp <csharp@georgialibraries.org>
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
echo "This script will install OpenSRF and Evergreen on Debian 'squeeze'."
echo 
# we manually ask for these parameters without any checking, so a typo may = failure of script
# TODO: work in some regexes to check for proper format (at least) - or a numbered list to select from
#read -p "Which Linux distribution (currently supported: debian-lenny, debian-squeeze)? " DISTRO
read -p "Which packaged version of OpenSRF (e.g. '2.0.1')? " OSRF_VERSION
read -p "Which version (Git branch) of Evergreen-ILS (eg. '2.0.9', '2.1')? " EG_VERSION
read -p "What would you like to use for your Jabber password? " JABBER_PASSWORD
read -p "What would you like to use for your Evergreen admin user's name? " ADMIN_USER
read -p "What would you like your Evergreen admin user's password to be? " ADMIN_PASS

DISTRO='debian-squeeze'
PG_VERSION="9.0" # as of 2011-10-03
OSRF_TGZ="opensrf-$OSRF_VERSION.tar.gz"
EG_TGZ="Evergreen-ILS-$EG_VERSION.tar.gz"
OSRF_URL="http://evergreen-ils.org/downloads/$OSRF_TGZ"
# we'll change this to work with git instead
#EG_URL="http://evergreen-ils.org/downloads/$EG_TGZ"
GIT_URL="git://git.evergreen-ils.org/Evergreen.git"
DOJO_RELEASE="1.3.3"

# Define some directories
BASE_DIR=$PWD
WORKING_DIR="/home/opensrf"
EG_DIR="$WORKING_DIR/Evergreen"
OSRF_DIR="$WORKING_DIR/opensrf-$OSRF_VERSION"
SC_BUILD="rel_$(echo $EG_VERSION | tr "." "_")"

# copy the Jabber password into opensrf_core.xml.patch and srfsh.xml.patch
PatchOpenSRF () {
	if [ ! -e "$BASE_DIR/opensrf_core.xml.patch" ]; then	
		cp "$BASE_DIR/opensrf_core.xml.patch.example" "$BASE_DIR/opensrf_core.xml.patch" && sed -i "s^OpenSRF_Password^$JABBER_PASSWORD^g" "$BASE_DIR/opensrf_core.xml.patch" || {
		echo "ERROR: Could not create opensrf_core.xml.patch.";
		exit 1;
		}
	else
		echo "opensrf_core.xml.patch has already been created - please review that its settings are correct"
		sleep 2
		editor "$BASE_DIR/opensrf_core.xml.patch"
	fi
}

PatchSrfsh () {
	if [ ! -e "$BASE_DIR/srfsh.xml.patch" ]; then
		cp "$BASE_DIR/srfsh.xml.patch.example" "$BASE_DIR/srfsh.xml.patch" && sed -i "s^OpenSRF_Password^$JABBER_PASSWORD^g" "$BASE_DIR/srfsh.xml.patch" || {
		echo "ERROR: Could not create srfsh.xml.patch.";
		exit 1;
		}
	else
		echo "srfsh.xml.patch.example has already been created - please review that its settings are correct"
		sleep 2
		editor "$BASE_DIR/srfsh.xml.patch"
	fi
}

# customize the hosts file and move it into place
PatchHosts () {
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
}



# Make sure the system is configured to use UTF-8.  Otherwise, Postgres setup will fail
CheckLang () {
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
}

# Install some essential tools
# For Debian Squeeze: Note syslog-ng was removed since it now requires libdbi (squeeze=0.8.2), but if this version of 
# libdbi is installed, the later version installed for Evergreen (0.8.3) will not work.  
# You can hack in syslog-ng with something like this, but it will not survive package updates:
# $ apt-get install syslog-ng;
# $ apt-get remove libdbi0; # removes both, but leave them in the cache
# $ dpkg -i --ignore-depends=libdbi0  /var/cache/apt/archives/syslog-ng_3.1.1*.deb

InstallTools () {
	echo 'deb http://backports.debian.org/debian-backports squeeze-backports main contrib' >> /etc/apt/sources.list || {
		echo "Could not add backports repository line to /etc/apt/sources.list";
		exit 1;
	}
	apt-get update; 
	apt-get -yq dist-upgrade;
#	if [ $DISTRO == "debian-lenny" ]; then
#		apt-get -yq install vim build-essential syslog-ng psmisc automake ntpdate ; 
#	elif [ $DISTRO == "debian-squeeze" ]; then
	 apt-get -yq install vim build-essential autoconf libtool psmisc automake ntpdate git-core; 
#	fi
	ntpdate pool.ntp.org 
	cp $BASE_DIR/evergreen.ld.conf /etc/ld.so.conf.d/
	ldconfig;
# XXX: For some reason, when PG is installed with Makefile.install, the initial DB cluster templates 
# are created with Encoding SQL_ASCII, even though all locale settings (locale, $LANG, etc.) indicate UTF-8.
# This could be a Squeeze oddity or something going on in this script.
# Forcing the PG install manually up front avoids the problem.  Go figure.
#	apt-get -yq install postgresql-$PG_VERSION postgresql-client-$PG_VERSION
#	echo "Created PG cluster with databases:"
#	su - postgres sh -c "psql -l"
}

# Create opensrf user and set up environment
CreateOpenSRF () {
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
}

# Force cpan config 
ConfigCPAN () {
	if [ ! "$(grep datapipe /etc/perl/CPAN/Config.pm)" ]; then
    	cpan foo
    	cd /etc/perl/CPAN/;
    	patch -p0 < $BASE_DIR/CPAN_Config.pm.EG.patch
	fi;
}

# Net::Z3950::SimpleServer is still broken, so we install an older version before proceeding
SimpleServer () {
	cd /root
	apt-get install libyaz-dev
	wget http://search.cpan.org/CPAN/authors/id/M/MI/MIRK/Net-Z3950-SimpleServer-1.12.tar.gz
	tar xzf Net-Z3950-SimpleServer-1.12.tar.gz
	cd Net-Z3950-SimpleServer-1.12/
	perl Makefile.PL
	make &&	make install
} 

# Install pre-reqs
WgetTar () {
if [ ! -f "$WORKING_DIR/$OSRF_TGZ" ]; then
	OSRF_COMMAND="
	wget $OSRF_URL;
	tar xzf $OSRF_TGZ;"
	su - opensrf sh -c "$OSRF_COMMAND"
fi
# we don't want to do this if we're using git...
#if [ ! -f "$WORKING_DIR/$EG_TGZ" ]; then
#	OSRF_COMMAND="
#	wget $EG_URL;
#	tar xzf $EG_TGZ;"
#	su - opensrf sh -c "$OSRF_COMMAND"
#fi
}

GitEvergreen () {
if [ ! -d "$EG_DIR" ]; then
	ORSF_COMMAND="
	cd $WORKING_DIR
	git clone $GIT_URL"
	su - opensrf sh -c "$OSRF_COMMAND"
else
	read -p "$EG_DIR already exists... Continue (y/n)?" ANSWER
	if [ $ANSWER = "Y" -o $ANSWER = "y" ]; then
		echo "Continuing on, then."
	else
		echo "Exiting..." && exit 1;
	fi	
fi
OSRF_COMMAND="
cd $EG_DIR
git checkout $SC_BUILD"
su - opensrf sh -c "$OSRF_COMMAND"
}

InstallPreReqs () {	
cd $OSRF_DIR || {
	echo "ERROR: Cannot cd to OpenSRF directory.";
	exit 1;
	}
make -f src/extras/Makefile.install $DISTRO
#if [ $DISTRO == "debian-lenny" ]; then
#	cd $EG_DIR || {
#		echo "ERROR: Cannot cd to Evergreen-ILS directory.";
#		exit 1;
#	}
#	make -f Open-ILS/src/extras/Makefile.install $DISTRO
#	make -f Open-ILS/src/extras/Makefile.install install_pgsql_server_debs_83
#elif [ $DISTRO == "debian-squeeze" ]; then
#	wget 'http://svn.open-ils.org/trac/ILS/export/19421/tags/rel_2_0_1/Open-ILS/src/extras/Makefile.install' -O Makefile.install.ils
#	make -f Makefile.install.ils $DISTRO
cd $EG_DIR || {
	echo "ERROR: Cannot cd to Evergreen-ILS directory.";
	exit 1;
	}
make -f Open-ILS/src/extras/Makefile.install $DISTRO
make -f Open-ILS/src/extras/Makefile.install install_pgsql_server_debs_`echo $PG_VERSION | sed 's/\.//'`
#fi
}
# Patch Ejabberd and register users
ConfigEJabberd () {
	if [ ! "$(grep 'public.localhost' /etc/ejabberd/ejabberd.cfg)" ]; then
    		cd /etc/ejabberd/
    		/etc/init.d/ejabberd stop;
    		killall beam epmd; # just in case
    		cp ejabberd.cfg /root/ejabberd.cfg.orig
	fi
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
}


InstallOpenSRF () {
	OSRF_COMMAND="
	cd $OSRF_DIR;
	./configure --prefix=/openils --sysconfdir=/openils/conf;
	make;"
	su - opensrf sh -c "$OSRF_COMMAND"
	cd "$OSRF_DIR"
	make install
}

Autogen () {
	cd $EG_DIR
	./autogen.sh
}


InstallEG () {
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
}

InstallDojo () {
	wget http://download.dojotoolkit.org/release-$DOJO_RELEASE/dojo-release-$DOJO_RELEASE.tar.gz
	tar -C /openils/var/web/js -xzf dojo-release-$DOJO_RELEASE.tar.gz
	cp -r /openils/var/web/js/dojo-release-$DOJO_RELEASE/* /openils/var/web/js/dojo/.
}

# give it all to opensrf
ChownOpenSRF () {
	chown -R opensrf:opensrf /openils
	chown opensrf:opensrf /home/opensrf/.srfsh.xml;
}


# Create the DB
CreateDBUser () {
	PG_COMMAND="
	createuser -P -s evergreen;"
	su - postgres sh -c "$PG_COMMAND"
}


# Apply the DB schema
DBSchema () {
	cd $EG_DIR;
	perl Open-ILS/src/support-scripts/eg_db_config.pl --update-config \
    		--service all --create-database --create-schema --create-offline \
   		 --user evergreen --password evergreen --hostname localhost --database evergreen \
		 --admin-user $ADMIN_USER --admin-pass $ADMIN_PASS
}

# Copy apache configs into place and create SSL cert
ConfigApache () {
cp Open-ILS/examples/apache/eg.conf       /etc/apache2/sites-available/
cp Open-ILS/examples/apache/eg_vhost.conf /etc/apache2/
cp Open-ILS/examples/apache/startup.pl    /etc/apache2/
if [ ! -d /etc/apache2/ssl ] ; then
    mkdir /etc/apache2/ssl
else
    echo -e "\nApache SSL directory already exists.  Skipping...\n";
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
}

PatchOpenSRF
PatchSrfsh
PatchHosts
CheckLang
InstallTools
CreateOpenSRF
ConfigCPAN
SimpleServer
WgetTar
GitEvergreen
InstallPreReqs
ConfigEJabberd
InstallOpenSRF
Autogen
InstallEG
InstallDojo
ChownOpenSRF
CreateDBUser
DBSchema
ConfigApache

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
