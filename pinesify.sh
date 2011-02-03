#!/bin/bash
# ============================================================================
# PINES Customization script
#
# (c) 2011 Georgia Public Library Service
#
# This script will modify and replace files in a default Evergreen 1.6 
# installation to replicate the look and feel of the PINES production cluster.
#
# ============================================================================

BASE_DIR=$PWD
FILES_DIR=$BASE_DIR/PINES-files
PATCH_DIR=$BASE_DIR/PINES-Patches

# copy the PINES files into place
cd $FILES_DIR
for file in `cat files.list`; do
if [ -e "$file" ]
then
        mv "$file" "$file.$(date +%H%M_%m%d%Y)"
fi
cp "$FILES_DIR/$file" "$file";
done

# patch the files
cd $PATCH_DIR
for patch in `ls $PATCH_DIR`; do
patch -p0 < $patch;
done

# restart apache
/etc/init.d/apache2 restart

# restore file ownership to opensrf
chown -R opensrf:opensrf /openils

echo "Done." && exit

