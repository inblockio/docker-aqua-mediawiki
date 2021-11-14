
# Copy of https://github.com/wikimedia/mediawiki-docker/edit/master/1.36/apache/Dockerfile with PHP and MW versions changed
FROM php:8.0-apache as mw37

# System dependencies
RUN set -eux; \
	\
	apt-get update; \
	apt-get install -y --no-install-recommends \
		git \
		librsvg2-bin \
		imagemagick \
		# Required for SyntaxHighlighting
		python3 \
	; \
	rm -rf /var/lib/apt/lists/*

# Install the PHP extensions we need
RUN set -eux; \
	\
	savedAptMark="$(apt-mark showmanual)"; \
	\
	apt-get update; \
	apt-get install -y --no-install-recommends \
		libicu-dev \
		libonig-dev \
	; \
	\
	docker-php-ext-install -j "$(nproc)" \
		intl \
		mbstring \
		mysqli \
		opcache \
	; \
	\
	pecl install APCu-5.1.20; \
	docker-php-ext-enable \
		apcu \
	; \
	rm -r /tmp/pear; \
	\
	# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
	apt-mark auto '.*' > /dev/null; \
	apt-mark manual $savedAptMark; \
	ldd "$(php -r 'echo ini_get("extension_dir");')"/*.so \
		| awk '/=>/ { print $3 }' \
		| sort -u \
		| xargs -r dpkg-query -S \
		| cut -d: -f1 \
		| sort -u \
		| xargs -rt apt-mark manual; \
	\
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	rm -rf /var/lib/apt/lists/*

# Enable Short URLs
RUN set -eux; \
	a2enmod rewrite; \
	{ \
		echo "<Directory /var/www/html>"; \
		echo "  RewriteEngine On"; \
		echo "  RewriteCond %{REQUEST_FILENAME} !-f"; \
		echo "  RewriteCond %{REQUEST_FILENAME} !-d"; \
		echo "  RewriteRule ^ %{DOCUMENT_ROOT}/index.php [L]"; \
		echo "</Directory>"; \
	} > "$APACHE_CONFDIR/conf-available/short-url.conf"; \
	a2enconf short-url

# Enable AllowEncodedSlashes for VisualEditor
RUN sed -i "s/<\/VirtualHost>/\tAllowEncodedSlashes NoDecode\n<\/VirtualHost>/" "$APACHE_CONFDIR/sites-available/000-default.conf"

# set recommended PHP.ini settings
# see https://secure.php.net/manual/en/opcache.installation.php
RUN { \
		echo 'opcache.memory_consumption=128'; \
		echo 'opcache.interned_strings_buffer=8'; \
		echo 'opcache.max_accelerated_files=4000'; \
		echo 'opcache.revalidate_freq=60'; \
	} > /usr/local/etc/php/conf.d/opcache-recommended.ini

# SQLite Directory Setup
RUN set -eux; \
	mkdir -p /var/www/data; \
	chown -R www-data:www-data /var/www/data

# Version
ENV MEDIAWIKI_MAJOR_VERSION 1.37
ENV MEDIAWIKI_VERSION 1.37.0-rc.2

# MediaWiki setup
RUN set -eux; \
	fetchDeps=" \
		gnupg \
		dirmngr \
	"; \
	apt-get update; \
	apt-get install -y --no-install-recommends $fetchDeps; \
	\
	curl -fSL "https://releases.wikimedia.org/mediawiki/${MEDIAWIKI_MAJOR_VERSION}/mediawiki-${MEDIAWIKI_VERSION}.tar.gz" -o mediawiki.tar.gz; \
	curl -fSL "https://releases.wikimedia.org/mediawiki/${MEDIAWIKI_MAJOR_VERSION}/mediawiki-${MEDIAWIKI_VERSION}.tar.gz.sig" -o mediawiki.tar.gz.sig; \
	export GNUPGHOME="$(mktemp -d)"; \
# gpg key from https://www.mediawiki.org/keys/keys.txt
	gpg --batch --keyserver keyserver.ubuntu.com --recv-keys \
		D7D6767D135A514BEB86E9BA75682B08E8A3FEC4 \
		441276E9CCD15F44F6D97D18C119E1A64D70938E \
		F7F780D82EBFB8A56556E7EE82403E59F9F8CD79 \
		1D98867E82982C8FE0ABC25F9B69B3109D3BB7B0 \
	; \
	gpg --batch --verify mediawiki.tar.gz.sig mediawiki.tar.gz; \
	tar -x --strip-components=1 -f mediawiki.tar.gz; \
	gpgconf --kill all; \
	rm -r "$GNUPGHOME" mediawiki.tar.gz.sig mediawiki.tar.gz; \
	chown -R www-data:www-data extensions skins cache images; \
	\
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false $fetchDeps; \
	rm -rf /var/lib/apt/lists/*

CMD ["apache2-foreground"]





FROM mw37

# Define the MW_ROOT in MediaWiki as a variable name.
ENV MW_ROOT /var/www/html

# Make sure that existing software are updated and install development tools.
# The /etc/apt/preferences.d/no-debian-php is to ensure that we can install php-zip.
# We need php-zip so that Composer can install packages.
# TODO remove the /etc/apt/preferences.d/no-debian-php and apt-get -q install -y --no-install-recommends zip unzip php-zip once we upgrade to 1.36 because they are not necessary anymore.
RUN set -ex && \
    apt-get -q update && apt-get upgrade -y && \
    apt-get -q install -y --no-install-recommends nano vim ripgrep tig fd-find && \
    rm /etc/apt/preferences.d/no-debian-php && \
    apt-get -q install -y --no-install-recommends zip unzip php-zip && \
    apt-get -q install -y --no-install-recommends mariadb-client && \
    rm -rf /var/lib/apt/lists/*  # Remove unnecessary apt cache to keep the layer small

# Define working directory for the following commands
WORKDIR ${MW_ROOT}

# Copy Medik skin to skins/
COPY ./skins/Medik skins/Medik

# Copy extensions
COPY ./extensions extensions

# Copy the php.ini with desired upload_max_filesize into the php directory.
COPY ./resources/php.ini /usr/local/etc/php/php.ini
# Copy more assets and composer file.
COPY ./resources/aqua.png resources/assets/aqua.png
COPY ./composer.local.json composer.local.json

# Install the latest version of PHP package manager "Composer" and install
# MW-OAuth2Client from Git master.
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin/ --filename=composer && \
    composer update --no-dev && \
    cd extensions && \
    git clone https://github.com/rht/MW-OAuth2Client.git && \
    cd MW-OAuth2Client && \
    git submodule update --init && \
    cd vendors/oauth2-client && \
    composer install
