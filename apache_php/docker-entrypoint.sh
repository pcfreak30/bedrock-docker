#!/usr/bin/env bash

set -e
error=false
if [ -n "$MYSQL_PORT_3306_TCP" ]; then
	if [ -z "$DB_HOST" ]; then
		export DB_HOST='mysql:3306'
	else
		echo >&2 'warning: both WORDPRESS_DB_HOST and MYSQL_PORT_3306_TCP found'
		echo >&2 "  Connecting to WORDPRESS_DB_HOST ($WORDPRESS_DB_HOST)"
		echo >&2 '  instead of the linked mysql container'
	fi
fi

if [ -z "$DB_HOST" ]; then
	echo >&2 'error: missing WORDPRESS_DB_HOST and MYSQL_PORT_3306_TCP environment variables'
	echo >&2 '  Did you forget to --link some_mysql_container:mysql or set an external db'
	echo >&2 '  with -e WORDPRESS_DB_HOST=hostname:port?'
	error=true
fi

for env in "DB_NAME" "DB_USER" "DB_PASSWORD" "WP_HOME" "WP_SITEURL"; do
    if [ -z "${!env}" ]; then
        error=true
        echo >&2 "error: $env required"
    fi
done

if [ "$error" = true ]; then
     echo >&2 'errors occurred, existing'
    exit 1
fi

if ! [ -e "web/" -a -e "web/wp/wp-includes/version.php" ]; then
	echo >&2 "WordPress not found in $(pwd) - copying now..."
	if [ "$(ls -A)" ]; then
		echo >&2 "WARNING: $(pwd) is not empty - press Ctrl+C now if this is an error!"
		( set -x; ls -A; sleep 10 )
	fi
	tar cf - --one-file-system -C /usr/src/wordpress . | tar xf -
	echo >&2 "Complete! WordPress has been successfully copied to $(pwd)"
	echo >&2 "Running composer install in $(pwd)"
    composer install
    echo >&2 "Complete! Composer application has been successfully setup in $(pwd)"
	if [ ! -e web/.htaccess ]; then
		# NOTE: The "Indexes" option is disabled in the php:apache base image
		cat > web/.htaccess <<-'EOF'
			# BEGIN WordPress
			<IfModule mod_rewrite.c>
            RewriteEngine On
            RewriteBase /
            RewriteRule ^index\.php$ - [L]
            RewriteRule ^wp-admin$ wp-admin/ [R=301,L]
            RewriteCond %{REQUEST_FILENAME} -f [OR]
            RewriteCond %{REQUEST_FILENAME} -d
            RewriteRule ^ - [L]
            RewriteRule ^(.*\.php)$ /wp/$1 [L]
            RewriteRule ^(wp-(content|admin|includes).*)$ wp/$1 [L]
            RewriteRule . index.php [L]
			</IfModule>
			# END WordPress
		EOF
		chown www-data:www-data web/.htaccess
	fi
fi

# allow any of these "Authentication Unique Keys and Salts." to be specified via
# environment variables with a "WORDPRESS_" prefix (ie, "WORDPRESS_AUTH_KEY")
UNIQUES=(
	AUTH_KEY
	SECURE_AUTH_KEY
	LOGGED_IN_KEY
	NONCE_KEY
	AUTH_SALT
	SECURE_AUTH_SALT
	LOGGED_IN_SALT
	NONCE_SALT
)
for unique in "${UNIQUES[@]}"; do
	unique_value=${!unique}
	if [ ! -z "$unique_value" ]; then
	    eval "$unique_value=$(head -c1M /dev/urandom | sha1sum | cut -d' ' -f1)"
	    export "$unique"
	fi
done

TERM=dumb php -- "$DB_HOST" "$DB_USER" "$DB_PASSWORD" "$DB_NAME" <<'EOPHP'
<?php
// database might not exist, so let's try creating it (just to be safe)

$stderr = fopen('php://stderr', 'w');

list($host, $port) = explode(':', $argv[1], 2);

$maxTries = 10;
do {
	$mysql = new mysqli($host, $argv[2], $argv[3], '', (int)$port);
	if ($mysql->connect_error) {
		fwrite($stderr, "\n" . 'MySQL Connection Error: (' . $mysql->connect_errno . ') ' . $mysql->connect_error . "\n");
		--$maxTries;
		if ($maxTries <= 0) {
			exit(1);
		}
		sleep(3);
	}
} while ($mysql->connect_error);

if (!$mysql->query('CREATE DATABASE IF NOT EXISTS `' . $mysql->real_escape_string($argv[4]) . '`')) {
	fwrite($stderr, "\n" . 'MySQL "CREATE DATABASE" Error: ' . $mysql->error . "\n");
	$mysql->close();
	exit(1);
}

$mysql->close();
EOPHP

exec "$@"
